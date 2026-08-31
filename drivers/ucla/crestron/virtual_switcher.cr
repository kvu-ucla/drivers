# UCLA-maintained copy of drivers/crestron/virtual_switcher.cr (vendored 2026-08-30 from ucla-dev @ ce19af2a18)
# Version 2.0.0 — documentation: virtual_switcher_readme.md
require "placeos-driver"
require "placeos-driver/interface/switchable"
require "placeos-driver/interface/muteable"
require "./nvx_models"

class Crestron::VirtualSwitcher < PlaceOS::Driver
  descriptive_name "Crestron Virtual Switcher (UCLA)"
  generic_name :Switcher
  description <<-DESC
    Routes video across Crestron NVX endpoints by reading the transmitter's
    advertised StreamLocation and writing it to the receiver's StreamReceive.
    Audio routing hands the transmitter's NAX (AES67) address to the
    configured audio sink.
  DESC

  include Interface::Switchable(String, Int32 | String)
  include Interface::Muteable

  default_settings({
    # friendly input name => transmitter module reference
    transmitters: {"PC" => "Encoder_1"},
    # friendly output name => receiver module reference
    receivers:  {"Projector" => "Decoder_1"},
    audio_sink: {
      module_id:     "Mixer_1",
      function_name: "set_string",
      arguments:     ["aes67_control_id"],
      named_args:    {} of String => JSON::Any,
    },
  })

  class AudioSink
    include JSON::Serializable

    getter module_id : String
    getter function_name : String
    getter arguments : Array(JSON::Any) { [] of JSON::Any }
    getter named_args : Hash(String, JSON::Any) { {} of String => JSON::Any }
  end

  @audio : AudioSink? = nil
  @transmitters = {} of String => String
  @receivers = {} of String => String
  # commanded intent: output name => input name (nil once blanked)
  @routes = {} of String => String?
  # observed truth, derived from each receiver's reported stream location
  @routes_actual = {} of String => String?
  @actual_locations = {} of String => String?
  # bumped on every settings load; stale subscription callbacks and in-flight
  # routes check it before recording state against the old topology
  @generation : UInt64 = 0_u64

  # Serializes topology rebuilds with callback/intent commits. The commit
  # paths suspend on redis (transmitter status reads, status publications), so
  # generation/mapping checks are only sound while this lock is held through
  # the mutation AND the publications - an unlocked check goes stale at the
  # first suspension point. Also prevents two on_update invocations from
  # interleaving their rebuild/subscribe sequences.
  @topology_lock = Mutex.new

  def on_update
    @topology_lock.synchronize do
      @audio = setting?(AudioSink, :audio_sink)
      @transmitters = setting?(Hash(String, String), :transmitters) || {} of String => String
      @receivers = setting?(Hash(String, String), :receivers) || {} of String => String

      generation = (@generation += 1)

      self[:inputs] = @transmitters.keys
      self[:outputs] = @receivers.keys

      # drop intent records for outputs no longer configured
      @routes.select! { |output, _| @receivers.has_key?(output) }
      self[:routes] = @routes

      # observations restart from one nil entry per configured receiver so the
      # published records always carry the full output key set; the receiver
      # subscriptions below repopulate them (including their initial values)
      @routes_actual = {} of String => String?
      @actual_locations = {} of String => String?
      @receivers.each_key do |output|
        @routes_actual[output] = nil
        @actual_locations[output] = nil
      end
      self[:routes_actual] = @routes_actual
      publish_derived_views

      # observe each receiver's reported stream location so `routes_actual`
      # tracks reality - including out-of-band changes made by device UIs,
      # reboots or other controllers
      subscriptions.clear
      @receivers.each do |output, rx_mod|
        system.subscribe(rx_mod, :stream_location) do |_sub, payload|
          location = (JSON.parse(payload).as_s? rescue nil)
          commit_observation(generation, output, rx_mod, location.try(&.presence))
        end
      end
    end
  end

  # Commit an observed receiver report. Callbacks dispatch asynchronously, so
  # one can arrive - or already be suspended mid-commit - after the topology
  # that registered it is gone; the predicate is re-checked while HOLDING the
  # topology lock so nothing can invalidate it before the publications land.
  protected def commit_observation(generation : UInt64, output : String, rx_mod : String, location : String?) : Nil
    @topology_lock.synchronize do
      return unless @generation == generation && @receivers[output]? == rx_mod
      update_actual_route(output, location)
    end
  end

  # dummy to supress errors in routing
  def power(state : Bool)
    state
  end

  def available_inputs
    @transmitters.keys
  end

  def available_outputs
    @receivers.keys
  end

  def switch_to(input : Input)
    @receivers.each_key { |output| route_one(input, output, SwitchLayer::All) }
  end

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    layer ||= SwitchLayer::All

    return unless layer.all? || layer.video? || layer.audio?

    logger.debug { "switching #{layer}: #{map}" }

    map.each do |input, outputs|
      outputs.each { |output| route_one(input, output, layer) }
    end
  end

  # only support muting the outputs, no unmuting
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo,
  )
    return unless state
    switch_layer = case layer
                   in MuteLayer::Audio      then SwitchLayer::Audio
                   in MuteLayer::Video      then SwitchLayer::Video
                   in MuteLayer::AudioVideo then SwitchLayer::All
                   end
    switch({"none" => [index]}, switch_layer)
  end

  BLANK_INPUTS = {"none", "break", "clear", "blank", "black", "0"}

  # Route a single input to a single output: one status read (the
  # transmitter's advertised stream location) and one write (the receiver's
  # StreamReceive) per route.
  protected def route_one(input : String, output : Int32 | String, layer : SwitchLayer) : Nil
    resolved = resolve_output(output)
    return unless resolved
    output_name, rx_mod = resolved
    generation = @generation
    rx = system[rx_mod]

    if BLANK_INPUTS.includes?(input.downcase)
      if layer.all?
        rx.switch_to("blank").get
      else
        rx.switch({"blank" => [] of Int32}, layer).get
      end
      # revalidate immediately after the wait, BEFORE any further side
      # effect - a stale blank must not touch the newly configured audio sink
      @topology_lock.synchronize do
        verify_topology!(generation, output_name, rx_mod)
        set_route_intent(output_name, nil) if layer.all? || layer.video?
      end
      switch_audio_to JSON::Any.new("") if layer.all? || layer.audio?
      return
    end

    tx_mod = @transmitters[input]?
    raise "no transmitter configured for input #{input.inspect}" unless tx_mod
    tx = system[tx_mod]

    if layer.all? || layer.video?
      location = (tx[:stream_location]?.try(&.as_s?) rescue nil).try(&.presence)
      raise "transmitter #{tx_mod} (#{input}) has not advertised a stream_location" unless location

      rx.switch_stream_location(location).get
      @topology_lock.synchronize do
        verify_topology!(generation, output_name, rx_mod)
        set_route_intent(output_name, input)
      end
    end

    if layer.all? || layer.audio?
      switch_audio_to((tx[:nax_address]? rescue nil))
    end
  end

  # Settings can change while a remote receiver call is in flight - recording
  # intent for a remapped or removed output would claim a route on a receiver
  # that was never commanded.
  protected def verify_topology!(generation : UInt64, output : String, rx_mod : String) : Nil
    return if @generation == generation && @receivers[output]? == rx_mod
    raise "topology changed while routing to #{output} (was #{rx_mod}) - route intent not recorded"
  end

  protected def resolve_output(output : Int32 | String) : Tuple(String, String)?
    case output
    in String
      if rx_mod = @receivers[output]?
        {output, rx_mod}
      else
        logger.warn { "could not find receiver for output #{output}" }
        nil
      end
    in Int32
      # legacy numeric addressing maps to the Decoder_<n> module reference
      mod = "Decoder_#{output}"
      if entry = @receivers.find { |_, rx_mod| rx_mod == mod }
        entry
      else
        logger.warn { "could not find receiver for output #{output} (no #{mod} configured)" }
        nil
      end
    end
  end

  protected def set_route_intent(output : String, input : String?) : Nil
    @routes[output] = input
    self[:routes] = @routes
  end

  protected def switch_audio_to(address : JSON::Any?)
    return unless address
    if sink = @audio
      args = sink.arguments + [address]
      system[sink.module_id].__send__(sink.function_name, args, sink.named_args)
    end
  end

  # Called whenever a receiver reports a new stream location - reverse-maps
  # the URI to the transmitter advertising it and republishes observed state.
  protected def update_actual_route(output : String, location : String?) : Nil
    input = input_for(location)
    @actual_locations[output] = location
    @routes_actual[output] = input
    self[:routes_actual] = @routes_actual

    intent = @routes[output]?
    if @routes.has_key?(output) && intent != input
      # message built eagerly: interpolating union locals inside the log
      # closure (captured within the surrounding synchronize block) segfaulted
      # in String#inspect - see fix round 2 notes
      mismatch = "route mismatch on #{output}: commanded #{intent || "(blank)"}, observed #{input || "(no stream)"}"
      logger.warn { mismatch }
    end

    publish_derived_views
  end

  # Reverse-map a reported stream location to the input advertising it.
  # `unknown:<uri>` when no configured transmitter matches.
  protected def input_for(location : String?) : String?
    return nil unless location.presence
    @transmitters.each do |input, tx_mod|
      advertised = (system[tx_mod][:stream_location]?.try(&.as_s?) rescue nil)
      return input if advertised.try(&.presence) == location
    end
    "unknown:#{location}"
  end

  protected def publish_derived_views : Nil
    detail = {} of String => NamedTuple(
      input: String?,
      tx_module: String?,
      rx_module: String,
      stream_location: String?,
      tx_host: String?,
      rx_host: String?)
    active = {} of String => Array(String)

    @receivers.each do |output, rx_mod|
      input = @routes_actual[output]?
      location = @actual_locations[output]?
      tx_mod = input ? @transmitters[input]? : nil

      detail[output] = {
        input:           input,
        tx_module:       tx_mod,
        rx_module:       rx_mod,
        stream_location: location,
        tx_host:         tx_mod.try { |mod| host_for(mod) },
        rx_host:         host_for(rx_mod),
      }

      if input && tx_mod
        (active[input] ||= [] of String) << output
      end
    end

    self[:routes_detail] = detail
    self[:transmitters_active] = active
  end

  # hosts come from the device's published device_info status - nil when the
  # module hasn't published one, never fabricated
  protected def host_for(mod : String) : String?
    (system[mod][:device_info]?.try(&.[]?("ip_address")).try(&.as_s?) rescue nil)
  end
end

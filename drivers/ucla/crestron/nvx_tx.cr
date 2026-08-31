# UCLA-maintained copy of drivers/crestron/nvx_tx.cr (vendored 2026-08-30 from ucla-dev @ ce19af2a18)
require "./cres_next"
require "placeos-driver/interface/switchable"

class Crestron::NvxTx < Crestron::CresNext # < PlaceOS::Driver
  enum Input
    None
    Input1
    Input2
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)
  include Crestron::Transmitter

  descriptive_name "Crestron NVX Transmitter (UCLA)"
  generic_name :Encoder
  description <<-DESC
    Crestron NVX network media encoder
  DESC

  uri_base "wss://192.168.0.5/websockify"

  protected def on_authenticated : Nil
    # NVX hardware can be confiured a either a RX or TX unit - check this
    # device is in the correct mode
    query("/DeviceSpecific/DeviceMode") do |mode|
      # "DeviceMode":"Transmitter|Receiver",
      next if mode == "Transmitter"
      logger.warn { "device configured as a #{mode}" }
      self[:WARN] = "device configured as a #{mode}. Expecting Transmitter"
    end

    # Refresh state now that we're authenticated. The *recurring* poll lives in
    # `connected` (see below) - not here - so it can't accumulate
    update_source_info
  end

  # The recurring background poll is registered here rather than in
  # `on_authenticated`. `connected` runs `schedule.clear` (via super) on every
  # (re)connect, so the schedule is re-armed cleanly. `on_authenticated` fires
  # on the independent HTTP-auth lifecycle, so registering a recurring task
  # there meant each re-auth added another schedule that was never cleared -
  # leaking schedules (and, under the old per-timer scheduler, a fiber each).
  def connected
    super

    # Background poll to remain in sync with any external routing changes
    schedule.every(5.minutes) { update_source_info }
  end

  def switch_to(input : Input)
    logger.debug { "switching to #{input}" }
    update(
      "/DeviceSpecific",
      {VideoSource: input, AudioSource: "AudioFollowsVideo"},
      name: :switch
    ).get
    update_source_info
  end

  def output(state : Bool)
    logger.debug { "#{state ? "enabling" : "disabling"} output sync" }

    update(
      "/AudioVideoInputOutput/Outputs",
      [{
        Ports: [{
          Hdmi: {IsOutputDisabled: !state},
        }],
      }],
      name: :output
    )
  end

  def multicast_address(address : String)
    logger.debug { "setting multicast address to #{address}" }
    update("/StreamTransmit/Streams", [{MulticastAddress: address}], name: :multicast_address)
  end

  # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/StreamTransmit.htm
  def stream_start
    logger.debug { "starting stream" }
    update("/StreamTransmit/Streams", [{Start: true}], name: :stream_start)
  end

  def stream_stop
    logger.debug { "stopping stream" }
    update("/StreamTransmit/Streams", [{Stop: true}], name: :stream_stop)
  end

  def emulate_input_sync(state : Bool = true, idx : Int32 = 1)
    self["input_#{idx}_sync"] = state
  end

  # Build friendly source names based on a device state.
  protected def query_source_name_for(type : SourceType)
    type_downcase = type.to_s.downcase
    query("/DeviceSpecific/Active#{type}Source", name: "#{type_downcase}_source") do |source_name|
      self["#{type_downcase}_source"] = source_name
    end
  end

  # Queries the stream state, including the advertised `StreamLocation` - the
  # RTSP URI receivers route to by POSTing it into their StreamReceive object.
  protected def query_stream_state
    query("/StreamTransmit/Streams", name: "streams") do |streams|
      publish_stream_state streams.as_a?.try(&.first?)
    end
  end

  # The device pushes partial updates, so only publish the properties present.
  protected def publish_stream_state(stream : JSON::Any?) : Nil
    stream = stream.try &.as_h?
    return unless stream

    if address = stream["MulticastAddress"]?
      self[:multicast_address] = address
    end
    if location = stream["StreamLocation"]?
      self[:stream_location] = location.as_s?.presence
    end
    if status = stream["Status"]?
      self[:stream_status] = status
    end
  end

  # this is the audio AES67 address
  # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/NaxAudio.htm
  protected def query_nax_address
    query("/NaxAudio/NaxTx/NaxTxStreams/Stream01/SessionNameStatus", name: "audio_name") do |stream|
      self["nax_address"] = stream
    end
  end

  protected def query_stream_name
    query("/Localization/Name", name: "stream_name") do |name|
      self["stream_name"] = name
    end
  end

  # Query the device for the current source state and update status vars.
  protected def update_source_info
    query_stream_name
    query_nax_address
    query_stream_state
    query_source_name_for(:video)
    query_source_name_for(:audio)
  end

  def received(data, task)
    raw_json = String.new data
    logger.debug { "Crestron sent: #{raw_json}" }

    return unless raw_json.includes?("AudioVideoInputOutput") || raw_json.includes?("StreamTransmit")
    raw_json.lines.each do |line|
      next if line.empty?

      begin
        payload = JSON.parse(line)

        # stream state (Status / StreamLocation / MulticastAddress) is pushed
        # when transmission starts, stops or is re-addressed
        if streams = payload.dig?("Device", "StreamTransmit", "Streams").try &.as_a?
          publish_stream_state streams.first?
        end

        # we're checking if a device is plugged into a port
        # Device/AudioVideoInputOutput/Inputs/0/Ports/0/IsSyncDetected
        if av_inputs = payload.dig?("Device", "AudioVideoInputOutput", "Inputs").try &.as_a?
          av_inputs.each do |input|
            name = input["Name"]?.try(&.as_s) || ""

            # Device returns inputs as "input0", "input1" ... "inputN" within
            # long poll responses, but appears to reference these same inputs
            # as "input-1", "input-2" ... "input-N" within direct state queries
            idx = case name
                  when /input(\d+)/
                    # increment by 1
                    $~[1].to_i.succ
                  when /input-(\d+)/
                    $~[1].to_i
                  else
                    # There also appears to be situations where no name is
                    # returned. As only the first input is in use across all
                    # encoders, default to input 1 as a nasty hack around
                    # this craziness.
                    1
                  end

            sync = input.dig?("Ports", 0, "IsSyncDetected").try &.as_bool?
            self["input_#{idx}_sync"] = sync unless sync.nil?
          end
        end
      rescue error
        logger.warn(exception: error) { "error parsing JSON:\n#{line}" }
      end
    end
  end
end

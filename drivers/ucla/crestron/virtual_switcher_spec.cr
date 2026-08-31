require "placeos-driver/spec"

# :nodoc:
class EncoderMock < DriverSpecs::MockDriver
  def advertise(location : String?)
    self[:stream_location] = location
  end
end

# :nodoc:
class DecoderMock < DriverSpecs::MockDriver
  def switch_stream_location(location : String)
    self[:last_location] = location
    self[:stream_location] = location
  end

  def switch_to(input : String)
    self[:input] = input
    self[:stream_location] = "" if input == "blank"
  end

  def switch(map : Hash(String, Array(JSON::Any)), layer : String? = nil)
    self[:switch_map] = map
  end
end

# :nodoc:
class MixerMock < DriverSpecs::MockDriver
  def set_string(id : String, value : String)
    self[:last_set] = [id, value]
  end
end

# :nodoc:
# Holds the switcher's remote `.get` long enough for the spec to change the
# topology underneath the in-flight route.
class SlowDecoderMock < DriverSpecs::MockDriver
  def switch_stream_location(location : String)
    sleep 2.seconds
    self[:last_location] = location
    self[:stream_location] = location
  end

  def switch_to(input : String)
    sleep 2.seconds
    self[:input] = input
    self[:stream_location] = "" if input == "blank"
  end
end

DriverSpecs.mock_driver "Crestron::VirtualSwitcher" do
  system({
    Encoder: {EncoderMock, EncoderMock},
    Decoder: {DecoderMock, DecoderMock},
    Slow:    {SlowDecoderMock},
    Mixer:   {MixerMock},
  })

  settings({
    transmitters: {
      "PC"     => "Encoder_1",
      "Laptop" => "Encoder_2",
    },
    receivers: {
      "Projector_Front"    => "Decoder_1",
      "Confidence_Monitor" => "Decoder_2",
    },
    audio_sink: {
      module_id:     "Mixer_1",
      function_name: "set_string",
      arguments:     ["aes67_control_id"],
      named_args:    {} of String => JSON::Any,
    },
  })

  # give the settings time to load and subscriptions time to register
  sleep 0.5

  status[:inputs].should eq(["PC", "Laptop"])
  status[:outputs].should eq(["Projector_Front", "Confidence_Monitor"])

  # the observed records are published immediately with the complete output
  # key set - never-routed receivers are present as nil, nothing is omitted
  status[:routes_actual].should eq({"Projector_Front" => nil, "Confidence_Monitor" => nil})
  status[:routes_detail].as_h.keys.sort!.should eq(status[:routes_actual].as_h.keys.sort!)
  status[:transmitters_active].should eq({} of String => Array(String))

  # transmitters advertise their stream locations + NAX audio addresses
  pc = system(:Encoder_1)
  laptop = system(:Encoder_2)
  pc[:stream_location] = "rtsp://10.0.0.1:554/live.sdp"
  pc[:nax_address] = "nax-pc"
  pc[:device_info] = {ip_address: "10.0.0.1"}
  laptop[:stream_location] = "rtsp://10.0.0.2:554/live.sdp"
  laptop[:nax_address] = "nax-laptop"

  d1 = system(:Decoder_1)
  d2 = system(:Decoder_2)
  d1[:device_info] = {ip_address: "10.0.1.1"}

  # ------------------------------------------------------------------
  # route: one read (tx stream_location) + one write (rx StreamReceive)
  # ------------------------------------------------------------------
  exec(:switch, {"PC" => ["Projector_Front"]}).get

  d1[:last_location].should eq("rtsp://10.0.0.1:554/live.sdp")
  status[:routes].should eq({"Projector_Front" => "PC"})
  system(:Mixer_1)[:last_set].should eq(["aes67_control_id", "nax-pc"])

  # observed truth derived from the rx's reported stream_location - complete
  # record, with the un-routed receiver still present as nil
  sleep 0.5
  status[:routes_actual].should eq({"Projector_Front" => "PC", "Confidence_Monitor" => nil})
  status[:routes_detail].as_h.keys.sort!.should eq(status[:routes_actual].as_h.keys.sort!)
  status[:transmitters_active].should eq({"PC" => ["Projector_Front"]})

  detail = status[:routes_detail]["Projector_Front"]
  detail["input"].should eq("PC")
  detail["tx_module"].should eq("Encoder_1")
  detail["rx_module"].should eq("Decoder_1")
  detail["stream_location"].should eq("rtsp://10.0.0.1:554/live.sdp")
  detail["tx_host"].should eq("10.0.0.1")
  detail["rx_host"].should eq("10.0.1.1")
  # Decoder_2 has no route and no device_info - nothing is fabricated
  status[:routes_detail]["Confidence_Monitor"]["input"].should eq(nil)
  status[:routes_detail]["Confidence_Monitor"]["rx_host"].should eq(nil)

  # second route via the friendly-name map form
  exec(:switch, {"Laptop" => ["Confidence_Monitor"]}).get
  d2[:last_location].should eq("rtsp://10.0.0.2:554/live.sdp")
  status[:routes].should eq({"Projector_Front" => "PC", "Confidence_Monitor" => "Laptop"})

  sleep 0.5
  status[:routes_actual].should eq({"Projector_Front" => "PC", "Confidence_Monitor" => "Laptop"})
  status[:transmitters_active].should eq({
    "PC"     => ["Projector_Front"],
    "Laptop" => ["Confidence_Monitor"],
  })

  # ------------------------------------------------------------------
  # out-of-band change: rx reports a location no configured tx advertises
  # ------------------------------------------------------------------
  d2[:stream_location] = "rtsp://172.16.9.9:554/rogue.sdp"
  sleep 0.5
  status[:routes_actual].should eq({
    "Projector_Front"    => "PC",
    "Confidence_Monitor" => "unknown:rtsp://172.16.9.9:554/rogue.sdp",
  })
  # intent is unchanged - the divergence is visible by comparing the records
  status[:routes]["Confidence_Monitor"].should eq("Laptop")
  status[:routes_detail]["Confidence_Monitor"]["tx_module"].should eq(nil)
  status[:transmitters_active].should eq({"PC" => ["Projector_Front"]})

  # ------------------------------------------------------------------
  # blank: clears the route intent, rx reports no stream
  # ------------------------------------------------------------------
  exec(:switch, {"none" => ["Projector_Front"]}).get
  d1[:input].should eq("blank")
  status[:routes]["Projector_Front"]?.should eq(nil)
  status[:routes]["Confidence_Monitor"].should eq("Laptop")

  sleep 0.5
  status[:routes_actual].should eq({
    "Projector_Front"    => nil,
    "Confidence_Monitor" => "unknown:rtsp://172.16.9.9:554/rogue.sdp",
  })
  status[:transmitters_active].should eq({} of String => Array(String))

  # ------------------------------------------------------------------
  # error cases are visible, not silent no-ops
  # ------------------------------------------------------------------
  laptop[:stream_location] = nil
  expect_raises(PlaceOS::Driver::RemoteException, /has not advertised a stream_location/) do
    exec(:switch, {"Laptop" => ["Projector_Front"]}).get
  end

  expect_raises(PlaceOS::Driver::RemoteException, /no transmitter configured/) do
    exec(:switch, {"Bluray" => ["Projector_Front"]}).get
  end

  # ------------------------------------------------------------------
  # switch_to routes an input to every configured output
  # ------------------------------------------------------------------
  exec(:switch_to, "PC").get
  d1[:last_location].should eq("rtsp://10.0.0.1:554/live.sdp")
  d2[:last_location].should eq("rtsp://10.0.0.1:554/live.sdp")
  status[:routes].should eq({"Projector_Front" => "PC", "Confidence_Monitor" => "PC"})

  sleep 0.5
  status[:routes_actual].should eq({"Projector_Front" => "PC", "Confidence_Monitor" => "PC"})

  # ------------------------------------------------------------------
  # topology change: remap Projector_Front to Decoder_2, remove the
  # Confidence_Monitor output entirely
  # ------------------------------------------------------------------
  settings({
    transmitters: {
      "PC"     => "Encoder_1",
      "Laptop" => "Encoder_2",
    },
    receivers: {
      "Projector_Front" => "Decoder_2",
    },
    audio_sink: {
      module_id:     "Mixer_1",
      function_name: "set_string",
      arguments:     ["aes67_control_id"],
      named_args:    {} of String => JSON::Any,
    },
  })
  sleep 0.5

  # records rebuilt for the new topology: removed output is gone everywhere,
  # and the new subscription's initial value (Decoder_2 still reports the PC
  # stream) repopulates the observed route
  status[:outputs].should eq(["Projector_Front"])
  status[:routes].should eq({"Projector_Front" => "PC"})
  status[:routes_actual].should eq({"Projector_Front" => "PC"})
  status[:routes_detail].as_h.keys.should eq(["Projector_Front"])
  status[:routes_detail]["Projector_Front"]["rx_module"].should eq("Decoder_2")
  status[:transmitters_active].should eq({"PC" => ["Projector_Front"]})

  # events from the previously mapped module must not pollute the new
  # topology - Decoder_1 is no longer subscribed and its output name now
  # points elsewhere
  d1[:stream_location] = "rtsp://10.0.0.2:554/live.sdp"
  sleep 0.5
  status[:routes_actual].should eq({"Projector_Front" => "PC"})
  status[:routes_detail].as_h.keys.should eq(["Projector_Front"])

  # ------------------------------------------------------------------
  # stale-callback commit race: each iteration registers a subscription
  # whose initial-value callback dispatches concurrently with an immediate
  # topology wipe. Whatever the interleaving, a callback from the old
  # generation must never commit into the new (empty) topology - the
  # under-lock re-check rejects late commits.
  # ------------------------------------------------------------------
  5.times do
    settings({
      transmitters: {
        "PC"     => "Encoder_1",
        "Laptop" => "Encoder_2",
      },
      receivers: {
        "Projector_Front" => "Decoder_2",
      },
      audio_sink: {
        module_id:     "Mixer_1",
        function_name: "set_string",
        arguments:     ["aes67_control_id"],
        named_args:    {} of String => JSON::Any,
      },
    })
    # no sleep: the Decoder_2 initial-value callback races the next update
    settings({
      transmitters: {
        "PC"     => "Encoder_1",
        "Laptop" => "Encoder_2",
      },
      receivers:  {} of String => String,
      audio_sink: {
        module_id:     "Mixer_1",
        function_name: "set_string",
        arguments:     ["aes67_control_id"],
        named_args:    {} of String => JSON::Any,
      },
    })
    sleep 0.6
    status[:routes_actual].should eq({} of String => String?)
    status[:routes_detail].should eq({} of String => String)
    status[:transmitters_active].should eq({} of String => Array(String))
  end

  # ------------------------------------------------------------------
  # topology change during an in-flight route (nonblank branch): the
  # receiver answers slowly; settings remove the output mid-wait. The
  # route must fail loudly and record nothing.
  # ------------------------------------------------------------------
  base_audio = {
    module_id:     "Mixer_1",
    function_name: "set_string",
    arguments:     ["aes67_control_id"],
    named_args:    {} of String => JSON::Any,
  }

  settings({
    transmitters: {"PC" => "Encoder_1", "Laptop" => "Encoder_2"},
    receivers:    {"Stage" => "Slow_1", "Aux" => "Decoder_1"},
    audio_sink:   base_audio,
  })
  sleep 0.5

  # a normal fast route seeds a known mixer state for the blank case below
  exec(:switch, {"PC" => ["Aux"]}).get
  system(:Mixer_1)[:last_set].should eq(["aes67_control_id", "nax-pc"])

  slow_route = exec(:switch, {"PC" => ["Stage"]})
  sleep 0.5 # the switcher is now blocked inside Slow_1's 2s answer

  settings({
    transmitters: {"PC" => "Encoder_1", "Laptop" => "Encoder_2"},
    receivers:    {} of String => String,
    audio_sink:   base_audio,
  })

  expect_raises(PlaceOS::Driver::RemoteException, /topology changed/) do
    slow_route.get
  end
  status[:routes].should eq({} of String => String?)
  status[:routes_actual].should eq({} of String => String?)

  # ------------------------------------------------------------------
  # topology change during an in-flight blank: the stale blank must fail
  # BEFORE touching the (potentially reconfigured) audio sink
  # ------------------------------------------------------------------
  settings({
    transmitters: {"PC" => "Encoder_1", "Laptop" => "Encoder_2"},
    receivers:    {"Stage" => "Slow_1"},
    audio_sink:   base_audio,
  })
  sleep 0.5

  slow_blank = exec(:switch, {"none" => ["Stage"]})
  sleep 0.5 # blocked inside Slow_1's 2s blank answer

  settings({
    transmitters: {"PC" => "Encoder_1", "Laptop" => "Encoder_2"},
    receivers:    {} of String => String,
    audio_sink:   base_audio,
  })

  expect_raises(PlaceOS::Driver::RemoteException, /topology changed/) do
    slow_blank.get
  end
  # the audio sink still holds the pre-blank route's value - the stale
  # blank did not write "" to it
  system(:Mixer_1)[:last_set].should eq(["aes67_control_id", "nax-pc"])
  status[:routes].should eq({} of String => String?)
end

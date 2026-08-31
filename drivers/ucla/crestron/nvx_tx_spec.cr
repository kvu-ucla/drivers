require "placeos-driver/spec"
require "uri"

DriverSpecs.mock_driver "Crestron::NvxTx" do
  settings({
    username: "admin",
    password: "admin",
  })

  # The driver authenticates over HTTP, then queries device state from
  # `on_authenticated` over the websocket. The driver isn't loaded in websocket
  # mode in specs, so we kick off authentication manually.
  exec :authenticate

  auth = URI::Params.build { |form|
    form.add("login", "admin")
    form.add("passwd", "admin")
  }

  expect_http_request do |request, response|
    io = request.body
    if io
      request_body = io.gets_to_end
      if request_body == auth
        response.status_code = 200
        response.headers["CREST-XSRF-TOKEN"] = "1234"
        cookies = response.cookies
        cookies["AuthByPasswd"] = "true"
        cookies["iv"] = "true"
        cookies["tag"] = "true"
        cookies["userid"] = "admin"
        cookies["userstr"] = "admin"
      else
        response.status_code = 401
      end
    else
      raise "expected request to include login form #{request.inspect}"
    end
  end

  # on_authenticated runs and queries device state
  should_send "/Device/DeviceSpecific/DeviceMode"
  responds %({"Device": {"DeviceSpecific": {"DeviceMode": "Transmitter"}}})

  should_send "/Device/Localization/Name"
  responds %({"Device": {"Localization": {"Name": "pc-in-rack"}}})

  should_send "/Device/NaxAudio/NaxTx/NaxTxStreams/Stream01/SessionNameStatus"
  responds %({"Device": {"NaxAudio": {"NaxTx": {"NaxTxStreams": {"Stream01": {"SessionNameStatus": "pc-in-rack"}}}}}})

  # The stream state query now also surfaces the advertised StreamLocation -
  # the value receivers use to route - and the reported stream status.
  should_send "/Device/StreamTransmit/Streams"
  responds %({"Device": {"StreamTransmit": {"Streams": [{"MulticastAddress": "192.168.0.2", "StreamLocation": "rtsp://192.168.0.5:554/live.sdp", "Status": "Streaming"}]}}})

  should_send "/Device/DeviceSpecific/ActiveVideoSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveVideoSource": "Input1"}}})

  should_send "/Device/DeviceSpecific/ActiveAudioSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveAudioSource": "Input1"}}})

  status[:stream_name].should eq("pc-in-rack")
  status[:nax_address].should eq("pc-in-rack")
  status[:multicast_address].should eq("192.168.0.2")
  status[:stream_location].should eq("rtsp://192.168.0.5:554/live.sdp")
  status[:stream_status].should eq("Streaming")
  status[:video_source].should eq("Input1")
  status[:audio_source].should eq("Input1")

  transmit %({"Device": {"AudioVideoInputOutput": {"Inputs": [
    {"Name": "input0", "Ports": [{"IsSyncDetected": true}]},
    {"Name": "input-2", "Ports": [{"IsSyncDetected": false}]}
  ]}}}).gsub(/\s/, "")

  status["input_1_sync"].should eq(true)
  status["input_2_sync"].should eq(false)

  # ------------------------------------------------------------------
  # StreamLocation routing additions
  # ------------------------------------------------------------------

  # Unsolicited stream state pushes update the advertised location/status
  # without touching properties the delta doesn't carry.
  transmit %({"Device":{"StreamTransmit":{"Streams":[{"Status":"Stopped","StreamLocation":""}]}}})

  status[:stream_status].should eq("Stopped")
  status[:stream_location]?.should be_nil
  status[:multicast_address].should eq("192.168.0.2")

  # stream_start / stream_stop POST the StreamTransmit commands over HTTP
  start_result = exec(:stream_start)
  expect_http_request do |request, response|
    request.method.should eq("POST")
    request.path.should eq("/Device/StreamTransmit/Streams")
    request.headers["CREST-XSRF-TOKEN"]?.should eq("1234")
    body = request.body.try(&.gets_to_end) || ""
    body.should eq(%({"Device":{"StreamTransmit":{"Streams":[{"Start":true}]}}}))
    response.status_code = 200
    response.print %({"Actions":[{"Results":[{"StatusId":9}]}]})
  end
  start_result.get

  stop_result = exec(:stream_stop)
  expect_http_request do |request, response|
    request.method.should eq("POST")
    request.path.should eq("/Device/StreamTransmit/Streams")
    body = request.body.try(&.gets_to_end) || ""
    body.should eq(%({"Device":{"StreamTransmit":{"Streams":[{"Stop":true}]}}}))
    response.status_code = 200
    response.print %({"Actions":[{"Results":[{"StatusId":9}]}]})
  end
  stop_result.get
end

require "placeos-driver/spec"

# Self-contained per-room driver: room_id comes from settings, status is flat.
# running_specs disables the event WebSocket (config.uri points at the mock HTTP
# server under test); basic_auth is kept so the Authorization header is added.

DriverSpecs.mock_driver "Zoom::ZRC::Controller" do
  settings({
    room_id:         "room-1",
    activation_code: "SET-CODE",
    running_specs:   true,
    basic_auth:      {username: "spec", password: "spec"},
  })

  it "should pair using an explicit activation code" do
    result = exec(:pair_room, "ACT-123")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/pair")
      body = JSON.parse(request.body.not_nil!)
      body["activation_code"].should eq("ACT-123")
      response.status_code = 200
      response << %({})
    end

    result.get
  end

  it "should pair using the activation_code setting when none is passed" do
    result = exec(:pair_room)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/pair")
      body = JSON.parse(request.body.not_nil!)
      body["activation_code"].should eq("SET-CODE")
      response.status_code = 200
      response << %({})
    end

    result.get
  end

  it "should get room status" do
    result = exec(:get_room_status)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/status")
      response.status_code = 200
      response << %({"status": "available"})
    end

    result.get
    status[:room_status].should_not be_nil
  end

  it "should join a meeting with basic auth" do
    result = exec(:join_meeting, "123456789", "password", false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/join")
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["meeting_number"].should eq("123456789")
      body["password"].should eq("password")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:meeting_active].should eq(true)
  end

  it "should start an instant meeting" do
    result = exec(:start_instant_meeting)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/start_instant")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:meeting_active].should eq(true)
  end

  it "should start a scheduled meeting, omitting unset fields and parsing the response" do
    result = exec(:start_meeting, "999888777")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/start")
      body = JSON.parse(request.body.not_nil!).as_h
      body["meeting_number"].should eq("999888777")
      body.has_key?("meeting_name").should be_false
      body.has_key?("bring_share").should be_false
      response.status_code = 200
      response << %({"meeting_number": "999888777", "host_name": "Alice"})
    end

    meeting = result.get.not_nil!
    meeting["meeting_number"].should eq("999888777")
    meeting["host_name"].should eq("Alice")
    status[:meeting_active].should eq(true)
  end

  it "should mute audio via the mute query param" do
    result = exec(:mute_audio, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/mute")
      request.query_params["mute"].should eq("true")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    status[:mic_mute].should eq(true)
  end

  it "should stop (mute) video via the stop query param" do
    result = exec(:mute_video, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/mute")
      request.query_params["stop"].should eq("true")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    status[:camera_mute].should eq(true)
  end

  it "should set speaker volume" do
    result = exec(:set_speaker_volume, 75.0)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/settings/volume/speaker")
      body = JSON.parse(request.body.not_nil!)
      body["volume"].should eq(75.0)
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(75.0)
    status[:speaker_volume].should eq(75.0)
  end

  it "should start cloud recording" do
    result = exec(:start_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:recording].should eq("started")
  end

  it "should stop cloud recording" do
    result = exec(:stop_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/stop")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:recording].should eq("stopped")
  end

  it "should list calendar meetings and expose them as status" do
    result = exec(:list_meetings)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meetings/list")
      response.status_code = 200
      response << %({"room_id": "room-1", "list_success": true, "meetings": [{"meetingName": "Standup", "meetingNumber": "123"}]})
    end

    data = result.get.not_nil!
    data["list_success"].should eq(true)
    status[:meetings].should_not be_nil
  end

  it "should get participants" do
    result = exec(:get_participants)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %([{"user_id": 1, "name": "Alice"}])
    end

    result.get.should_not be_nil
    status[:participants].should_not be_nil
  end

  it "should confirm a consent prompt and clear its status" do
    result = exec(:confirm_consent, 2, true, "consent-9")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/confirm-consent")
      body = JSON.parse(request.body.not_nil!)
      body["is_agree"].should eq(true)
      body["consent_type"].should eq(2)
      body["consent_id"].should eq("consent-9")
      response.status_code = 200
      response << %({"success": true})
    end

    result.get
    status[:consent_prompt]?.should be_nil
  end

  it "should respond to a recording request" do
    result = exec(:respond_to_recording_request, true, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/respond-to-request")
      body = JSON.parse(request.body.not_nil!)
      body["agree"].should eq(true)
      body["is_persist"].should eq(false)
      response.status_code = 200
      response << %({"agreed": true})
    end

    result.get
    status[:recording_request]?.should be_nil
  end

  it "should cancel waiting for host" do
    result = exec(:cancel_waiting_for_host)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/cancel-waiting-host")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:waiting_for_host]?.should be_nil
  end

  it "should exit a meeting and reconcile meeting state from the device" do
    result = exec(:exit_meeting)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/exit")
      response.status_code = 200
      response << %({})
    end

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %(null)
    end

    result.get
    status[:meeting_active].should eq(false)
  end

  it "should mark the room offline when unpaired" do
    result = exec(:unpair_room)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/unpair")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:online].should eq(false)
  end
end

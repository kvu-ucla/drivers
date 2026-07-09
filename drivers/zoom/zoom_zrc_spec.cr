require "placeos-driver/spec"

# The gateway is a single shared instance driving many rooms by room_id. Every
# room-scoped call takes a room_id and status is namespaced per room, so these
# specs use an explicit room id ("room-1") and assert on "room-1/<key>" status.

DriverSpecs.mock_driver "Zoom::ZRC::Controller" do
  # disable the per-room event WebSockets: config.uri points at the spec's mock
  # HTTP server, so a WS handshake would collide with the HTTP expectations.
  # basic_auth is kept so the transport still adds the Authorization header.
  settings({
    running_specs: true,
    basic_auth:    {username: "spec", password: "spec"},
  })

  it "should pair a room with an activation code" do
    result = exec(:pair_room, "room-1", "ACT-123")

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

  it "should get room status into a namespaced key" do
    result = exec(:get_room_status, "room-1")

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/status")
      response.status_code = 200
      response << %({"status": "available"})
    end

    result.get
    status["room-1/room_status"].should_not be_nil
  end

  it "should join a meeting with basic auth" do
    result = exec(:join_meeting, "room-1", "123456789", "password", false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/join")
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["meeting_number"].should eq("123456789")
      body["password"].should eq("password")
      body["bring_share"].should eq(false)
      response.status_code = 200
      response << %({})
    end

    result.get
    status["room-1/meeting_active"].should eq(true)
  end

  it "should start an instant meeting" do
    result = exec(:start_instant_meeting, "room-1")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/start_instant")
      response.status_code = 200
      response << %({})
    end

    result.get
    status["room-1/meeting_active"].should eq(true)
  end

  it "should start a scheduled meeting, omitting unset fields and parsing the response" do
    result = exec(:start_meeting, "room-1", "999888777")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/start")
      body = JSON.parse(request.body.not_nil!).as_h
      body["meeting_number"].should eq("999888777")
      # optional fields are omitted from the body when not provided
      body.has_key?("meeting_name").should be_false
      body.has_key?("bring_share").should be_false
      response.status_code = 200
      response << %({"meeting_number": "999888777", "host_name": "Alice"})
    end

    meeting = result.get.not_nil!
    meeting["meeting_number"].should eq("999888777")
    meeting["host_name"].should eq("Alice")
    status["room-1/meeting_active"].should eq(true)
  end

  it "should mute audio via the mute query param and reflect it" do
    result = exec(:mute_audio, "room-1", true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/mute")
      request.query_params["mute"].should eq("true")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    status["room-1/mic_mute"].should eq(true)
  end

  it "should not clobber another room's namespaced state" do
    result = exec(:mute_audio, "room-2", false)

    expect_http_request do |request, response|
      request.path.should eq("/api/rooms/room-2/audio/mute")
      request.query_params["mute"].should eq("false")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(false)
    status["room-2/mic_mute"].should eq(false)
    # room-1 is untouched
    status["room-1/mic_mute"].should eq(true)
  end

  it "should stop (mute) video via the stop query param" do
    result = exec(:mute_video, "room-1", true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/mute")
      request.query_params["stop"].should eq("true")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    status["room-1/camera_mute"].should eq(true)
  end

  it "should start (unmute) video via stop=false" do
    result = exec(:mute_video, "room-1", false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/mute")
      request.query_params["stop"].should eq("false")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(false)
    status["room-1/camera_mute"].should eq(false)
  end

  it "should set speaker volume" do
    result = exec(:set_speaker_volume, "room-1", 75.0)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/settings/volume/speaker")
      body = JSON.parse(request.body.not_nil!)
      body["volume"].should eq(75.0)
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(75.0)
    status["room-1/speaker_volume"].should eq(75.0)
  end

  it "should set microphone volume" do
    result = exec(:set_microphone_volume, "room-1", 60.0)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/settings/volume/microphone")
      body = JSON.parse(request.body.not_nil!)
      body["volume"].should eq(60.0)
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(60.0)
    status["room-1/microphone_volume"].should eq(60.0)
  end

  it "should start cloud recording" do
    result = exec(:start_recording, "room-1")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 200
      response << %({})
    end

    result.get
    status["room-1/recording"].should eq("started")
  end

  it "should stop cloud recording" do
    result = exec(:stop_recording, "room-1")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/stop")
      response.status_code = 200
      response << %({})
    end

    result.get
    status["room-1/recording"].should eq("stopped")
  end

  it "should get participants" do
    result = exec(:get_participants, "room-1")

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %([{"user_id": 1, "name": "Alice"}])
    end

    result.get.should_not be_nil
    status["room-1/participants"].should_not be_nil
  end

  it "should wake up the room" do
    result = exec(:wake_up, "room-1")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/pre-meeting/wake-up")
      response.status_code = 200
      response << %({})
    end

    result.get
  end

  it "should exit a meeting and reconcile meeting state from the device" do
    result = exec(:exit_meeting, "room-1")

    # the exit command itself
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/exit")
      response.status_code = 200
      response << %({})
    end

    # reconcile: re-read meeting status; device reports no active meeting
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %(null)
    end

    result.get
    status["room-1/meeting_active"].should eq(false)
  end

  it "should mark the room offline when unpaired" do
    result = exec(:unpair_room, "room-1")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/unpair")
      response.status_code = 200
      response << %({})
    end

    result.get
    status["room-1/online"].should eq(false)
  end
end

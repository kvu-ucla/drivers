require "placeos-driver/spec"

DriverSpecs.mock_driver "Zoom::ZRC::Controller" do
  it "should join a meeting with basic auth" do
    result = exec(:join_meeting, "123456789", "password", false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/meeting/join")
      request.headers["Authorization"]?.should_not be_nil
      body = JSON.parse(request.body.not_nil!)
      body["meeting_number"].should eq("123456789")
      body["password"].should eq("password")
      body["bring_share"].should eq(false)
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
      request.path.should eq("/api/rooms/default/meeting/start_instant")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:meeting_active].should eq(true)
  end

  it "should exit a meeting" do
    result = exec(:exit_meeting)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/meeting/exit")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:meeting_active].should eq(false)
  end

  it "should mute audio" do
    result = exec(:mute_audio, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/audio/mute")
      body = JSON.parse(request.body.not_nil!)
      body["mute"].should eq(true)
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    status[:mic_mute].should eq(true)
  end

  it "should unmute audio" do
    result = exec(:mute_audio, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/audio/mute")
      body = JSON.parse(request.body.not_nil!)
      body["mute"].should eq(false)
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(false)
    status[:mic_mute].should eq(false)
  end

  it "should mute video (toggle API called when state differs)" do
    # camera_mute is currently false (unset), muting to true should call API
    result = exec(:mute_video, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/video/mute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    status[:camera_mute].should eq(true)
  end

  it "should skip video mute API when state already matches" do
    # camera_mute was set to true above; calling mute_video(true) again should not hit the API
    result = exec(:mute_video, true)
    result.get.should eq(true)
    status[:camera_mute].should eq(true)
  end

  it "should set speaker volume" do
    result = exec(:set_speaker_volume, 75.0)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/settings/volume/speaker")
      body = JSON.parse(request.body.not_nil!)
      body["volume"].should eq(75.0)
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(75.0)
    status[:speaker_volume].should eq(75.0)
  end

  it "should set microphone volume" do
    result = exec(:set_microphone_volume, 60.0)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/settings/volume/microphone")
      body = JSON.parse(request.body.not_nil!)
      body["volume"].should eq(60.0)
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(60.0)
    status[:microphone_volume].should eq(60.0)
  end

  it "should start cloud recording" do
    result = exec(:start_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/recording/cloud/start")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:recording].should eq("started")
  end

  it "should pause cloud recording" do
    result = exec(:pause_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/recording/cloud/pause")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:recording].should eq("paused")
  end

  it "should resume cloud recording" do
    result = exec(:resume_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/recording/cloud/resume")
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
      request.path.should eq("/api/rooms/default/recording/cloud/stop")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:recording].should eq("stopped")
  end

  it "should get participants" do
    result = exec(:get_participants)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/default/participants/")
      response.status_code = 200
      response << %([{"user_id": 1, "name": "Alice"}])
    end

    participants = result.get
    participants.should_not be_nil
    status[:participants].should_not be_nil
  end

  it "should wake up the room" do
    result = exec(:wake_up)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/default/pre-meeting/wake-up")
      response.status_code = 200
      response << %({})
    end

    result.get
  end

  it "should get room status" do
    result = exec(:get_room_status)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/default/status")
      response.status_code = 200
      response << %({"status": "available"})
    end

    result.get
    status[:room_status].should_not be_nil
  end
end

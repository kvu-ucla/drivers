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

  it "should join a meeting by url without the removed bring_share argument" do
    result = exec(:join_meeting_by_url, "https://zoom.us/j/123456789")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/join-url")
      request.query_params["url"].should eq("https://zoom.us/j/123456789")
      request.query_params.has_key?("bring_share").should be_false
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:meeting_active].should eq(true)
  end

  it "should turn on ai companion with the required features bitmask" do
    result = exec(:ai_companion_on, 32)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/turn-on")
      request.query_params["features"].should eq("32")
      response.status_code = 200
      response << %({})
    end

    result.get
  end

  it "should turn off ai companion with features and delete_assets" do
    result = exec(:ai_companion_off, 32, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/turn-off")
      request.query_params["features"].should eq("32")
      request.query_params["delete_assets"].should eq("true")
      response.status_code = 200
      response << %({})
    end

    result.get
  end

  it "should answer an AI companion turn-on request without toggling directly" do
    result = exec(:respond_to_ai_companion_request, 2, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/respond-to-turn-on")
      request.query_params["agree"].should eq("false")
      request.query_params.has_key?("delete_assets").should be_false
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:ai_companion_request]?.should be_nil
  end

  it "should answer an AI companion turn-off request with the asset choice" do
    result = exec(:respond_to_ai_companion_request, 1, true, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/respond-to-turn-off")
      request.query_params["agree"].should eq("true")
      request.query_params["delete_assets"].should eq("true")
      response.status_code = 200
      response << %({})
    end

    result.get
  end

  it "should confirm the AI companion state shown when the host joins" do
    result = exec(:confirm_ai_companion_status, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/confirm-status-when-join")
      request.query_params["agree"].should eq("false")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:ai_companion_confirm]?.should be_nil
  end

  it "should mute audio via the mute endpoint" do
    result = exec(:mute_audio, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/mute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    status[:mic_mute].should eq(true)
  end

  it "should unmute audio via the unmute endpoint" do
    result = exec(:mute_audio, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/unmute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(false)
    status[:mic_mute].should eq(false)
  end

  it "should stop (mute) video via the mute endpoint" do
    result = exec(:mute_video, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/mute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    status[:camera_mute].should eq(true)
  end

  it "should start (unmute) video via the unmute endpoint" do
    result = exec(:mute_video, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/unmute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(false)
    status[:camera_mute].should eq(false)
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

  it "should surface a disclaimer gate without accepting it automatically" do
    result = exec(:start_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 409
      response << %({"detail": {"message": "Recording disclaimer required before starting cloud recording", "precheck": {"disclaimer_check_result": 0, "disclaimer_needed": true}, "next_step": "POST /api/rooms/{room_id}/recording/prompt-disclaimer"}})
    end

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/prompt-disclaimer")
      response.status_code = 200
      response << %({"message": "Recording disclaimer prompt sent"})
    end

    response = result.get.not_nil!
    response["recording_started"].should eq(false)
    response["disclaimer_needed"].should eq(true)
    status[:recording_disclaimer_needed].should eq(true)
  end

  it "should clear a stale disclaimer status when the wrapper reports false" do
    result = exec(:check_recording_disclaimer)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/recording/disclaimer-needed")
      response.status_code = 200
      response << %({"disclaimer_needed": false})
    end

    result.get.not_nil!["disclaimer_needed"].should eq(false)
    status[:recording_disclaimer_needed]?.should be_nil
  end

  it "should only start after explicit disclaimer confirmation" do
    first_start = exec(:start_recording, "recordings@example.edu")
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 409
      response << %({"detail": {"message": "Recording disclaimer required before starting cloud recording", "precheck": {"disclaimer_check_result": 0, "disclaimer_needed": true}}})
    end

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/prompt-disclaimer")
      response.status_code = 200
      response << %({"message": "Recording disclaimer prompt sent"})
    end

    first_start.get.not_nil!["recording_started"].should eq(false)

    confirmation = exec(:confirm_reminder, "REMINDER_TYPE_RECORDING_DISCLAIMER", true)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/confirm-reminder")
      body = JSON.parse(request.body.not_nil!)
      body["is_agree"].should eq(true)
      body["notification_type"].should eq("REMINDER_TYPE_RECORDING_DISCLAIMER")
      response.status_code = 200
      response << %({"result": 0, "success": true})
    end

    confirmation.get
    status[:recording_disclaimer_needed]?.should be_nil

    second_start = exec(:start_recording, "recordings@example.edu")
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 500
      response << %({"detail": {"message": "Failed to start cloud recording", "error_code": 352, "error_name": "ZRCSDKERR_NOT_SET_RECORDING_NOTIFICATION_EMAIL"}})
    end

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/notification-email")
      JSON.parse(request.body.not_nil!)["email"].should eq("recordings@example.edu")
      response.status_code = 200
      response << %({"message": "Notification email set to recordings@example.edu"})
    end

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 500
      response << %({"detail": {"message": "Failed to start cloud recording", "error_code": 10, "error_name": "ZRCSDKERR_ALREADY_IN_THIS_STATE"}})
    end

    second_start.get
    status[:recording].should eq("started")
  end

  # SDK error 352 (NOT_SET_RECORDING_NOTIFICATION_EMAIL) without the disclaimer
  # gate: set the email and retry; ALREADY_IN_THIS_STATE (10) on the retry means
  # the held start consumed the email and recording is already running.
  it "should set the notification email and retry when the SDK reports 352" do
    result = exec(:start_recording, "recordings@example.edu")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 500
      response << %({"detail": {"message": "Failed to start cloud recording", "error_code": 352, "error_name": "ZRCSDKERR_NOT_SET_RECORDING_NOTIFICATION_EMAIL"}})
    end

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/notification-email")
      JSON.parse(request.body.not_nil!)["email"].should eq("recordings@example.edu")
      response.status_code = 200
      response << %({"message": "Notification email set to recordings@example.edu"})
    end

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 500
      response << %({"detail": {"message": "Failed to start cloud recording", "error_code": 10, "error_name": "ZRCSDKERR_ALREADY_IN_THIS_STATE"}})
    end

    result.get
    status[:recording].should eq("started")
  end

  # The email is caller-supplied, not stored: a 352 with no email to fall back
  # on surfaces as an error rather than silently proceeding.
  it "should raise on a 352 when no notification email was supplied" do
    result = exec(:start_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 500
      response << %({"detail": {"message": "Failed to start cloud recording", "error_code": 352, "error_name": "ZRCSDKERR_NOT_SET_RECORDING_NOTIFICATION_EMAIL"}})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /notification email/) do
      result.get
    end
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

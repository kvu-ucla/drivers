require "placeos-driver/spec"
require "http/server"
require "http/web_socket"
require "./zoom_zrc_models"

# The driver process connects to this local server exactly as it connects to the
# wrapper. Specs send raw wrapper JSON over the socket so notification coverage
# passes through run_event_stream and handle_event, not a public test command.
private class ZRCEventTestServer
  getter port : Int32

  @sockets = [] of HTTP::WebSocket

  def initialize
    handler = HTTP::WebSocketHandler.new do |socket, context|
      unless context.request.path == "/api/rooms/room-1/events"
        socket.close
        next
      end

      @sockets << socket
      socket.on_close { @sockets.delete(socket) }
    end
    @server = HTTP::Server.new([handler])
    @port = @server.bind_unused_port("127.0.0.1").port
    server = @server
    spawn { server.listen }
    Fiber.yield
  end

  def send_event(event : JSON::Any, timeout = 5.seconds) : Nil
    deadline = Time.instant + timeout
    until socket = @sockets.last?
      raise "timed out waiting for the ZRC event WebSocket" if Time.instant > deadline
      sleep 10.milliseconds
    end
    socket.send(event.to_json)
  end

  def close : Nil
    @sockets.each { |socket| socket.close rescue nil }
    @server.close rescue nil
  end
end

private def wait_for_zrc_status(timeout = 5.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "timed out waiting for ZRC event status" if Time.instant > deadline
    sleep 10.milliseconds
  end
end

event_server = ZRCEventTestServer.new

describe Zoom::ZRC::EventState do
  it "normalizes REST meeting-status values" do
    in_meeting = JSON.parse(%({"status":"MeetingStatus.MeetingStatusInMeeting"}))
    not_in_meeting = JSON.parse(%({"status":"MeetingStatus.MeetingStatusNotInMeeting"}))

    Zoom::ZRC::EventState.meeting_active?(in_meeting).should be_true
    Zoom::ZRC::EventState.meeting_active?(not_in_meeting).should be_false
    Zoom::ZRC::EventState.meeting_active?(JSON.parse("null")).should be_false
    Zoom::ZRC::EventState.meeting_session_ended?("MeetingStatusNotInMeeting").should be_true
    Zoom::ZRC::EventState.meeting_session_ended?(nil).should be_true
    Zoom::ZRC::EventState.meeting_session_ended?("MeetingStatusLoggedOut").should be_true
    Zoom::ZRC::EventState.meeting_session_ended?("MeetingStatusConnectingToMeeting").should be_false
  end

  it "normalizes REST and WebSocket connection-state values" do
    Zoom::ZRC::EventState.connection_state(JSON.parse(%({"connection_state":"Connected"}))).should eq("ConnectionStateConnected")
    Zoom::ZRC::EventState.connection_state(JSON.parse(%({"connection_state":"ConnectionState.ConnectionStateDisconnected"}))).should eq("ConnectionStateDisconnected")
    Zoom::ZRC::EventState.connection_state(JSON.parse(%("ConnectionStateEstablished"))).should eq("ConnectionStateEstablished")
    Zoom::ZRC::EventState.connection_online?(JSON.parse(%({"connection_state":"Connected"}))).should be_true
    Zoom::ZRC::EventState.connection_online?(JSON.parse(%({"connection_state":"Disconnected"}))).should be_false
  end

  it "rejects hidden and no-op notifications as prompts" do
    hidden_consent = JSON.parse(%({"info":{"is_showing":false,"type":"CONSENT_TYPE_HDMI_CONNECTED"}}))
    hidden_combined = JSON.parse(%({"combinedConsent":{"isShowing":false,"type":7}}))
    hidden_custom = JSON.parse(%({"customizedContent":{"isShowing":false}}))
    hidden_inactivity = JSON.parse(%({"isShowPrompt":false}))
    hidden_waiting_host = JSON.parse(%({"showWaitForHostDialog":false}))
    hidden_ask_unmute = JSON.parse(%({"show":false}))
    no_op_privacy = JSON.parse(%({"action":"PRIVACY_ALERT_ACTION_NONE"}))
    missing_privacy = JSON.parse(%({"event":"OnPrivacyAlertNotification"}))
    closed_privacy = JSON.parse(%({"action":"PRIVACY_ALERT_ACTION_CLOSE_DISCLAIMER"}))
    actionable_privacy = JSON.parse(%({"action":"PRIVACY_ALERT_ACTION_SHOW"}))
    actionable_disclaimer = JSON.parse(%({"action":"PRIVACY_ALERT_ACTION_SHOW_DISCLAIMER"}))
    ai_switch = JSON.parse(%({"info":{"type":"AICompanionRequestSwitch","switchAction":2}}))
    ai_enable = JSON.parse(%({"info":{"type":"AICompanionRequestEnable","switchAction":2}}))
    ai_none = JSON.parse(%({"info":{"type":"AICompanionRequestSwitch","switchAction":0}}))

    Zoom::ZRC::EventState.actionable_prompt?("OnConsentNotification", hidden_consent).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnCombinedConsentNotification", hidden_combined).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnCustomizedReminderNotification", hidden_custom).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnInactiveDetectionNotification", hidden_inactivity).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnJBHWaitingHostNotification", hidden_waiting_host).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnAskUnmuteAudioByHostNotification", hidden_ask_unmute).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnPrivacyAlertNotification", no_op_privacy).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnPrivacyAlertNotification", missing_privacy).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnPrivacyAlertNotification", closed_privacy).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnPrivacyAlertNotification", actionable_privacy).should be_true
    Zoom::ZRC::EventState.actionable_prompt?("OnPrivacyAlertNotification", actionable_disclaimer).should be_true
    Zoom::ZRC::EventState.actionable_prompt?("OnReceiveAICompanionRequest", ai_switch).should be_true
    Zoom::ZRC::EventState.actionable_prompt?("OnReceiveAICompanionRequest", ai_enable).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnReceiveAICompanionRequest", ai_none).should be_false
    Zoom::ZRC::EventState.actionable_prompt?("OnConsolidatedCustomizedConsentNotification", JSON.parse(%({"isAudioVideoBlocked":true,"disclaimers":[]}))).should be_true
  end
end

# Self-contained per-room driver: room_id comes from settings, status is flat.
# running_specs disables the event WebSocket (config.uri points at the mock HTTP
# server under test); basic_auth is kept so the Authorization header is added.

DriverSpecs.mock_driver "Zoom::ZRC::Controller" do
  settings({
    room_id:          "room-1",
    activation_code:  "SET-CODE",
    running_specs:    true,
    event_stream_uri: "http://127.0.0.1:#{event_server.port}",
    basic_auth:       {username: "spec", password: "spec"},
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
    status[:paired].should eq(true)
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
      response << %({"room_id":"room-1","paired":true,"connection_state":"ConnectionState.ConnectionStateConnected","get_state_result":0})
    end

    result.get
    status[:room_status].should_not be_nil
    status[:paired].should eq(true)
    status[:connection_state].should eq("ConnectionStateConnected")
    status[:online].should eq(true)
  end

  it "should reject a failed room-state read returned with HTTP 200" do
    result = exec(:get_room_status)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/status")
      response.status_code = 200
      response << %({"room_id":"room-1","paired":true,"connection_state":"Unknown","get_state_result":11})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /get room status failed/) do
      result.get
    end
  end

  it "should preserve an authoritative false paired state" do
    result = exec(:get_room_status)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/status")
      response.status_code = 200
      response << %({"room_id":"room-1","paired":false,"connection_state":"ConnectionState.ConnectionStateDisconnected","get_state_result":0})
    end

    result.get
    status[:paired].should eq(false)
    status[:online].should eq(false)
  end

  it "should get the pre-meeting connection state" do
    result = exec(:get_connection_state)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/pre-meeting/connection-state")
      response.status_code = 200
      response << %({"connection_state":"Connected","connection_state_value":1})
    end

    result.get
    status[:connection_state].should eq("ConnectionStateConnected")
    status[:online].should eq(true)
  end

  it "should keep a disconnected room offline after a successful wrapper response" do
    result = exec(:get_connection_state)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/pre-meeting/connection-state")
      response.status_code = 200
      response << %({"connection_state":"Disconnected","connection_state_value":3})
    end

    result.get
    status[:connection_state].should eq("ConnectionStateDisconnected")
    status[:online].should eq(false)
  end

  it "should list paired rooms" do
    result = exec(:list_rooms)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms")
      response.status_code = 200
      response << %({"rooms":[{"room_id":"room-1","paired":true}]})
    end

    result.get.not_nil!["rooms"].as_a.size.should eq(1)
  end

  it "should report wrapper health" do
    result = exec(:get_health)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/health")
      response.status_code = 200
      response << %({"status":"healthy","sdk_initialized":true})
    end

    result.get
    status[:health].should_not be_nil
  end

  it "should wake the room" do
    result = exec(:wake_up)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/pre-meeting/wake-up")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
  end

  it "should join a meeting with basic auth" do
    status[:meeting_error] = JSON.parse(%({"errorCode":300,"errorInfo":"previous failure"}))
    status[:meeting_ended] = JSON.parse(%({"errorCode":0}))
    status[:meeting_password_lock_status] = JSON.parse(%({"isLocked":true}))
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
    status[:meeting_active].should eq(false)
    status[:meeting_error]?.should be_nil
    status[:meeting_ended]?.should be_nil
    status[:meeting_password_lock_status]?.should be_nil
  end

  it "should submit a meeting password only through the SDK password route" do
    result = exec(:send_meeting_password, "correct horse battery staple")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/password/send")
      request.query_params["password"].should eq("correct horse battery staple")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
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
    status[:meeting_active].should eq(false)
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
    status[:meeting_active].should eq(false)
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
    status[:meeting_active].should eq(false)
  end

  it "should reject a failed scheduled start returned with HTTP 200" do
    result = exec(:start_meeting, "999888777")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/start")
      response.status_code = 200
      response << %({"meeting_number":"999888777","result":200,"success":false})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /start scheduled meeting failed/) do
      result.get
    end
    status[:meeting_active].should eq(false)
  end

  it "should derive meeting_active from the REST status field" do
    not_active = exec(:get_meeting_status)
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %({"status":"MeetingStatus.MeetingStatusNotInMeeting","result":0,"success":true})
    end
    not_active.get
    status[:meeting_active].should eq(false)
    status[:meeting_status].should eq("MeetingStatusNotInMeeting")

    active = exec(:get_meeting_status)
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %({"status":"MeetingStatus.MeetingStatusInMeeting","result":0,"success":true})
    end
    active.get
    status[:meeting_active].should eq(true)
    status[:meeting_status].should eq("MeetingStatusInMeeting")
  end

  it "should preserve meeting prompts during transient meeting states" do
    waiting_prompt = JSON.parse(%({"event":"OnJBHWaitingHostNotification","showWaitForHostDialog":true}))
    informational = JSON.parse(%({"event":"OnMeetingWillStopAutomatically"}))
    status[:waiting_for_host] = waiting_prompt
    status[:meeting_will_stop] = informational

    result = exec(:get_meeting_status)
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %({"status":"MeetingStatus.MeetingStatusConnectingToMeeting","result":0,"success":true})
    end

    result.get
    status[:meeting_active].should eq(false)
    status[:meeting_status].should eq("MeetingStatusConnectingToMeeting")
    status[:waiting_for_host].should eq(waiting_prompt)
    status[:meeting_will_stop].should eq(informational)
  end

  it "should reject a failed authoritative meeting-status response" do
    result = exec(:get_meeting_status)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %({"status":"MeetingStatus.MeetingStatusNotInMeeting","result":11,"success":false})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /get meeting status failed/) do
      result.get
    end
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

  it "should reject an AI companion SDK failure returned with HTTP 200" do
    result = exec(:ai_companion_on, 32)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/turn-on")
      response.status_code = 200
      response << %({"room_id":"room-1","features":32,"result":705,"success":false})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /turn on AI Companion failed/) do
      result.get
    end
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

  it "should preserve a structured AI companion response failure" do
    result = exec(:respond_to_ai_companion_request, 2, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/respond-to-turn-on")
      response.status_code = 502
      response << %({"detail":{"message":"Failed to respond to AI Companion turn-on request","error_code":705,"error_name":"ZRCSDKERR_AIC_NOT_SET_MEETING_SUMMARY_NOTIFY_EMAIL"}})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /ZRCSDKERR_AIC_NOT_SET_MEETING_SUMMARY_NOTIFY_EMAIL/) do
      result.get
    end
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

  it "should mute audio via the mute endpoint without writing state optimistically" do
    status[:mic_mute] = false
    result = exec(:mute_audio, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/mute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    # OnUpdateMyAudioStatus owns mic_mute; the POST ack must not clear spinners early
    status[:mic_mute].should eq(false)

    event_server.send_event(JSON.parse(%({"event":"OnUpdateMyAudioStatus","audioStatus":{"isMuted":true}})))
    wait_for_zrc_status { status[:mic_mute]? == true }
  end

  it "should unmute audio via the unmute endpoint without writing state optimistically" do
    result = exec(:mute_audio, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/unmute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(false)
    status[:mic_mute].should eq(true)

    event_server.send_event(JSON.parse(%({"event":"OnUpdateMyAudioStatus","audioStatus":{"isMuted":false}})))
    wait_for_zrc_status { status[:mic_mute]? == false }
  end

  it "should stop (mute) video via the mute endpoint without writing state optimistically" do
    status[:camera_mute] = false
    result = exec(:mute_video, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/mute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(true)
    # OnUpdateMyVideoNotification owns camera_mute
    status[:camera_mute].should eq(false)

    event_server.send_event(JSON.parse(%({"event":"OnUpdateMyVideoNotification","videoStatus":{"sending":false}})))
    wait_for_zrc_status { status[:camera_mute]? == true }
  end

  it "should start (unmute) video via the unmute endpoint without writing state optimistically" do
    result = exec(:mute_video, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/unmute")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(false)
    status[:camera_mute].should eq(true)

    event_server.send_event(JSON.parse(%({"event":"OnUpdateMyVideoNotification","videoStatus":{"sending":true}})))
    wait_for_zrc_status { status[:camera_mute]? == false }
  end

  it "should normalize an already-muted video result as idempotent success" do
    status[:camera_mute] = true
    result = exec(:mute_video, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/mute")
      response.status_code = 200
      response << %({"result":10,"success":false})
    end

    result.get.should eq(true)
    status[:camera_mute].should eq(true)
  end

  it "should normalize a structured already-unmuted audio error as idempotent success" do
    status[:mic_mute] = false
    result = exec(:mute_audio, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/unmute")
      response.status_code = 502
      response << %({"detail":{"message":"Failed to unmute audio","error_code":10,"error_name":"ZRCSDKERR_ALREADY_IN_THIS_STATE"}})
    end

    result.get.should eq(false)
    status[:mic_mute].should eq(false)
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

  it "should publish the requested microphone volume without reading a stale getter" do
    result = exec(:set_microphone_volume, 209.0)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/settings/volume/microphone")
      response.status_code = 200
      response << %({})
    end

    result.get.should eq(209.0)
    status[:microphone_volume].should eq(209.0)
  end

  it "should start cloud recording" do
    result = exec(:start_recording, "recordings@example.edu")

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
    result = exec(:start_recording, "recordings@example.edu")

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

  it "should reject a missing notification email before making a request" do
    result = exec(:start_recording)

    expect_raises(PlaceOS::Driver::RemoteException, /recording notification email is required/) do
      result.get
    end
  end

  it "should not publish started state for a body-level recording failure" do
    reset = exec(:stop_recording)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/stop")
      response.status_code = 200
      response << %({"message":"Cloud recording stopped"})
    end
    reset.get
    status[:recording].should eq("stopped")

    result = exec(:start_recording, "recordings@example.edu")
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/start")
      response.status_code = 200
      response << %({"result":352,"success":false})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /start cloud recording failed/) do
      result.get
    end
    status[:recording].should eq("stopped")
  end

  it "should preserve the service error body when stopping recording fails" do
    result = exec(:stop_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/stop")
      response.status_code = 500
      response << %({"detail":"Failed to stop cloud recording: ZRCSDKError.???"})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /Failed to stop cloud recording/) do
      result.get
    end
  end

  it "should normalize a structured duplicate recording stop" do
    result = exec(:stop_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/stop")
      response.status_code = 500
      response << %({"detail":{"message":"Failed to stop cloud recording","error_code":10,"error_name":"ZRCSDKERR_ALREADY_IN_THIS_STATE"}})
    end

    data = result.get.not_nil!
    data["recording_stopped"].should eq(true)
    status[:recording].should eq("stopped")
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

  it "should pause cloud recording" do
    result = exec(:pause_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/pause")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
    status[:recording].should eq("paused")
  end

  it "should resume cloud recording" do
    result = exec(:resume_recording)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/cloud/resume")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
    status[:recording].should eq("started")
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

  it "should reject a failed calendar callback returned with HTTP 200" do
    result = exec(:list_meetings)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meetings/list")
      response.status_code = 200
      response << %({"request_result":0,"request_success":true,"list_result":11,"list_success":false,"meetings":[]})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /list meetings failed/) do
      result.get
    end
  end

  it "should get participants" do
    result = exec(:get_participants)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[{"user_id":1,"user_name":"Alice","is_in_waiting_room":null}],"count":1})
    end

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/silent-mode")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[],"count":0})
    end

    result.get.should_not be_nil
    status[:participants].should_not be_nil
    status[:participants]["count"].should eq(1)
  end

  it "merges waiting-room participants from the silent-mode list" do
    result = exec(:get_participants)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[{"user_id":16778240,"user_name":"Room","is_host":true,"is_in_waiting_room":null}],"count":1})
    end

    # the wrapper's is_in_waiting_room is null even for silent-mode users (it
    # reads an SDK attribute that does not exist); list membership is the truth.
    # A user in both lists must not be duplicated or flagged.
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/silent-mode")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[{"user_id":16782336,"user_name":"Kenneth","is_host":false,"is_in_waiting_room":null},{"user_id":16778240,"user_name":"Room","is_host":true,"is_in_waiting_room":null}],"count":2})
    end

    merged = result.get.not_nil!
    participants = merged["participants"].as_a
    participants.size.should eq(2)
    merged["count"].should eq(2)

    room = participants.find! { |entry| entry["user_id"] == 16778240 }
    room["is_in_waiting_room"].raw.should be_nil

    waiting = participants.find! { |entry| entry["user_id"] == 16782336 }
    waiting["is_in_waiting_room"].should eq(true)
    status[:participants]["participants"].as_a.size.should eq(2)
  end

  it "should reject a failed participant query returned with HTTP 200" do
    result = exec(:get_participants)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %({"result":11,"success":false,"participants":[]})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /get participants failed/) do
      result.get
    end
  end

  it "rejects a failed waiting-room query rather than degrading to the base roster" do
    # body-level failure: waiting-room users failing silently is the original
    # bug, so a silent-mode failure must raise, never return the base list
    result = exec(:get_participants)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[{"user_id":1,"user_name":"Alice"}],"count":1})
    end

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/silent-mode")
      response.status_code = 200
      response << %({"result":11,"success":false,"participants":[]})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /get waiting-room participants failed/) do
      result.get
    end

    # HTTP-level failure on the silent-mode fetch must raise the same way
    result = exec(:get_participants)

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[{"user_id":1,"user_name":"Alice"}],"count":1})
    end

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/silent-mode")
      response.status_code = 502
      response << %({"detail":"upstream error"})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /get waiting-room participants failed: HTTP 502/) do
      result.get
    end
  end

  it "passes a non-hash participants payload through unchanged" do
    result = exec(:get_participants)

    # older wrapper shapes returned a bare array; the merge must fall back to
    # relaying the payload verbatim instead of raising on the missing hash
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %([{"user_id":1,"user_name":"Alice"}])
    end

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/silent-mode")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[{"user_id":2,"user_name":"Waiting"}],"count":1})
    end

    expected = JSON.parse(%([{"user_id":1,"user_name":"Alice"}]))
    result.get.should eq(expected)
    status[:participants].should eq(expected)
  end

  it "coalesces a burst of roster events into a single participants fetch" do
    status[:participants] = nil

    # the SDK emits several of these per action; the driver must fold the burst
    # into one trailing GET. Extra fetches would leave unconsumed requests that
    # poison the next expect_http_request, so a single handler here is the assertion.
    ["OnUserJoin", "OnInitMeetingParticipants", "OnMeetingParticipantsChanged"].each do |name|
      event_server.send_event(JSON.parse(%({"event":"#{name}"})))
    end

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[{"user_id":7,"user_name":"Coalesced"}],"count":1})
    end

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/silent-mode")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[],"count":0})
    end

    wait_for_zrc_status { status[:participants]?.try(&.to_s.includes?("Coalesced")) == true }

    # a roster event landing after the fetch queues a fresh trailing refresh
    event_server.send_event(JSON.parse(%({"event":"OnUserLeave"})))

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[{"user_id":7,"user_name":"Trailing"}],"count":1})
    end

    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/participants/silent-mode")
      response.status_code = 200
      response << %({"result":0,"success":true,"participants":[],"count":0})
    end

    wait_for_zrc_status { status[:participants]?.try(&.to_s.includes?("Trailing")) == true }
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

  it "should echo an open integer combined-consent type" do
    result = exec(:confirm_combined_consent, 7_i64, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/confirm-combined-consent")
      body = JSON.parse(request.body.not_nil!)
      body["is_agree"].should eq(false)
      body["notification_type"].should eq(7)
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
    status[:combined_consent_prompt]?.should be_nil
  end

  it "should answer consolidated customized consent through the prompt facade" do
    pending = JSON.parse(%({"event":"OnConsolidatedCustomizedConsentNotification","disclaimers":[{"title":"Recording"}],"isAudioVideoBlocked":true}))
    status[:consolidated_customized_consent_prompt] = pending
    result = exec(:confirm_prompt, "consolidated_customized_consent_prompt", false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/agree-consolidated-customized-consent")
      body = JSON.parse(request.body.not_nil!)
      body["is_agree"].should eq(false)
      response.status_code = 200
      response << %({"result":0,"success":true,"is_agree":false})
    end

    result.get
    status[:consolidated_customized_consent_prompt]?.should be_nil
  end

  it "should preserve consolidated customized consent when the SDK response fails" do
    pending = JSON.parse(%({"event":"OnConsolidatedCustomizedConsentNotification","disclaimers":[],"isAudioVideoBlocked":true}))
    status[:consolidated_customized_consent_prompt] = pending
    result = exec(:agree_consolidated_customized_consent, true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/agree-consolidated-customized-consent")
      response.status_code = 200
      response << %({"result":11,"success":false})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /agree to consolidated customized consent failed/) do
      result.get
    end
    status[:consolidated_customized_consent_prompt].should eq(pending)
  end

  it "should confirm a customized reminder" do
    result = exec(:confirm_custom_reminder, 7_i64, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/confirm-custom-reminder")
      body = JSON.parse(request.body.not_nil!)
      body["is_agree"].should eq(false)
      body["notification_type"].should eq(7)
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
    status[:customized_reminder]?.should be_nil
  end

  it "should preserve a privacy alert after a successful show transition" do
    pending = JSON.parse(%({"event":"OnPrivacyAlertNotification","action":"PRIVACY_ALERT_ACTION_SHOW"}))
    status[:privacy_alert] = pending
    result = exec(:handle_privacy_alert, "PRIVACY_ALERT_ACTION_SHOW", "PRIVACY_ALERT_TYPE_NEW_LTT_CAPTION")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/handle-privacy")
      body = JSON.parse(request.body.not_nil!)
      body["privacy_alert_action"].should eq("PRIVACY_ALERT_ACTION_SHOW")
      body["privacy_alert_type"].should eq("PRIVACY_ALERT_TYPE_NEW_LTT_CAPTION")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
    status[:privacy_alert].should eq(pending)
  end

  it "should clear a privacy alert only after a successful close transition" do
    status[:privacy_alert] = JSON.parse(%({"event":"OnPrivacyAlertNotification","action":"PRIVACY_ALERT_ACTION_SHOW_DISCLAIMER"}))
    result = exec(:handle_privacy_alert, "PRIVACY_ALERT_ACTION_CLOSE_DISCLAIMER", "PRIVACY_ALERT_TYPE_NEW_LTT_CAPTION")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/handle-privacy")
      body = JSON.parse(request.body.not_nil!)
      body["privacy_alert_action"].should eq("PRIVACY_ALERT_ACTION_CLOSE_DISCLAIMER")
      body["privacy_alert_type"].should eq("PRIVACY_ALERT_TYPE_NEW_LTT_CAPTION")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
    status[:privacy_alert]?.should be_nil
  end

  it "should preserve a privacy alert when a close transition fails" do
    pending = JSON.parse(%({"event":"OnPrivacyAlertNotification","action":"PRIVACY_ALERT_ACTION_SHOW"}))
    status[:privacy_alert] = pending
    result = exec(:handle_privacy_alert, "PRIVACY_ALERT_ACTION_CLOSE", "PRIVACY_ALERT_TYPE_NEW_LTT_CAPTION")

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/handle-privacy")
      response.status_code = 200
      response << %({"result":11,"success":false})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /handle privacy alert failed/) do
      result.get
    end
    status[:privacy_alert].should eq(pending)
  end

  it "should continue after an inactivity prompt" do
    result = exec(:continue_on_inactivity)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/continue-on-inactivity")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
    status[:inactive_detection]?.should be_nil
  end

  it "should reject an unsupported inactivity denial without clearing the prompt" do
    pending = JSON.parse(%({"event":"OnInactiveDetectionNotification","isShowPrompt":true}))
    status[:inactive_detection] = pending

    result = exec(:confirm_prompt, "inactive_detection", false)
    expect_raises(PlaceOS::Driver::RemoteException, /inactive_detection does not support denial/) do
      result.get
    end
    status[:inactive_detection].should eq(pending)
  end

  it "should deny a host audio-unmute prompt through its dedicated SDK route" do
    pending = JSON.parse(%({"event":"OnAskUnmuteAudioByHostNotification","show":true}))
    status[:ask_unmute_audio] = pending
    result = exec(:confirm_prompt, "ask_unmute_audio", false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/answer-unmute-request")
      request.query_params["accepted"].should eq("false")
      response.status_code = 200
      response << %({"accepted":false,"result":0,"success":true})
    end

    result.get
    status[:ask_unmute_audio]?.should be_nil
  end

  it "should accept a host start-video prompt through its dedicated SDK route" do
    pending = JSON.parse(%({"event":"OnAskStartVideoByHostNotification"}))
    status[:ask_start_video] = pending
    result = exec(:confirm_prompt, "ask_start_video", true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/answer-unmute-request")
      request.query_params["accepted"].should eq("true")
      response.status_code = 200
      response << %({"accepted":true,"result":0,"success":true})
    end

    result.get
    status[:ask_start_video]?.should be_nil
  end

  it "should preserve a host prompt when its dedicated SDK response fails" do
    pending = JSON.parse(%({"event":"OnAskUnmuteAudioByHostNotification","show":true}))
    status[:ask_unmute_audio] = pending
    result = exec(:confirm_prompt, "ask_unmute_audio", true)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/answer-unmute-request")
      request.query_params["accepted"].should eq("true")
      response.status_code = 200
      response << %({"accepted":true,"result":14,"success":false})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /answer host audio unmute request failed/) do
      result.get
    end
    status[:ask_unmute_audio].should eq(pending)
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

  it "should preserve a recording request when its structured SDK response fails" do
    pending = JSON.parse(%({"event":"OnReceiveRecordingRequest","requester":{"userID":42,"userName":"Guest"}}))
    status[:recording_request] = pending

    result = exec(:respond_to_recording_request, true, false)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/respond-to-request")
      response.status_code = 502
      response << %({"detail":{"message":"Failed to respond to recording request","error_code":11,"error_name":"ZRCSDKERR_NOT_CONNECT_TO_ZOOMROOM"}})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /ZRCSDKERR_NOT_CONNECT_TO_ZOOMROOM/) do
      result.get
    end
    status[:recording_request].should eq(pending)
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

  # These examples send raw JSON over the same WebSocket used in production.
  it "ingests consolidated customized consent and answers it through the facade" do
    event = JSON.parse(%({"event":"OnConsolidatedCustomizedConsentNotification","disclaimers":[{"title":"Recording","body":"This meeting is recorded"}],"isAudioVideoBlocked":true}))
    event_server.send_event(event)
    wait_for_zrc_status { status[:consolidated_customized_consent_prompt]? == event }

    result = exec(:confirm_prompt, "consolidated_customized_consent_prompt", false)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/agree-consolidated-customized-consent")
      JSON.parse(request.body.not_nil!)["is_agree"].should eq(false)
      response.status_code = 200
      response << %({"result":0,"success":true})
    end

    result.get
    status[:consolidated_customized_consent_prompt]?.should be_nil
  end

  it "ingests privacy show and close transitions through the event handler" do
    show = JSON.parse(%({"event":"OnPrivacyAlertNotification","action":"PRIVACY_ALERT_ACTION_SHOW_DISCLAIMER","type":"PRIVACY_ALERT_TYPE_NEW_LTT_CAPTION"}))
    event_server.send_event(show)
    wait_for_zrc_status { status[:privacy_alert]? == show }

    close = JSON.parse(%({"event":"OnPrivacyAlertNotification","action":"PRIVACY_ALERT_ACTION_CLOSE_DISCLAIMER","type":"PRIVACY_ALERT_TYPE_NEW_LTT_CAPTION"}))
    event_server.send_event(close)
    wait_for_zrc_status { status[:privacy_alert]?.nil? }

    event_server.send_event(show)
    wait_for_zrc_status { status[:privacy_alert]? == show }
    result = exec(:handle_privacy_alert, "PRIVACY_ALERT_ACTION_CLOSE_DISCLAIMER", "PRIVACY_ALERT_TYPE_NEW_LTT_CAPTION")
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/handle-privacy")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end
    result.get
    status[:privacy_alert]?.should be_nil
  end

  it "ingests inactivity show/hide and preserves an unsupported denial" do
    visible = JSON.parse(%({"event":"OnInactiveDetectionNotification","isShowPrompt":true}))
    event_server.send_event(visible)
    wait_for_zrc_status { status[:inactive_detection]? == visible }

    denial = exec(:confirm_prompt, "inactive_detection", false)
    expect_raises(PlaceOS::Driver::RemoteException, /inactive_detection does not support denial/) do
      denial.get
    end
    status[:inactive_detection].should eq(visible)

    continuation = exec(:confirm_prompt, "inactive_detection", true)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/reminder/continue-on-inactivity")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end
    continuation.get
    status[:inactive_detection]?.should be_nil

    event_server.send_event(visible)
    wait_for_zrc_status { status[:inactive_detection]? == visible }
    event_server.send_event(JSON.parse(%({"event":"OnInactiveDetectionNotification","isShowPrompt":false})))
    wait_for_zrc_status { status[:inactive_detection]?.nil? }
  end

  it "ingests a recording request and denies it through the facade" do
    event = JSON.parse(%({"event":"OnReceiveRecordingRequest","info":{"recordingType":"RecordingTypeCloud","senderName":"Guest"}}))
    event_server.send_event(event)
    wait_for_zrc_status { status[:recording_request]? == event }

    result = exec(:confirm_prompt, "recording_request", false)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/recording/respond-to-request")
      body = JSON.parse(request.body.not_nil!)
      body["agree"].should eq(false)
      body["is_persist"].should eq(false)
      response.status_code = 200
      response << %({"result":0,"success":true,"agreed":false})
    end
    result.get
    status[:recording_request]?.should be_nil
  end

  it "only exposes actionable AI Companion switch requests" do
    switch = JSON.parse(%({"event":"OnReceiveAICompanionRequest","info":{"AICFeatures":32,"senderNames":["Guest"],"switchAction":2,"type":"AICompanionRequestSwitch"}}))
    event_server.send_event(switch)
    wait_for_zrc_status { status[:ai_companion_request]? == switch }

    non_switch = JSON.parse(%({"event":"OnReceiveAICompanionRequest","info":{"AICFeatures":32,"switchAction":2,"type":"AICompanionRequestEnable"}}))
    event_server.send_event(non_switch)
    wait_for_zrc_status { status[:ai_companion_request]?.nil? }

    event_server.send_event(switch)
    wait_for_zrc_status { status[:ai_companion_request]? == switch }
    result = exec(:confirm_prompt, "ai_companion_request", false)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/respond-to-turn-on")
      request.query_params["agree"].should eq("false")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end
    result.get
    status[:ai_companion_request]?.should be_nil
  end

  it "publishes authoritative AI Companion summary state from its WebSocket callback" do
    status[:ai_companion_status] = nil
    status[:ai_companion_summary_on] = nil
    status[:ai_companion_summary_email_set] = nil

    requested = exec(:ai_companion_on, 32)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/ai-companion/turn-on")
      request.query_params["features"].should eq("32")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end
    requested.get
    status[:ai_companion_status]?.should be_nil
    status[:ai_companion_summary_on]?.should be_nil

    enabled = JSON.parse(%({"event":"OnSmartSummaryOn","summaryOn":true,"hasSetEmail":true}))
    event_server.send_event(enabled)
    wait_for_zrc_status do
      status[:ai_companion_status]? == enabled &&
        status[:ai_companion_summary_on]? == true &&
        status[:ai_companion_summary_email_set]? == true
    end

    disabled = JSON.parse(%({"event":"OnSmartSummaryOn","summaryOn":false,"hasSetEmail":true}))
    event_server.send_event(disabled)
    wait_for_zrc_status do
      status[:ai_companion_status]? == disabled &&
        status[:ai_companion_summary_on]? == false &&
        status[:ai_companion_summary_email_set]? == true
    end
  end

  it "ingests and denies a host ask-to-unmute prompt through its SDK response" do
    event = JSON.parse(%({"event":"OnAskUnmuteAudioByHostNotification","show":true,"type":"AskUnmuteAudioTypeUnmuteAudio"}))
    event_server.send_event(event)
    wait_for_zrc_status { status[:ask_unmute_audio]? == event }

    result = exec(:confirm_prompt, "ask_unmute_audio", false)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/audio/answer-unmute-request")
      request.query_params["accepted"].should eq("false")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end
    result.get
    status[:ask_unmute_audio]?.should be_nil
  end

  it "ingests and accepts a host ask-to-start-video prompt through its SDK response" do
    event = JSON.parse(%({"event":"OnAskStartVideoByHostNotification","userID":42}))
    event_server.send_event(event)
    wait_for_zrc_status { status[:ask_start_video]? == event }

    result = exec(:confirm_prompt, "ask_start_video", true)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/video/answer-unmute-request")
      request.query_params["accepted"].should eq("true")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end
    result.get
    status[:ask_start_video]?.should be_nil
  end

  it "ingests join-before-host show/hide and cancels through the facade" do
    visible = JSON.parse(%({"event":"OnJBHWaitingHostNotification","showWaitForHostDialog":true}))
    event_server.send_event(visible)
    wait_for_zrc_status { status[:waiting_for_host]? == visible }

    result = exec(:confirm_prompt, "waiting_for_host", false)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/meeting/cancel-waiting-host")
      response.status_code = 200
      response << %({"result":0,"success":true})
    end
    result.get
    status[:waiting_for_host]?.should be_nil

    event_server.send_event(visible)
    wait_for_zrc_status { status[:waiting_for_host]? == visible }
    event_server.send_event(JSON.parse(%({"event":"OnJBHWaitingHostNotification","showWaitForHostDialog":false})))
    wait_for_zrc_status { status[:waiting_for_host]?.nil? }
  end

  it "ingests informational notification payloads without fabricating meeting state" do
    active = exec(:get_meeting_status)
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %({"status":"MeetingStatus.MeetingStatusInMeeting","result":0,"success":true})
    end
    active.get

    silent = JSON.parse(%({"event":"OnInSilentModeNotification","info":{"inSilentMode":true}}))
    auto_stop = JSON.parse(%({"event":"OnMeetingWillStopAutomatically"}))
    incoming_share = JSON.parse(%({"event":"OnIncomingMeetingShareNotification","noti":{"incomingSource":"IncomingShareSourceMeeting","shareUserName":"Guest","currentShareType":"ShareTypeScreen"}}))
    event_server.send_event(silent)
    event_server.send_event(auto_stop)
    event_server.send_event(incoming_share)
    wait_for_zrc_status do
      status[:silent_mode]? == silent &&
        status[:meeting_will_stop]? == auto_stop &&
        status[:incoming_share]? == incoming_share
    end
    status[:meeting_active].should eq(true)

    inactive = exec(:get_meeting_status)
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %({"status":"MeetingStatus.MeetingStatusNotInMeeting","result":0,"success":true})
    end
    inactive.get
    status[:meeting_active].should eq(false)
    status[:silent_mode]?.should be_nil
    status[:meeting_will_stop]?.should be_nil
    status[:incoming_share]?.should be_nil

    auto_release = JSON.parse(%({"event":"OnMeetingWillReleaseAutomatically","meetingItem":{"meetingName":"Standup","meetingNumber":"123"}}))
    event_server.send_event(auto_release)
    wait_for_zrc_status { status[:meeting_will_release]? == auto_release }

    reconcile = exec(:get_meeting_status)
    expect_http_request do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/api/rooms/room-1/meeting/status")
      response.status_code = 200
      response << %({"status":"MeetingStatus.MeetingStatusNotInMeeting","result":0,"success":true})
    end
    reconcile.get
    status[:meeting_will_release].should eq(auto_release)
    status[:meeting_active].should eq(false)
  end

  it "lets an authoritative speaker-volume event replace the requested value" do
    result = exec(:set_speaker_volume, 170.0)
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/settings/volume/speaker")
      JSON.parse(request.body.not_nil!)["volume"].should eq(170.0)
      response.status_code = 200
      response << %({"volume":170.0})
    end
    result.get.should eq(170.0)
    status[:speaker_volume].should eq(170.0)

    event_server.send_event(JSON.parse(%({"event":"OnCurrentSpeakerVolumeChanged","volume":171.0})))
    wait_for_zrc_status { status[:speaker_volume]? == 171.0 }
  end

  it "should exit a meeting and reconcile meeting state from the device" do
    status[:consent_prompt] = JSON.parse(%({"event":"OnConsentNotification"}))
    room_notification = JSON.parse(%({"event":"OnMeetingWillReleaseAutomatically","meetingItem":{"meetingNumber":"123"}}))
    status[:meeting_will_release] = room_notification
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
    status[:meeting_status]?.should be_nil
    status[:recording].should eq("stopped")
    status[:participants]?.should be_nil
    status[:consent_prompt]?.should be_nil
    status[:meeting_will_release].should eq(room_notification)
  end

  it "should mark the room offline when unpaired" do
    status[:meeting_will_release] = JSON.parse(%({"event":"OnMeetingWillReleaseAutomatically"}))
    result = exec(:unpair_room)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/unpair")
      response.status_code = 200
      response << %({})
    end

    result.get
    status[:online].should eq(false)
    status[:paired].should eq(false)
    status[:meeting_active].should eq(false)
    status[:meeting_status]?.should be_nil
    status[:meeting_will_release]?.should be_nil
  end

  it "should reject a failed unpair returned with HTTP 200" do
    result = exec(:unpair_room)

    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/api/rooms/room-1/unpair")
      response.status_code = 200
      response << %({"room_id":"room-1","result":11,"success":false})
    end

    expect_raises(PlaceOS::Driver::RemoteException, /unpair room failed/) do
      result.get
    end
  end
end

event_server.close

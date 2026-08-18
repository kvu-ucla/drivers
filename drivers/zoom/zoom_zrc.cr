require "base64"
require "uri"
require "http/web_socket"
require "placeos-driver"
require "placeos-driver/interface/muteable"
require "./zoom_zrc_models"

# Controls a single Zoom Room via the ZRC SDK microservice.
#
# One instance lives in each Zoom Room's system. It is self-contained: it talks
# HTTP to the microservice for commands (keyed by its own `room_id`), holds its
# own event WebSocket for real-time push, and exposes flat status keys that room
# UIs bind to directly (`mic_mute`, `meeting_active`, ...).
#
# The microservice is central and addresses rooms by an arbitrary `room_id`, so
# every instance points `uri_base` at the same service (set it at the zone level)
# and sets its own `room_id`.

class Zoom::ZRC::Controller < PlaceOS::Driver
  include Interface::AudioMuteable
  include Interface::VideoMuteable

  descriptive_name "Zoom ZRC Room"
  generic_name :ZoomZRC
  description "Controls a single Zoom Room via the ZRC SDK microservice"

  uri_base "http://localhost:8000"

  default_settings({
    # REQUIRED: the room_id this space maps to on the ZRC microservice
    room_id: "",
    # activation code used to pair this room (fallback for pair_room)
    activation_code: "",
    poll_interval:   30,
    basic_auth:      {
      username: "",
      password: "",
    },
  })

  JSON_HEADERS = {"Content-Type" => "application/json", "Accept" => "application/json"}

  # Interactive prompt / toast notifications that a room UI must surface and
  # often answer before the meeting can proceed (consent dialogs, recording
  # requests, waiting-for-host, ask-to-unmute, ...). Each event's FULL payload
  # is reflected into the mapped status key; the matching respond_* /confirm_*
  # methods below answer the prompt and clear the key. Enum/id values needed by
  # a response are read from the captured payload.
  PROMPT_EVENTS = {
    "OnConsentNotification"                       => "consent_prompt",
    "OnCombinedConsentNotification"               => "combined_consent_prompt",
    "OnConsolidatedCustomizedConsentNotification" => "consolidated_customized_consent_prompt",
    "OnMeetingReminderNotification"               => "meeting_reminder",
    "OnCustomizedReminderNotification"            => "customized_reminder",
    "OnPrivacyAlertNotification"                  => "privacy_alert",
    "OnInactiveDetectionNotification"             => "inactive_detection",
    "OnReceiveRecordingRequest"                   => "recording_request",
    "OnAskUnmuteAudioByHostNotification"          => "ask_unmute_audio",
    "OnAskStartVideoByHostNotification"           => "ask_start_video",
    "OnJBHWaitingHostNotification"                => "waiting_for_host",
    "OnReceiveAICompanionRequest"                 => "ai_companion_request",
    "OnAICompanionStatusNeedConfirm"              => "ai_companion_confirm",
  }

  # Notifications this driver currently exposes for observation only. They are
  # deliberately kept out of confirm_prompt; adding close/extend/pin/admission
  # controls is a separate API expansion from preserving these callbacks.
  INFORMATIONAL_EVENTS = {
    "OnEnableWaitingRoomOnEntryNotification" => "waiting_room_on_entry",
    "OnUpdateAdmitGuestEnableNotification"   => "admit_guest_enabled",
    "OnInSilentModeNotification"             => "silent_mode",
    "OnMeetingWillStopAutomatically"         => "meeting_will_stop",
    "OnIncomingMeetingShareNotification"     => "incoming_share",
  }

  # Auto-release is a calendar/room event emitted before a meeting starts. It
  # must survive normal NotInMeeting reconciliation; otherwise the fallback
  # poll erases it almost immediately. Room reset/unpair still clears it.
  ROOM_INFORMATIONAL_EVENTS = {
    "OnMeetingWillReleaseAutomatically" => "meeting_will_release",
  }

  @room_id : String = ""
  @activation_code : String = ""
  @poll_interval : Int32 = 30
  @socket : HTTP::WebSocket?
  @ws_generation = 0
  @pending_meeting_password : String?
  @meeting_password_attempted = false

  def on_load
    on_update
  end

  def on_update
    stop_event_stream

    # Settings updates can move this driver instance to a different room. Never
    # carry meeting prompts or a pending password across that boundary (or even
    # across a reconnect of the same room).
    reset_room_state

    @room_id = setting?(String, :room_id) || ""
    @activation_code = setting?(String, :activation_code) || ""
    @poll_interval = setting?(Int32, :poll_interval) || 30

    schedule.clear
    if @room_id.empty?
      logger.warn { "room_id not configured; driver idle until set" }
      return
    end

    unless setting?(Bool, :running_specs)
      schedule.every(@poll_interval.seconds) { poll }
      schedule.in(2.seconds) { poll }
    end

    start_event_stream
  end

  def on_unload
    schedule.clear
    stop_event_stream
  end

  # =========================================================
  # Pairing
  # =========================================================

  # Pair this room. Uses the passed code, otherwise the `activation_code` setting.
  def pair_room(activation_code : String? = nil) : JSON::Any
    code = (activation_code || @activation_code).presence
    raise "no activation_code provided or configured for this room" unless code
    body = PairRoomRequest.new(code).to_json
    response = post("/api/rooms/#{@room_id}/pair", body: body, headers: JSON_HEADERS)
    data = parse_command_response(response, "pair room")
    self[:paired] = true
    if state = EventState.connection_state(data)
      self[:connection_state] = state
      self[:online] = EventState.connection_online?(data)
    end
    data
  end

  def unpair_room : JSON::Any
    response = post("/api/rooms/#{@room_id}/unpair", headers: JSON_HEADERS)
    data = parse_command_response(response, "unpair room")
    self[:paired] = false
    self[:online] = false
    self[:connection_state] = nil
    self[:room_status] = nil
    self[:meeting_status] = nil
    self[:meeting_active] = false
    clear_meeting_session_state
    clear_room_notifications
    data
  end

  # =========================================================
  # Status
  # =========================================================

  def get_room_status : JSON::Any
    response = get("/api/rooms/#{@room_id}/status", headers: JSON_HEADERS)
    data = parse_command_response(response, "get room status")
    assert_zero_result(data, "get_state_result", "get room status")
    self[:room_status] = data
    paired = data.as_h?.try(&.["paired"]?).try(&.as_bool?)
    self[:paired] = paired unless paired.nil?
    if state = EventState.connection_state(data)
      self[:connection_state] = state
      self[:online] = EventState.connection_online?(data)
    end
    data
  end

  def get_connection_state : JSON::Any
    response = get("/api/rooms/#{@room_id}/pre-meeting/connection-state", headers: JSON_HEADERS)
    data = parse_command_response(response, "get connection state")
    state = EventState.connection_state(data) || raise "invalid connection state response: #{response.body}"
    self[:connection_state] = state
    self[:online] = EventState.connection_online?(data)
    data
  end

  def get_meeting_status : JSON::Any
    response = get("/api/rooms/#{@room_id}/meeting/status", headers: JSON_HEADERS)
    data = parse_command_response(response, "get meeting status")
    meeting_status = EventState.meeting_status(data)
    self[:meeting_status] = meeting_status
    meeting_active = EventState.meeting_active?(data)
    self[:meeting_active] = meeting_active
    if meeting_active
      clear_meeting_password_state
    elsif EventState.meeting_session_ended?(meeting_status)
      clear_meeting_session_state
    end
    data
  end

  def get_volumes : Nil
    begin
      fetch_volume("speaker", :speaker_volume)
    rescue e
      logger.warn(exception: e) { "speaker volume refresh failed" }
    end

    begin
      fetch_volume("microphone", :microphone_volume)
    rescue e
      logger.warn(exception: e) { "microphone volume refresh failed" }
    end
  end

  def list_rooms : JSON::Any
    response = get("/api/rooms", headers: JSON_HEADERS)
    parse_command_response(response, "list rooms")
  end

  # Re-fetch this room's full state on demand.
  def refresh : Nil
    begin
      get_connection_state
    rescue e
      logger.warn(exception: e) { "connection-state refresh failed" }
      self[:online] = false
      return
    end

    begin
      get_room_status
    rescue e
      logger.warn(exception: e) { "room-status refresh failed" }
    end

    begin
      get_meeting_status
    rescue e
      logger.warn(exception: e) { "meeting-status refresh failed" }
    end

    get_volumes
  end

  # =========================================================
  # Meeting Controls
  # =========================================================

  def start_instant_meeting : JSON::Any
    prepare_meeting_join
    response = post("/api/rooms/#{@room_id}/meeting/start_instant", headers: JSON_HEADERS)
    parse_command_response(response, "start instant meeting")
  end

  def join_meeting(meeting_number : String, password : String? = nil, bring_share : Bool = false) : JSON::Any
    prepare_meeting_join
    @pending_meeting_password = password.try(&.presence)
    @meeting_password_attempted = false
    body = JoinMeetingRequest.new(meeting_number, password, bring_share).to_json
    response = post("/api/rooms/#{@room_id}/meeting/join", body: body, headers: JSON_HEADERS)
    parse_command_response(response, "join meeting")
  rescue e
    clear_meeting_password_state
    raise e
  end

  # Submit a password only after the SDK reports OnMeetingNeedsPasswordNotification.
  # This is also public so a UI can retry with a corrected password after the SDK
  # reports wrongAndRetry; the automatic path deliberately attempts a supplied
  # join password only once to avoid locking the room through repeated retries.
  def send_meeting_password(password : String) : JSON::Any
    value = password.presence || raise "a meeting password is required"
    @pending_meeting_password = value
    @meeting_password_attempted = true
    response = post("/api/rooms/#{@room_id}/meeting/password/send", params: {"password" => value}, headers: JSON_HEADERS)
    parse_command_response(response, "send meeting password")
  end

  # `url` is a required query param. The current ZRC SDK does not support
  # bringing a local share into meetings joined by URL.
  def join_meeting_by_url(url : String) : JSON::Any
    prepare_meeting_join
    response = post("/api/rooms/#{@room_id}/meeting/join-url", params: {"url" => url}, headers: JSON_HEADERS)
    parse_command_response(response, "join meeting by URL")
  end

  def start_meeting(
    meeting_number : String,
    meeting_name : String? = nil,
    host_name : String? = nil,
    start_time : String? = nil,
    end_time : String? = nil,
    bring_share : Bool? = nil,
  ) : StartMeetingRequest
    prepare_meeting_join
    body = StartMeetingRequest.new(meeting_number, meeting_name, host_name, start_time, end_time, bring_share).to_json
    response = post("/api/rooms/#{@room_id}/meeting/start", body: body, headers: JSON_HEADERS)
    data = parse_command_response(response, "start scheduled meeting")
    StartMeetingRequest.from_json(data.to_json)
  end

  # =========================================================
  # Meeting List (room calendar)
  # =========================================================

  # Fetch the room's calendar meeting list. The service resolves this via the
  # SDK's OnUpdateMeetingList callback, so allow its default 15s wait.
  def list_meetings : JSON::Any
    response = get("/api/rooms/#{@room_id}/meetings/list", headers: JSON_HEADERS)
    data = parse_command_response(response, "list meetings")
    assert_true_result(data, "request_success", "list meetings")
    assert_true_result(data, "list_success", "list meetings")
    self[:meetings] = data["meetings"]?
    data
  end

  def exit_meeting : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/exit", headers: JSON_HEADERS)
    data = parse_command_response(response, "exit meeting")
    # Reconcile from the device rather than fabricating the post-exit cascade.
    get_meeting_status
    data
  end

  # =========================================================
  # Prompt responses
  # =========================================================
  #
  # Answers for the interactive prompts captured via PROMPT_EVENTS. Each clears
  # its prompt status key on success.
  #
  # `confirm_prompt` is the general facade: answer any yes/no prompt by its
  # status key, with type/id arguments derived from the captured payload — the
  # caller never echoes SDK enums back. The typed methods below remain for
  # explicit control; prompts that aren't yes/no keep dedicated methods
  # (handle_privacy_alert, prompt_recording_disclaimer).
  #
  # Enum `type` fields arrive from the event stream as SDK enum NAMES (e.g.
  # "CONSENT_TYPE_ARCHIVING"); the typed methods pass either that name or the
  # raw int through — the service resolves whichever it receives.

  # Answer a pending prompt by status key, e.g.
  #   confirm_prompt("consent_prompt")            # accept
  #   confirm_prompt("recording_request", false)  # deny
  def confirm_prompt(prompt : String, agree : Bool = true) : Nil
    payload = self[prompt]?
    raise "no pending #{prompt}" unless payload

    case prompt
    when "consent_prompt"
      consent_type = payload.dig?("info", "type").try(&.as_s?) || raise "consent payload missing type"
      consent_id = payload.dig?("info", "consent_id").try(&.as_s?) || ""
      confirm_consent(consent_type, agree, consent_id)
    when "combined_consent_prompt"
      type_value = payload.dig?("combinedConsent", "type") || raise "combined consent payload missing type"
      consent_type = type_value.as_s? || type_value.as_i? || raise "combined consent payload has invalid type"
      confirm_combined_consent(consent_type, agree)
    when "consolidated_customized_consent_prompt"
      agree_consolidated_customized_consent(agree)
    when "meeting_reminder"
      reminder_type = payload.dig?("reminderContent", "reminderType").try(&.as_s?) || raise "reminder payload missing type"
      confirm_reminder(reminder_type, agree)
    when "customized_reminder"
      type_value = payload.dig?("customizedContent", "customizedDisclaimerType") || raise "customized reminder payload missing type"
      reminder_type = type_value.as_s? || type_value.as_i? || raise "customized reminder payload has invalid type"
      confirm_custom_reminder(reminder_type, agree)
    when "recording_request"
      respond_to_recording_request(agree)
    when "inactive_detection"
      # The SDK only exposes a continue operation. A false response cannot be
      # sent to Zoom, so preserve the prompt until Zoom hides it or the meeting
      # ends rather than reporting a denial that never happened.
      raise "inactive_detection does not support denial" unless agree
      continue_on_inactivity
    when "waiting_for_host"
      # agree = keep waiting (prompt stays pending); deny = stop waiting
      cancel_waiting_for_host unless agree
    when "ai_companion_request"
      action_value = payload.dig?("info", "switchAction") || raise "ai companion payload missing switchAction"
      action = action_value.as_s? || action_value.as_i? || raise "invalid AI companion switchAction"
      respond_to_ai_companion_request(action, agree)
    when "ai_companion_confirm"
      confirm_ai_companion_status(agree)
    when "ask_unmute_audio"
      answer_unmute_audio_request(agree)
    when "ask_start_video"
      answer_start_video_request(agree)
    else
      raise "#{prompt} is not a confirmable prompt"
    end
    nil
  end

  def confirm_reminder(notification_type : Int32 | String, agree : Bool = true) : JSON::Any
    body = {is_agree: agree, notification_type: notification_type}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/confirm-reminder", body: body, headers: JSON_HEADERS)
    data = parse_command_response(response, "confirm meeting reminder")
    self[:meeting_reminder] = nil
    if recording_disclaimer?(notification_type)
      self[:recording_disclaimer_needed] = agree ? nil : true
    end
    data
  end

  private def recording_disclaimer?(notification_type : Int32 | String) : Bool
    notification_type == RECORDING_DISCLAIMER || notification_type == RECORDING_DISCLAIMER_VALUE
  end

  def confirm_custom_reminder(notification_type : Int32 | Int64 | String, agree : Bool = true) : JSON::Any
    body = {is_agree: agree, notification_type: notification_type}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/confirm-custom-reminder", body: body, headers: JSON_HEADERS)
    data = parse_command_response(response, "confirm customized reminder")
    self[:customized_reminder] = nil
    data
  end

  def confirm_consent(consent_type : Int32 | String, agree : Bool = true, consent_id : String = "") : JSON::Any
    body = {is_agree: agree, consent_type: consent_type, consent_id: consent_id}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/confirm-consent", body: body, headers: JSON_HEADERS)
    data = parse_command_response(response, "confirm consent")
    self[:consent_prompt] = nil
    data
  end

  def confirm_combined_consent(notification_type : Int32 | Int64 | String, agree : Bool = true) : JSON::Any
    body = {is_agree: agree, notification_type: notification_type}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/confirm-combined-consent", body: body, headers: JSON_HEADERS)
    data = parse_command_response(response, "confirm combined consent")
    self[:combined_consent_prompt] = nil
    data
  end

  # SDK 7.1 consolidated customized consent is distinct from the legacy
  # combined-consent notification. Its callback carries the complete list of
  # disclaimers and whether audio/video is blocked; the response only needs the
  # user's decision.
  def agree_consolidated_customized_consent(agree : Bool = true) : JSON::Any
    body = {is_agree: agree}.to_json
    response = post(
      "/api/rooms/#{@room_id}/meeting/reminder/agree-consolidated-customized-consent",
      body: body,
      headers: JSON_HEADERS
    )
    data = parse_command_response(response, "agree to consolidated customized consent")
    self[:consolidated_customized_consent_prompt] = nil
    data
  end

  def handle_privacy_alert(privacy_alert_action : Int32 | String, privacy_alert_type : Int32 | String) : JSON::Any
    body = {privacy_alert_action: privacy_alert_action, privacy_alert_type: privacy_alert_type}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/handle-privacy", body: body, headers: JSON_HEADERS)
    data = parse_command_response(response, "handle privacy alert")
    # SHOW/SHOW_DISCLAIMER are display transitions, not dismissals. Preserve
    # the payload until a close action succeeds or Zoom emits a close callback.
    self[:privacy_alert] = nil if privacy_alert_close_action?(privacy_alert_action)
    data
  end

  private def privacy_alert_close_action?(action : Int32 | String) : Bool
    action.in?(
      0,
      2,
      4,
      "PRIVACY_ALERT_ACTION_NONE",
      "PRIVACY_ALERT_ACTION_CLOSE",
      "PRIVACY_ALERT_ACTION_CLOSE_DISCLAIMER"
    )
  end

  # Keep the meeting alive after an inactivity-detection prompt.
  def continue_on_inactivity : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/reminder/continue-on-inactivity", headers: JSON_HEADERS)
    data = parse_command_response(response, "continue after inactivity prompt")
    self[:inactive_detection] = nil
    data
  end

  # Approve or deny a participant's recording request.
  def respond_to_recording_request(agree : Bool, persist : Bool = false) : JSON::Any
    body = {agree: agree, is_persist: persist}.to_json
    response = post("/api/rooms/#{@room_id}/recording/respond-to-request", body: body, headers: JSON_HEADERS)
    data = parse_command_response(response, "respond to recording request")
    self[:recording_request] = nil
    data
  end

  def check_recording_disclaimer : JSON::Any
    response = get("/api/rooms/#{@room_id}/recording/disclaimer-needed", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    needed = data["disclaimer_needed"]?.try(&.as_bool?) || false
    self[:recording_disclaimer_needed] = needed ? true : nil
    data
  end

  # Show the start-recording disclaimer on the Zoom Room for in-room acceptance.
  def prompt_recording_disclaimer : JSON::Any
    response = post("/api/rooms/#{@room_id}/recording/prompt-disclaimer", headers: JSON_HEADERS)
    parse_command_response(response, "prompt recording disclaimer")
  end

  # Directly turn on AI Companion features. The ZRC SDK accepts an Int64 bitmask
  # (SmartSummary=32, SmartQuestion=64); SmartRecording cannot be turned on with
  # this API.
  def ai_companion_on(features : Int64) : JSON::Any
    response = post("/api/rooms/#{@room_id}/ai-companion/turn-on", params: {"features" => features.to_s}, headers: JSON_HEADERS)
    parse_command_response(response, "turn on AI Companion")
  end

  # `delete_assets` discards any already-generated AI assets when turning off.
  def ai_companion_off(features : Int64, delete_assets : Bool = false) : JSON::Any
    response = post("/api/rooms/#{@room_id}/ai-companion/turn-off", params: {"features" => features.to_s, "delete_assets" => delete_assets.to_s}, headers: JSON_HEADERS)
    parse_command_response(response, "turn off AI Companion")
  end

  # Respond to a participant request. This is deliberately separate from the
  # direct turn-on/turn-off operations: denying a request must not change state.
  def respond_to_ai_companion_request(
    switch_action : Int32 | Int64 | String,
    agree : Bool = true,
    delete_assets : Bool = false,
  ) : JSON::Any
    turn_on = ai_companion_turn_on_action?(switch_action)
    path = turn_on ? "respond-to-turn-on" : "respond-to-turn-off"
    params = {"agree" => agree.to_s}
    params["delete_assets"] = delete_assets.to_s unless turn_on

    response = post("/api/rooms/#{@room_id}/ai-companion/#{path}", params: params, headers: JSON_HEADERS)
    data = parse_command_response(response, "respond to AI Companion request")
    self[:ai_companion_request] = nil
    data
  end

  # Confirm the AI Companion state that a participant changed before the host
  # joined. This prompt has its own SDK operation and does not take a bitmask.
  def confirm_ai_companion_status(agree : Bool = true) : JSON::Any
    response = post("/api/rooms/#{@room_id}/ai-companion/confirm-status-when-join", params: {"agree" => agree.to_s}, headers: JSON_HEADERS)
    data = parse_command_response(response, "confirm AI Companion status")
    self[:ai_companion_confirm] = nil
    data
  end

  private def ai_companion_turn_on_action?(switch_action : Int32 | Int64 | String) : Bool
    case switch_action
    when 2, "AICompanionSwitchActionTurnOn", "turn_on"
      true
    when 1, "AICompanionSwitchActionTurnOff", "turn_off"
      false
    else
      raise "unknown AI companion switch action: #{switch_action}"
    end
  end

  # Stop waiting in the join-before-host state.
  def cancel_waiting_for_host : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/cancel-waiting-host", headers: JSON_HEADERS)
    data = parse_command_response(response, "cancel waiting for host")
    self[:waiting_for_host] = nil
    data
  end

  # =========================================================
  # Audio / Video (Interface::AudioMuteable, Interface::VideoMuteable)
  # =========================================================

  # Answer a host prompt using the SDK's dedicated response API. This is not a
  # generic self-unmute command: false must be sent so the host receives a deny.
  def answer_unmute_audio_request(accepted : Bool) : JSON::Any
    response = post(
      "/api/rooms/#{@room_id}/audio/answer-unmute-request",
      params: {"accepted" => accepted.to_s},
      headers: JSON_HEADERS
    )
    data = parse_command_response(response, "answer host audio unmute request")
    self[:ask_unmute_audio] = nil
    data
  end

  # The Zoom SDK names this an "unmute video" response even though the room
  # notification asks the user to start video.
  def answer_start_video_request(accepted : Bool) : JSON::Any
    response = post(
      "/api/rooms/#{@room_id}/video/answer-unmute-request",
      params: {"accepted" => accepted.to_s},
      headers: JSON_HEADERS
    )
    data = parse_command_response(response, "answer host start video request")
    self[:ask_start_video] = nil
    data
  end

  # Desired state lives in the path: /audio/mute vs /audio/unmute. No request
  # body or query param — the verb endpoints mirror the wrapper's start/stop style.
  def mute_audio(state : Bool = true, index : Int32 | String = 0) : Bool
    action = state ? "mute" : "unmute"
    response = post("/api/rooms/#{@room_id}/audio/#{action}", headers: JSON_HEADERS)
    parse_command_response(response, "#{action} room audio")
    self[:mic_mute] = state
    state
  end

  # /video/mute stops self video, /video/unmute starts it. Not a toggle, so the
  # desired state is sent directly by picking the endpoint.
  def mute_video(state : Bool = true, index : Int32 | String = 0) : Bool
    action = state ? "mute" : "unmute"
    response = post("/api/rooms/#{@room_id}/video/#{action}", headers: JSON_HEADERS)
    parse_command_response(response, "#{action} room video")
    self[:camera_mute] = state
    state
  end

  # =========================================================
  # Volume
  # =========================================================

  def set_speaker_volume(volume : Float64) : Float64
    body = {volume: volume}.to_json
    response = post("/api/rooms/#{@room_id}/settings/volume/speaker", body: body, headers: JSON_HEADERS)
    parse_command_response(response, "set speaker volume")
    # The SDK getter can lag immediately after a successful set. Publish the
    # requested value now; OnCurrentSpeakerVolumeChanged is authoritative and
    # will replace it if the room applies a different value.
    self[:speaker_volume] = volume
    volume
  end

  def set_microphone_volume(volume : Float64) : Float64
    body = {volume: volume}.to_json
    response = post("/api/rooms/#{@room_id}/settings/volume/microphone", body: body, headers: JSON_HEADERS)
    parse_command_response(response, "set microphone volume")
    # Automatic gain control may adjust this asynchronously. The WebSocket event
    # updates the status when that happens; an immediate GET can still be stale.
    self[:microphone_volume] = volume
    volume
  end

  # =========================================================
  # Cloud Recording
  # =========================================================
  #
  # Starting can be gated by account policy: the service 409s until a person
  # accepts the in-room disclaimer, and the SDK refuses with 352 until a
  # recording notification email is set. The driver may satisfy the email gate,
  # but it never accepts the consent disclaimer on a person's behalf.
  #
  # `notification_email` is the address Zoom sends the recording link to. It is
  # supplied by whoever starts the recording (not stored) and is required before
  # any remote request. It is only sent to the SDK if the email gate demands it.

  RECORDING_DISCLAIMER       = "REMINDER_TYPE_RECORDING_DISCLAIMER"
  RECORDING_DISCLAIMER_VALUE =   3
  ERR_ALREADY_IN_THIS_STATE  =  10
  ERR_RECORDING_EMAIL_UNSET  = 352

  def start_recording(notification_email : String? = nil) : JSON::Any
    email = notification_email.try(&.presence) || raise "a recording notification email is required"
    response = post("/api/rooms/#{@room_id}/recording/cloud/start", headers: JSON_HEADERS)
    detail = error_detail(response)

    if sdk_error_code(detail) == ERR_RECORDING_EMAIL_UNSET
      set_recording_notification_email(email)
      response = post("/api/rooms/#{@room_id}/recording/cloud/start", headers: JSON_HEADERS)
      detail = error_detail(response)
    end

    if response.status_code == 409 && disclaimer_gated?(detail)
      prompt_recording_disclaimer
      self[:recording_disclaimer_needed] = true
      return JSON.parse(%({"message":"recording disclaimer confirmation required","recording_started":false,"disclaimer_needed":true}))
    end

    data = if response.success?
             # Validate body-level failures before publishing optimistic state.
             parse_command_response(response, "start cloud recording")
           elsif sdk_error_code(detail) == ERR_ALREADY_IN_THIS_STATE
             JSON.parse(%({"message":"cloud recording already started","recording_started":true}))
           else
             parse_command_response(response, "start cloud recording")
           end

    self[:recording_disclaimer_needed] = nil
    self[:recording] = "started"
    data
  end

  # Set the address Zoom emails the recording link to. Supplied by the caller.
  def set_recording_notification_email(email : String) : JSON::Any
    address = email.presence
    raise "a notification email is required" unless address
    body = {email: address}.to_json
    response = post("/api/rooms/#{@room_id}/recording/notification-email", body: body, headers: JSON_HEADERS)
    parse_command_response(response, "set recording notification email")
  end

  private def error_detail(response) : JSON::Any?
    return nil if response.success?
    JSON.parse(response.body)["detail"]?
  rescue
    nil
  end

  private def sdk_error_code(detail : JSON::Any?) : Int32?
    detail.try(&.["error_code"]?).try(&.as_i?)
  rescue
    nil
  end

  private def disclaimer_gated?(detail : JSON::Any?) : Bool
    !!detail.try(&.dig?("precheck", "disclaimer_needed")).try(&.as_bool?)
  rescue
    false
  end

  def stop_recording : JSON::Any
    response = post("/api/rooms/#{@room_id}/recording/cloud/stop", headers: JSON_HEADERS)
    detail = error_detail(response)
    data = if response.success?
             parse_command_response(response, "stop cloud recording")
           elsif sdk_error_code(detail) == ERR_ALREADY_IN_THIS_STATE
             JSON.parse(%({"message":"cloud recording already stopped","recording_stopped":true}))
           else
             parse_command_response(response, "stop cloud recording")
           end

    self[:recording] = "stopped"
    data
  end

  def pause_recording : JSON::Any
    response = post("/api/rooms/#{@room_id}/recording/cloud/pause", headers: JSON_HEADERS)
    data = parse_command_response(response, "pause cloud recording")
    self[:recording] = "paused"
    data
  end

  def resume_recording : JSON::Any
    response = post("/api/rooms/#{@room_id}/recording/cloud/resume", headers: JSON_HEADERS)
    data = parse_command_response(response, "resume cloud recording")
    self[:recording] = "started"
    data
  end

  # =========================================================
  # Participants
  # =========================================================

  def get_participants : JSON::Any
    response = get("/api/rooms/#{@room_id}/participants/", headers: JSON_HEADERS)
    data = parse_command_response(response, "get participants")
    self[:participants] = data
    data
  end

  # =========================================================
  # Utility
  # =========================================================

  def wake_up : JSON::Any
    response = post("/api/rooms/#{@room_id}/pre-meeting/wake-up", headers: JSON_HEADERS)
    parse_command_response(response, "wake room")
  end

  def get_health : JSON::Any
    response = get("/health", headers: JSON_HEADERS)
    msg = parse_command_response(response, "get wrapper health")
    self[:health] = msg
    msg
  end

  # =========================================================
  # Event stream (WebSocket push)
  # =========================================================
  #
  # The microservice pushes SDK callbacks for this room over a WebSocket
  # (including mute, volume, recording and participant changes). We hold one
  # reconnecting socket and reflect events straight into status. Polling remains
  # a slow fallback reconciler for anything missed while a socket was down.

  private def start_event_stream : Nil
    # Specs normally disable live sockets because config.uri points at the mock
    # command server. A dedicated override lets event-ingestion specs exercise
    # the real WebSocket and private handler without exposing a command that can
    # inject events into production drivers.
    return if setting?(Bool, :running_specs) && event_stream_uri.nil?
    @ws_generation += 1
    generation = @ws_generation
    room_id = @room_id
    spawn { run_event_stream(generation, room_id) }
  end

  private def stop_event_stream : Nil
    @ws_generation += 1
    socket = @socket
    @socket = nil
    socket.try(&.close)
  rescue e
    logger.debug(exception: e) { "error closing event stream" }
  end

  private def run_event_stream(generation : Int32, room_id : String) : Nil
    while generation == @ws_generation
      begin
        socket = HTTP::WebSocket.new(URI.parse("#{event_ws_base}/api/rooms/#{room_id}/events"), ws_headers)
        unless generation == @ws_generation
          socket.close
          break
        end
        @socket = socket
        socket.on_message { |message| handle_event(message) if generation == @ws_generation }
        logger.debug { "event stream connected for #{room_id}" }
        socket.run # blocks until the socket closes
      rescue e
        logger.warn(exception: e) { "event stream error for #{room_id}" }
      ensure
        @socket = nil if @socket == socket
      end
      break unless generation == @ws_generation
      sleep 5.seconds
    end
  end

  # WebSocket base derived from the driver's configured HTTP uri (uri_base):
  # http -> ws, https -> wss. Keeps the event stream on the same host as commands.
  private def event_ws_base : String
    base = (event_stream_uri || config.uri.try(&.to_s).presence || "http://localhost:8000").rchop("/")
    base.sub(/\Ahttps?/) { |scheme| scheme == "https" ? "wss" : "ws" }
  end

  private def event_stream_uri : String?
    setting?(String, :event_stream_uri).try(&.presence)
  end

  private def ws_headers : HTTP::Headers
    headers = HTTP::Headers.new
    auth = setting?(JSON::Any, :basic_auth)
    user = auth.try(&.["username"]?).try(&.as_s?)
    if user && !user.empty?
      pass = auth.try(&.["password"]?).try(&.as_s?) || ""
      headers["Authorization"] = "Basic #{Base64.strict_encode("#{user}:#{pass}")}"
    end
    headers
  end

  # Translate a room event into status. Payload shapes match the wrapper's
  # room_manager sinks: enums are emitted as their SDK member names (e.g.
  # "MeetingStatusInMeeting", "ConnectionStateConnected"), structs as flat dicts
  # (AudioStatus.isMuted, VideoStatus.sending, MeetingRecordingInfo.*).
  # Unknown events are logged so new callbacks can be discovered without
  # dropping data silently.
  private def handle_event(message : String) : Nil
    event = JSON.parse(message)
    event_name = event["event"]?.try(&.as_s)
    case event_name
    when "keepalive"
      # idle heartbeat from the service; nothing to do
    when "EventsDropped"
      # our subscriber queue overflowed upstream; view may be stale -> resync
      logger.warn { "event stream dropped #{event["count"]?} events; resyncing" }
      spawn { refresh }
    when "OnUpdateMeetingStatus"
      if status_payload = event["status"]?
        if meeting_status = EventState.meeting_status(status_payload)
          self[:meeting_status] = meeting_status
          # Exact match required: "MeetingStatusNotInMeeting" also ends in
          # "InMeeting". Transient states such as waiting-for-host are not an
          # active meeting, but must not erase the prompt that explains them.
          meeting_active = meeting_status == "MeetingStatusInMeeting"
          self[:meeting_active] = meeting_active
          if meeting_active
            clear_meeting_password_state
          elsif EventState.meeting_session_ended?(meeting_status)
            clear_meeting_session_state
          end
        end
      end
    when "OnZRConnectionStateChanged"
      state = event["state"]?.try(&.as_s)
      self[:connection_state] = state
      self[:online] = state == "ConnectionStateConnected"
    when "OnConfReadyNotification"
      # Ready is not the same as in-meeting. Reconcile from the authoritative
      # status endpoint instead of fabricating an active meeting.
      spawn { reconcile_meeting_status }
    when "OnExitMeetingNotification"
      result = event["result"]?.try(&.as_i?)
      if result.nil? || result == 0
        self[:meeting_status] = "MeetingStatusNotInMeeting"
        self[:meeting_active] = false
        clear_meeting_session_state
      else
        # A failed exit callback is not evidence that the room left. Ask the
        # authoritative status endpoint instead of fabricating an inactive state.
        spawn { reconcile_meeting_status }
      end
    when "OnMeetingErrorNotification"
      # Join/start commands are asynchronous: result 0 only means the Zoom Room
      # accepted the command. Preserve the SDK's authoritative failure details
      # even when the subsequent NotInMeeting/exit events clear session state.
      self[:meeting_error] = event["errorInfo"]? || event
    when "OnMeetingEndedNotification"
      self[:meeting_ended] = event["errorInfo"]? || event
      self[:meeting_status] = "MeetingStatusNotInMeeting"
      self[:meeting_active] = false
      clear_meeting_session_state
    when "OnMeetingNeedsPasswordNotification"
      show = event["showPasswordDialog"]?.try(&.as_bool?) || false
      wrong_and_retry = event["wrongAndRetry"]?.try(&.as_bool?) || false
      if show
        self[:meeting_password_required] = event
        if (password = @pending_meeting_password) && !@meeting_password_attempted && !wrong_and_retry
          # Mark before spawning so duplicate SDK notifications cannot submit the
          # same password twice and risk incrementing the room's lockout counter.
          @meeting_password_attempted = true
          spawn do
            send_meeting_password(password)
          rescue e
            logger.warn(exception: e) { "automatic meeting password submission failed" }
          end
        end
      else
        clear_meeting_password_state
      end
    when "OnConfDeviceLockStatusNotification"
      self[:meeting_password_lock_status] = event["lockStatus"]? || event
    when "OnPairRoomResult"
      self[:paired] = event["result"]?.try(&.as_i?) == 0
    when "OnRoomUnpairedReason"
      self[:room_unpaired_reason] = event["reason"]? || event
      self[:paired] = false
      self[:online] = false
      self[:connection_state] = nil
      self[:room_status] = nil
      self[:meeting_status] = nil
      self[:meeting_active] = false
      clear_meeting_session_state
      clear_room_notifications
    when "OnUpdateMyAudioStatus"
      muted = event.dig?("audioStatus", "isMuted").try(&.as_bool?)
      self[:mic_mute] = muted unless muted.nil?
    when "OnUpdateMyVideoNotification"
      sending = event.dig?("videoStatus", "sending").try(&.as_bool?)
      self[:camera_mute] = !sending unless sending.nil?
    when "OnCurrentSpeakerVolumeChanged"
      self[:speaker_volume] = event["volume"]?
    when "OnCurrentMicrophoneVolumeChanged"
      self[:microphone_volume] = event["volume"]?
    when "OnCurrentSelectedMicrophoneMuted"
      muted = event["muted"]?.try(&.as_bool?)
      self[:microphone_hardware_muted] = muted unless muted.nil?
    when "OnUpdateMeetingRecordingInfo"
      if info = event["recordingInfo"]?
        self[:recording_info] = info
        self[:recording] = if info["isCMRPaused"]?.try(&.as_bool?)
                             "paused"
                           elsif info["isCMRInProgress"]?.try(&.as_bool?)
                             "started"
                           else
                             "stopped"
                           end
      end
    when "OnNeedPromptStartRecordingDisclaimerUpdate"
      needed = event["need"]?.try(&.as_bool?) || false
      self[:recording_disclaimer_needed] = needed ? true : nil
    when "OnUserJoin", "OnUserLeave", "OnUserUpdate", "OnInitMeetingParticipants", "OnMeetingParticipantsChanged"
      # Roster changed; OnUserUpdate also carries waiting-room/silent-mode
      # participant changes. Re-fetch the authoritative list over REST.
      spawn { update_participants }
    when "OnUpdateMeetingList"
      # fires when the calendar list changes or a ListMeeting request resolves;
      # payload carries the full list so no follow-up fetch is needed
      self[:meetings] = event["meetings"]?
      self[:meetings_count] = event["count"]?
    when "OnUpdatedScheduleCalendarEventNotification"
      self[:calendar_schedule_result] = event["result"]?
    when "OnUpdatedDeleteCalendarEventNotification"
      self[:calendar_delete_result] = event["result"]?
    else
      if event_name && (key = PROMPT_EVENTS[event_name]?)
        self[key] = EventState.actionable_prompt?(event_name, event) ? event : nil
      elsif event_name && (key = INFORMATIONAL_EVENTS[event_name]?)
        self[key] = event
      elsif event_name && (key = ROOM_INFORMATIONAL_EVENTS[event_name]?)
        self[key] = event
      else
        logger.debug { "unhandled room event: #{message}" }
      end
    end
  rescue e
    logger.warn(exception: e) { "bad event payload: #{message}" }
  end

  private def update_participants : Nil
    get_participants
  rescue e
    logger.warn(exception: e) { "participant refresh failed" }
  end

  private def reconcile_meeting_status : Nil
    get_meeting_status
  rescue e
    logger.warn(exception: e) { "meeting status reconciliation failed" }
  end

  private def clear_meeting_notifications : Nil
    PROMPT_EVENTS.each_value { |key| self[key] = nil }
    INFORMATIONAL_EVENTS.each_value { |key| self[key] = nil }
  end

  private def clear_room_notifications : Nil
    ROOM_INFORMATIONAL_EVENTS.each_value { |key| self[key] = nil }
  end

  private def clear_meeting_session_state : Nil
    clear_meeting_password_state
    clear_meeting_notifications
    self[:participants] = nil
    self[:recording] = "stopped"
    self[:recording_info] = nil
    self[:recording_disclaimer_needed] = nil
  end

  private def reset_room_state : Nil
    clear_meeting_session_state
    clear_room_notifications
    self[:meeting_error] = nil
    self[:meeting_ended] = nil
    self[:meeting_password_lock_status] = nil
    self[:paired] = false
    self[:online] = false
    self[:room_status] = nil
    self[:connection_state] = nil
    self[:meeting_status] = nil
    self[:meeting_active] = false
  end

  private def clear_meeting_password_state : Nil
    @pending_meeting_password = nil
    @meeting_password_attempted = false
    self[:meeting_password_required] = nil
  end

  private def prepare_meeting_join : Nil
    clear_meeting_password_state
    self[:meeting_error] = nil
    self[:meeting_ended] = nil
    self[:meeting_password_lock_status] = nil
  end

  private def fetch_volume(kind : String, status_key : Symbol) : Float64
    response = get("/api/rooms/#{@room_id}/settings/volume/#{kind}", headers: JSON_HEADERS)
    data = parse_command_response(response, "get #{kind} volume")
    raw_volume = data.as_h?.try(&.["volume"]?) || data
    volume = raw_volume.as_f? || raw_volume.as_i?.try(&.to_f)
    raise "invalid #{kind} volume response: #{response.body}" unless volume
    self[status_key] = volume
    volume
  end

  private def parse_command_response(response, operation : String) : JSON::Any
    unless response.success?
      raise "#{operation} failed: HTTP #{response.status_code}: #{response.body}"
    end

    data = JSON.parse(response.body)
    if data.as_h?.try(&.["success"]?).try(&.as_bool?) == false
      raise "#{operation} failed: #{response.body}"
    end
    data
  end

  private def assert_true_result(data : JSON::Any, key : String, operation : String) : Nil
    if data.as_h?.try(&.[key]?).try(&.as_bool?) == false
      raise "#{operation} failed: #{data.to_json}"
    end
  end

  private def assert_zero_result(data : JSON::Any, key : String, operation : String) : Nil
    if (result = data.as_h?.try(&.[key]?).try(&.as_i?)) && result != 0
      raise "#{operation} failed: #{data.to_json}"
    end
  end

  # =========================================================
  # Polling (fallback reconciler)
  # =========================================================

  private def poll : Nil
    begin
      # get_room_status derives online from the SDK connection state. A healthy
      # wrapper HTTP response alone must never mark a disconnected room online.
      get_room_status
    rescue e
      logger.warn(exception: e) { "room-status poll failed" }
      self[:online] = false
      return
    end

    begin
      get_meeting_status
    rescue e
      logger.warn(exception: e) { "meeting-status poll failed" }
    end
  end
end

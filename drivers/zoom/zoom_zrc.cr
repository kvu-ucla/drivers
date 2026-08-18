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
    "OnConsentNotification"                  => "consent_prompt",
    "OnCombinedConsentNotification"          => "combined_consent_prompt",
    "OnMeetingReminderNotification"          => "meeting_reminder",
    "OnCustomizedReminderNotification"       => "customized_reminder",
    "OnPrivacyAlertNotification"             => "privacy_alert",
    "OnInactiveDetectionNotification"        => "inactive_detection",
    "OnReceiveRecordingRequest"              => "recording_request",
    "OnAskUnmuteAudioByHostNotification"     => "ask_unmute_audio",
    "OnAskStartVideoByHostNotification"      => "ask_start_video",
    "OnJBHWaitingHostNotification"           => "waiting_for_host",
    "OnEnableWaitingRoomOnEntryNotification" => "waiting_room_on_entry",
    "OnUpdateAdmitGuestEnableNotification"   => "admit_guest_enabled",
    "OnMeetingWillReleaseAutomatically"      => "meeting_will_release",
    "OnMeetingWillStopAutomatically"         => "meeting_will_stop",
    "OnReceiveAICompanionRequest"            => "ai_companion_request",
    "OnAICompanionStatusNeedConfirm"         => "ai_companion_confirm",
    "OnIncomingMeetingShareNotification"     => "incoming_share",
  }

  @room_id : String = ""
  @activation_code : String = ""
  @poll_interval : Int32 = 30
  @socket : HTTP::WebSocket?
  @ws_generation = 0

  def on_load
    on_update
  end

  def on_update
    stop_event_stream

    @room_id = setting?(String, :room_id) || ""
    @activation_code = setting?(String, :activation_code) || ""
    @poll_interval = setting?(Int32, :poll_interval) || 30

    schedule.clear
    if @room_id.empty?
      logger.warn { "room_id not configured; driver idle until set" }
      return
    end

    schedule.every(@poll_interval.seconds) { poll }
    schedule.in(2.seconds) { poll }

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
    raise "request failed with #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  def unpair_room : JSON::Any
    response = post("/api/rooms/#{@room_id}/unpair", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:online] = false
    JSON.parse(response.body)
  end

  # =========================================================
  # Status
  # =========================================================

  def get_room_status : JSON::Any
    response = get("/api/rooms/#{@room_id}/status", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    self[:room_status] = data
    data
  end

  def get_connection_state : JSON::Any
    response = get("/api/rooms/#{@room_id}/pre-meeting/connection-state", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    self[:connection_state] = data
    data
  end

  def get_meeting_status : JSON::Any
    response = get("/api/rooms/#{@room_id}/meeting/status", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    self[:meeting_status] = data
    # Treat any non-empty/non-null response as an active meeting
    self[:meeting_active] = !data.raw.nil? && data.raw != false
    data
  end

  def get_volumes : Nil
    speaker_resp = get("/api/rooms/#{@room_id}/settings/volume/speaker", headers: JSON_HEADERS)
    if speaker_resp.success?
      data = JSON.parse(speaker_resp.body)
      self[:speaker_volume] = data["volume"]? || data
    end

    mic_resp = get("/api/rooms/#{@room_id}/settings/volume/microphone", headers: JSON_HEADERS)
    if mic_resp.success?
      data = JSON.parse(mic_resp.body)
      self[:microphone_volume] = data["volume"]? || data
    end
  end

  def list_rooms : JSON::Any
    response = get("/api/rooms", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  # Re-fetch this room's full state on demand.
  def refresh : Nil
    get_connection_state
    get_room_status
    get_meeting_status
    get_volumes
    self[:online] = true
  rescue e
    logger.warn(exception: e) { "refresh failed" }
    self[:online] = false
  end

  # =========================================================
  # Meeting Controls
  # =========================================================

  def start_instant_meeting : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/start_instant", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:meeting_active] = true
    JSON.parse(response.body)
  end

  def join_meeting(meeting_number : String, password : String? = nil, bring_share : Bool = false) : JSON::Any
    body = JoinMeetingRequest.new(meeting_number, password, bring_share).to_json
    response = post("/api/rooms/#{@room_id}/meeting/join", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:meeting_active] = true
    JSON.parse(response.body)
  end

  # `url` is a required query param. The current ZRC SDK does not support
  # bringing a local share into meetings joined by URL.
  def join_meeting_by_url(url : String) : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/join-url", params: {"url" => url}, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:meeting_active] = true
    JSON.parse(response.body)
  end

  def start_meeting(
    meeting_number : String,
    meeting_name : String? = nil,
    host_name : String? = nil,
    start_time : String? = nil,
    end_time : String? = nil,
    bring_share : Bool? = nil,
  ) : StartMeetingRequest
    body = StartMeetingRequest.new(meeting_number, meeting_name, host_name, start_time, end_time, bring_share).to_json
    response = post("/api/rooms/#{@room_id}/meeting/start", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:meeting_active] = true
    StartMeetingRequest.from_json(response.body)
  end

  # =========================================================
  # Meeting List (room calendar)
  # =========================================================

  # Fetch the room's calendar meeting list. The service resolves this via the
  # SDK's OnUpdateMeetingList callback, so allow its default 15s wait.
  def list_meetings : JSON::Any
    response = get("/api/rooms/#{@room_id}/meetings/list", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    self[:meetings] = data["meetings"]?
    data
  end

  def exit_meeting : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/exit", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
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
      consent_type = payload.dig?("combinedConsent", "type").try(&.as_s?) || raise "combined consent payload missing type"
      confirm_combined_consent(consent_type, agree)
    when "meeting_reminder"
      reminder_type = payload.dig?("reminderContent", "reminderType").try(&.as_s?) || raise "reminder payload missing type"
      confirm_reminder(reminder_type, agree)
    when "customized_reminder"
      reminder_type = payload.dig?("customizedContent", "customizedDisclaimerType").try(&.as_s?) || raise "customized reminder payload missing type"
      confirm_custom_reminder(reminder_type, agree)
    when "recording_request"
      respond_to_recording_request(agree)
    when "inactive_detection"
      continue_on_inactivity if agree
      self[:inactive_detection] = nil
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
      mute_audio(false) if agree
      self[:ask_unmute_audio] = nil
    when "ask_start_video"
      mute_video(false) if agree
      self[:ask_start_video] = nil
    else
      raise "#{prompt} is not a confirmable prompt"
    end
    nil
  end

  def confirm_reminder(notification_type : Int32 | String, agree : Bool = true) : JSON::Any
    body = {is_agree: agree, notification_type: notification_type}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/confirm-reminder", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:meeting_reminder] = nil
    if recording_disclaimer?(notification_type)
      self[:recording_disclaimer_needed] = agree ? nil : true
    end
    JSON.parse(response.body)
  end

  private def recording_disclaimer?(notification_type : Int32 | String) : Bool
    notification_type == RECORDING_DISCLAIMER || notification_type == RECORDING_DISCLAIMER_VALUE
  end

  def confirm_custom_reminder(notification_type : Int32 | String, agree : Bool = true) : JSON::Any
    body = {is_agree: agree, notification_type: notification_type}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/confirm-custom-reminder", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:customized_reminder] = nil
    JSON.parse(response.body)
  end

  def confirm_consent(consent_type : Int32 | String, agree : Bool = true, consent_id : String = "") : JSON::Any
    body = {is_agree: agree, consent_type: consent_type, consent_id: consent_id}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/confirm-consent", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:consent_prompt] = nil
    JSON.parse(response.body)
  end

  def confirm_combined_consent(notification_type : Int32 | String, agree : Bool = true) : JSON::Any
    body = {is_agree: agree, notification_type: notification_type}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/confirm-combined-consent", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:combined_consent_prompt] = nil
    JSON.parse(response.body)
  end

  def handle_privacy_alert(privacy_alert_action : Int32 | String, privacy_alert_type : Int32 | String) : JSON::Any
    body = {privacy_alert_action: privacy_alert_action, privacy_alert_type: privacy_alert_type}.to_json
    response = post("/api/rooms/#{@room_id}/meeting/reminder/handle-privacy", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:privacy_alert] = nil
    JSON.parse(response.body)
  end

  # Keep the meeting alive after an inactivity-detection prompt.
  def continue_on_inactivity : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/reminder/continue-on-inactivity", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:inactive_detection] = nil
    JSON.parse(response.body)
  end

  # Approve or deny a participant's recording request.
  def respond_to_recording_request(agree : Bool, persist : Bool = false) : JSON::Any
    body = {agree: agree, is_persist: persist}.to_json
    response = post("/api/rooms/#{@room_id}/recording/respond-to-request", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:recording_request] = nil
    JSON.parse(response.body)
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
    raise "request failed with #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  # Directly turn on AI Companion features. The ZRC SDK accepts an Int64 bitmask
  # (SmartSummary=32, SmartQuestion=64); SmartRecording cannot be turned on with
  # this API.
  def ai_companion_on(features : Int64) : JSON::Any
    response = post("/api/rooms/#{@room_id}/ai-companion/turn-on", params: {"features" => features.to_s}, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  # `delete_assets` discards any already-generated AI assets when turning off.
  def ai_companion_off(features : Int64, delete_assets : Bool = false) : JSON::Any
    response = post("/api/rooms/#{@room_id}/ai-companion/turn-off", params: {"features" => features.to_s, "delete_assets" => delete_assets.to_s}, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    JSON.parse(response.body)
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
    raise "request failed with #{response.status_code}" unless response.success?
    self[:ai_companion_request] = nil
    JSON.parse(response.body)
  end

  # Confirm the AI Companion state that a participant changed before the host
  # joined. This prompt has its own SDK operation and does not take a bitmask.
  def confirm_ai_companion_status(agree : Bool = true) : JSON::Any
    response = post("/api/rooms/#{@room_id}/ai-companion/confirm-status-when-join", params: {"agree" => agree.to_s}, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:ai_companion_confirm] = nil
    JSON.parse(response.body)
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
    raise "request failed with #{response.status_code}" unless response.success?
    self[:waiting_for_host] = nil
    JSON.parse(response.body)
  end

  # =========================================================
  # Audio / Video (Interface::AudioMuteable, Interface::VideoMuteable)
  # =========================================================

  # Desired state lives in the path: /audio/mute vs /audio/unmute. No request
  # body or query param — the verb endpoints mirror the wrapper's start/stop style.
  def mute_audio(state : Bool = true, index : Int32 | String = 0) : Bool
    action = state ? "mute" : "unmute"
    response = post("/api/rooms/#{@room_id}/audio/#{action}", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:mic_mute] = state
    state
  end

  # /video/mute stops self video, /video/unmute starts it. Not a toggle, so the
  # desired state is sent directly by picking the endpoint.
  def mute_video(state : Bool = true, index : Int32 | String = 0) : Bool
    action = state ? "mute" : "unmute"
    response = post("/api/rooms/#{@room_id}/video/#{action}", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:camera_mute] = state
    state
  end

  # =========================================================
  # Volume
  # =========================================================

  def set_speaker_volume(volume : Float64) : Float64
    body = {volume: volume}.to_json
    response = post("/api/rooms/#{@room_id}/settings/volume/speaker", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:speaker_volume] = volume
    volume
  end

  def set_microphone_volume(volume : Float64) : Float64
    body = {volume: volume}.to_json
    response = post("/api/rooms/#{@room_id}/settings/volume/microphone", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
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
  # supplied by whoever starts the recording (not stored); it is only sent to
  # the SDK if a gate actually demands it, so unrestricted accounts can start
  # without one.

  RECORDING_DISCLAIMER       = "REMINDER_TYPE_RECORDING_DISCLAIMER"
  RECORDING_DISCLAIMER_VALUE =   3
  ERR_ALREADY_IN_THIS_STATE  =  10
  ERR_RECORDING_EMAIL_UNSET  = 352

  def start_recording(notification_email : String? = nil) : JSON::Any
    response = post("/api/rooms/#{@room_id}/recording/cloud/start", headers: JSON_HEADERS)
    detail = error_detail(response)

    if sdk_error_code(detail) == ERR_RECORDING_EMAIL_UNSET
      raise "recording needs a notification email; call start_recording with notification_email" unless notification_email
      set_recording_notification_email(notification_email)
      response = post("/api/rooms/#{@room_id}/recording/cloud/start", headers: JSON_HEADERS)
      detail = error_detail(response)
    end

    if response.status_code == 409 && disclaimer_gated?(detail)
      prompt_recording_disclaimer
      self[:recording_disclaimer_needed] = true
      return JSON.parse(%({"message":"recording disclaimer confirmation required","recording_started":false,"disclaimer_needed":true}))
    end

    unless response.success? || sdk_error_code(detail) == ERR_ALREADY_IN_THIS_STATE
      raise "start recording failed: #{response.status_code} #{response.body}"
    end

    self[:recording_disclaimer_needed] = nil
    self[:recording] = "started"
    response.success? ? JSON.parse(response.body) : JSON.parse(%({"message":"cloud recording already started","recording_started":true}))
  end

  # Set the address Zoom emails the recording link to. Supplied by the caller.
  def set_recording_notification_email(email : String) : JSON::Any
    address = email.presence
    raise "a notification email is required" unless address
    body = {email: address}.to_json
    response = post("/api/rooms/#{@room_id}/recording/notification-email", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    JSON.parse(response.body)
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
    raise "request failed with #{response.status_code}" unless response.success?
    self[:recording] = "stopped"
    JSON.parse(response.body)
  end

  def pause_recording : JSON::Any
    response = post("/api/rooms/#{@room_id}/recording/cloud/pause", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:recording] = "paused"
    JSON.parse(response.body)
  end

  def resume_recording : JSON::Any
    response = post("/api/rooms/#{@room_id}/recording/cloud/resume", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:recording] = "started"
    JSON.parse(response.body)
  end

  # =========================================================
  # Participants
  # =========================================================

  def get_participants : JSON::Any
    response = get("/api/rooms/#{@room_id}/participants/", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    self[:participants] = data
    data
  end

  # =========================================================
  # Utility
  # =========================================================

  def wake_up : JSON::Any
    response = post("/api/rooms/#{@room_id}/pre-meeting/wake-up", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  def get_health : JSON::Any
    response = get("/health", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    msg = JSON.parse(response.body)
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
    return if setting?(Bool, :running_specs) # no live sockets under the spec harness
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
    base = (config.uri.try(&.to_s).presence || "http://localhost:8000").rchop("/")
    base.sub(/\Ahttps?/) { |scheme| scheme == "https" ? "wss" : "ws" }
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
      meeting_status = event["status"]?.try(&.as_s)
      self[:meeting_status] = meeting_status
      # exact match required: "MeetingStatusNotInMeeting" also ends in "InMeeting"
      self[:meeting_active] = meeting_status == "MeetingStatusInMeeting"
    when "OnZRConnectionStateChanged"
      state = event["state"]?.try(&.as_s)
      self[:connection_state] = state
      self[:online] = state == "ConnectionStateConnected"
    when "OnConfReadyNotification"
      self[:meeting_active] = true
    when "OnExitMeetingNotification"
      self[:meeting_active] = false
    when "OnPairRoomResult"
      self[:paired] = event["result"]?.try(&.as_i?) == 0
    when "OnRoomUnpairedReason"
      self[:paired] = false
      self[:online] = false
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
    when "OnUserJoin", "OnUserLeave", "OnInitMeetingParticipants", "OnMeetingParticipantsChanged"
      # roster changed; re-fetch the authoritative list over REST
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

  # =========================================================
  # Polling (fallback reconciler)
  # =========================================================

  private def poll : Nil
    get_room_status
    get_meeting_status
    self[:online] = true
  rescue e
    logger.warn(exception: e) { "poll failed" }
    self[:online] = false
  end
end

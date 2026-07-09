require "set"
require "base64"
require "uri"
require "http/web_socket"
require "placeos-driver"
require "./zoom_zrc_models"

class Zoom::ZRC::Controller < PlaceOS::Driver
  descriptive_name "Zoom ZRC Gateway"
  generic_name :ZoomZRC
  description "Shared gateway to the Zoom ZRC SDK microservice; drives many rooms by room_id"

  uri_base "http://localhost:8000"

  default_settings({
    poll_interval: 30,
    basic_auth:    {
      username: "",
      password: "",
    },
  })

  JSON_HEADERS = {"Content-Type" => "application/json", "Accept" => "application/json"}

  @poll_interval : Int32 = 30
  @polled_rooms = Set(String).new

  # Per-room event WebSockets (real-time push). See "Room event streams" below.
  @room_sockets = {} of String => HTTP::WebSocket
  @event_rooms = Set(String).new

  def on_load
    on_update
  end

  def on_update
    @poll_interval = setting?(Int32, :poll_interval) || 30

    schedule.clear
    schedule.every(@poll_interval.seconds) { poll_status }
    schedule.in(2.seconds) { poll_status }

    # Announce (re)start so existing room modules re-seed + re-register. Their
    # `refresh` calls repopulate @polled_rooms, which a fresh instance has lost.
    publish("zoom/gateway", {online: true}.to_json)
  end

  private def key(room_id : String, name : String) : String
    "#{room_id}/#{name}"
  end

  # Set a room's status key locally AND broadcast the delta to subscribers.
  # No-ops when the value is unchanged, sparing both the local change event and
  # the bus. Field names here MUST match Zoom::ZRC::StatusUpdate.
  private def publish_status(room_id : String, name : String, value) : Nil
    k = key(room_id, name)
    return if self[k]? == value
    self[k] = value
    publish("zoom/#{room_id}/status", {room_id: room_id, key: name, value: value}.to_json)
  end

  private def track(room_id : String) : Nil
    @polled_rooms << room_id
    ensure_event_stream(room_id)
  end

  # Fetch and publish a room's full current state. Called by each logic module
  # on load (and after a gateway restart) to seed itself, and registers the room
  # for ongoing polling.
  def refresh(room_id : String) : Nil
    track(room_id)
    get_connection_state(room_id)
    get_room_status(room_id)
    get_meeting_status(room_id)
    get_volumes(room_id)
    publish_status(room_id, "online", true)
  rescue e
    logger.warn(exception: e) { "refresh failed for room #{room_id}" }
    publish_status(room_id, "online", false)
  end

  # =========================================================
  # Pairing
  # =========================================================

  # Pair a Zoom Room using an activation code
  def pair_room(room_id : String, activation_code : String) : JSON::Any
    body = PairRoomRequest.new(activation_code).to_json
    response = post("/api/rooms/#{room_id}/pair", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    track(room_id)
    JSON.parse(response.body)
  end

  # Unpair the Zoom Room
  def unpair_room(room_id : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/unpair", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    @polled_rooms.delete(room_id)
    @room_sockets.delete(room_id).try(&.close)
    publish_status(room_id, "online", false)
    JSON.parse(response.body)
  end

  # =========================================================
  # Status / Polling
  # =========================================================

  def get_room_status(room_id : String) : JSON::Any
    response = get("/api/rooms/#{room_id}/status", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    publish_status(room_id, "room_status", data)
    data
  end

  def get_connection_state(room_id : String) : JSON::Any
    response = get("/api/rooms/#{room_id}/pre-meeting/connection-state", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    publish_status(room_id, "connection_state", data)
    data
  end

  def get_meeting_status(room_id : String) : JSON::Any
    response = get("/api/rooms/#{room_id}/meeting/status", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    publish_status(room_id, "meeting_status", data)
    # Treat any non-empty/non-null response as an active meeting
    publish_status(room_id, "meeting_active", !data.raw.nil? && data.raw != false)
    data
  end

  def get_volumes(room_id : String) : Nil
    speaker_resp = get("/api/rooms/#{room_id}/settings/volume/speaker", headers: JSON_HEADERS)
    if speaker_resp.success?
      data = JSON.parse(speaker_resp.body)
      publish_status(room_id, "speaker_volume", data["volume"]? || data)
    end

    mic_resp = get("/api/rooms/#{room_id}/settings/volume/microphone", headers: JSON_HEADERS)
    if mic_resp.success?
      data = JSON.parse(mic_resp.body)
      publish_status(room_id, "microphone_volume", data["volume"]? || data)
    end
  end

  def list_rooms : JSON::Any
    response = get("/api/rooms", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    JSON.parse(response.body)
  end

  # =========================================================
  # Meeting Controls
  # =========================================================

  def start_instant_meeting(room_id : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/meeting/start_instant", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "meeting_active", true)
    JSON.parse(response.body)
  end

  def join_meeting(room_id : String, meeting_number : String, password : String? = nil, bring_share : Bool = false) : JSON::Any
    body = JoinMeetingRequest.new(meeting_number, password, bring_share).to_json
    response = post("/api/rooms/#{room_id}/meeting/join", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "meeting_active", true)
    JSON.parse(response.body)
  end

  def join_meeting_by_url(room_id : String, url : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/meeting/join-url", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "meeting_active", true)
    JSON.parse(response.body)
  end

  def start_meeting(
    room_id : String,
    meeting_number : String,
    meeting_name : String? = nil,
    host_name : String? = nil,
    start_time : String? = nil,
    end_time : String? = nil,
    bring_share : Bool? = nil,
  ) : StartMeetingRequest
    body = StartMeetingRequest.new(meeting_number, meeting_name, host_name, start_time, end_time, bring_share).to_json
    response = post("/api/rooms/#{room_id}/meeting/start", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "meeting_active", true)
    StartMeetingRequest.from_json(response.body)
  end

  def exit_meeting(room_id : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/meeting/exit", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    # Reconcile from the device rather than fabricating the post-exit cascade:
    # get_meeting_status publishes the observed meeting_active / meeting_status.
    get_meeting_status(room_id)
    data
  end

  # =========================================================
  # Audio / Video
  # =========================================================

  # `mute` is a query param (boolean); there is no request body.
  def mute_audio(room_id : String, state : Bool = true) : Bool
    response = post("/api/rooms/#{room_id}/audio/mute", params: {"mute" => state.to_s}, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "mic_mute", state)
    state
  end

  # `stop` is a required query param (boolean): stop=true mutes self video,
  # stop=false starts it. Not a toggle, so the desired state is sent directly.
  def mute_video(room_id : String, state : Bool = true) : Bool
    response = post("/api/rooms/#{room_id}/video/mute", params: {"stop" => state.to_s}, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "camera_mute", state)
    state
  end

  # =========================================================
  # Volume
  # =========================================================

  def set_speaker_volume(room_id : String, volume : Float64) : Float64
    body = {volume: volume}.to_json
    response = post("/api/rooms/#{room_id}/settings/volume/speaker", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "speaker_volume", volume)
    volume
  end

  def set_microphone_volume(room_id : String, volume : Float64) : Float64
    body = {volume: volume}.to_json
    response = post("/api/rooms/#{room_id}/settings/volume/microphone", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "microphone_volume", volume)
    volume
  end

  # =========================================================
  # Cloud Recording
  # =========================================================

  def start_recording(room_id : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/recording/cloud/start", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "recording", "started")
    JSON.parse(response.body)
  end

  def stop_recording(room_id : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/recording/cloud/stop", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "recording", "stopped")
    JSON.parse(response.body)
  end

  def pause_recording(room_id : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/recording/cloud/pause", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "recording", "paused")
    JSON.parse(response.body)
  end

  def resume_recording(room_id : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/recording/cloud/resume", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    publish_status(room_id, "recording", "started")
    JSON.parse(response.body)
  end

  # =========================================================
  # Participants
  # =========================================================

  def get_participants(room_id : String) : JSON::Any
    response = get("/api/rooms/#{room_id}/participants/", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    data = JSON.parse(response.body)
    publish_status(room_id, "participants", data)
    data
  end

  # =========================================================
  # Utility
  # =========================================================

  def wake_up(room_id : String) : JSON::Any
    response = post("/api/rooms/#{room_id}/pre-meeting/wake-up", headers: JSON_HEADERS)
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
  # Private
  # =========================================================

  # =========================================================
  # Room event streams (WebSocket push)
  # =========================================================
  #
  # The microservice pushes SDK callbacks per room over a WebSocket. We hold one
  # socket per tracked room and translate events into the same publish_status
  # deltas the poll loop uses, so state reflects the device in real time. Polling
  # remains as a fallback that reconciles anything a socket drops or never pushes.

  # Start a reconnecting event stream for a room if one isn't already running.
  private def ensure_event_stream(room_id : String) : Nil
    return if setting?(Bool, :running_specs) # no live sockets under the spec harness
    return if @event_rooms.includes?(room_id)
    @event_rooms << room_id
    spawn { run_event_stream(room_id) }
  end

  private def run_event_stream(room_id : String) : Nil
    while @polled_rooms.includes?(room_id)
      begin
        socket = HTTP::WebSocket.new(URI.parse("#{event_ws_base}/api/rooms/#{room_id}/events"), ws_headers)
        @room_sockets[room_id] = socket
        socket.on_message { |message| handle_event(room_id, message) }
        logger.debug { "event stream connected for #{room_id}" }
        socket.run # blocks until the socket closes
      rescue e
        logger.warn(exception: e) { "event stream error for #{room_id}" }
      ensure
        @room_sockets.delete(room_id)
      end
      # reconnect unless the room was untracked while we were connected
      sleep 5.seconds if @polled_rooms.includes?(room_id)
    end
    @event_rooms.delete(room_id)
    logger.debug { "event stream stopped for #{room_id}" }
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

  # Translate a room event into status deltas. Unknown events are logged so the
  # real catalog can be discovered without dropping data silently.
  private def handle_event(room_id : String, message : String) : Nil
    event = JSON.parse(message)
    case event["event"]?.try(&.as_s)
    when "OnUpdateMeetingStatus"
      meeting_status = event["status"]?.try(&.as_s)
      publish_status(room_id, "meeting_status", meeting_status)
      publish_status(room_id, "meeting_active", meeting_status == "InMeeting")
    when "OnZRConnectionStateChanged"
      state = event["state"]?.try(&.as_s)
      publish_status(room_id, "connection_state", state)
      publish_status(room_id, "online", state == "ConnectionStateConnected")
    when "OnConfReadyNotification"
      publish_status(room_id, "meeting_active", true)
    when "OnExitMeetingNotification"
      publish_status(room_id, "meeting_active", false)
    when "OnPairRoomResult"
      publish_status(room_id, "paired", event["result"]?.try(&.as_i?) == 0)
    when "OnRoomUnpairedReason"
      publish_status(room_id, "paired", false)
      publish_status(room_id, "online", false)
    else
      logger.debug { "unhandled room event for #{room_id}: #{message}" }
    end
  rescue e
    logger.warn(exception: e) { "bad event payload for #{room_id}: #{message}" }
  end

  # =========================================================
  # Polling (fallback reconciler)
  # =========================================================

  # One poll loop for the whole fleet: check gateway liveness, then refresh each
  # tracked room. Per-room failures mark just that room offline; a dead gateway
  # marks `connected` false and skips the rooms.
  private def poll_status : Nil
    begin
      get_health
      self[:connected] = true
    rescue e
      self[:connected] = false
      logger.warn(exception: e) { "gateway health check failed" }
      return
    end

    @polled_rooms.each { |room_id| poll_room(room_id) }
  end

  private def poll_room(room_id : String) : Nil
    get_room_status(room_id)
    get_meeting_status(room_id)
    publish_status(room_id, "online", true)
  rescue e
    logger.warn(exception: e) { "poll failed for room #{room_id}" }
    publish_status(room_id, "online", false)
  end
end

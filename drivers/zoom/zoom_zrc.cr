require "placeos-driver"
require "placeos-driver/interface/muteable"
require "./zoom_zrc_models"

# REST API for controlling Zoom Rooms via the ZRC SDK microservice
# The microservice must be running locally on the Zoom Room device

class Zoom::ZRC::Controller < PlaceOS::Driver
  include Interface::AudioMuteable
  include Interface::VideoMuteable

  descriptive_name "Zoom ZRC Room Controller"
  generic_name :ZoomZRC
  description "Controls a Zoom Room via the ZRC SDK microservice running on the device"

  uri_base "http://localhost:8000"

  default_settings({
    room_id:       "default",
    poll_interval: 30,
    basic_auth:    {
      username: "",
      password: "",
    },
  })

  JSON_HEADERS = {"Content-Type" => "application/json", "Accept" => "application/json"}

  @room_id : String = "default"
  @poll_interval : Int32 = 30

  def on_load
    on_update
  end

  def on_update
    @room_id = setting(String, :room_id)
    @poll_interval = setting?(Int32, :poll_interval) || 30

    schedule.clear
    schedule.every(@poll_interval.seconds) { poll_status }
    schedule.in(2.seconds) { poll_status }
  end

  # =========================================================
  # Status / Polling
  # =========================================================

  def get_room_status : JSON::Any
    response = get("/api/rooms/#{@room_id}/status", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    status_data = JSON.parse(response.body)
    self[:room_status] = status_data
    status_data
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

  def join_meeting_by_url(url : String) : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/join-url", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:meeting_active] = true
    JSON.parse(response.body)
  end

  def start_meeting(
    meeting_number : String,
    meeting_name : String = "",
    host_name : String = "",
    start_time : String = "",
    end_time : String = "",
    bring_share : Bool = false,
  ) : JSON::Any
    body = StartMeetingRequest.new(meeting_number, meeting_name, host_name, start_time, end_time, bring_share).to_json
    response = post("/api/rooms/#{@room_id}/meeting/start", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:meeting_active] = true
    JSON.parse(response.body)
  end

  def exit_meeting : JSON::Any
    response = post("/api/rooms/#{@room_id}/meeting/exit", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:meeting_active] = false
    self[:meeting_status] = nil
    self[:mic_mute] = nil
    self[:camera_mute] = nil
    self[:recording] = nil
    JSON.parse(response.body)
  end

  # =========================================================
  # Audio / Video (implements Interface::AudioMuteable, Interface::VideoMuteable)
  # =========================================================

  def mute_audio(state : Bool = true, index : Int32 | String = 0) : Bool
    body = {mute: state}.to_json
    response = post("/api/rooms/#{@room_id}/audio/mute", body: body, headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:mic_mute] = state
    state
  end

  # The /video/mute endpoint has no request body (toggle behaviour in the ZRC SDK).
  # We track current state and only call the API when a state change is needed.
  def mute_video(state : Bool = true, index : Int32 | String = 0) : Bool
    current = self[:camera_mute]?.try(&.as_bool?) || false
    if current != state
      response = post("/api/rooms/#{@room_id}/video/mute", headers: JSON_HEADERS)
      raise "request failed with #{response.status_code}" unless response.success?
    end
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

  def start_recording : JSON::Any
    response = post("/api/rooms/#{@room_id}/recording/cloud/start", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    self[:recording] = "started"
    JSON.parse(response.body)
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
    response = post("/api/health", headers: JSON_HEADERS)
    raise "request failed with #{response.status_code}" unless response.success?
    msg = JSON.parse(response.body)

    logger.debug { "#{msg}" }
  end

  # =========================================================
  # Private
  # =========================================================

  private def poll_status : Nil
    get_health
  rescue e
    logger.warn(exception: e) { "poll failed" }
  end
end

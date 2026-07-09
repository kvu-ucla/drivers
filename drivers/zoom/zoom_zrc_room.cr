require "placeos-driver"
require "placeos-driver/interface/muteable"
require "./zoom_zrc_models"

class Zoom::ZRC::Room < PlaceOS::Driver
  include Interface::AudioMuteable
  include Interface::VideoMuteable

  descriptive_name "Zoom ZRC Room"
  generic_name :ZoomRoom
  description "Binds a single Zoom Room (by room_id) to the shared Zoom ZRC gateway"

  default_settings({
    # REQUIRED: the room_id this space maps to on the ZRC microservice
    room_id: "",
  })

  # Status keys accepted off the gateway's status channel. Anything else on the
  # channel is ignored so a malformed publish can't write arbitrary keys.
  STATUS_KEYS = {
    "room_status", "connection_state", "meeting_status", "meeting_active",
    "mic_mute", "camera_mute", "recording", "speaker_volume",
    "microphone_volume", "participants", "online",
  }

  @room_id : String = ""

  def on_load
    on_update
  end

  def on_update
    @room_id = resolve_room_id

    subscriptions.clear
    # Real-time per-key status deltas for this room.
    monitor("zoom/#{@room_id}/status") { |_sub, payload| apply_status(payload) }
    # Re-seed + re-register whenever the gateway (re)starts.
    monitor("zoom/gateway") { |_sub, payload| on_gateway_event(payload) }

    # Seed current state now; also registers this room for gateway polling.
    seed
  end

  # The shared gateway module in this system
  protected def gateway
    system[:ZoomZRC]
  end

  # =========================================================
  # Pairing
  # =========================================================

  def pair_room(activation_code : String)
    gateway.pair_room(@room_id, activation_code)
  end

  def unpair_room
    gateway.unpair_room(@room_id)
  end

  # Force a fresh pull of this room's full state from the gateway.
  def refresh
    gateway.refresh(@room_id)
  end

  # =========================================================
  # Meeting Controls
  # =========================================================

  def start_instant_meeting
    gateway.start_instant_meeting(@room_id)
  end

  def join_meeting(meeting_number : String, password : String? = nil, bring_share : Bool = false)
    gateway.join_meeting(@room_id, meeting_number, password, bring_share)
  end

  def join_meeting_by_url(url : String)
    gateway.join_meeting_by_url(@room_id, url)
  end

  def start_meeting(
    meeting_number : String,
    meeting_name : String = "",
    host_name : String = "",
    start_time : String = "",
    end_time : String = "",
    bring_share : Bool = false,
  )
    gateway.start_meeting(@room_id, meeting_number, meeting_name, host_name, start_time, end_time, bring_share)
  end

  def exit_meeting
    gateway.exit_meeting(@room_id)
  end

  # =========================================================
  # Audio / Video (Interface::AudioMuteable, Interface::VideoMuteable)
  # =========================================================

  def mute_audio(state : Bool = true, index : Int32 | String = 0) : Nil
    gateway.mute_audio(@room_id, state)
  end

  def mute_video(state : Bool = true, index : Int32 | String = 0) : Nil
    gateway.mute_video(@room_id, state)
  end

  # =========================================================
  # Volume
  # =========================================================

  def set_speaker_volume(volume : Float64)
    gateway.set_speaker_volume(@room_id, volume)
  end

  def set_microphone_volume(volume : Float64)
    gateway.set_microphone_volume(@room_id, volume)
  end

  # =========================================================
  # Cloud Recording
  # =========================================================

  def start_recording
    gateway.start_recording(@room_id)
  end

  def stop_recording
    gateway.stop_recording(@room_id)
  end

  def pause_recording
    gateway.pause_recording(@room_id)
  end

  def resume_recording
    gateway.resume_recording(@room_id)
  end

  # =========================================================
  # Participants
  # =========================================================

  def get_participants
    gateway.get_participants(@room_id)
  end

  # =========================================================
  # Utility
  # =========================================================

  def wake_up
    gateway.wake_up(@room_id)
  end

  # =========================================================
  # Private
  # =========================================================

  # Resolve this space's Zoom room_id. 

  private def resolve_room_id : String
    if explicit = setting?(String, :room_id).presence
      return explicit
    end

    calendar_id = setting?(String, :calendar_id).presence
    unless calendar_id
      raise "room_id could not be resolved: set a `room_id` on this module, or a calendar_id"
    end
    calendar_id.downcase
  end

  private def seed
    gateway.refresh(@room_id)
  rescue e
    logger.warn(exception: e) { "seed failed for room #{@room_id}" }
  end

  # Turn a published delta into a flat status key the UI binds to.
  private def apply_status(payload : String)
    update = StatusUpdate.from_json(payload)
    return unless STATUS_KEYS.includes?(update.key)
    self[update.key] = update.value
  rescue e
    logger.warn(exception: e) { "bad status payload: #{payload}" }
  end

  private def on_gateway_event(payload : String)
    data = JSON.parse(payload)
    seed if data["online"]?.try(&.as_bool?)
  rescue e
    logger.warn(exception: e) { "bad gateway event: #{payload}" }
  end
end

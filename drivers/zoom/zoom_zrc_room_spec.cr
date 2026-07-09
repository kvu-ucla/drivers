require "placeos-driver/spec"

# :nodoc:
# Stands in for the shared Zoom::ZRC gateway module. Records the room_id each
# call was tagged with so we can assert the logic module forwards correctly.
class ZoomZRCMock < DriverSpecs::MockDriver
  def refresh(room_id : String) : Nil
    self[:refresh_room] = room_id
  end

  def mute_audio(room_id : String, state : Bool = true) : Bool
    self[:mute_room] = room_id
    self[:mute_state] = state
    state
  end

  def pair_room(room_id : String, activation_code : String)
    self[:pair_room_id] = room_id
    self[:pair_code] = activation_code
    JSON.parse(%({"ok": true}))
  end
end

DriverSpecs.mock_driver "Zoom::ZRC::Room" do
  system({
    ZoomZRC: {ZoomZRCMock},
  })

  # ====
  # With no room_id / calendar_id set, room_id resolves to the system resource
  # email. The module seeds itself on load by calling gateway.refresh(room_id).
  sleep 500.milliseconds
  system(:ZoomZRC)[:refresh_room].should eq("spec@acaprojects.com")

  # ====
  # Commands forward to the gateway tagged with the resolved room_id.
  exec(:mute_audio, true).get
  system(:ZoomZRC)[:mute_room].should eq("spec@acaprojects.com")
  system(:ZoomZRC)[:mute_state].should eq(true)

  exec(:pair_room, "ACT-9").get
  system(:ZoomZRC)[:pair_room_id].should eq("spec@acaprojects.com")
  system(:ZoomZRC)[:pair_code].should eq("ACT-9")

  # ====
  # Status deltas published by the gateway are reflected into flat local keys.
  publish("zoom/spec@acaprojects.com/status", {room_id: "spec@acaprojects.com", key: "mic_mute", value: true}.to_json)
  sleep 500.milliseconds
  status[:mic_mute].should eq(true)

  # ====
  # Keys outside the whitelist are ignored (a malformed publish can't write
  # arbitrary status).
  publish("zoom/spec@acaprojects.com/status", {room_id: "spec@acaprojects.com", key: "not_allowed", value: true}.to_json)
  sleep 500.milliseconds
  status[:not_allowed]?.should be_nil

  # ====
  # An explicit room_id setting overrides the calendar/email fallback, and the
  # module re-seeds + re-subscribes on the new channel.
  settings({room_id: "custom-room"})
  sleep 500.milliseconds
  system(:ZoomZRC)[:refresh_room].should eq("custom-room")

  publish("zoom/custom-room/status", {room_id: "custom-room", key: "camera_mute", value: false}.to_json)
  sleep 500.milliseconds
  status[:camera_mute].should eq(false)

  # ====
  # pair_room with no argument falls back to the activation_code setting.
  settings({room_id: "custom-room", activation_code: "SET-CODE"})
  sleep 500.milliseconds
  exec(:pair_room).get
  system(:ZoomZRC)[:pair_room_id].should eq("custom-room")
  system(:ZoomZRC)[:pair_code].should eq("SET-CODE")
end

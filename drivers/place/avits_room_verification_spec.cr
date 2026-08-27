require "placeos-driver/spec"

# Mock device modules — minimal stand-ins that mirror the real drivers'
# observable status keys and callable functions (per the capability audit).

# :nodoc:
class MockDisplay < DriverSpecs::MockDriver
  def on_load
    self[:power] = false
    self[:input] = "Hdmi1"
  end

  def power(state : Bool)
    self[:power] = state
    state
  end
end

# :nodoc:
class MockZoom < DriverSpecs::MockDriver
  def on_load
    self[:connection_state] = "ConnectionStateConnected"
    self[:online] = true
    self[:paired] = true
    self[:meeting_active] = false
    self[:meeting_ended] = nil
  end

  def get_connection_state
    self[:connection_state]
  end

  # real driver reconciles this via the event stream; the mock reflects the
  # observable end state directly.
  def start_instant_meeting
    self[:meeting_ended] = nil
    self[:meeting_active] = true
    "started"
  end

  def exit_meeting
    self[:meeting_active] = false
    self[:meeting_ended] = {reason: "ended"}
    "exited"
  end
end

# :nodoc: DSP exposing no output level/meter readback (today's reality).
class MockMixer < DriverSpecs::MockDriver
  def on_load
  end
end

# :nodoc: NVX encoder exposing no on-demand input-signal readback.
class MockEncoder < DriverSpecs::MockDriver
  def on_load
  end
end

# :nodoc: NVX decoder exposing no stream-lock / output-present readback.
class MockDecoder < DriverSpecs::MockDriver
  def on_load
  end
end

DriverSpecs.mock_driver "Place::AvitsRoomVerification" do
  system({
    Display: {MockDisplay},
    ZoomZRC: {MockZoom},
    Mixer:   {MockMixer},
    Encoder: {MockEncoder},
    Decoder: {MockDecoder},
  })

  settings({
    profile:         {display_input: "Hdmi1"},
    confirm_timeout: 2,
    poll_interval:   0.05,
  })

  find = ->(checks : Array(JSON::Any), device : String, check : String) {
    checks.find { |c| c["device"].as_s == device && c["check"].as_s == check }.not_nil!
  }

  # --- happy path -----------------------------------------------------------
  exec(:verify).get

  verification = status[:verification]
  verification["ranAt"].as_s.should_not be_empty
  checks = verification["checks"].as_a

  # Display read-only input vs expected
  input_check = find.call(checks, "display", "input")
  input_check["type"].as_s.should eq("read")
  input_check["result"].as_s.should eq("pass")
  input_check["observed"]["input"].as_s.should eq("Hdmi1")
  input_check["expected"].as_s.should eq("Hdmi1")

  # Display active power: on -> confirm -> restore prior (off) state
  power_check = find.call(checks, "display", "power")
  power_check["type"].as_s.should eq("active")
  power_check["result"].as_s.should eq("pass")
  power_check["restored"].as_bool.should eq(true)
  system(:Display_1)[:power].should eq(false)

  # Zoom read-only connection
  conn_check = find.call(checks, "zoom", "connection")
  conn_check["result"].as_s.should eq("pass")

  # Zoom active meeting round-trip, left with no meeting running
  meet_check = find.call(checks, "zoom", "meeting")
  meet_check["type"].as_s.should eq("active")
  meet_check["result"].as_s.should eq("pass")
  meet_check["restored"].as_bool.should eq(true)
  system(:ZoomZRC_1)[:meeting_active].should eq(false)

  # DSP pending readback (no meter today) — never fails
  dsp_check = find.call(checks, "dsp", "audio_signal")
  dsp_check["result"].as_s.should eq("skipped")
  dsp_check["reason"].as_s.should eq("pending_readback")

  # NVX encoder + decoder pending readback
  enc_check = find.call(checks, "nvx_encoder", "input_signal")
  enc_check["result"].as_s.should eq("skipped")
  enc_check["reason"].as_s.should eq("pending_readback")
  lock_check = find.call(checks, "nvx_decoder", "stream_lock")
  lock_check["result"].as_s.should eq("skipped")
  lock_check["reason"].as_s.should eq("pending_readback")
  out_check = find.call(checks, "nvx_decoder", "output_present")
  out_check["result"].as_s.should eq("skipped")
  out_check["reason"].as_s.should eq("pending_readback")

  # --- safety: never touch a live meeting ----------------------------------
  system(:ZoomZRC_1)[:meeting_active] = true
  exec(:verify).get
  live = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  live["result"].as_s.should eq("skipped")
  live["reason"].as_s.should eq("meeting_already_active")
  system(:ZoomZRC_1)[:meeting_active].should eq(true)
  system(:ZoomZRC_1)[:meeting_active] = false

  # --- auto light-up: DSP meter readback appears ---------------------------
  system(:Mixer_1)[:output_level] = 0.7
  exec(:verify).get
  lit = find.call(status[:verification]["checks"].as_a, "dsp", "audio_signal")
  lit["result"].as_s.should eq("pass")

  # --- failure surfaced, not hidden: input mismatch ------------------------
  settings({
    profile:         {display_input: "Hdmi2"},
    confirm_timeout: 2,
    poll_interval:   0.05,
  })
  exec(:verify).get
  mism = find.call(status[:verification]["checks"].as_a, "display", "input")
  mism["result"].as_s.should eq("fail")
end

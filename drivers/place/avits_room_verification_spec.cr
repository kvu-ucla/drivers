require "placeos-driver/spec"

# Mock device modules — minimal stand-ins that mirror the real drivers'
# observable status keys and callable functions (per the capability audit).
#
# The active-check mocks expose the device readback functions the logic module
# now insists on (`power?`, `input?`), plus call counters and failure/delay
# controls (driven from status keys the spec sets) so the cleanup/restore
# behaviour can be proven, not just the happy path.

# :nodoc:
class MockDisplay < DriverSpecs::MockDriver
  def on_load
    self[:power] = false
    self[:input] = "Hdmi1"
    self[:power_query_count] = 0
    self[:input_query_count] = 0
    self[:power_set_count] = 0
  end

  # active command — controllable failure + delay
  def power(state : Bool)
    self[:power_set_count] = (self[:power_set_count]?.try(&.as_i) || 0) + 1
    raise "power command failed" if self[:fail_power_set]?.try(&.as_bool?)
    if (delay = self[:set_delay]?.try(&.as_f?)) && delay > 0
      sleep delay.seconds
    end
    self[:power] = state
    state
  end

  # device readback — forces a fresh read. Returns nil (unknown) when the spec
  # sets `report_power` false, modelling a stale/unreadable capture.
  def power?
    self[:power_query_count] = (self[:power_query_count]?.try(&.as_i) || 0) + 1
    return nil if self[:report_power]?.try(&.as_bool?) == false
    self[:power]?
  end

  def input?
    self[:input_query_count] = (self[:input_query_count]?.try(&.as_i) || 0) + 1
    return nil if self[:report_input]?.try(&.as_bool?) == false
    self[:input]?
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
    self[:start_count] = 0
    self[:exit_count] = 0
  end

  def get_connection_state
    self[:connection_state]
  end

  # real driver reconciles this via the event stream; the mock reflects the
  # observable end state directly. Controls:
  #   fail_start  -> raise (start exception)
  #   stall_start -> count the call but never mark the meeting active (models a
  #                  start that does not confirm within the timeout)
  def start_instant_meeting
    self[:start_count] = (self[:start_count]?.try(&.as_i) || 0) + 1
    raise "start_instant_meeting failed" if self[:fail_start]?.try(&.as_bool?)
    unless self[:stall_start]?.try(&.as_bool?)
      self[:meeting_ended] = nil
      self[:meeting_active] = true
    end
    "started"
  end

  # Control: fail_exit -> raise without clearing the meeting (models an exit we
  # cannot confirm — the room may still be running a meeting).
  def exit_meeting
    self[:exit_count] = (self[:exit_count]?.try(&.as_i) || 0) + 1
    raise "exit_meeting failed" if self[:fail_exit]?.try(&.as_bool?)
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

  # Display read-only input vs expected — proves the `input?` readback was called
  input_check = find.call(checks, "display", "input")
  input_check["type"].as_s.should eq("read")
  input_check["result"].as_s.should eq("pass")
  input_check["observed"]["input"].as_s.should eq("Hdmi1")
  input_check["expected"].as_s.should eq("Hdmi1")
  system(:Display_1)[:input_query_count].as_i.should be > 0

  # Display active power: on -> confirm -> restore prior (off) state via readback
  power_check = find.call(checks, "display", "power")
  power_check["type"].as_s.should eq("active")
  power_check["result"].as_s.should eq("pass")
  power_check["restored"].as_bool.should eq(true)
  system(:Display_1)[:power].should eq(false)
  system(:Display_1)[:power_query_count].as_i.should be > 0

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
  # start_instant_meeting must NEVER be called while a meeting is already active.
  system(:ZoomZRC_1)[:meeting_active] = true
  start_before = system(:ZoomZRC_1)[:start_count].as_i
  exit_before = system(:ZoomZRC_1)[:exit_count].as_i
  exec(:verify).get
  live = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  live["result"].as_s.should eq("skipped")
  live["reason"].as_s.should eq("meeting_already_active")
  system(:ZoomZRC_1)[:meeting_active].should eq(true)
  # neither meeting command was issued against the live meeting
  system(:ZoomZRC_1)[:start_count].as_i.should eq(start_before)
  system(:ZoomZRC_1)[:exit_count].as_i.should eq(exit_before)
  system(:ZoomZRC_1)[:meeting_active] = false

  # --- auto light-up: DSP meter readback appears ---------------------------
  system(:Mixer_1)[:output_level] = 0.7
  exec(:verify).get
  lit = find.call(status[:verification]["checks"].as_a, "dsp", "audio_signal")
  lit["result"].as_s.should eq("pass")

  # --- Zoom start times out (never confirms) -> cleanup STILL runs ----------
  # Even though start is never confirmed, exit_meeting is issued and the room is
  # left with no meeting active.
  system(:ZoomZRC_1)[:stall_start] = true
  exit_before = system(:ZoomZRC_1)[:exit_count].as_i
  exec(:verify).get
  stalled = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  stalled["result"].as_s.should eq("fail")
  stalled["observed"]["started"].as_bool.should eq(false)
  stalled["restored"].as_bool.should eq(true)
  system(:ZoomZRC_1)[:exit_count].as_i.should eq(exit_before + 1)
  system(:ZoomZRC_1)[:meeting_active].should eq(false)
  system(:ZoomZRC_1)[:stall_start] = false

  # --- Zoom start raises -> cleanup STILL runs ------------------------------
  system(:ZoomZRC_1)[:fail_start] = true
  exit_before = system(:ZoomZRC_1)[:exit_count].as_i
  exec(:verify).get
  raised = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  raised["result"].as_s.should eq("unknown")
  system(:ZoomZRC_1)[:exit_count].as_i.should eq(exit_before + 1)
  system(:ZoomZRC_1)[:meeting_active].should eq(false)
  system(:ZoomZRC_1)[:fail_start] = false

  # --- Zoom exit raises -> restored is honestly false -----------------------
  # A meeting starts, but exit cannot be confirmed; we must NOT claim restored.
  system(:ZoomZRC_1)[:fail_exit] = true
  exec(:verify).get
  exit_err = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  exit_err["result"].as_s.should eq("fail")
  exit_err["restored"].as_bool.should eq(false)
  system(:ZoomZRC_1)[:fail_exit] = false
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil

  # --- Display: stale/unknown prior -> never power on -----------------------
  # power? cannot report -> prior is unknown -> the display is NOT powered on and
  # no set command is issued.
  system(:Display_1)[:report_power] = false
  set_before = system(:Display_1)[:power_set_count].as_i
  exec(:verify).get
  unknown_pwr = find.call(status[:verification]["checks"].as_a, "display", "power")
  unknown_pwr["result"].as_s.should eq("unknown")
  unknown_pwr["reason"].as_s.should eq("prior_power_unknown")
  system(:Display_1)[:power_set_count].as_i.should eq(set_before)
  system(:Display_1)[:report_power] = true

  # --- Display: power command fails -> restore is STILL attempted -----------
  # power(true) raises; the ensure path still attempts to restore the captured
  # prior state (a second set call), and the result is not a false pass.
  system(:Display_1)[:fail_power_set] = true
  set_before = system(:Display_1)[:power_set_count].as_i
  exec(:verify).get
  failed_pwr = find.call(status[:verification]["checks"].as_a, "display", "power")
  failed_pwr["result"].as_s.should eq("unknown")
  # one set attempt for power(true), one for the restore attempt
  system(:Display_1)[:power_set_count].as_i.should eq(set_before + 2)
  system(:Display_1)[:fail_power_set] = false

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

require "placeos-driver/spec"

# Mock device modules — minimal stand-ins that mirror the real drivers'
# observable status keys and callable functions (per the capability audit).
#
# The active-check mocks expose the device readback functions the logic module
# insists on (`power?`, `input?`), plus call counters and failure/delay/race
# controls (driven from status keys the spec sets) so the cleanup/restore
# behaviour and the readback gate can be PROVEN, not merely asserted on the
# happy path.

# :nodoc:
class MockDisplay < DriverSpecs::MockDriver
  def on_load
    self[:power] = false
    self[:input] = "Hdmi1"
    self[:power_query_count] = 0
    self[:input_query_count] = 0
    self[:power_set_count] = 0
    self[:readback_broken] = false
  end

  # active command — controllable failure + delay. When `arm_readback_fail` is
  # set, performing a set "breaks" the readback (models a device that changes
  # but can no longer be read back to confirm).
  def power(state : Bool)
    self[:power_set_count] = (self[:power_set_count]?.try(&.as_i) || 0) + 1
    raise "power command failed" if self[:fail_power_set]?.try(&.as_bool?)
    self[:readback_broken] = true if self[:arm_readback_fail]?.try(&.as_bool?)
    if (delay = self[:set_delay]?.try(&.as_f?)) && delay > 0
      sleep delay.seconds
    end
    self[:power] = state
    state
  end

  # device readback — forces a fresh read. Controls (in precedence order):
  #   report_power=false           -> nil (unknown / unreadable capture)
  #   power_readback_stuck_off     -> always false (never confirms a power-on)
  #   readback_broken              -> nil (post-change readback failure)
  def power?
    self[:power_query_count] = (self[:power_query_count]?.try(&.as_i) || 0) + 1
    raise "power? readback faulted (disconnected device)" if self[:raise_power]?.try(&.as_bool?)
    return nil if self[:report_power]?.try(&.as_bool?) == false
    return false if self[:power_readback_stuck_off]?.try(&.as_bool?)
    return nil if self[:readback_broken]?.try(&.as_bool?)
    self[:power]?
  end

  # device readback — `live_input_override` returns a LIVE value that differs
  # from the cached `:input` status, proving the logic prefers the live value.
  def input?
    self[:input_query_count] = (self[:input_query_count]?.try(&.as_i) || 0) + 1
    return nil if self[:report_input]?.try(&.as_bool?) == false
    if (ov = self[:live_input_override]?) && !ov.raw.nil?
      return ov.as_s?
    end
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
    self[:pending_activation] = false
  end

  def get_connection_state
    self[:connection_state]
  end

  # Controls:
  #   fail_start  -> raise (start exception)
  #   stall_start -> count the call but never mark the meeting active (a start
  #                  that never confirms and never actually starts)
  #   late_start  -> arm a start that has NOT confirmed yet but WILL activate
  #                  the meeting on the next exit attempt (models a start that
  #                  becomes active after the confirmation window closed)
  def start_instant_meeting
    self[:start_count] = (self[:start_count]?.try(&.as_i) || 0) + 1
    raise "start_instant_meeting failed" if self[:fail_start]?.try(&.as_bool?)
    if self[:late_start]?.try(&.as_bool?)
      self[:pending_activation] = true
    elsif self[:stall_start]?.try(&.as_bool?)
      # counted only; meeting never becomes active
    else
      self[:meeting_ended] = nil
      self[:meeting_active] = true
    end
    "started"
  end

  # Controls:
  #   fail_exit    -> raise without clearing the meeting (an exit we cannot confirm)
  #   noop_exit    -> issued, but the meeting genuinely never ends (stays active)
  #   unknown_exit -> post-exit meeting_active readback is unknown/nil
  #   clean_exit   -> a clean self-initiated exit (OnExitMeetingNotification
  #                   result 0): the room leaves the meeting (meeting_active=false)
  #                   but NO meeting_ended is ever published (only
  #                   OnMeetingEndedNotification sets that)
  # Late-start race: the first exit "misses" the meeting because the async start
  # activates exactly as the exit lands; a subsequent exit then ends it.
  def exit_meeting
    self[:exit_count] = (self[:exit_count]?.try(&.as_i) || 0) + 1
    raise "exit_meeting failed" if self[:fail_exit]?.try(&.as_bool?)
    if self[:pending_activation]?.try(&.as_bool?)
      self[:pending_activation] = false
      self[:meeting_active] = true
      self[:meeting_ended] = nil
      return "raced"
    end
    return "still-active" if self[:noop_exit]?.try(&.as_bool?)
    if self[:unknown_exit]?.try(&.as_bool?)
      self[:meeting_active] = nil
      self[:meeting_ended] = nil
      return "exited-unknown"
    end
    if self[:clean_exit]?.try(&.as_bool?)
      self[:meeting_active] = false
      self[:meeting_ended] = nil
      return "exited-clean"
    end
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

  # Short confirm timeout keeps the timeout/race paths quick and deterministic.
  settings({
    profile:         {display_input: "Hdmi1"},
    confirm_timeout: 0.5,
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
  system(:ZoomZRC_1)[:start_count].as_i.should eq(start_before)
  system(:ZoomZRC_1)[:exit_count].as_i.should eq(exit_before)
  system(:ZoomZRC_1)[:meeting_active] = false

  # --- auto light-up: DSP meter readback appears ---------------------------
  system(:Mixer_1)[:output_level] = 0.7
  exec(:verify).get
  lit = find.call(status[:verification]["checks"].as_a, "dsp", "audio_signal")
  lit["result"].as_s.should eq("pass")

  # --- Zoom start times out (never confirms) -> cleanup STILL runs ----------
  # SPEC PROOF 4 (timeout path): restored transitions false -> confirmed-true.
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

  # --- Zoom GENUINE late start (the case that used to escape) ---------------
  # SPEC PROOF 3: start does NOT confirm in the window but the meeting becomes
  # active as the first exit lands; the retry loop must exit it again and leave
  # the room inactive. The extra exit call (+2) proves the retry actually fired.
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil
  system(:ZoomZRC_1)[:pending_activation] = false
  system(:ZoomZRC_1)[:late_start] = true
  exit_before = system(:ZoomZRC_1)[:exit_count].as_i
  exec(:verify).get
  late = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  late["result"].as_s.should eq("fail")
  late["observed"]["started"].as_bool.should eq(false)
  late["restored"].as_bool.should eq(true)
  system(:ZoomZRC_1)[:meeting_active].should eq(false)
  system(:ZoomZRC_1)[:exit_count].as_i.should eq(exit_before + 2)
  system(:ZoomZRC_1)[:late_start] = false

  # --- Zoom start raises -> cleanup STILL runs, restored carried on error ----
  # SPEC PROOF 4 / LOW: exception path reports restored (confirmed-true here)
  # via error_result rather than discarding it.
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil
  system(:ZoomZRC_1)[:fail_start] = true
  exit_before = system(:ZoomZRC_1)[:exit_count].as_i
  exec(:verify).get
  raised = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  raised["result"].as_s.should eq("unknown")
  raised["restored"].as_bool.should eq(true)
  system(:ZoomZRC_1)[:exit_count].as_i.should eq(exit_before + 1)
  system(:ZoomZRC_1)[:meeting_active].should eq(false)
  system(:ZoomZRC_1)[:fail_start] = false

  # --- Zoom exit raises -> restored is honestly false -----------------------
  # SPEC PROOF 4 (cannot confirm): a meeting starts but exit never confirms; we
  # must NOT claim restored.
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil
  system(:ZoomZRC_1)[:fail_exit] = true
  exec(:verify).get
  exit_err = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  exit_err["result"].as_s.should eq("fail")
  exit_err["restored"].as_bool.should eq(false)
  system(:ZoomZRC_1)[:fail_exit] = false
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil

  # --- Zoom CLEAN self-initiated exit (REGRESSION) --------------------------
  # OnExitMeetingNotification (result 0) leaves the room with meeting_active=false
  # but NEVER publishes meeting_ended. The old check REQUIRED meeting_ended and so
  # reported a genuinely-restored room as restored:false. Confirmation must
  # succeed on an affirmative meeting_active=false alone.
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil
  system(:ZoomZRC_1)[:clean_exit] = true
  exec(:verify).get
  clean = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  clean["result"].as_s.should eq("pass")
  clean["observed"]["ended"].as_bool.should eq(true)
  clean["restored"].as_bool.should eq(true)
  system(:ZoomZRC_1)[:meeting_active].should eq(false)
  system(:ZoomZRC_1)[:clean_exit] = false

  # --- Zoom exit publishes meeting_ended (OnMeetingEndedNotification) --------
  # The other real end path DOES publish meeting_ended; it must still confirm.
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil
  exec(:verify).get
  ended = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  ended["result"].as_s.should eq("pass")
  ended["restored"].as_bool.should eq(true)
  system(:ZoomZRC_1)[:meeting_active].should eq(false)
  system(:ZoomZRC_1)[:meeting_ended]["reason"].as_s.should eq("ended")

  # --- Zoom meeting stays active after bounded attempts -> restored FALSE ----
  # The exit is issued but the meeting genuinely never ends; we must never claim
  # restored while a meeting may still be running. All EXIT_ATTEMPTS (3) fire.
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil
  system(:ZoomZRC_1)[:noop_exit] = true
  exit_before = system(:ZoomZRC_1)[:exit_count].as_i
  exec(:verify).get
  stuck = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  stuck["result"].as_s.should eq("fail")
  stuck["restored"].as_bool.should eq(false)
  system(:ZoomZRC_1)[:meeting_active].should eq(true)
  system(:ZoomZRC_1)[:exit_count].as_i.should eq(exit_before + 3)
  system(:ZoomZRC_1)[:noop_exit] = false
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil

  # --- Zoom post-exit meeting_active reads UNKNOWN/nil -> does NOT confirm ----
  # Fail-closed: an unknown meeting_active must never confirm restoration.
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil
  system(:ZoomZRC_1)[:unknown_exit] = true
  exec(:verify).get
  unknown_meet = find.call(status[:verification]["checks"].as_a, "zoom", "meeting")
  unknown_meet["result"].as_s.should eq("fail")
  unknown_meet["restored"].as_bool.should eq(false)
  system(:ZoomZRC_1)[:unknown_exit] = false
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil

  # --- Display power-on confirmation TIMES OUT, restore SUCCEEDS -------------
  # SPEC PROOF 1: the power-on readback never confirms (stuck off), so the check
  # fails, but the captured prior state is restored and confirmed -> restored
  # true and the room returns to the captured (off) state, with the restore
  # command actually issued.
  system(:Display_1)[:power] = false
  system(:Display_1)[:power_readback_stuck_off] = true
  set_before = system(:Display_1)[:power_set_count].as_i
  exec(:verify).get
  timed_out = find.call(status[:verification]["checks"].as_a, "display", "power")
  timed_out["result"].as_s.should eq("fail")
  timed_out["restored"].as_bool.should eq(true)
  system(:Display_1)[:power].should eq(false)
  # power(true) attempt + the power(false) restore both issued
  system(:Display_1)[:power_set_count].as_i.should eq(set_before + 2)
  system(:Display_1)[:power_readback_stuck_off] = false

  # --- Display post-capture readback FAILS after change -> restored WITHHELD --
  # SPEC PROOF 2: the readback breaks the moment we change state, so even though
  # the restore command runs, restoration cannot be CONFIRMED -> restored false.
  # (Proves the readback gate, not merely that set-calls happened.)
  system(:Display_1)[:power] = false
  system(:Display_1)[:readback_broken] = false
  system(:Display_1)[:arm_readback_fail] = true
  set_before = system(:Display_1)[:power_set_count].as_i
  exec(:verify).get
  broken = find.call(status[:verification]["checks"].as_a, "display", "power")
  broken["result"].as_s.should eq("fail")
  broken["restored"].as_bool.should eq(false)
  # the restore command still ran (2 sets) even though it could not be confirmed
  system(:Display_1)[:power_set_count].as_i.should eq(set_before + 2)
  system(:Display_1)[:arm_readback_fail] = false
  system(:Display_1)[:readback_broken] = false

  # --- Display: stale/unknown prior -> never power on -----------------------
  system(:Display_1)[:report_power] = false
  set_before = system(:Display_1)[:power_set_count].as_i
  exec(:verify).get
  unknown_pwr = find.call(status[:verification]["checks"].as_a, "display", "power")
  unknown_pwr["result"].as_s.should eq("unknown")
  unknown_pwr["reason"].as_s.should eq("prior_power_unknown")
  system(:Display_1)[:power_set_count].as_i.should eq(set_before)
  system(:Display_1)[:report_power] = true

  # --- Display: power command fails -> restore attempted, restored honest ----
  # LOW: error_result now carries the cleanup outcome (restored false here).
  system(:Display_1)[:fail_power_set] = true
  set_before = system(:Display_1)[:power_set_count].as_i
  exec(:verify).get
  failed_pwr = find.call(status[:verification]["checks"].as_a, "display", "power")
  failed_pwr["result"].as_s.should eq("unknown")
  failed_pwr["restored"].as_bool.should eq(false)
  system(:Display_1)[:power_set_count].as_i.should eq(set_before + 2)
  system(:Display_1)[:fail_power_set] = false

  # --- MEDIUM proof: live input readback preferred over cached status --------
  # cached :input is stale ("Hdmi1") while the LIVE input? returns "Hdmi2"; the
  # profile expects "Hdmi2". A pass proves the logic used the live value, not
  # the cached status.
  settings({
    profile:         {display_input: "Hdmi2"},
    confirm_timeout: 0.5,
    poll_interval:   0.05,
  })
  system(:Display_1)[:input] = "Hdmi1"
  system(:Display_1)[:live_input_override] = "Hdmi2"
  exec(:verify).get
  live_in = find.call(status[:verification]["checks"].as_a, "display", "input")
  live_in["result"].as_s.should eq("pass")
  live_in["observed"]["input"].as_s.should eq("Hdmi2")
  system(:Display_1)[:live_input_override] = nil

  # --- failure surfaced, not hidden: input mismatch ------------------------
  # No override: live input? returns cached "Hdmi1" while the profile wants
  # "Hdmi2" -> fail.
  exec(:verify).get
  mism = find.call(status[:verification]["checks"].as_a, "display", "input")
  mism["result"].as_s.should eq("fail")
  mism["observed"]["input"].as_s.should eq("Hdmi1")

  # === round-2 hardening: trigger completeness contract ====================
  # The trigger reads a COMPLETE 8-tuple record on self[:verification]; verify
  # must always publish one. These cases prove a faulting/disconnected room can
  # no longer leave the sweep partial or unpublished.

  # --- a dependent module faulting mid-check does NOT abort the sweep --------
  # Display power readback RAISES (disconnected device) and Zoom start RAISES;
  # verify must still publish all 8 tuples, carry honest tuples for the faulting
  # checks (not drop them), keep the healthy checks real, and still run cleanup.
  settings({
    profile:         {display_input: "Hdmi1"},
    confirm_timeout: 0.5,
    poll_interval:   0.05,
  })
  system(:Display_1)[:power] = false
  system(:Display_1)[:report_power] = true
  system(:Display_1)[:report_input] = true
  system(:Display_1)[:readback_broken] = false
  system(:Display_1)[:arm_readback_fail] = false
  system(:Display_1)[:power_readback_stuck_off] = false
  system(:Display_1)[:fail_power_set] = false
  system(:Display_1)[:live_input_override] = nil
  system(:Display_1)[:raise_power] = true
  system(:ZoomZRC_1)[:meeting_active] = false
  system(:ZoomZRC_1)[:meeting_ended] = nil
  system(:ZoomZRC_1)[:clean_exit] = false
  system(:ZoomZRC_1)[:unknown_exit] = false
  system(:ZoomZRC_1)[:noop_exit] = false
  system(:ZoomZRC_1)[:stall_start] = false
  system(:ZoomZRC_1)[:late_start] = false
  system(:ZoomZRC_1)[:fail_exit] = false
  system(:ZoomZRC_1)[:fail_start] = true
  zoom_exit_before = system(:ZoomZRC_1)[:exit_count].as_i

  exec(:verify).get
  faulted = status[:verification]
  faulted["ranAt"].as_s.should_not be_empty
  fchecks = faulted["checks"].as_a
  # COMPLETE record: exactly the 8 sweep tuples, none dropped.
  fchecks.size.should eq(8)
  # faulting checks carry honest tuples (present, not missing)
  find.call(fchecks, "display", "power")["result"].as_s.should eq("unknown")
  zmeet = find.call(fchecks, "zoom", "meeting")
  zmeet["result"].as_s.should eq("unknown")
  # restore/cleanup invariant intact: exit attempted + confirmed even on the raise
  zmeet["restored"].as_bool.should eq(true)
  system(:ZoomZRC_1)[:exit_count].as_i.should eq(zoom_exit_before + 1)
  # healthy checks are still real, not collateral-aborted
  find.call(fchecks, "zoom", "connection")["result"].as_s.should eq("pass")
  find.call(fchecks, "dsp", "audio_signal")["result"].as_s.should eq("pass")
  find.call(fchecks, "display", "input")["result"].as_s.should eq("pass")
  find.call(fchecks, "nvx_encoder", "input_signal")["result"].as_s.should eq("skipped")
  find.call(fchecks, "nvx_decoder", "stream_lock")["result"].as_s.should eq("skipped")
  find.call(fchecks, "nvx_decoder", "output_present")["result"].as_s.should eq("skipped")
  system(:Display_1)[:raise_power] = false
  system(:ZoomZRC_1)[:fail_start] = false

  # --- absent / disconnected dependent modules -> absent tuples, no raise -----
  # Every dependent module points at a generic name absent from the system; the
  # sweep must publish 8 honest module_absent tuples, not raise or truncate.
  settings({
    modules: {display: "Ghost", zoom: "Ghost", dsp: "Ghost", encoder: "Ghost", decoder: "Ghost"},
    profile: {display_input: "Hdmi1"},
    confirm_timeout: 0.5,
    poll_interval:   0.05,
  })
  exec(:verify).get
  gone = status[:verification]
  gone["ranAt"].as_s.should_not be_empty
  gone_checks = gone["checks"].as_a
  gone_checks.size.should eq(8)
  gone_checks.each do |c|
    c["result"].as_s.should eq("skipped")
    c["reason"].as_s.should eq("module_absent")
  end
end

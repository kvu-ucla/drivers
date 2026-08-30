require "json"
require "placeos-driver"

# AVITS Room Verification
#
# A system-scoped logic module that actively verifies a room's core AV devices
# are functioning and records structured, evidence-shaped results on
# `self[:verification]` for the AVITS Room Check to consume. It orchestrates the
# *existing* device drivers (calling functions they already expose) via
# `system[:Module]`; it never reimplements device protocols and never edits a
# device driver.
#
# Display + Zoom are fully verified today. DSP (Shure) and NVX (Crestron) require
# readbacks the device drivers do not yet expose (audio meter, stream-lock,
# output-present); those checks degrade gracefully to `pending_readback` and
# light up automatically once the configured readback status key appears.
class Place::AvitsRoomVerification < PlaceOS::Driver
  descriptive_name "AVITS Room Verification"
  generic_name :AvitsRoomVerification
  description <<-DESC
    Actively verifies a room's core AV devices (Display, Zoom, DSP, NVX) and
    records evidence-shaped results on `self[:verification]` for the AVITS Room
    Check. Active checks capture prior state, act, confirm via readback, then
    restore. DSP + NVX checks report `pending_readback` until the device drivers
    expose the required signal/meter readbacks.
  DESC

  # Generic module names to verify within this system.
  struct Modules
    include JSON::Serializable
    getter display : String = "Display"
    getter zoom : String = "ZoomZRC"
    getter dsp : String = "Mixer"
    getter encoder : String = "Encoder"
    getter decoder : String = "Decoder"

    def initialize
    end
  end

  # Expected values sourced from the room readiness profile. The module verifies
  # against these; it does not invent them.
  struct Profile
    include JSON::Serializable
    getter display_input : String? = nil
    getter dsp_preset : Int32? = nil
    getter nvx_stream : String? = nil

    def initialize
    end
  end

  # Prospective readback status keys for checks that are pending driver support.
  # When the driver team exposes one of these keys (and it is configured here),
  # the matching check evaluates it automatically — no code change required.
  struct ReadbackKeys
    include JSON::Serializable
    getter dsp_meter : String = "output_level"
    getter encoder_signal : String = "input_1_sync"
    getter decoder_lock : String = "stream_locked"
    getter decoder_output : String = "output_present"

    def initialize
    end
  end

  # One evidence-shaped verification result. Optional fields are omitted when nil.
  struct CheckResult
    include JSON::Serializable
    getter device : String
    getter check : String
    getter type : String
    getter result : String

    @[JSON::Field(emit_null: false)]
    getter observed : JSON::Any?
    @[JSON::Field(emit_null: false)]
    getter expected : JSON::Any?
    @[JSON::Field(emit_null: false)]
    getter restored : Bool?
    @[JSON::Field(emit_null: false)]
    getter reason : String?

    def initialize(@device, @check, @type, @result, @observed = nil, @expected = nil, @restored = nil, @reason = nil)
    end
  end

  default_settings({
    # Generic module names to verify within this system.
    modules: {
      display: "Display",
      zoom:    "ZoomZRC",
      dsp:     "Mixer",
      encoder: "Encoder",
      decoder: "Decoder",
    },
    # Expected values from the room readiness profile.
    profile: {
      display_input: "Hdmi1",
      dsp_preset:    nil,
      nvx_stream:    nil,
    },
    # Readback keys that light up DSP/NVX checks once the drivers expose them.
    readback_keys: {
      dsp_meter:      "output_level",
      encoder_signal: "input_1_sync",
      decoder_lock:   "stream_locked",
      decoder_output: "output_present",
    },
    confirm_timeout: 10,
    poll_interval:   0.5,
  })

  @modules : Modules = Modules.new
  @profile : Profile = Profile.new
  @readback : ReadbackKeys = ReadbackKeys.new
  @confirm_timeout : Float64 = 10.0
  @poll_interval : Float64 = 0.5

  # Bounded number of exit attempts when cleaning up a Zoom verification meeting.
  # Defends against a start that activates *after* the confirmation window.
  EXIT_ATTEMPTS = 3

  def on_load
    on_update
  end

  def on_update
    @modules = setting?(Modules, :modules) || Modules.new
    @profile = setting?(Profile, :profile) || Profile.new
    @readback = setting?(ReadbackKeys, :readback_keys) || ReadbackKeys.new
    @confirm_timeout = setting?(Float64, :confirm_timeout) || 10.0
    @poll_interval = setting?(Float64, :poll_interval) || 0.5
  end

  # The full, ORDERED sweep contract: every (device, check, type) tuple this
  # module must publish on `self[:verification]` on EVERY run. The AVITS trigger
  # readback expects this complete 8-tuple record; a missing/partial record reads
  # as an execution fault. Any tuple not replaced by a real check result is
  # published fail-closed as `unknown` / `sweep_aborted`.
  SWEEP = [
    {device: "display", check: "input", type: "read"},
    {device: "display", check: "power", type: "active"},
    {device: "zoom", check: "connection", type: "read"},
    {device: "zoom", check: "meeting", type: "active"},
    {device: "dsp", check: "audio_signal", type: "active"},
    {device: "nvx_encoder", check: "input_signal", type: "read"},
    {device: "nvx_decoder", check: "stream_lock", type: "read"},
    {device: "nvx_decoder", check: "output_present", type: "read"},
  ]

  # Run every device verification and record the evidence schema. The trigger
  # contract (a COMPLETE 8-tuple record on `self[:verification]`) must hold on
  # EVERY path: individual checks never raise out of here, and even an
  # unexpected raise — or this fiber being killed mid-sweep (e.g. an exec/RPC
  # timeout while a check waits on a disconnected device) — still leaves a
  # complete, fail-closed record behind.
  @[Security(Level::Support)]
  def verify
    ran_at = Time.utc.to_rfc3339
    results = seed_sweep

    # Publish the fail-closed skeleton BEFORE any work: if the fiber is killed
    # mid-sweep before the ensure can run, the trigger still reads a complete
    # (all-`sweep_aborted`) record instead of an absent one.
    published = publish_sweep(ran_at, results)

    begin
      run_family(results) { display_checks }
      run_family(results) { zoom_checks }
      run_family(results) { [dsp_check] }
      run_family(results) { nvx_checks }
    ensure
      # Guarantees a COMPLETE record on every path — normal completion or an
      # unexpected raise — carrying whatever real results the sweep produced and
      # leaving the rest fail-closed.
      published = publish_sweep(ran_at, results)
    end

    published
  end

  # Pre-seed all 8 sweep tuples fail-closed (`unknown` / `sweep_aborted`) so a
  # tuple that never gets a real result is still published in the honest schema.
  private def seed_sweep : Hash(Tuple(String, String), CheckResult)
    seeded = {} of Tuple(String, String) => CheckResult
    SWEEP.each do |t|
      seeded[{t[:device], t[:check]}] =
        CheckResult.new(t[:device], t[:check], t[:type], "unknown", reason: "sweep_aborted")
    end
    seeded
  end

  # Run one check family and merge its results, keyed by (device, check). A
  # family that raises (a defensive backstop — families already emit their own
  # absent/error tuples) leaves its pre-seeded fail-closed tuples in place rather
  # than aborting the whole sweep.
  private def run_family(results, & : -> Array(CheckResult)) : Nil
    yield.each { |check| results[{check.device, check.check}] = check }
  rescue e
    logger.error(exception: e) { "verification check family raised mid-sweep; retaining fail-closed tuples" }
  end

  # Emit the full ordered sweep and publish it to `self[:verification]`.
  private def publish_sweep(ran_at : String, results)
    payload = {ranAt: ran_at, checks: SWEEP.map { |t| results[{t[:device], t[:check]}] }}
    self[:verification] = payload
    payload
  end

  # ------------------------------------------------------------------ Display

  private def display_checks : Array(CheckResult)
    name = @modules.display
    unless module_present?(name)
      return [absent("display", "input", "read"), absent("display", "power", "active")]
    end

    mod = system[name]
    [display_input_check(mod), display_power_check(mod)]
  rescue e
    # A disconnected/absent module can raise from the `system[name]` proxy lookup
    # itself (outside the leaf checks' own rescues) — emit honest error tuples so
    # the sweep stays complete instead of aborting.
    [error_result("display", "input", "read", e), error_result("display", "power", "active", e)]
  end

  # read-only: current input vs the profile's expected input. Forces a live
  # `input?` device readback first — never trust a stale cached status.
  private def display_input_check(mod) : CheckResult
    observed = read_input(mod)
    expected = @profile.display_input
    result =
      if observed.nil?
        "unknown"
      elsif expected.nil?
        "skipped"
      elsif observed == expected
        "pass"
      else
        "fail"
      end
    CheckResult.new("display", "input", "read", result,
      observed: any({input: observed}),
      expected: expected ? any(expected) : nil)
  rescue e
    error_result("display", "input", "read", e)
  end

  # active: capture the *confirmed* prior power via a live `power?` readback ->
  # power(true) -> confirm on -> restore the captured state on EVERY exit path.
  # We never mutate a display whose prior state we could not read, and only
  # report `restored: true` once the readback confirms the captured state.
  private def display_power_check(mod) : CheckResult
    restored : Bool? = nil
    prior = read_power(mod)

    # Do not act on an unknown prior — a stale/blank status must not lead us to
    # power a display on and then be unable to put it back.
    if prior.nil?
      return CheckResult.new("display", "power", "active", "unknown",
        observed: any({prior: nil}),
        reason: "prior_power_unknown")
    end

    powered = false
    begin
      mod.power(true).get
      powered = wait_until { read_power(mod) == true }
    ensure
      # Runs on completion, timeout, and exception alike.
      restored = restore_power(mod, prior)
    end

    CheckResult.new("display", "power", "active", powered ? "pass" : "fail",
      observed: any({powered_on: powered, prior: prior}),
      restored: restored)
  rescue e
    # Carry the cleanup outcome so the audit is honest even on the error path.
    error_result("display", "power", "active", e, restored: restored)
  end

  # Force a live device power readback. Returns the confirmed Bool, or nil when
  # the device cannot report it (unknown) — we deliberately do NOT fall back to
  # cached status, since staleness is exactly the risk we are guarding against.
  private def read_power(mod) : Bool?
    mod.power?.get.as_bool?
  rescue
    nil
  end

  # Force a live device input readback and PREFER the live returned value. The
  # cached `:input` status is only an explicit fallback for drivers whose
  # `input?` returns a non-string (e.g. an enum) form; a JSON-null return means
  # the device could not determine the input (reported as "unknown").
  private def read_input(mod) : String?
    raw = mod.input?.get
    return nil if raw.nil? || raw.raw.nil?
    raw.as_s? || mod.status?(String, :input)
  end

  # Restore the display to its captured prior power state and confirm via
  # readback. Returns true ONLY once the readback matches the captured state.
  private def restore_power(mod, prior : Bool) : Bool
    if prior
      wait_until { read_power(mod) == true }
    else
      mod.power(false).get
      wait_until { read_power(mod) == false }
    end
  rescue
    false
  end

  # --------------------------------------------------------------------- Zoom

  private def zoom_checks : Array(CheckResult)
    name = @modules.zoom
    unless module_present?(name)
      return [absent("zoom", "connection", "read"), absent("zoom", "meeting", "active")]
    end

    mod = system[name]
    [zoom_connection_check(mod), zoom_meeting_check(mod)]
  rescue e
    # Guard the `system[name]` proxy lookup (outside the leaf rescues) so a
    # disconnected/absent Zoom module yields honest error tuples, not an abort.
    [error_result("zoom", "connection", "read", e), error_result("zoom", "meeting", "active", e)]
  end

  # read-only: connection / online state.
  private def zoom_connection_check(mod) : CheckResult
    conn = mod.status?(String, :connection_state)
    online = mod.status?(Bool, :online)
    result =
      if online == true || conn == "ConnectionStateConnected"
        "pass"
      elsif conn.nil? && online.nil?
        "unknown"
      else
        "fail"
      end
    CheckResult.new("zoom", "connection", "read", result,
      observed: any({connection_state: conn, online: online}))
  rescue e
    error_result("zoom", "connection", "read", e)
  end

  # active: never touch a live meeting. Otherwise start the meeting, then ALWAYS
  # attempt to exit and confirm the room is left with no meeting running — on
  # every path (started, late/timed-out start, or an exception mid-sequence). A
  # verification meeting must never be left running.
  private def zoom_meeting_check(mod) : CheckResult
    if mod.status?(Bool, :meeting_active) == true
      return CheckResult.new("zoom", "meeting", "active", "skipped",
        observed: any({meeting_active: true}),
        reason: "meeting_already_active")
    end

    started = false
    ended = false
    restored : Bool? = false
    begin
      mod.start_instant_meeting.get
      started = wait_until { mod.status?(Bool, :meeting_active) == true }
    ensure
      # Cleanup runs even if start timed out or raised: a meeting may be running
      # even when we failed to confirm the start. `restored` stays false until
      # the readback confirms no meeting is active.
      ended = end_meeting(mod)
      restored = ended
    end

    result = started && ended ? "pass" : "fail"
    CheckResult.new("zoom", "meeting", "active", result,
      observed: any({started: started, ended: ended}),
      restored: restored)
  rescue e
    # Carry the cleanup outcome so the audit is honest even on the error path.
    error_result("zoom", "meeting", "active", e, restored: restored)
  end

  # Robustly end any meeting our start may have created — including a start that
  # activates *after* the initial confirmation window closed. Each pass re-issues
  # exit_meeting and re-confirms; we keep retrying while a meeting is (or becomes)
  # active, up to EXIT_ATTEMPTS. Returns true ONLY once a readback confirms no
  # meeting is active; otherwise false (never leaves a meeting reported as
  # restored when it might still be running).
  private def end_meeting(mod) : Bool
    EXIT_ATTEMPTS.times do
      begin
        mod.exit_meeting.get
      rescue
        # exit command raised; re-check state below and maybe retry.
      end

      confirmed = wait_until { meeting_confirmed_ended?(mod) }
      return true if confirmed

      # Not confirmed ended. If a meeting IS (or has become) active, loop and
      # exit again — this is the late-activating-start race. If nothing is
      # active we cannot do better, so report the honest current state.
      return false unless meeting_active?(mod) == true
    end

    # Exhausted attempts — report the honest final state.
    meeting_active?(mod) == false
  rescue
    false
  end

  # Confirm a verification meeting is truly ended. The sole REQUIRED signal is an
  # AFFIRMATIVE `meeting_active == false` (strict Bool false) — the authoritative
  # "not in meeting" readback that a clean self-initiated exit sets via
  # OnExitMeetingNotification (result 0). That path NEVER publishes
  # `meeting_ended` (only OnMeetingEndedNotification does), so requiring
  # `meeting_ended` here wrongly reported a genuinely-restored room as
  # `restored: false`. A `nil`/unknown `meeting_active` must NEVER confirm
  # (fail-closed: we do not claim a meeting restored when it might still be
  # running). A non-nil `meeting_ended` or a `MeetingStatusNotInMeeting` status
  # may corroborate, but none of them is required for confirmation.
  private def meeting_confirmed_ended?(mod) : Bool
    meeting_active?(mod) == false
  end

  private def meeting_active?(mod) : Bool?
    mod.status?(Bool, :meeting_active)
  rescue
    nil
  end

  # ---------------------------------------------------------------------- DSP

  # active-intent: prove program audio is flowing. The Shure driver exposes no
  # output level/meter readback yet, so until the configured meter key appears
  # this records `pending_readback` (never fails). Once the meter key exists it
  # evaluates signal-present automatically. The active preset/mute + restore
  # sequence is deliberately deferred until that proof readback exists — mutating
  # audio state we cannot verify is not worth the risk.
  private def dsp_check : CheckResult
    name = @modules.dsp
    return absent("dsp", "audio_signal", "active") unless module_present?(name)

    key = @readback.dsp_meter
    raw = key.empty? ? nil : system[name].status?(JSON::Any, key)
    if raw.nil? || raw.raw.nil?
      return CheckResult.new("dsp", "audio_signal", "active", "skipped",
        observed: any({readback_key: key}),
        reason: "pending_readback")
    end

    present = signal_present?(raw)
    CheckResult.new("dsp", "audio_signal", "active", present ? "pass" : "fail",
      observed: any({level: raw}),
      expected: any("signal_present"))
  rescue e
    error_result("dsp", "audio_signal", "active", e)
  end

  # ---------------------------------------------------------------------- NVX

  private def nvx_checks : Array(CheckResult)
    [
      nvx_signal_check("nvx_encoder", @modules.encoder, @readback.encoder_signal, "input_signal"),
      nvx_signal_check("nvx_decoder", @modules.decoder, @readback.decoder_lock, "stream_lock"),
      nvx_signal_check("nvx_decoder", @modules.decoder, @readback.decoder_output, "output_present"),
    ]
  rescue e
    [
      error_result("nvx_encoder", "input_signal", "read", e),
      error_result("nvx_decoder", "stream_lock", "read", e),
      error_result("nvx_decoder", "output_present", "read", e),
    ]
  end

  # read-only signal probe. The NVX drivers do not yet expose stream-lock /
  # output-present / on-demand input-signal readbacks, so absent keys record
  # `pending_readback` (never fail) and light up when exposed + configured.
  private def nvx_signal_check(device : String, name : String, key : String, check : String) : CheckResult
    return absent(device, check, "read") unless module_present?(name)

    raw = key.empty? ? nil : system[name].status?(JSON::Any, key)
    if raw.nil? || raw.raw.nil?
      return CheckResult.new(device, check, "read", "skipped",
        observed: any({readback_key: key}),
        reason: "pending_readback")
    end

    present = signal_present?(raw)
    CheckResult.new(device, check, "read", present ? "pass" : "fail",
      observed: any({value: raw}))
  rescue e
    error_result(device, check, "read", e)
  end

  # ------------------------------------------------------------------ helpers

  private def module_present?(name : String) : Bool
    system.count(name) > 0
  rescue
    false
  end

  # Interpret a readback value as "signal present": truthy bool or positive number.
  private def signal_present?(raw : JSON::Any) : Bool
    return true if raw.as_bool? == true
    if (i = raw.as_i?)
      return i > 0
    end
    if (f = raw.as_f?)
      return f > 0
    end
    false
  end

  # Poll a condition until true or the confirm timeout elapses.
  private def wait_until(& : -> Bool) : Bool
    deadline = Time.monotonic + @confirm_timeout.seconds
    loop do
      return true if yield
      return false if Time.monotonic >= deadline
      sleep @poll_interval.seconds
    end
  end

  private def absent(device : String, check : String, type : String) : CheckResult
    CheckResult.new(device, check, type, "skipped", reason: "module_absent")
  end

  # Records an errored check as `unknown`. Carries the `restored` outcome when
  # the caller captured one in cleanup, so the audit trail is not lost.
  private def error_result(device : String, check : String, type : String, e : Exception, restored : Bool? = nil) : CheckResult
    logger.warn(exception: e) { "#{device}/#{check} verification errored" }
    CheckResult.new(device, check, type, "unknown", reason: e.message, restored: restored)
  end

  # Wrap any JSON-serializable value as JSON::Any for evidence fields.
  private def any(value) : JSON::Any
    JSON.parse(value.to_json)
  end
end

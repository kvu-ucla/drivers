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

  # Run every device verification and record the evidence schema. Individual
  # checks never raise out of here — a failed device yields a recorded result,
  # not an aborted run.
  @[Security(Level::Support)]
  def verify
    checks = [] of CheckResult
    checks.concat display_checks
    checks.concat zoom_checks
    checks << dsp_check
    checks.concat nvx_checks

    payload = {ranAt: Time.utc.to_rfc3339, checks: checks}
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
  end

  # read-only: current input vs the profile's expected input.
  private def display_input_check(mod) : CheckResult
    observed = mod.status?(String, :input)
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

  # active: capture power -> power(true) -> confirm on -> restore prior state.
  private def display_power_check(mod) : CheckResult
    prior = mod.status?(Bool, :power)
    mod.power(true).get
    powered = wait_until { mod.status?(Bool, :power) == true }

    restored = true
    if prior == false
      begin
        mod.power(false).get
        restored = wait_until { mod.status?(Bool, :power) == false }
      rescue
        restored = false
      end
    end

    CheckResult.new("display", "power", "active", powered ? "pass" : "fail",
      observed: any({powered_on: powered, prior: prior}),
      restored: restored)
  rescue e
    error_result("display", "power", "active", e)
  end

  # --------------------------------------------------------------------- Zoom

  private def zoom_checks : Array(CheckResult)
    name = @modules.zoom
    unless module_present?(name)
      return [absent("zoom", "connection", "read"), absent("zoom", "meeting", "active")]
    end

    mod = system[name]
    [zoom_connection_check(mod), zoom_meeting_check(mod)]
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

  # active: never touch a live meeting. Otherwise start -> confirm -> exit ->
  # confirm, leaving the room with no meeting running.
  private def zoom_meeting_check(mod) : CheckResult
    if mod.status?(Bool, :meeting_active) == true
      return CheckResult.new("zoom", "meeting", "active", "skipped",
        observed: any({meeting_active: true}),
        reason: "meeting_already_active")
    end

    mod.start_instant_meeting.get
    started = wait_until { mod.status?(Bool, :meeting_active) == true }

    ended = false
    restored = true
    if started
      mod.exit_meeting.get
      ended = wait_until do
        val = mod.status?(JSON::Any, :meeting_ended)
        mod.status?(Bool, :meeting_active) != true && !(val.nil? || val.raw.nil?)
      end
      restored = ended
    end

    result = started && ended ? "pass" : "fail"
    CheckResult.new("zoom", "meeting", "active", result,
      observed: any({started: started, ended: ended}),
      restored: restored)
  rescue e
    error_result("zoom", "meeting", "active", e)
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

  private def error_result(device : String, check : String, type : String, e : Exception) : CheckResult
    logger.warn(exception: e) { "#{device}/#{check} verification errored" }
    CheckResult.new(device, check, type, "unknown", reason: e.message)
  end

  # Wrap any JSON-serializable value as JSON::Any for evidence fields.
  private def any(value) : JSON::Any
    JSON.parse(value.to_json)
  end
end

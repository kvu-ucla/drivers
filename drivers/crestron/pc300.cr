require "placeos-driver"
# Load the stock TCP transport BEFORE the patch below: Crystal's last method
# definition wins, and placeos-driver requires transport/tcp late in its own
# graph — without this, the framework's start_tls (which sends SNI) silently
# overrides the patched version at compile time.
require "placeos-driver/transport/tcp"

# Crestron PC-300 / PC-200 power controller, driven over the secure console
# (CTP over TLS, port 41797). Connection behaviour verified against a live
# unit — see pc300-connection-strategy.md for the full findings.
#
# The device's TLS stack is old and strict-modern defaults break against it:
#   * self-signed device cert            -> verification must be disabled
#   * TLS 1.2 / ECDHE-RSA-AES128-SHA     -> OpenSSL security level 0 + broad ciphers
#   * SNI containing an IP literal kills the handshake -> SNI must not be sent
#
# The stock transport always passes the connection host as the SNI hostname, so
# `start_tls` is overridden below. Each driver compiles into its own binary, so
# this patch affects the PC-300 driver only.
class PlaceOS::Driver::TransportTCP < PlaceOS::Driver::Transport
  def start_tls(verify_mode = OpenSSL::SSL::VerifyMode::NONE, context = @tls) : Nil
    @mutex.synchronize do
      return if @tls_started
      raise "cannot start tls while disconnected" if @socket.nil? || @socket.try(&.closed?)

      socket = @socket.as(TCPSocket)

      tls = context || begin
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.security_level = 0
        ctx.ciphers = "ALL:COMPLEMENTOFALL:@SECLEVEL=0"
        ctx
      end
      tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      @tls = tls

      # The device's handshake is flaky between sessions: a failed attempt
      # needs a beat before the next one can succeed, so immediate reconnects
      # fail deterministically. Retry in-place with backoff (verified working
      # cadence against a live unit) — each failure closes the TCP socket, so
      # every retry dials a fresh one. Safe here: the transport's read fiber
      # only spawns after start_tls returns.
      attempt = 0
      loop do
        attempt += 1
        begin
          socket.sync = true
          # hostname: nil => no SNI extension is sent
          logger.debug { "PC-300 TLS patch active: no SNI, security level 0 (attempt #{attempt})" }
          @socket = OpenSSL::SSL::Socket::Client.new(socket, context: tls, sync_close: true, hostname: nil)
          @tls_started = true
          socket.sync = false
          break
        rescue error : OpenSSL::SSL::Error | IO::Error
          socket.close rescue nil
          raise error if attempt >= 4
          logger.debug { "TLS handshake attempt #{attempt} failed (#{error.message}); retrying" }
          sleep 2.5.seconds
          socket = TCPSocket.new(@ip, @port, connect_timeout: 10)
          configure_socket_options(socket)
          @socket = socket
        end
      end
    end
  end

  # TCP-level options belong on the raw socket and must be applied BEFORE the
  # TLS upgrade: the stock flow sets them afterwards via a stale local variable,
  # which raises EBADF when a handshake retry has replaced the socket.
  private def configure_socket_options(socket : TCPSocket, connect_timeout = 10) : Nil
    socket.tcp_nodelay = true
    socket.tcp_keepalive_idle = 60
    socket.tcp_keepalive_interval = 30
    socket.tcp_keepalive_count = 3
    socket.keepalive = true
    socket.write_timeout = connect_timeout.seconds
  end

  # Replaces the stock start_socket (copied from placeos-driver transport/tcp.cr
  # - keep aligned on framework updates) to fix two defects in its TLS path:
  #   1. it configures TCP options on a stale local after start_tls, which
  #      raises EBADF once the handshake-retry path replaces the socket
  #   2. it spawns the read fiber on the RAW socket, so with TLS the driver
  #      receives ciphertext - the reader must consume from @socket, which is
  #      the SSL wrapper after an upgrade
  private def start_socket(connect_timeout)
    handed_off = false
    @mutex.synchronize do
      @socket = socket = TCPSocket.new(@ip, @port, connect_timeout: connect_timeout)
      configure_socket_options(socket, connect_timeout)

      @tls_started = false
      start_tls if @start_tls

      # manually managed buffering; the raw socket under a TLS wrapper is
      # handled inside start_tls
      io = if @tls_started
             @socket.as(OpenSSL::SSL::Socket::Client)
           else
             socket.sync = false
             socket
           end

      # consume from the upgraded socket, not the raw one
      spawn(same_thread: true, name: "tcp-consume") { consume_io(io) }
      handed_off = true
    end

    # Signal connected state / enable queuing
    set_connected_state(true)
  rescue error
    logger.info(exception: error) { "error connecting to device on #{@ip}:#{@port}" }
    unless handed_off
      @socket.try(&.close) rescue nil
    end
    set_connected_state(false)
    raise error
  end
end

require "placeos-driver/interface/device_info"

class Crestron::PC300 < PlaceOS::Driver
  include Interface::DeviceInfo

  descriptive_name "Crestron PC-300/PC-200 Power Controller"
  generic_name :PowerController
  description "Controls outlets on a Crestron PC-300 (8 outlets) or PC-200 (3 banks) via the secure console. Enable TLS on the module (port 41797)."

  tcp_port 41797

  default_settings({
    # credentials only needed when console authentication is enabled
    username:      "",
    password:      "",
    poll_interval: 60,
    # cadence for `monitor all -once` (temperatures + per-outlet energy)
    monitor_interval: 300,
  })

  # end-of-message markers: the command prompt, or the login cue when console
  # authentication is enabled
  TERMINATOR = /PC-\d+>|credentials to Login:/

  # e.g. "Outlet 1: On" / "Bank 2 Off" / "3: on"
  OUTLET_STATE = /^\s*(?:outlet|bank)?\s*(\d+)\s*[:=]?\s*\b(on|off)\b/mi

  # monitor output, e.g. " # E. Mon OUTLET_1: 120.91 VRMS,  0.29 IRMS, 15.34 W,  185088.0 Wh"
  MONITOR_OUTLET = /E\. Mon OUTLET_(\d+):\s*([-\d.]+)\s*VRMS,\s*([-\d.]+)\s*IRMS,\s*([-\d.]+)\s*W,\s*([-\d.]+)\s*Wh/i
  # e.g. " # External Temp: 37.9C, 100.2F" (first reading is celsius)
  TEMPERATURE = /(External|Internal) Temp:\s*([-\d.]+)\s*C/i
  # e.g. " # TOTAL:            120.68 VRMS   1.07 IRMS  82.78 W" (space separated)
  MONITOR_TOTAL = /TOTAL:\s*([-\d.]+)\s*VRMS\s+([-\d.]+)\s*IRMS\s+([-\d.]+)\s*W/i

  @username : String = ""
  @password : String = ""
  @poll_interval : Int32 = 60
  @monitor_interval : Int32 = 300
  @ready : Bool = false
  @login_attempts : Int32 = 0

  # populated from the console prompt and showhw output (see device_info)
  @model_name : String = "PC-300"
  @hw_info = {} of String => String

  # last-known per-outlet on/off states and energy readings; combined into the
  # outlet_monitor status object whenever either side updates
  @outlet_states = {} of Int32 => Bool
  @outlet_energy = {} of Int32 => Hash(String, Float64)

  def on_load
    queue.delay = 100.milliseconds
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.to_slice
      # the console can emit non-UTF-8 bytes which PCRE2 refuses to match.
      # Substitute high bytes 1:1 with '?' — byte offsets are preserved (unlike
      # String#scrub) and the ASCII-only patterns are unaffected.
      sanitized = Bytes.new(bytes.size) do |i|
        byte = bytes[i]
        byte >= 0x80_u8 ? 0x3F_u8 : byte
      end
      buffer = String.new(sanitized)
      if match = TERMINATOR.match(buffer)
        match.byte_end(0)
      else
        -1
      end
    end
    on_update
  end

  def on_update
    @username = setting?(String, :username) || ""
    @password = setting?(String, :password) || ""
    @poll_interval = setting?(Int32, :poll_interval) || 60
    @monitor_interval = setting?(Int32, :monitor_interval) || 300
  end

  def connected
    # NOTE: set_connected_state repaints fire this callback again (on a fresh
    # fiber) - a real transport connect always arrives with @ready == false,
    # so a ready session means this is just the repaint echo.
    return if @ready

    # the device speaks first: either the banner + prompt, or the login cue.
    # received() drives the login phase; polling starts once ready.
    @login_attempts = 0

    # report offline until the console actually speaks: the single-session
    # device accepts TLS even when another session holds the console, so a bare
    # socket proves nothing. Green in backoffice == console session ready.
    set_connected_state(false)

    schedule.every(@poll_interval.seconds) { query_outlets if @ready }
    schedule.every(@monitor_interval.seconds) { monitor if @ready }

    # single-session console: if another session holds it, the device accepts
    # TLS but never sends the banner. Recycle the connection until we get one -
    # a fresh session is what eventually claims the console once it frees up.
    schedule.in(15.seconds) do
      unless @ready
        logger.warn { "no console banner within 15s of connect (session held elsewhere?) - reconnecting" }
        transport.disconnect
      end
    end
  end

  def disconnected
    # set_connected_state(false) repaints also fire this callback while the
    # socket is still up; a REAL disconnect is distinguished by the queue being
    # taken offline by the transport (status-only repaints never touch it)
    return if queue.online

    schedule.clear
    @ready = false
    self[:ready] = false
  end

  # =========================================================
  # Outlets
  # =========================================================

  # Query the state of all outlets
  def query_outlets
    do_send "outlet", name: "outlet_status"
  end

  # Switch a single outlet: 1-8 on a PC-300, banks 1-3 on a PC-200
  def outlet(index : Int32, state : Bool)
    do_send "outlet #{index} #{state ? "on" : "off"}", name: "outlet_#{index}"
  end

  def all_outlets(state : Bool)
    do_send "outlet all #{state ? "on" : "off"}", name: "all_outlets"
  end

  def power_on(index : Int32)
    outlet(index, true)
  end

  def power_off(index : Int32)
    outlet(index, false)
  end

  # =========================================================
  # Hardware / Sensors
  # =========================================================

  # Current hardware configuration and settings
  def show_hardware
    do_send "showhw", name: "showhw"
  end

  # External/internal temperature, RTC battery voltage, energy monitor readings,
  # current limiting parameters and surge peak voltage sensor values
  def monitor
    do_send "monitor all -once", name: "monitor"
  end

  # Firmware/id string, e.g. "PC-300 [v1.3275.00047, #9EE28AE5]"
  def version
    do_send "ver", name: "ver"
  end

  # Reboot the PC-300 itself (not the outlets). The console drops without a
  # prompt response, so this is fire-and-forget; the transport reconnects and
  # the session re-establishes once the device is back.
  def reboot
    do_send "reboot", name: "reboot", wait: false
  end

  # Send any raw console command and return its output, e.g.
  #   send_command("estatus")
  # The command is serialised through the queue like any other and its response
  # is whatever the console printed up to the next prompt.
  def send_command(command : String)
    do_send command, name: "manual_command"
  end

  # =========================================================
  # Interface::DeviceInfo
  # =========================================================

  # Built from the console prompt (model) and cached showhw output; showhw is
  # queried on session-ready so these fields populate shortly after connect.
  def device_info : Descriptor
    Descriptor.new(
      make: "Crestron",
      model: @hw_info["model"]? || @model_name,
      serial: @hw_info["serial"]?,
      firmware: @hw_info["firmware"]?,
      mac_address: @hw_info["mac_address"]?,
      ip_address: config.ip,
      hostname: @hw_info["hostname"]?,
    )
  end

  # =========================================================
  # Response handling
  # =========================================================

  def received(data, task)
    # scrub: the console can emit non-UTF-8 bytes; regex on invalid UTF-8 raises
    data = String.new(data).scrub
    logger.debug { "received: #{data.inspect}" }

    # login phase: the device asked for credentials
    if data =~ /credentials to Login:/
      handle_login_request
      return
    end

    # the prompt reveals the model family (PC-300> / PC-200>)
    if model = data.match(/(PC-\d+)>/).try(&.[1])
      @model_name = model
    end

    # any prompt-terminated message before ready is the banner: session is up
    unless @ready
      @ready = true
      self[:ready] = true
      set_connected_state(true) # console is interactive: show green in backoffice
      @login_attempts = 0
      query_outlets
      show_hardware
      version
      monitor
      return
    end

    body = strip_response(data)

    case task.try(&.name) || ""
    when "outlet_status"
      task.try &.success(parse_outlets(data))
    when "all_outlets", .starts_with?("outlet_")
      # device confirmed the command; reconcile actual states from the device
      query_outlets
      task.try &.success(body)
    when "showhw"
      info = parse_hardware(body)
      self[:hardware] = info
      cache_hardware_info(info)
      task.try &.success(info)
    when "monitor"
      sensors = parse_key_values(body)
      self[:sensors] = sensors
      parse_monitor(body)
      task.try &.success(sensors)
    when "ver"
      # "PC-300 [v1.3275.00047, #9EE28AE5]" -> firmware + unique device id
      self[:version] = body
      if match = body.match(/(PC-\d+)\s*\[v?([\w.]+),\s*#(\w+)\]/)
        @model_name = match[1]
        @hw_info["firmware"] = match[2]
        @hw_info["serial"] = match[3]
        update_device_info
      end
      task.try &.success(body)
    else
      task.try &.success(body)
    end
  end

  # =========================================================
  # Private
  # =========================================================

  protected def do_send(command : String, **options)
    send "#{command}\r\n", **options
  end

  protected def handle_login_request
    if @username.empty?
      logger.error { "console authentication is enabled but no credentials are configured" }
      return
    end

    @login_attempts += 1
    if @login_attempts > 3
      logger.error { "login failed after #{@login_attempts - 1} attempts" }
      return
    end

    logger.debug { "authenticating (attempt #{@login_attempts})" }
    # a single write; the device consumes the two lines in order
    transport.send "#{@username}\r\n#{@password}\r\n"
  end

  protected def parse_outlets(data : String)
    outlets = {} of Int32 => Bool
    data.scan(OUTLET_STATE) do |match|
      index = match[1].to_i
      state = match[2].downcase == "on"
      outlets[index] = state
      self["outlet_#{index}"] = state
    end
    unless outlets.empty?
      self[:outlets] = outlets
      @outlet_states = outlets
      publish_outlet_monitor
    end
    outlets
  end

  # structured extraction from `monitor all -once`: per-outlet energy readings
  # (combined with on/off state into outlet_monitor), top-level temperatures
  # and the unit-wide totals
  protected def parse_monitor(body : String) : Nil
    energy = {} of Int32 => Hash(String, Float64)
    body.scan(MONITOR_OUTLET) do |match|
      energy[match[1].to_i] = {
        "voltage"   => match[2].to_f,
        "current"   => match[3].to_f,
        "power"     => match[4].to_f,
        "energy_wh" => match[5].to_f,
      }
    end
    unless energy.empty?
      @outlet_energy = energy
      publish_outlet_monitor
    end

    body.scan(TEMPERATURE) do |match|
      self["#{match[1].downcase}_temperature"] = match[2].to_f
    end

    if total = MONITOR_TOTAL.match(body)
      self[:total_voltage] = total[1].to_f
      self[:total_current] = total[2].to_f
      self[:total_power] = total[3].to_f
    end
  end

  # one object per outlet combining on/off state with the energy readings, e.g.
  #   {"outlet_1" => {"state" => true, "voltage" => 120.9, "power" => 15.3, ...}}
  # state comes from the (faster) outlet poll, energy from the monitor poll
  protected def publish_outlet_monitor : Nil
    indexes = (@outlet_states.keys + @outlet_energy.keys).uniq!.sort!
    return if indexes.empty?

    combined = {} of String => Hash(String, Bool | Float64)
    indexes.each do |index|
      info = {} of String => Bool | Float64
      # explicit key check: a stored `false` state must still be published
      if @outlet_states.has_key?(index)
        info["state"] = @outlet_states[index]
      end
      @outlet_energy[index]?.try(&.each { |key, value| info[key] = value })
      combined["outlet_#{index}"] = info
    end
    self[:outlet_monitor] = combined
  end

  # showhw as a flat object. Lines can carry several comma-separated pairs
  # ("Tmax: 105.0,  Vmax: 145, ...") so each line is split on commas first;
  # section headers ("Nonvolatile settings") carry no value and are dropped.
  # Colons inside values (URLs, "0:30 secs") survive: only the first colon of
  # each segment splits key from value.
  protected def parse_hardware(body : String)
    pairs = {} of String => String
    body.each_line do |line|
      line.split(',').each do |segment|
        key, _, value = segment.partition(":")
        key = key.strip
        value = value.strip
        next if key.empty? || value.empty?
        pairs[key] = value
      end
    end
    pairs
  end

  # best-effort "Key: value" extraction for human-oriented console output;
  # monitor lines are prefixed "# " (e.g. " # External Temp: 37.9C, 100.2F")
  protected def parse_key_values(body : String)
    pairs = {} of String => String
    body.each_line do |line|
      key, _, value = line.partition(":")
      next if value.empty?
      key = key.gsub(/\A[#\s]+/, "").strip
      value = value.strip
      next if key.empty? || value.empty?
      pairs[key] = value
    end
    pairs
  end

  # remove the trailing prompt and any echoed command line from a response
  protected def strip_response(data : String) : String
    body = data.sub(/PC-\d+>\s*\z/, "").strip
    lines = body.lines
    lines.shift if lines.first?.try(&.matches?(/\A(outlet\b|showhw|monitor\b)/i))
    lines.join('\n').strip
  end

  # map showhw's key/value output onto the DeviceInfo descriptor fields;
  # the model arrives as "System type: PC-300" (verified against a live unit —
  # showhw carries no serial/firmware/mac, those come from `ver`)
  protected def cache_hardware_info(pairs : Hash(String, String)) : Nil
    pairs.each do |key, value|
      case key.downcase
      when .includes?("system type"), .includes?("model")
        @hw_info["model"] = value
      when .includes?("mac")
        @hw_info["mac_address"] = value
      when .includes?("host")
        @hw_info["hostname"] = value
      end
    end
    update_device_info
  end
end

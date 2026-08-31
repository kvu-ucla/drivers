# UCLA-maintained copy of drivers/sony/displays/bravia.cr (vendored 2026-08-30 from ucla-dev fork @ ca4750ac07)
require "placeos-driver"
require "placeos-driver/interface/device_info"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

# Documentation: https://aca.im/driver_docs/Sony/sony%20bravia%20simple%20ip%20control.pdf

class Sony::Displays::Bravia < PlaceOS::Driver
  include Interface::DeviceInfo
  include Interface::Powerable
  include Interface::Muteable

  private INDICATOR = "\x2A\x53" # *S
  private HASH      = "################"

  # Discovery Information
  tcp_port 20060
  descriptive_name "Sony Bravia LCD Display (UCLA)"
  generic_name :Display

  enum Input : UInt32
    {% for idx in 0..3 %}
      Tv{{idx}}     = {{ idx }}
      Hdmi{{idx}}   = {{10000_0000 + idx}}
      Mirror{{idx}} = {{50000_0000 + idx}}
      Vga{{idx}}    = {{60000_0000 + idx}}
    {% end %}

    def self.from_param(value : String) : self
      from_value UInt32.new(value)
    rescue
      raise "Unknown enum #{self} value: #{value}"
    end

    def to_param : String
      value.to_s.rjust(5, '0')
    end
  end

  include Interface::InputSelection(Input)

  def switch_to(input : Input)
    logger.debug { "switching input to #{input}" }
    request(Command::Input, input.to_param)
    self[:input] = input.to_s
    input?
  end

  def input?
    query(Command::Input, priority: 0)
  end

  def on_load
    self[:volume_min] = 0
    self[:volume_max] = 100
  end

  def connected
    # one-time identity enquiry - the response caches via update_status
    mac_address?

    schedule.every(30.seconds, true) do
      do_poll
    end
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    request(Command::Power, state)
    power?
  end

  def power?
    query(Command::Power)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo,
  )
    request(Command::Mute, state)
    mute?
  end

  def unmute
    mute false
  end

  def mute?
    query(Command::Mute, priority: 0)
  end

  def mute_audio(state : Bool = true)
    request(Command::AudioMute, state)
    audio_mute?
  end

  def unmute_audio
    mute_audio false
  end

  def audio_mute?
    query(Command::AudioMute, priority: 0)
  end

  def volume(level : Int32 | Float64)
    level = level.to_f.clamp(0.0, 100.0).round_away.to_i
    request(Command::Volume, level)
    volume?
  end

  def volume?
    query(Command::Volume, priority: 0)
  end

  # the getMacAddress enquiry requires the interface name in the parameter
  # (right-padded to 16 bytes), unlike the generic all-# enquiry form
  def mac_address?
    query(Command::MacAddress, "eth0".ljust(16, '#'), priority: 0)
  end

  # ====== DeviceInfo Interface ======

  # Simple IP control has no model/serial/firmware enquiries. The MAC caches
  # via update_status when the connect-time enquiry is answered; everything
  # else degrades to nil - this is a pure cache read, no protocol traffic.
  def device_info : Descriptor
    Descriptor.new(
      make: "Sony",
      model: "Bravia",
      mac_address: status?(String, :mac_address),
      ip_address: config.ip,
    )
  end

  def volume_up
    current_volume = status?(Float64, :volume) || 50.0
    volume(current_volume + 5.0)
  end

  def volume_down
    current_volume = status?(Float64, :volume) || 50.0
    volume(current_volume - 5.0)
  end

  def do_poll
    if self[:power]?
      input?
      mute?
      audio_mute?
      volume?
    end
  end

  enum MessageType : UInt8
    Answer  = 0x41
    Control = 0x43
    Enquiry = 0x45
    Notify  = 0x4e
    Error   = 0x46

    def control_character
      value.chr
    end
  end

  def received(data, task)
    parsed_data = convert_binary(data[3..6])
    cmd = Command.from_response?(parsed_data)

    logger.debug { "Sony sent: #{cmd}" }

    return task.try(&.abort("unrecognised command: #{parsed_data}")) if cmd.nil?
    param = data[7..-1]
    return task.try(&.abort("error")) if param.first? == MessageType::Error.value
    case MessageType.from_value?(data[2])
    when MessageType::Answer
      update_status cmd, param
      task.try &.success
    when MessageType::Notify
      update_status cmd, param
    else
      logger.debug { "Unhandled device response: #{data[2].chr rescue data[2]}" }
      task.try &.abort("Unhandled device response")
    end
  end

  COMMANDS = {
    ir_code:           "IRCC",
    power:             "POWR",
    volume:            "VOLU",
    audio_mute:        "AMUT",
    mute:              "PMUT",
    channel:           "CHNN",
    tv_input:          "ISRC",
    input:             "INPT",
    toggle_mute:       "TPMU",
    pip:               "PIPI",
    toggle_pip:        "TPIP",
    position_pip:      "TPPP",
    broadcast_address: "BADR",
    mac_address:       "MADR",
  }

  {% begin %}
  enum Command
    {% begin %}
      {% for command in COMMANDS.keys %}
        {{ command.camelcase.id }}
      {% end %}
    {% end %}

    def function
      {% begin %}
      case self
      {% for kv in COMMANDS.to_a %}
        {% command, value = kv[0], kv[1] %}
          in {{ command.camelcase }} then {{ value }}
      {% end %}
      end
      {% end %}
    end

    def self.from_response?(message)
      {% begin %}
      case message
        {% for kv in COMMANDS.to_a %}
          {% command, value = kv[0], kv[1] %}
          when {{ value }} then {{ command.camelcase.id }}
        {% end %}
      end
      {% end %}
    end
  end
  {% end %}

  protected def convert_binary(data)
    String.new(slice: data)
  end

  protected def request(command, parameter, **options)
    cmd = command.function
    parameter = parameter ? 1 : 0 if parameter.is_a?(Bool)
    param = parameter.to_s.rjust(16, '0')
    do_send(MessageType::Control, cmd, param, **options)
  end

  protected def query(state, parameter = HASH, **options)
    cmd = state.function
    do_send(MessageType::Enquiry, cmd, parameter, **options)
  end

  protected def do_send(type, command, parameter, **options)
    cmd = "#{INDICATOR}#{type.control_character}#{command}#{parameter}\n"
    send(cmd, **options)
  end

  protected def update_status(cmd : Command, param)
    parsed_data = convert_binary(param)
    case cmd
    when .power?
      self[:power] = parsed_data.to_i == 1
    when .mute?
      self[:mute] = parsed_data.to_i == 1
    when .audio_mute?
      self[:audio_mute] = parsed_data.to_i == 1
    when .pip?
      self[:pip] = parsed_data.to_i == 1
    when .volume?
      self[:volume] = parsed_data.to_i
    when .mac_address?
      self[:mac_address] = parsed_data.split('#')[0]
    when .input?
      self[:input] = Input.from_param(parsed_data[7..15])
    end
  end
end

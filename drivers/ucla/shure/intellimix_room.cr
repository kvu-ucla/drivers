# UCLA-maintained copy of drivers/shure/intellimix_room.cr (vendored 2026-08-30 from ucla-dev @ ce19af2a18)
# Version 2.0.1 — documentation: intellimix_room_readme.md
require "placeos-driver"
require "placeos-driver/interface/device_info"
require "placeos-driver/interface/muteable"

# Documentation: https://www.shure.com/en-US/docs/commandstrings/IntelliMixRoom
# TCP Port: 2202

class Shure::IntellimixRoom < PlaceOS::Driver
  include Interface::DeviceInfo
  include Interface::Muteable

  tcp_port 2202
  descriptive_name "Shure IntelliMix Room Audio Processor (UCLA)"
  generic_name :Mixer
  description "Software-based digital signal processing for Shure networked microphones"

  def connected
    # Shure uses space + > as the response terminator
    transport.tokenizer = Tokenizer.new(" >")
    logger.debug { "-- Polling device status" }

    # identity is queried once per connection - the DeviceInfo interface owns
    # the device-info cadence; the recurring poll only tracks live state,
    # at low priority so it never preempts queued commands
    query_device_identity
    schedule.every(50.seconds, immediate: true) do
      do_send "GET ALL", name: :get_all, priority: 0
    end
  end

  def disconnected
    schedule.clear
  end

  # Device Information:
  # one-shot identity queries; responses cache via received and device_info
  # serves them from state
  def query_device_identity
    do_send "GET MODEL", name: :get_device_model, priority: 0
    do_send "GET FW_VER", name: :get_firmware_version, priority: 0
    do_send "GET DEVICE_ID", name: :get_device_info, priority: 0
  end

  def get_all
    do_send "GET ALL", name: :get_all
  end

  # ====== DeviceInfo Interface ======

  # served from state cached by the get_device_info poll; serial_num only
  # populates if the device reports it via GET ALL
  def device_info : Descriptor
    Descriptor.new(
      make: "Shure",
      model: status?(String, :model).presence || "IntelliMix Room",
      serial: status?(String, :serial_num),
      firmware: status?(String, :fw_ver),
      ip_address: config.ip,
    )
  end

  def get_na_device_name
    do_send "GET NA_DEVICE_NAME", name: :get_na_device_name
  end

  def get_onhook_enable
    do_send "GET ONHOOK_ENABLE", name: :get_onhook_enable
  end

  def set_onhook_enable(enable : Bool)
    do_send "SET ONHOOK_ENABLE #{enable ? "ON" : "OFF"}", name: :set_onhook_enable
  end

  # Presets
  def get_preset
    do_send "GET PRESET", name: :get_preset
  end

  def set_preset(number : Int32)
    do_send "SET PRESET #{number.to_s(precision: 2)}", name: :set_preset
  end

  # Channel Commands
  def get_audio_gain_hi_res(index : Int32)
    do_send "GET #{index.to_s(precision: 2)} AUDIO_GAIN_HI_RES", name: :get_audio_gain_hi_res
  end

  def set_audio_gain_hi_res(index : Int32, value : Int32)
    do_send "SET #{index.to_s(precision: 2)} AUDIO_GAIN_HI_RES #{value.to_s(precision: 4)}", name: :set_audio_gain_hi_res
  end

  def get_device_audio_mute
    do_send "GET DEVICE_AUDIO_MUTE", name: :get_device_audio_mute
  end

  def set_device_audio_mute(mute : Bool)
    do_send "SET DEVICE_AUDIO_MUTE #{mute ? "ON" : "OFF"}", name: :set_device_audio_mute
  end

  def get_audio_mute(index : Int32)
    do_send "GET #{index.to_s(precision: 2)} AUDIO_MUTE", name: :get_audio_mute
  end

  def set_audio_mute(index : Int32, mute : Bool)
    do_send "SET #{index.to_s(precision: 2)} AUDIO_MUTE #{mute ? "ON" : "OFF"}", name: :set_audio_mute
  end

  def get_matrix_mxr_route(input : Int32, output : Int32)
    do_send "GET #{input.to_s(precision: 2)} MATRIX_MXR_ROUTE #{output.to_s(precision: 2)}", name: :get_matrix_mxr_route
  end

  def set_matrix_mxr_route(input : Int32, output : Int32, enabled : Bool)
    do_send "SET #{input.to_s(precision: 2)} MATRIX_MXR_ROUTE #{output.to_s(precision: 2)} #{enabled ? "ON" : "OFF"}", name: :set_matrix_mxr_route
  end

  def get_matrix_mxr_gain(input : Int32, output : Int32)
    do_send "GET #{input.to_s(precision: 2)} MATRIX_MXR_GAIN #{output.to_s(precision: 2)}", name: :get_matrix_mxr_gain
  end

  def set_matrix_mxr_gain(input : Int32, output : Int32, gain : Int32)
    do_send "SET #{input.to_s(precision: 2)} MATRIX_MXR_GAIN #{output.to_s(precision: 2)} #{gain.to_s(precision: 4)}", name: :set_matrix_mxr_gain
  end

  def get_automxr_mute(index : Int32)
    do_send "GET #{index.to_s(precision: 2)} AUTOMXR_MUTE", name: :get_automxr_mute
  end

  def set_automxr_mute(index : Int32, mute : Bool)
    do_send "SET #{index.to_s(precision: 2)} AUTOMXR_MUTE #{mute ? "ON" : "OFF"}", name: :set_automxr_mute
  end

  def get_audio_gain_postgate(index : Int32)
    do_send "GET #{index.to_s(precision: 2)} AUDIO_GAIN_POSTGATE", name: :get_audio_gain_postgate
  end

  def set_audio_gain_postgate(index : Int32, gain : Int32)
    do_send "SET #{index.to_s(precision: 2)} AUDIO_GAIN_POSTGATE #{gain.to_s(precision: 4)}", name: :set_audio_gain_postgate
  end

  def get_automxr_gate(index : Int32)
    do_send "GET #{index.to_s(precision: 2)} AUTOMXR_GATE", name: :get_automxr_gate
  end

  def get_chan_config
    do_send "GET CHAN_CONFIG", name: :get_chan_config
  end

  def get_chan_count
    do_send "GET CHAN_COUNT", name: :get_chan_count
  end

  def get_lic_exp_date
    do_send "GET LIC_EXP_DATE", name: :get_lic_exp_date
  end

  def get_lic_type
    do_send "GET LIC_TYPE", name: :get_lic_type
  end

  def get_lic_valid
    do_send "GET LIC_VALID", name: :get_lic_valid
  end

  def get_denoiser_enable(index : Int32)
    do_send "GET #{index.to_s(precision: 2)} DENOISER_ENABLE", name: :get_denoiser_enable
  end

  def set_denoiser_enable(index : Int32, enable : Bool)
    do_send "SET #{index.to_s(precision: 2)} DENOISER_ENABLE #{enable ? "ON" : "OFF"}", name: :set_denoiser_enable
  end

  def get_denoiser_level(index : Int32)
    do_send "GET #{index.to_s(precision: 2)} DENOISER_LEVEL", name: :get_denoiser_level
  end

  def set_denoiser_level(index : Int32, level : String)
    raise "ArgumentError: level must be LOW, MEDIUM or HIGH" unless level.in?(["LOW", "MEDIUM", "HIGH"])
    do_send "SET #{index.to_s(precision: 2)} DENOISER_LEVEL #{level}", name: :set_denoiser_level
  end

  # === Interface::Muteable Implementation ===

  # this is defined in Interface::Muteable, calling mute function
  # def mute_audio(state : Bool = true, index : Int32 | String = 0)
  #  set_audio_mute(index.to_i, state)
  # end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo,
  )
    case layer
    in .audio?, .audio_video?
      # NOTE:: maybe we want to use index here?
      set_device_audio_mute(state)
    in .video?
      # ignore
    end
  end

  def received(bytes, task)
    data = String.new(bytes).strip
    logger.debug { "-- received: #{data}" }

    # NOTE: lstrip/rstrip with a string strip a character SET - that mangles
    # parameters starting with those characters (e.g. "PRESET" -> "SET"), so
    # peel the frame with anchored patterns instead
    response = data.sub(/\A<\s*REP\s+/, "").sub(/\s*>\z/, "")
    parts = tokenize(response)
    return task.try(&.abort("Empty response")) if parts.empty?

    # Handle error responses
    if parts.first == "ERR"
      logger.error { "Device error: #{response}" }
      return task.try(&.abort(response))
    end

    # Parse response based on parameter structure
    case parts.size
    when 1
      # Must be ERR, which is handled above
    when 2
      # Parameter with 1 value
      key = parts[0].downcase
      changed = self[key]?.try(&.raw) != parts[1]
      self[key] = parts[1]
      # keep the published descriptor in sync when identity details change
      # (e.g. GET ALL reporting a new firmware after an upgrade)
      update_device_info if changed && key.in?("model", "fw_ver", "serial_num")
    when 3
      # Channel-specific parameter like "nn AUDIO_MUTE sts"
      channel = parts[0]
      param = parts[1].downcase
      value = parts[2]
      self["#{param}_#{channel}"] = value
    when 4
      # Matrix-specific parameter like "1 input MATRIX_MXR_ROUTE output sts"
      input = parts[0]
      param = parts[1].downcase
      output = parts[2]
      value = parts[3]
      self["#{param}_#{input}_#{output}"] = value
    else
      # Handle multi-part responses or unknown formats
      logger.warn { "Unknown response format: #{response}" }
    end
    task.try(&.success)
  end

  def tokenize(input : String) : Array(String)
    tokens = [] of String
    i = 0
    n = input.bytesize

    while i < n
      case input[i]
      when '{'
        # find closing brace
        j = input.index('}', i) || raise "missing }"
        tokens << input[i + 1, j - i - 1].strip
        i = j + 1
      when ' ', '\t', '\n'
        i += 1
      else
        # normal word
        j = i
        while j < n && !input[j].whitespace? && input[j] != '{'
          j += 1
        end
        tokens << input[i, j - i]
        i = j
      end
    end

    tokens
  end

  protected def do_send(*command, **options)
    cmd = "< #{command.join(" ")} >"
    logger.debug { "-- sending: #{cmd}" }
    send(cmd, **options)
  end
end

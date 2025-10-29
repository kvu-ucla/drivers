require "placeos-driver"
require "./hub_dsp_models"

# Documentation: https://docs.catchbox.com/
# API Command List: https://docs.google.com/spreadsheets/d/10aOYyVSSGEU3oRSo80UGlRG2WUvq-uPR/edit

class Catchbox::HubDSP < PlaceOS::Driver
  # Discovery Information
  udp_port 39030
  descriptive_name "Catchbox Hub DSP Receiver"
  description "Controls Catchbox Hub DSP receiver for wireless microphone management. Configure IP address and UDP port in device settings."
  generic_name :Mixer

  default_settings({
    poll_interval: 30,
  })

  def on_load
    transport.tokenizer = Tokenizer.new("\n")
    on_update
  end

  def on_update
    @poll_interval = setting(Int32, :poll_interval) || 30
    # Clamp to a sensible minimum to avoid tight loops
    # @poll_interval = 1 if @poll_interval < 1
  end

  def connected
    logger.debug { "Connected to Catchbox Hub DSP" }
    # schedule.clear

    # schedule.every(60.seconds) {
    #   query_device_info
    #   query_network_info
    #   query_mic_status
    # }
  end

  def disconnected
    logger.debug { "Disconnected to Catchbox Hub DSP" }
    # schedule.clear
  end

  # def query_device_info_slice
  #   # request = ApiRequest.new(
  #   #   rx: RxCommand.new(
  #   #     device: DeviceCommand.new(name: nil)
  #   #   )
  #   # )

  #   request = %({"rx":{"device":{"device_type":null}}})
  #   send(request.to_slice)
  # end

  #   def query_device_info_raw
  #   # request = ApiRequest.new(
  #   #   rx: RxCommand.new(
  #   #     device: DeviceCommand.new(name: nil)
  #   #   )
  #   # )

  #   request = %({"rx":{"device":{"device_type":null}}})
  #   send(request)
  # end

  # def query_network_info
  #   request = ApiRequest.new(
  #     rx: RxCommand.new(
  #       network: NetworkCommand.new(
  #         mac: nil,
  #         ip_mode: nil,
  #         ip: nil,
  #         subnet: nil,
  #         gateway: nil
  #       )
  #     )
  #   )
  #   send_request(request, name: "network_info")
  # end

  # def query_mic_status
  #   request = ApiRequest.new(
  #     rx: RxCommand.new(
  #       audio: AudioCommand.new(
  #         input: AudioInputCommand.new(
  #           mic1: MicCommand.new(mute: nil),
  #           mic2: MicCommand.new(mute: nil),
  #           mic3: MicCommand.new(mute: nil)
  #         )
  #       )
  #     )
  #   )
  #   send_request(request, name: "mic_status")
  # end

  # def set_device_name(name : String)
  #   request = ApiRequest.new(
  #     rx: RxCommand.new(
  #       device: DeviceCommand.new(name: name)
  #     )
  #   )
  #   send_request(request, name: "set_device_name")
  # end

  # def set_network_config(ip_mode : String, ip : String? = nil, subnet : String? = nil, gateway : String? = nil)
  #   # Validate IP mode to reduce typos and protocol errors
  #   valid_modes = {"Static", "DHCP"}
  #   unless valid_modes.includes?(ip_mode)
  #     raise ArgumentError.new("ip_mode must be one of: #{valid_modes.join(", ")}")
  #   end

  #   request = ApiRequest.new(
  #     rx: RxCommand.new(
  #       network: NetworkCommand.new(
  #         ip_mode: ip_mode,
  #         ip: ip,
  #         subnet: subnet,
  #         gateway: gateway
  #       )
  #     )
  #   )
  #   send_request(request, name: "set_network")
  # end

  # def network_reboot
  #   request = ApiRequest.new(
  #     rx: RxCommand.new(
  #       network: NetworkCommand.new(reboot: true)
  #     )
  #   )
  #   send_request(request, name: "network_reboot")
  # end

  # def mute_mic(mic_number : Int32, muted : Bool = true)
  #   raise ArgumentError.new("Mic number must be 1, 2, or 3") unless (1..3).includes?(mic_number)

  #   mic_cmd = MicCommand.new(mute: muted)
  #   input_cmd = case mic_number
  #               when 1
  #                 AudioInputCommand.new(mic1: mic_cmd)
  #               when 2
  #                 AudioInputCommand.new(mic2: mic_cmd)
  #               when 3
  #                 AudioInputCommand.new(mic3: mic_cmd)
  #               else
  #                 raise ArgumentError.new("Invalid mic number")
  #               end

  #   request = ApiRequest.new(
  #     rx: RxCommand.new(
  #       audio: AudioCommand.new(input: input_cmd)
  #     )
  #   )

  #   send_request(request, name: "mute_mic_#{mic_number}")
  # end

  # def unmute_mic(mic_number : Int32)
  #   mute_mic(mic_number, false)
  # end

  # def mute_all_mics(muted : Bool = true)
  #   (1..3).each { |mic| mute_mic(mic, muted) }
  # end

  # def unmute_all_mics
  #   mute_all_mics(false)
  # end

  def send_request(request : ApiRequest)
    json = request.to_json
    logger.debug { "Sending: #{json}" }
    send(json.to_slice)  # Convert string to bytes for UDP
  end

  # def send_request_debug(request : JSON::Any)
  #   data = request.to_json
  #   logger.debug { "Sending Debug: #{json_string}" }
  #   send(data)
  # end

  def received(data, task)
    data_string = String.new(data).strip
    logger.debug { "Received: #{data_string}" }

    return unless data_string.starts_with?("{") && data_string.ends_with?("}")

    # begin
    #   response = ApiResponse.from_json(data_string)

    #   if response.error != 0
    #     logger.warn {"API Error #{response.error} received"}
    #     task.try(&.abort("API Error: #{response.error}"))
    #     return
    #   end

    #   process_response(response, task)
    #   task.try(&.success(response))

    # rescue ex : JSON::ParseException
    #   logger.error(exception: ex) { "JSON Parse Error: #{ex.message}" }
    #   logger.debug {"Raw data: #{data_string}"}
    #   task.try(&.abort("JSON Parse Error: #{ex.message}"))
    # rescue ex
    #   logger.error(exception: ex) { "Unexpected error: #{ex.message}" }
    #   task.try(&.abort("Unexpected error: #{ex.message}"))
    # end
  end

  # private def process_response(response : ApiResponse, task)
  #   return unless rx_response = response.rx

  #   if network = rx_response.network
  #     update_network_status(network)
  #   end

  #   if device = rx_response.device
  #     update_device_status(device)
  #   end

  #   if audio = rx_response.audio
  #     update_audio_status(audio)
  #   end
  # end

  # private def update_network_status(network : NetworkResponse)
  #   self[:mac_address] = network.mac if network.mac
  #   self[:ip_mode] = network.ip_mode if network.ip_mode
  #   self[:ip_address] = network.ip if network.ip
  #   self[:subnet_mask] = network.subnet if network.subnet
  #   self[:gateway] = network.gateway if network.gateway

  #   logger.debug { "Network status updated" }
  # end

  # private def update_device_status(device : DeviceResponse)
  #   self[:device_name] = device.name if device.name
  #   self[:firmware_version] = device.firmware if device.firmware
  #   self[:hardware_version] = device.hardware if device.hardware
  #   self[:serial_number] = device.serial if device.serial

  #   logger.debug { "Device status updated" }
  # end

  # private def update_audio_status(audio : AudioResponse)
  #   return unless input = audio.input

  #   if mic1 = input.mic1
  #     update_mic_status(1, mic1)
  #   end

  #   if mic2 = input.mic2
  #     update_mic_status(2, mic2)
  #   end

  #   if mic3 = input.mic3
  #     update_mic_status(3, mic3)
  #   end
  # end

  # private def update_mic_status(mic_number : Int32, mic : MicResponse)
  # prefix = "mic#{mic_number}"

  # if !mic.mute.nil?
  #   self[("#{prefix}_muted")] = mic.mute
  #   self[("#{prefix}_audio_enabled")] = !mic.mute
  # end

  # self[("#{prefix}_battery_level")] = mic.battery if mic.battery
  # self[("#{prefix}_signal_strength")] = mic.signal if mic.signal
  # self[("#{prefix}_connected")] = mic.connected if !mic.connected.nil?

  # logger.debug {"Mic #{mic_number} status updated"}
  # end
end

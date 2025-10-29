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
    transport.tokenizer = Tokenizer.new(Bytes.empty)
    on_update
  end

  def on_update
    @poll_interval = setting(Int32, :poll_interval) || 30
    # Clamp to a sensible minimum to avoid tight loops
    # @poll_interval = 1 if @poll_interval < 1
  end

  def connected
    logger.debug { "Connected to Catchbox Hub DSP" }
    logger.debug { "Transport class: #{transport.class}" }

    self[:transport] = transport.class.to_s
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

  def send_request(request : JSON::Any)
    json = request.to_json
    logger.debug { "Sending: #{json}" }
    send(json.to_slice) 
  end

  def received(data, task)
    logger.debug { "=== RECEIVED CALLED ===" }
    data_string = String.new(data).strip
    logger.debug { "Received: #{data_string}" }
    
    task.try(&.success)
  end

end

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

  # Error Codes
  # 0	OK (Command executed successfully)
  # 405	VALUE_OUT_OF_BOUNDS (Supplied value is outside the allowed parameter range)
  # 410	INCORRECT_VALUE (Supplied value has incorrect formatting)
  # 415	UNREACHABLE_ENDPOINT (Returned when requesting info from transmitters, when there is no RF link)
  # 425	MALFORMED_COMMAND (Command is improperly formatted)
  # 430	UNSUPPORTED_FEATURE (Returned when trying to get or set features which are not present on given product e.g. setting Mute button enable feature for Cube)

  default_settings({
    poll_interval: 30,
    subscribe_mics_status: true,
    subscribe_device_status: true, 
  })

  def on_load
    transport.tokenizer = nil
  end

  def on_update
    #TODO 
  end

  def connected
    logger.debug { "Connected to Catchbox Hub DSP" }
  end

  def disconnected
    logger.debug { "Disconnected to Catchbox Hub DSP" }
  end

  def send_request(request : JSON::Any)
    json = request.to_json
    logger.debug { "Sending Request: #{json}" }
    send(json.to_slice) 
  end

  def send_subscription(subscription : String)
    logger.debug { "Sending Subscription: #{subscription}" }
    send(subscription)
  end

  def received(data, task)
    data_string = String.new(data).strip
    logger.debug { "Received: #{data_string}" }
    
    task.try(&.success)
  end

  ## Subscriptions ##

  # Microphone Mute State
  def subscribe_mic_mute_states(period_ms : Int32, enable : Bool)
    ["mic1", "mic2", "mic3", "mic4"].each do |mic|
      sub = {
        "subscribe" => [{
          "#" => {"enable" => enable, "period_ms" => period_ms},
          "rx" => { "audio" => { "input" => { mic => { "mute" => nil }}}}
        }]
      }
      send_subscription(sub.to_json)
    end
  end

  # Microphone Battery Status
  def subscribe_mic_battery_levels(period_ms : Int32, enable : Bool)
    (1..4).each do |num|
      sub = {
        "subscribe" => [{
          "#" => {"enable" => enable, "period_ms" => period_ms},
          "tx#{num}" => { "device" => { "battery" => nil }}
        }]
      }
      send_subscription(sub.to_json)
    end
  end

  # Microphone Link Status
  def subscribe_mic_link_state(period_ms : Int32, enable : Bool)
    ["mic1", "mic2", "mic3", "mic4"].each do |mic|
      sub = {
        "subscribe" => [{
          "#" => {"enable" => enable, "period_ms" => period_ms},
          "rx" => {"device" => {"#{mic}_link_state" => nil}}
        }]
      }
      send_subscription(sub.to_json)
    end
  end

end

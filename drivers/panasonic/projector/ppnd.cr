require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"
require "http-client-digest_auth"
require "./ppnd_models"

# Documentation: PPND WEB API
# Base URL: https://{ip-address}/api/v1/
# Protocol: HTTP/HTTPS with JSON responses
# Authentication: Digest

class Panasonic::Projector::PPND < PlaceOS::Driver
  include Interface::Powerable

  enum Input
    COMPUTER
    HDMI1
    HDMI2
    MemoryViewer
    Network
    DigitalLink
  end

  include Interface::InputSelection(Input)

  # Discovery Information
  generic_name :Display
  descriptive_name "Panasonic Projector PPND API"
  uri_base "https://projector"

  default_settings({
    digest_auth: {
      username: "admin",
      password: "panasonic",
    },
    api_version:   "v1",
    poll_interval: 30,
    enable_https:  true,
  })

  @digest_auth : HTTP::Client::DigestAuth = HTTP::Client::DigestAuth.new
  @auth_challenge = ""
  @auth_uri : URI = URI.parse("http://localhost")
  @api_version : String = "v1"
  @poll_interval : Int32 = 30

  def on_load
    # Initialize digest auth
    @digest_auth = HTTP::Client::DigestAuth.new
    @auth_challenge = ""
    @auth_uri = URI.parse(config.uri.not_nil!)

    on_update
  end

  def on_update
    # Update digest auth credentials
    if auth_info = setting?(Hash(String, String), :digest_auth)
      @auth_uri.user = auth_info["username"]?
      @auth_uri.password = auth_info["password"]?
    end

    @api_version = setting?(String, :api_version) || "v1"
    @poll_interval = setting?(Int32, :poll_interval) || 30

    # Schedule periodic status polling
    schedule.clear
    schedule.every(@poll_interval.seconds) do
      query_power_status
      query_input_status
      query_shutter_status
      query_freeze_status
    end

    # Initial queries
    schedule.in(2.seconds) do
      query_device_info
      query_firmware_version
      query_power_status
      query_input_status
    end
  end

  # ====== Authentication helpers ======

  private def authenticate_if_needed(path : String)
    return unless @auth_challenge.empty?

    # Make initial request to get challenge
    response = http("GET", path)
    if response.status_code == 401 && (challenge = response.headers["WWW-Authenticate"]?)
      @auth_challenge = challenge
    elsif response.status_code == 503
      raise "Device unavailable (503)"
    else
      raise "Request failed with: #{response.status_code}"
    end
  end

  private def request_with_digest_auth(method : String, path : String, body : String? = nil, headers : HTTP::Headers? = nil, retry_count : Int32 = 0)
    if retry_count >= 2
      raise "Authentication failure"
    end

    authenticate_if_needed(path)

    uri = URI.parse("/api/#{@api_version}#{path}")
    @auth_uri.path = uri.path
    @auth_uri.query = uri.query

    auth_header = @digest_auth.auth_header(@auth_uri, @auth_challenge, method)
    request_headers = headers || HTTP::Headers.new
    request_headers["Authorization"] = auth_header
    request_headers["Content-Type"] = "application/json" if body

    response = http(method, "/api/#{@api_version}#{path}", body: body, headers: request_headers)

    case response.status_code
    when 401
      # Auth failed, clear challenge to re-authenticate next time
      @auth_challenge = ""
      @digest_auth = HTTP::Client::DigestAuth.new
      request_with_digest_auth(method, path, body, retry_count: retry_count + 1)
    when 503
      raise "Device unavailable (503)"
    when 409
      raise "Conflict - device busy (409)"
    else
      response
    end
  end

  private def get_with_auth(path : String)
    request_with_digest_auth("GET", path)
  end

  private def put_with_auth(path : String, body : String)
    request_with_digest_auth("PUT", path, body)
  end

  # ====== Powerable Interface ======

  def power(state : Bool)
    body = {state: state ? "on" : "standby"}.to_json

    queue(name: "power", priority: 99) do |task|
      response = put_with_auth("/power", body)

      unless response.success?
        raise "Power command failed: #{response.status_code} - #{response.body}"
      end

      result = Panasonic::Projector::PowerState.from_json(response.body)
      self[:power] = result.state == "on"
      self[:power_target] = state

      task.success(result.state == "on")
    end
  end

  def power?(**options)
    query_power_status(**options)
  end

  def query_power_status(**options)
    queue(**options) do |task|
      response = get_with_auth("/power")

      unless response.success?
        raise "Power query failed: #{response.status_code}"
      end

      result = Panasonic::Projector::PowerState.from_json(response.body)
      power_on = result.state == "on"
      self[:power] = power_on

      task.success(power_on)
    end
  end

  # ====== Input Selection ======

  INPUT_MAPPING = {
    Input::COMPUTER     => "COMPUTER",
    Input::HDMI1        => "HDMI1",
    Input::HDMI2        => "HDMI2",
    Input::MemoryViewer => "MEMORY VIEWER",
    Input::Network      => "NETWORK",
    Input::DigitalLink  => "DIGITAL LINK",
  }

  INPUT_REVERSE_MAPPING = INPUT_MAPPING.invert

  def switch_to(input : Input)
    input_str = INPUT_MAPPING[input]
    body = {state: input_str}.to_json

    queue(name: "input", delay: 2.seconds) do |task|
      response = put_with_auth("/input", body)

      unless response.success?
        raise "Input switch failed: #{response.status_code} - #{response.body}"
      end

      result = Panasonic::Projector::InputState.from_json(response.body)
      self[:input] = INPUT_REVERSE_MAPPING[result.state]?

      task.success(result.state)
    end
  end

  def query_input_status(**options)
    queue(**options) do |task|
      response = get_with_auth("/input")

      unless response.success?
        raise "Input query failed: #{response.status_code}"
      end

      result = Panasonic::Projector::InputState.from_json(response.body)
      self[:input] = INPUT_REVERSE_MAPPING[result.state]?
      self[:input_raw] = result.state

      task.success(result.state)
    end
  end

  # ====== Shutter Control ======

  def shutter(state : Bool)
    body = {state: state ? "open" : "close"}.to_json

    queue(name: "shutter") do |task|
      response = put_with_auth("/shutter", body)

      unless response.success?
        raise "Shutter command failed: #{response.status_code} - #{response.body}"
      end

      result = Panasonic::Projector::ShutterState.from_json(response.body)
      self[:shutter] = result.state
      self[:shutter_open] = result.state == "open"

      task.success(result.state)
    end
  end

  def shutter_open
    shutter(true)
  end

  def shutter_close
    shutter(false)
  end

  def query_shutter_status(**options)
    queue(**options) do |task|
      response = get_with_auth("/shutter")

      unless response.success?
        raise "Shutter query failed: #{response.status_code}"
      end

      result = Panasonic::Projector::ShutterState.from_json(response.body)
      self[:shutter] = result.state
      self[:shutter_open] = result.state == "open"

      task.success(result.state)
    end
  end

  # ====== Freeze Control ======

  def freeze(state : Bool)
    body = {state: state ? "on" : "off"}.to_json

    queue(name: "freeze") do |task|
      response = put_with_auth("/freeze", body)

      unless response.success?
        raise "Freeze command failed: #{response.status_code} - #{response.body}"
      end

      result = Panasonic::Projector::FreezeState.from_json(response.body)
      self[:freeze] = result.state == "on"
      self[:frozen] = result.state == "on"

      task.success(result.state == "on")
    end
  end

  def query_freeze_status(**options)
    queue(**options) do |task|
      response = get_with_auth("/freeze")

      unless response.success?
        raise "Freeze query failed: #{response.status_code}"
      end

      result = Panasonic::Projector::FreezeState.from_json(response.body)
      self[:freeze] = result.state == "on"
      self[:frozen] = result.state == "on"

      task.success(result.state == "on")
    end
  end

  # ====== Status Queries ======

  def query_signal
    queue do |task|
      response = get_with_auth("/signal")

      unless response.success?
        raise "Signal query failed: #{response.status_code}"
      end

      result = Panasonic::Projector::SignalInformation.from_json(response.body)
      self[:signal_info] = result.infomation
      self[:no_signal] = result.infomation == "NO SIGNAL"

      task.success(result.infomation)
    end
  end

  def query_errors
    queue do |task|
      response = get_with_auth("/error")

      unless response.success?
        raise "Error query failed: #{response.status_code}"
      end

      errors = Array(Panasonic::Projector::ErrorStatus).from_json(response.body)
      self[:errors] = errors
      self[:error_count] = errors.size
      self[:has_errors] = !errors.empty?

      task.success(errors)
    end
  end

  def query_lights
    queue do |task|
      response = get_with_auth("/lights")

      unless response.success?
        raise "Lights query failed: #{response.status_code}"
      end

      lights = Array(Panasonic::Projector::LightStatus).from_json(response.body)
      self[:lights] = lights

      # Store individual light states
      lights.each do |light|
        self["light_#{light.light_id}_state"] = light.light_state
        self["light_#{light.light_id}_runtime"] = light.light_runtime
      end

      task.success(lights)
    end
  end

  def query_light(light_id : Int32)
    queue do |task|
      response = get_with_auth("/lights/#{light_id}")

      unless response.success?
        raise "Light query failed: #{response.status_code}"
      end

      light = Panasonic::Projector::LightStatus.from_json(response.body)
      self["light_#{light.light_id}_state"] = light.light_state
      self["light_#{light.light_id}_runtime"] = light.light_runtime

      task.success(light)
    end
  end

  def query_device_info
    queue do |task|
      response = get_with_auth("/device-information")

      unless response.success?
        raise "Device info query failed: #{response.status_code}"
      end

      info = Panasonic::Projector::DeviceInformation.from_json(response.body)
      self[:model] = info.model_name
      self[:serial_number] = info.serial_no
      self[:projector_name] = info.projector_name
      self[:mac_address] = info.macadress

      task.success(info)
    end
  end

  def query_firmware_version
    queue do |task|
      response = get_with_auth("/version")

      unless response.success?
        raise "Firmware query failed: #{response.status_code}"
      end

      version = Panasonic::Projector::FirmwareVersion.from_json(response.body)
      self[:firmware_version] = version.main_version

      task.success(version.main_version)
    end
  end

  def query_temperatures
    queue do |task|
      response = get_with_auth("/temperatures")

      unless response.success?
        raise "Temperature query failed: #{response.status_code}"
      end

      temps = Array(Panasonic::Projector::TemperatureInfo).from_json(response.body)
      self[:temperatures] = temps

      # Store individual temperature readings
      temps.each do |temp|
        self["temp_#{temp.temperature_id}_name"] = temp.temperature_name
        self["temp_#{temp.temperature_id}_celsius"] = temp.temperature_celsius
      end

      task.success(temps)
    end
  end

  def query_temperature(temp_id : Int32)
    queue do |task|
      response = get_with_auth("/temperatures/#{temp_id}")

      unless response.success?
        raise "Temperature query failed: #{response.status_code}"
      end

      temp = Panasonic::Projector::TemperatureInfo.from_json(response.body)
      self["temp_#{temp.temperature_id}_name"] = temp.temperature_name
      self["temp_#{temp.temperature_id}_celsius"] = temp.temperature_celsius

      task.success(temp)
    end
  end

  # ====== Settings ======

  def configure_ntp(sync : Bool, server : String)
    body = {"ntp-sync": sync ? "on" : "off", "ntp-server": server}.to_json

    queue do |task|
      response = put_with_auth("/ntp", body)

      unless response.success?
        raise "NTP configuration failed: #{response.status_code} - #{response.body}"
      end

      result = Panasonic::Projector::NTPSettings.from_json(response.body)
      self[:ntp_sync] = result.ntp_sync == "on"
      self[:ntp_server] = result.ntp_server

      task.success(result)
    end
  end

  def query_ntp_settings
    queue do |task|
      response = get_with_auth("/ntp")

      unless response.success?
        raise "NTP query failed: #{response.status_code}"
      end

      result = Panasonic::Projector::NTPSettings.from_json(response.body)
      self[:ntp_sync] = result.ntp_sync == "on"
      self[:ntp_server] = result.ntp_server

      task.success(result)
    end
  end

  def configure_https(enabled : Bool)
    body = {state: enabled ? "on" : "off"}.to_json

    queue do |task|
      response = put_with_auth("/https", body)

      unless response.success?
        raise "HTTPS configuration failed: #{response.status_code} - #{response.body}"
      end

      result = Panasonic::Projector::HTTPSConfig.from_json(response.body)
      self[:https_enabled] = result.state == "on"

      task.success(result.state == "on")
    end
  end

  def query_https_config
    queue do |task|
      response = get_with_auth("/https")

      unless response.success?
        raise "HTTPS query failed: #{response.status_code}"
      end

      result = Panasonic::Projector::HTTPSConfig.from_json(response.body)
      self[:https_enabled] = result.state == "on"

      task.success(result.state == "on")
    end
  end
end

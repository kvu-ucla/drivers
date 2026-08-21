require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"
require "placeos-driver/interface/device_info"

# Documentation: https://pro-bravia.sony.net/develop/integrate/rest-api/spec/

class Sony::Displays::BraviaPro < PlaceOS::Driver
  include Interface::DeviceInfo
  include Interface::Powerable
  include Interface::Muteable

  # Discovery Information
  uri_base "http://"
  descriptive_name "Sony Bravia Pro Display (REST API)"
  generic_name :Display

  default_settings({
    psk: "1234", # Pre-Shared Key for authentication
  })

  enum Input
    Hdmi
    Hdmi1
    Hdmi2
    Hdmi3
    Hdmi4
    Tv
    ComponentVideo
    CompositeVideo
    Scart
    Pc
    AnalogRgb
    DviD

    def to_api_uri : String
      case self
      when .hdmi1?, .hdmi?
        "extInput:hdmi?port=1"
      when .hdmi2?
        "extInput:hdmi?port=2"
      when .hdmi3?
        "extInput:hdmi?port=3"
      when .hdmi4?
        "extInput:hdmi?port=4"
      when .tv?
        "tv:dvbt"
      when .component_video?
        "extInput:component?port=1"
      when .composite_video?
        "extInput:composite?port=1"
      when .scart?
        "extInput:scart?port=1"
      when .pc?
        "extInput:vga?port=1"
      when .analog_rgb?
        "extInput:vga?port=1"
      when .dvi_d?
        "extInput:dvi?port=1"
      else
        "extInput:hdmi?port=1"
      end
    end

    def self.from_api_uri(uri : String) : Input?
      case uri
      when /hdmi.*port=1/
        Hdmi1
      when /hdmi.*port=2/
        Hdmi2
      when /hdmi.*port=3/
        Hdmi3
      when /hdmi.*port=4/
        Hdmi4
      when /tv:dvbt/
        Tv
      when /component/
        ComponentVideo
      when /composite/
        CompositeVideo
      when /scart/
        Scart
      when /vga/
        AnalogRgb
      when /dvi/
        DviD
      else
        nil
      end
    end
  end

  include Interface::InputSelection(Input)

  # error codes the display returns during normal operation:
  # 40005 = display is in standby, 7 = no content active (e.g. home screen)
  EXPECTED_ERROR_CODES = {7, 40005}

  @psk : String = "1234"

  def on_load
    @psk = setting(String, :psk) || "1234"

    self[:volume_min] = 0
    self[:volume_max] = 100
  end

  def on_update
    @psk = setting(String, :psk) || "1234"
  end

  def connected
    schedule.every(30.seconds, true) do
      do_poll
    end
  end

  def disconnected
    schedule.clear
  end

  struct SonyDescriptor
    include JSON::Serializable

    getter generation : String
    getter product : String
    getter serial : String
    getter name : String
    getter model : String

    @[JSON::Field(key: "macAddr")]
    getter mac_addr : String

    @[JSON::Field(key: "fwVersion")]
    getter fw_version : String

    @[JSON::Field(key: "androidOs")]
    getter android_os : String

    @[JSON::Field(key: "webAppRuntimeVersion")]
    getter web_app_runtime_version : String
  end

  struct SonyInterface
    include JSON::Serializable

    @[JSON::Field(key: "modelName")]
    getter model_name : String

    @[JSON::Field(key: "interfaceVersion")]
    getter interface_version : String

    @[JSON::Field(key: "productName")]
    getter product_name : String

    @[JSON::Field(key: "productCategory")]
    getter product_category : String
  end

  def interface_details : SonyInterface
    response = post("/sony/system",
      headers: auth_headers,
      body: {
        method:  "getInterfaceInformation",
        id:      33,
        params:  [] of Nil,
        version: "1.0",
      }.to_json
    )

    result = parse_result(response, "getInterfaceInformation")
    raise "getInterfaceInformation command failed: #{response.body}" unless result

    Array(SonyInterface).from_json(result.to_json).first
  end

  def device_info : Descriptor
    interface = interface_details

    response = post("/sony/system",
      headers: auth_headers,
      body: {
        method:  "getSystemInformation",
        id:      33,
        params:  [] of Nil,
        version: "1.7",
      }.to_json
    )

    result = parse_result(response, "getSystemInformation")
    raise "getSystemInformation command failed: #{response.body}" unless result

    details = Array(SonyDescriptor).from_json(result.to_json).first
    ip_address = config.ip.presence || URI.parse(config.uri.as(String)).hostname

    Descriptor.new(
      make: "Sony",
      model: "#{interface.product_category} #{interface.product_name} #{interface.model_name}",
      serial: details.serial,
      firmware: "#{details.fw_version}, generation #{details.generation}, android #{details.android_os}, web app #{details.web_app_runtime_version}",
      mac_address: details.mac_addr,
      ip_address: ip_address,
    )
  end

  # Power Control
  def power(state : Bool)
    # setPowerStatus takes a boolean, the "active"/"standby" strings only
    # appear in getPowerStatus responses and are rejected as Illegal Argument
    response = post("/sony/system",
      headers: auth_headers,
      body: {
        method:  "setPowerStatus",
        id:      1,
        params:  [{status: state}],
        version: "1.0",
      }.to_json
    )

    if parse_result(response, "setPowerStatus")
      self[:power] = state
      power?
    end

    state
  end

  def power?
    response = post("/sony/system",
      headers: auth_headers,
      body: {
        method:  "getPowerStatus",
        id:      2,
        params:  [] of String,
        version: "1.0",
      }.to_json
    )

    if result = parse_result(response, "getPowerStatus")
      if status = result.as_a?.try(&.first?).try(&.["status"]?).try(&.as_s?)
        power_state = status == "active"
        self[:power] = power_state
        return power_state
      end
      logger.warn { "Failed to parse power status response: #{response.body}" }
    end
    nil
  end

  # Volume Control
  def volume(level : Int32 | Float64)
    level = level.to_f.clamp(0.0, 100.0).round_away.to_i

    response = post("/sony/audio",
      headers: auth_headers,
      body: {
        method: "setAudioVolume",
        id:     3,
        params: [{
          target: "speaker",
          # must be sent as a string, integers are rejected as Illegal Argument
          volume: level.to_s,
        }],
        version: "1.0",
      }.to_json
    )

    if parse_result(response, "setAudioVolume")
      self[:volume] = level
      volume?
    end

    level
  end

  def volume?
    if info = speaker_info
      # returned as a number on hardware, though older firmware may use strings
      level = info["volume"]?.try { |v| v.as_i? || v.as_s?.try(&.to_i?) }
      if level
        self[:volume] = level
        return level
      end
      logger.warn { "Failed to parse volume information: #{info}" }
    end
    nil
  end

  def volume_up
    current_volume = status?(Int32, :volume) || 50
    volume(current_volume + 5)
  end

  def volume_down
    current_volume = status?(Int32, :volume) || 50
    volume(current_volume - 5)
  end

  # Mute Control
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo,
  )
    response = post("/sony/audio",
      headers: auth_headers,
      body: {
        method: "setAudioMute",
        id:     5,
        params: [{
          status: state,
        }],
        version: "1.0",
      }.to_json
    )

    if parse_result(response, "setAudioMute")
      self[:mute] = state
      mute?
    end

    state
  end

  def unmute
    mute(false)
  end

  def mute?
    if info = speaker_info
      mute_state = info["mute"]?.try(&.as_bool?)
      unless mute_state.nil?
        self[:mute] = mute_state
        return mute_state
      end
      logger.warn { "Failed to parse mute information: #{info}" }
    end
    nil
  end

  # Input Selection
  def switch_to(input : Input)
    logger.debug { "switching input to #{input}" }

    response = post("/sony/avContent",
      headers: auth_headers,
      body: {
        method: "setPlayContent",
        id:     7,
        params: [{
          uri: input.to_api_uri,
        }],
        version: "1.0",
      }.to_json
    )

    if parse_result(response, "setPlayContent")
      self[:input] = input.to_s
      input?
    end

    input
  end

  def input?
    response = post("/sony/avContent",
      headers: auth_headers,
      body: {
        method:  "getPlayingContentInfo",
        id:      8,
        params:  [] of String,
        version: "1.0",
      }.to_json
    )

    if result = parse_result(response, "getPlayingContentInfo")
      if uri = result.as_a?.try(&.first?).try(&.["uri"]?).try(&.as_s?)
        if input = Input.from_api_uri(uri)
          self[:input] = input.to_s
          return input
        end
        logger.warn { "Unknown input URI: #{uri}" }
      end
    end
    nil
  end

  private def do_poll
    if self[:power]?
      input?
      mute?
      volume?
    end
  end

  # fetches the speaker entry from getVolumeInformation, shared by volume? and mute?
  private def speaker_info : JSON::Any?
    response = post("/sony/audio",
      headers: auth_headers,
      body: {
        method:  "getVolumeInformation",
        id:      4,
        params:  [] of String,
        version: "1.0",
      }.to_json
    )

    if result = parse_result(response, "getVolumeInformation")
      if targets = result.as_a?.try(&.first?).try(&.as_a?)
        return targets.find { |t| t["target"]? == "speaker" }
      end
      logger.warn { "Failed to parse volume information response: #{response.body}" }
    end
    nil
  end

  # the display reports failures as HTTP 200 with an {"error": [code, message]}
  # body, so the HTTP status alone cannot confirm a command was accepted
  private def parse_result(response, request : String) : JSON::Any?
    unless response.success?
      logger.warn { "#{request} request failed: HTTP #{response.status_code}, #{response.body}" }
      return nil
    end

    data = JSON.parse(response.body)
    if error = data["error"]?
      code = error.as_a?.try(&.first?).try(&.as_i?)
      if code.in?(EXPECTED_ERROR_CODES)
        logger.debug { "#{request} rejected: #{error}" }
      else
        logger.warn { "#{request} failed: #{error}" }
      end
      return nil
    end

    data["result"]?
  end

  private def auth_headers
    HTTP::Headers{
      "X-Auth-PSK"   => @psk,
      "Content-Type" => "application/json",
    }
  end
end

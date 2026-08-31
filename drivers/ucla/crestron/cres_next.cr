# UCLA-maintained copy of drivers/crestron/cres_next.cr (vendored 2026-08-30 from ucla-dev @ ce19af2a18)
require "placeos-driver"
require "placeos-driver/interface/device_info"
require "json"
require "path"
require "uri"
require "./nvx_models"
require "./cres_next_auth"

# Documentation: https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Prerequisites-Assumptions.htm
# inspecting request - response packets from the device webui is also useful

# Parent module for Crestron DM NVX devices.
abstract class Crestron::CresNext < PlaceOS::Driver
  include Crestron::CresNextAuth
  include Interface::DeviceInfo

  def websocket_headers
    authenticate

    headers = HTTP::Headers.new
    transport.cookies.add_request_headers(headers)
    headers["CREST-XSRF-TOKEN"] = @xsrf_token unless @xsrf_token.empty?
    headers["User-Agent"] = "advanced-rest-client"
    headers
  end

  def connected
    schedule.clear
    schedule.every(10.minutes) { maintain_session }
  end

  def disconnected
    schedule.clear
  end

  def tokenize(path : String)
    path.split('/').reject(&.empty?)
  end

  # ============================================
  # websocket for state changes and get requests
  # ============================================
  protected def query(path : String, **options, &block : (JSON::Any, ::PlaceOS::Driver::Task) -> Nil)
    request_path = Path["/Device"].join(path).to_s
    tokens = tokenize(request_path)
    parts = tokens.map { |part| %("#{part}":) }

    send(request_path, **options) do |data, task|
      raw_json = String.new(data)
      logger.debug { "Crestron sent: #{raw_json}" }

      # The device occasionally returns multiple JSON objects in a single
      # frame (e.g. an "Actions"/"Results" ack followed by the state update),
      # separated by a blank line. Parse each line independently.
      raw_json.each_line do |line|
        line = line.strip
        next if line.empty?

        # only consider lines that include the full response path
        next unless parts.all? { |p| line.includes?(p) }

        begin
          json = JSON.parse(line)
          tokens.each { |key| json = json[key] }
          block.call json, task
          task.success json
          break
        rescue error
          logger.warn(exception: error) { "failed to parse Crestron query response line: #{line}" }
        end
      end
    end
  end

  protected def ws_update(path : String, value, **options)
    request_path = Path["/Device"].join(path).to_s

    # expands into object that we need to post
    components = tokenize(request_path).map { |part| %({"#{part}") }
    payload = %(#{components.join(':')}:#{value.to_json}#{"}" * components.size})

    apply_ws_changes(payload, **options)
  end

  private def apply_ws_changes(payload : String, **options)
    logger.debug { "Sending WebSocket update: #{payload}" }
    send(payload, **options) do |data, task|
      raw_json = String.new(data)
      logger.debug { "Crestron sent: #{raw_json}" }

      # The device may bundle the Actions/Results ack with a state update in
      # the same frame, so we walk each line and only parse the ack line.
      raw_json.each_line do |line|
        line = line.strip
        next if line.empty?
        next unless line.includes? %("Results":)

        begin
          task.success JSON.parse(line)
          break
        rescue error
          logger.warn(exception: error) { "failed to parse Crestron ws update response: #{line}" }
        end
      end
    end
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def manual_send(payload : JSON::Any)
    data = payload.to_json
    logger.debug { "Sending: #{data}" }
    send data, wait: false
  end

  def received(data, task)
    raw_json = String.new data
    logger.debug { "Crestron sent: #{raw_json}" }
  end

  # ========================================
  # HTTP for updates and session maintenance
  # ========================================

  # keep the session cookies fresh without issuing device-info queries -
  # identity acquisition is owned by the DeviceInfo interface's schedule.
  #
  # The refresh is failure-isolated (`lifecycle: false`): a transient
  # HTTP/auth failure must NOT call queue.set_connected(false), which would
  # drive `disconnected` -> schedule.clear on a still-open websocket and
  # cancel this very cadence. Failures are logged and the untouched
  # 10-minute schedule simply retries on its next tick - a later success
  # needs no re-arming because nothing was ever cleared. Only genuine
  # transport failure drives the connection lifecycle.
  def maintain_session : Nil
    authenticate(lifecycle: false)
  rescue error
    logger.warn(exception: error) { "session refresh failed, will retry on the next scheduled refresh" }
  end

  # last successfully published descriptor, served when a query fails
  @device_info_cache : Descriptor? = nil

  def device_info : Descriptor
    response = get("/Device/DeviceInfo")
    raise "bad credentials, unauthenticated" unless response.success?

    payload = JSON.parse(response.body)
    logger.debug { "device details payload: #{payload.to_pretty_json}" }

    # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/DeviceInfo.htm
    ip_address = config.ip.presence || URI.parse(config.uri.as(String)).hostname

    model = payload.dig?("Device", "DeviceInfo", "Model").try(&.as_s?).presence || "NVX"
    if model_type = payload.dig?("Device", "DeviceInfo", "ModelSubType").try(&.as_s?).presence
      model = "#{model} (#{model_type})"
    end
    if category = payload.dig?("Device", "DeviceInfo", "Category").try(&.as_s?).presence
      model = "#{category} #{model}"
    end

    # DeviceVersion is the firmware running on the device; the payload's
    # Version property is the DeviceInfo schema version, not firmware
    firmware = [
      payload.dig?("Device", "DeviceInfo", "DeviceVersion").try(&.as_s?).presence,
      payload.dig?("Device", "DeviceInfo", "PufVersion").try(&.as_s?).presence.try { |version| "puf #{version}" },
      payload.dig?("Device", "DeviceInfo", "BuildDate").try(&.as_s?).presence.try { |date| "built #{date}" },
    ].compact.join(", ").presence

    mac = payload.dig("Device", "DeviceInfo", "MacAddress").as_s
    name = payload.dig?("Device", "DeviceInfo", "Name").try(&.as_s?).presence

    @device_info_cache = Descriptor.new(
      make: "Crestron",
      model: model,
      serial: payload.dig("Device", "DeviceInfo", "SerialNumber").as_s,
      firmware: firmware,
      mac_address: mac,
      ip_address: ip_address,
      hostname: name,
    )
  rescue error
    logger.warn(exception: error) { "device info query failed, serving cached/static details" }
    @device_info_cache || Descriptor.new(
      make: "Crestron",
      model: "NVX",
      ip_address: config.ip.presence || URI.parse(config.uri.as(String)).hostname,
    )
  end

  @[Security(Level::Administrator)]
  def reboot(now : Bool = false)
    sleep rand(5000).milliseconds unless now
    ws_update "/DeviceOperations/Reboot", true, name: "reboot"
  end

  # payload is expected to be a hash or named tuple
  protected def update(path : String, value, **options)
    request_path = Path["/Device"].join(path).to_s

    # expands into object that we need to post
    components = tokenize(request_path).map { |part| %({"#{part}") }
    payload = %(#{components.join(':')}:#{value.to_json}#{"}" * components.size})

    apply_http_changes(request_path, payload, **options)
  end

  private def apply_http_changes(request_path : String, payload : String, **options)
    queue(**options) do |task|
      response = post request_path, body: payload, headers: HTTP::Headers{"CREST-XSRF-TOKEN" => @xsrf_token}
      logger.debug { "updated requested for #{request_path}, response was #{response.body}" }

      # no real need to parse the responses as the changes will be sent down the websocket
      if response.success?
        task.success JSON.parse(response.body)
      else
        task.abort "crestron failed to apply changes to: #{request_path}\n#{response.body}"
      end
    end
  end
end

# UCLA-maintained copy of drivers/crestron/tsw_1070.cr (vendored 2026-08-30 from ucla-dev @ ce19af2a18)
require "placeos-driver"
require "placeos-driver/interface/device_info"
require "./tsw_models"
require "./cres_next_auth"
require "uri"

# Documentation: https://sdkcon78221.crestron.com/sdk/TSW-70-API/
# Crestron TSW-70/TS-1070 Touch Screen driver using HTTP JSON API
# Note: This device does not support WebSocket interface, uses HTTP polling instead

class Crestron::Tsw1070 < PlaceOS::Driver
  include Crestron::CresNextAuth
  include Interface::DeviceInfo

  descriptive_name "Crestron TSW-1070 Touch Screen (UCLA)"
  generic_name :TouchPanel
  description <<-DESC
    Crestron TSW-70 series touch screen control via HTTP JSON API.
    Requires firmware 3.002.0034.001 or later.
  DESC

  uri_base "https://192.168.0.5"

  default_settings({
    username: "admin",
    password: "admin",

    http_keep_alive_seconds: 600,
    http_max_requests:       1200,
  })

  @monitoring : Bool = false
  @lock : Mutex = Mutex.new

  # last full DeviceInfo snapshot (long-poll deltas are merged into this)
  @device_info_state : Crestron::DeviceInfo? = nil
  # last successfully published descriptor, served when a query fails
  @device_info_cache : Descriptor? = nil

  def on_load
    # Re-authenticate every 10 minutes
    schedule.every(10.minutes) { authenticate }
  end

  def on_update
    authenticate
  end

  def connected
    schedule.clear
    schedule.every(10.minutes) { authenticate }
    spawn { authenticate }
  end

  protected def on_authenticated : Nil
    update_device_info
    @lock.synchronize do
      if !@monitoring
        spawn { event_monitor }
        @monitoring = true
      end
    end
  end

  # ====== Device Information ======
  # Documentation: https://sdkcon78221.crestron.com/sdk/TSW-70-API/Content/Topics/Objects/DeviceInfo.htm

  def device_info : Descriptor
    response = get("/Device/DeviceInfo", concurrent: true)
    raise "unexpected response code: #{response.status_code}" unless response.success?

    payload = JSON.parse(response.body)
    info = Crestron::DeviceInfo.from_json(payload["Device"]["DeviceInfo"].to_json)
    @device_info_state = info
    self[:device_info_raw] = info
    @device_info_cache = to_descriptor(info)
  rescue error
    logger.warn(exception: error) { "device info query failed, serving cached/static details" }
    @device_info_cache || Descriptor.new(
      make: "Crestron",
      model: "TSW-1070",
      ip_address: config.ip.presence || URI.parse(config.uri.as(String)).hostname,
    )
  end

  # Long polling for real-time updates
  def event_monitor
    loop do
      break if terminated?
      if authenticated?
        logger.debug { "event monitor: performing long poll" }
        sleep 1.second unless long_poll
      else
        logger.debug { "event monitor: idling as not authenticated" }
        sleep 1.second
      end
    end
  end

  # NOTE:: /Device/Longpoll
  # 200 == check data
  #  when nothing new: {"Device":"Response Timeout"}
  #  when update: {"Device":{...}}
  # 301 == authentication required
  protected def long_poll : Bool
    response = get("/Device/Longpoll")

    # retry after authenticating
    if response.status_code == 301
      authenticate
      response = get("/Device/Longpoll")
    end
    raise "unexpected response code: #{response.status_code}" unless response.success?

    raw_json = response.body
    logger.debug { "long poll sent: #{raw_json}" }
    payload = JSON.parse(raw_json)

    # Check if there's actual device data (not just a timeout response)
    if device_data = payload["Device"]?
      # Skip if it's just a timeout message
      return true if device_data.as_s? == "Response Timeout"

      # Process any device info updates. Long-poll responses are partial
      # objects containing only the changed properties, so merge into the
      # last full snapshot rather than publishing the delta directly.
      if device_info_json = device_data.dig?("DeviceInfo")
        delta = Crestron::DeviceInfo.from_json(device_info_json.to_json)
        if base = @device_info_state
          info = merge_device_info(base, delta)
          @device_info_state = info
          self[:device_info_raw] = info
          self[:device_info] = @device_info_cache = to_descriptor(info)
        else
          # no full snapshot to merge the delta into yet - fetch one
          update_device_info
        end
        logger.debug { "Device updated via long poll: #{delta.name}" }
      end
    end

    true
  rescue timeout : IO::TimeoutError
    logger.debug { "timeout waiting for long poll to complete" }
    false
  rescue error
    logger.warn(exception: error) { "during long polling" }
    false
  end

  # map the device's DeviceInfo payload onto the common Descriptor shape;
  # fields the device did not report stay nil
  protected def to_descriptor(info : Crestron::DeviceInfo) : Descriptor
    model = info.model.presence || "TSW-1070"
    if category = info.category.presence
      model = "#{category} #{model}"
    end

    # DeviceVersion is the firmware running on the device; the payload's
    # Version property is the API schema version, not firmware
    firmware = [
      info.device_version,
      info.puf_version.try { |version| "puf #{version}" },
      info.build_date.try { |date| "built #{date}" },
    ].compact.join(", ").presence

    Descriptor.new(
      make: "Crestron",
      model: model,
      serial: info.serial_number,
      firmware: firmware,
      mac_address: info.mac_address,
      ip_address: config.ip.presence || URI.parse(config.uri.as(String)).hostname,
      hostname: info.name,
    )
  end

  # overlay the non-nil fields of a partial update onto a full snapshot
  protected def merge_device_info(base : Crestron::DeviceInfo, delta : Crestron::DeviceInfo) : Crestron::DeviceInfo
    base.model = delta.model unless delta.model.nil?
    base.category = delta.category unless delta.category.nil?
    base.manufacturer = delta.manufacturer unless delta.manufacturer.nil?
    base.model_id = delta.model_id unless delta.model_id.nil?
    base.device_id = delta.device_id unless delta.device_id.nil?
    base.serial_number = delta.serial_number unless delta.serial_number.nil?
    base.name = delta.name unless delta.name.nil?
    base.device_version = delta.device_version unless delta.device_version.nil?
    base.puf_version = delta.puf_version unless delta.puf_version.nil?
    base.build_date = delta.build_date unless delta.build_date.nil?
    base.device_key = delta.device_key unless delta.device_key.nil?
    base.mac_address = delta.mac_address unless delta.mac_address.nil?
    base.reboot_reason = delta.reboot_reason unless delta.reboot_reason.nil?
    base.version = delta.version unless delta.version.nil?
    base
  end

  # Additional API endpoints can be added here as needed
  # Refer to: https://sdkcon78221.crestron.com/sdk/TSW-70-API/Content/Topics/Home.htm
end

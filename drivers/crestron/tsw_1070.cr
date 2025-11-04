require "./cres_next"
require "./tsw_models"

# Documentation: https://sdkcon78221.crestron.com/sdk/TSW-70-API/
# Crestron TSW-70/TS-1070 Touch Screen driver using CresNext JSON API

class Crestron::Tsw1070 < Crestron::CresNext
  descriptive_name "Crestron TSW-1070 Touch Screen"
  generic_name :TouchPanel
  description <<-DESC
    Crestron TSW-70 series touch screen control via CresNext JSON API.
    Requires firmware 3.002.0034.001 or later.
  DESC

  uri_base "wss://192.168.0.5/websockify"

  default_settings({
    username: "admin",
    password: "admin",
  })

  def connected
    super

    # Query device information on connection
    schedule.every(5.minutes, immediate: true) do
      query_device_info
    end
  end

  # ====== Device Information ======
  # Documentation: https://sdkcon78221.crestron.com/sdk/TSW-70-API/Content/Topics/Objects/DeviceInfo.htm

  def query_device_info
    query("/DeviceInfo") do |info|
      # Parse the response using the DeviceInfo model
      device_info = Crestron::DeviceInfo.from_json(info.to_json)

      # Store complete info
      self[:device_info] = device_info

      # Store individual fields for easy access
      self[:model] = device_info.model
      self[:category] = device_info.category
      self[:manufacturer] = device_info.manufacturer
      self[:model_id] = device_info.model_id
      self[:device_id] = device_info.device_id
      self[:serial_number] = device_info.serial_number
      self[:name] = device_info.name
      self[:device_version] = device_info.device_version
      self[:puf_version] = device_info.puf_version
      self[:build_date] = device_info.build_date
      self[:mac_address] = device_info.mac_address
      self[:reboot_reason] = device_info.reboot_reason
      self[:api_version] = device_info.version

      logger.debug { "Device Info: #{device_info.model} (#{device_info.serial_number}), FW: #{device_info.puf_version}" }
    end
  end

  # Additional API endpoints can be added here as needed
  # Refer to: https://sdkcon78221.crestron.com/sdk/TSW-70-API/Content/Topics/Objects/
end

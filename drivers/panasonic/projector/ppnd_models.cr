require "json"

module Panasonic::Projector
  # State models for simple on/off or enum states
  struct PowerState
    include JSON::Serializable

    property state : String # "standby" or "on"
  end

  struct InputState
    include JSON::Serializable

    property state : String # "COMPUTER", "HDMI1", "HDMI2", "MEMORY VIEWER", "NETWORK", "DIGITAL LINK"
  end

  struct ShutterState
    include JSON::Serializable

    property state : String # "open" or "close"
  end

  struct FreezeState
    include JSON::Serializable

    property state : String # "off" or "on"
  end

  struct SignalInformation
    include JSON::Serializable

    property infomation : String # Note: API uses "infomation" (typo in API)
  end

  # Error status
  struct ErrorStatus
    include JSON::Serializable

    @[JSON::Field(key: "error-kind")]
    property error_kind : String # "warning" or "error"

    @[JSON::Field(key: "error-category")]
    property error_category : String # e.g., "temperature"

    @[JSON::Field(key: "error-code")]
    property error_code : String # e.g., "U11", "U23"

    @[JSON::Field(key: "error-message")]
    property error_message : String
  end

  # Light status
  struct LightStatus
    include JSON::Serializable

    @[JSON::Field(key: "light-id")]
    property light_id : Int32

    @[JSON::Field(key: "light-name")]
    property light_name : String

    @[JSON::Field(key: "light-state")]
    property light_state : String # "on" or "off"

    @[JSON::Field(key: "light-runtime")]
    property light_runtime : Int32 # Runtime in hours
  end

  # Device information
  struct DeviceInformation
    include JSON::Serializable

    @[JSON::Field(key: "model-name")]
    property model_name : String

    @[JSON::Field(key: "serial-no")]
    property serial_no : String

    @[JSON::Field(key: "projector-name")]
    property projector_name : String

    property macadress : String # Note: API uses "macadress" (typo in API)
  end

  # Firmware version
  struct FirmwareVersion
    include JSON::Serializable

    @[JSON::Field(key: "main-version")]
    property main_version : String
  end

  # Temperature information
  struct TemperatureInfo
    include JSON::Serializable

    @[JSON::Field(key: "temperature-id")]
    property temperature_id : Int32

    @[JSON::Field(key: "temperature-name")]
    property temperature_name : String

    @[JSON::Field(key: "temperature-celsius")]
    property temperature_celsius : Int32

    @[JSON::Field(key: "temperature-kelvin")]
    property temperature_kelvin : Int32
  end

  # NTP settings
  struct NTPSettings
    include JSON::Serializable

    @[JSON::Field(key: "ntp-sync")]
    property ntp_sync : String # "on" or "off"

    @[JSON::Field(key: "ntp-server")]
    property ntp_server : String
  end

  # HTTPS configuration
  struct HTTPSConfig
    include JSON::Serializable

    property state : String # "on" or "off"
  end
end

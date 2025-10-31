require "placeos-driver/spec"

DriverSpecs.mock_driver "Panasonic::Projector::PPND" do
  # Test power on
  it "should power on the projector" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "PUT" && request.path.includes?("/power")
        body = JSON.parse(request.body.not_nil!)
        body["state"].should eq("on")
        response.status_code = 200
        response << %{{"state":"on"}}
      end
    end

    exec(:power, true).get
    status[:power].should eq(true)
  end

  # Test power off
  it "should power off the projector" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "PUT" && request.path.includes?("/power")
        body = JSON.parse(request.body.not_nil!)
        body["state"].should eq("standby")
        response.status_code = 200
        response << %{{"state":"standby"}}
      end
    end

    exec(:power, false).get
    status[:power].should eq(false)
  end

  # Test power query
  it "should query power status" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "GET" && request.path.includes?("/power")
        response.status_code = 200
        response << %{{"state":"on"}}
      end
    end

    result = exec(:query_power_status).get
    result.should eq(true)
    status[:power].should eq(true)
  end

  # Test input switching
  it "should switch to HDMI1 input" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "PUT" && request.path.includes?("/input")
        body = JSON.parse(request.body.not_nil!)
        body["state"].should eq("HDMI1")
        response.status_code = 200
        response << %{{"state":"HDMI1"}}
      end
    end

    exec(:switch_to, "HDMI1").get
    status[:input].should eq("HDMI1")
  end

  # Test shutter open
  it "should open the shutter" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "PUT" && request.path.includes?("/shutter")
        body = JSON.parse(request.body.not_nil!)
        body["state"].should eq("open")
        response.status_code = 200
        response << %{{"state":"open"}}
      end
    end

    exec(:shutter, true).get
    status[:shutter_open].should eq(true)
  end

  # Test freeze on
  it "should enable freeze" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "PUT" && request.path.includes?("/freeze")
        body = JSON.parse(request.body.not_nil!)
        body["state"].should eq("on")
        response.status_code = 200
        response << %{{"state":"on"}}
      end
    end

    exec(:freeze, true).get
    status[:frozen].should eq(true)
  end

  # Test signal query
  it "should query signal information" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "GET" && request.path.includes?("/signal")
        response.status_code = 200
        response << %{{"infomation":"NO SIGNAL"}}
      end
    end

    result = exec(:query_signal).get
    result.should eq("NO SIGNAL")
    status[:no_signal].should eq(true)
  end

  # Test device information query
  it "should query device information" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "GET" && request.path.includes?("/device-information")
        response.status_code = 200
        response << %{
          {
            "model-name": "PT-CMZ50",
            "serial-no": "ABCDE1234",
            "projector-name": "NAME1234",
            "macadress": "11-22-33-44-55-66"
          }
        }
      end
    end

    exec(:query_device_info).get
    status[:model].should eq("PT-CMZ50")
    status[:serial_number].should eq("ABCDE1234")
  end

  # Test firmware version query
  it "should query firmware version" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "GET" && request.path.includes?("/version")
        response.status_code = 200
        response << %{{"main-version":"1.00"}}
      end
    end

    result = exec(:query_firmware_version).get
    result.should eq("1.00")
    status[:firmware_version].should eq("1.00")
  end

  # Test NTP configuration
  it "should configure NTP settings" do
    expect_http_request do |request, response|
      auth_header = request.headers["Authorization"]?

      if auth_header.nil?
        response.status_code = 401
        response.headers["WWW-Authenticate"] = %{Digest realm="Panasonic", qop="auth", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"}
      elsif request.method == "PUT" && request.path.includes?("/ntp")
        body = JSON.parse(request.body.not_nil!)
        body["ntp-sync"].should eq("on")
        body["ntp-server"].should eq("time.google.com")
        response.status_code = 200
        response << %{{"ntp-sync":"on","ntp-server":"time.google.com"}}
      end
    end

    exec(:configure_ntp, true, "time.google.com").get
    status[:ntp_sync].should eq(true)
    status[:ntp_server].should eq("time.google.com")
  end
end

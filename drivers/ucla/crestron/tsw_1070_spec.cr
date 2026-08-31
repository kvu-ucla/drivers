require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::Tsw1070" do
  # Set up ALL expected HTTP requests FIRST

  # authentication fires on connect
  expect_http_request do |request, response|
    data = request.body.try(&.gets_to_end)
    if data == "login=admin&passwd=admin"
      response.status_code = 200
      response.headers.add("Set-Cookie", [
        "userstr=61766974735f61646d696e;Path=/;Secure;HttpOnly;",
        "userid=7e0d210a66fc97b85347d7affc363b41672e9cad2ba8b8fa65019ea24cf2d7b909cd6d25985cc7e9471c03c83409c58c;Path=/;Secure;HttpOnly;",
        "iv=762701d96ba69f0800cd5b439fcc7020;Path=/;Secure;HttpOnly;",
        "tag=00000000000000000000000000000000;Path=/;Secure;HttpOnly;",
        "AuthByPasswd=crypt%3Ac17e34deffafa812f2a9f6570cee4d9234a24e1352379c7253e7907cabc7229a;Path=/;Secure;HttpOnly;",
        "TRACKID=6a8ac5cc159f81f90923406823bcde63890c330b6a99db6ba945237de1b59bfc;Path=/;Secure;HttpOnly;",
      ])
      response.headers["CREST-XSRF-TOKEN"] = "1234"
    else
      response.status_code = 401
      response << "bad password"
    end
  end

  # on_authenticated triggers update_device_info -> GET /Device/DeviceInfo
  expect_http_request do |request, response|
    if request.path == "/Device/DeviceInfo"
      response.status_code = 200
      response << %({
        "Device": {
          "DeviceInfo": {
            "Model": "TSW-1070",
            "Category": "TouchPanel",
            "Manufacturer": "Crestron",
            "ModelId": "0x79FE",
            "DeviceId": "@E-00107fda645f",
            "SerialNumber": "1948JBH01948",
            "Name": "TSW-1070-001",
            "DeviceVersion": "3.002.0034",
            "PufVersion": "3.002.0034.001",
            "BuildDate": "Tue Jul  1 15:31:42 EDT 2025  (574110)",
            "Devicekey": "No SystemKey Server",
            "MacAddress": "00:10:7F:DA:64:5F",
            "RebootReason": "unknown",
            "Version": "2.3.1"
          }
        }
      })
    else
      response.status_code = 404
      response << "not found"
    end
  end

  sleep 1.second

  # device_info published in the common Descriptor shape
  device_info = status[:device_info]
  device_info["make"].should eq("Crestron")
  device_info["model"].should eq("TouchPanel TSW-1070")
  device_info["serial"].should eq("1948JBH01948")
  device_info["firmware"].should eq("3.002.0034, puf 3.002.0034.001, built Tue Jul  1 15:31:42 EDT 2025  (574110)")
  device_info["mac_address"].should eq("00:10:7F:DA:64:5F")
  device_info["hostname"].should eq("TSW-1070-001")
  device_info["ip_address"].as_s?.should_not be_nil

  # the rich Crestron payload is retained separately
  raw = status[:device_info_raw]
  raw["Model"].should eq("TSW-1070")
  raw["SerialNumber"].should eq("1948JBH01948")

  # long-poll responses are partial deltas containing only changed properties;
  # a Name-only delta must not erase the previously fetched identity fields
  expect_http_request do |request, response|
    if request.path == "/Device/Longpoll"
      response.status_code = 200
      response << %({"Device":{"DeviceInfo":{"Name":"Room 101"}}})
    else
      response.status_code = 404
      response << "not found"
    end
  end

  sleep 1.second

  device_info = status[:device_info]
  device_info["make"].should eq("Crestron")
  device_info["model"].should eq("TouchPanel TSW-1070")
  device_info["hostname"].should eq("Room 101")
  device_info["serial"].should eq("1948JBH01948")
  device_info["firmware"].should eq("3.002.0034, puf 3.002.0034.001, built Tue Jul  1 15:31:42 EDT 2025  (574110)")
  device_info["mac_address"].should eq("00:10:7F:DA:64:5F")

  raw = status[:device_info_raw]
  raw["Name"].should eq("Room 101")
  raw["SerialNumber"].should eq("1948JBH01948")
end

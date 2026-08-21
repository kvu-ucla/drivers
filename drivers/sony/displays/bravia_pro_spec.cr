require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Displays::BraviaPro" do
  settings({
    psk: "test1234",
  })

  # Test power on
  exec(:power, true)
  expect_http_request do |request, response|
    request.method.should eq("POST")
    request.path.should eq("/sony/system")
    request.headers["X-Auth-PSK"]?.should eq("test1234")
    request.headers["Content-Type"]?.should eq("application/json")

    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("setPowerStatus")
      # the API takes a boolean, "active"/"standby" strings are rejected
      data["params"][0]["status"].should eq(true)
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [] of String, "id": 1}.to_json
  end

  expect_http_request do |request, response|
    request.method.should eq("POST")
    request.path.should eq("/sony/system")

    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("getPowerStatus")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [{"status": "active"}], "id": 2}.to_json
  end

  status[:power].should eq(true)

  # Test power off
  exec(:power, false)
  expect_http_request do |request, response|
    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["params"][0]["status"].should eq(false)
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [] of String, "id": 1}.to_json
  end

  expect_http_request do |request, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [{"status": "standby"}], "id": 2}.to_json
  end

  status[:power].should eq(false)

  # Test volume setting
  exec(:volume, 75)
  expect_http_request do |request, response|
    request.path.should eq("/sony/audio")

    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("setAudioVolume")
      # volume must be sent as a string, integers are rejected
      data["params"][0]["volume"].should eq("75")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [0], "id": 3}.to_json
  end

  expect_http_request do |request, response|
    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("getVolumeInformation")
    end

    # hardware returns volume as a number
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [[{"target": "speaker", "volume": 75, "mute": false, "maxVolume": 100, "minVolume": 0}]], "id": 4}.to_json
  end

  status[:volume].should eq(75)

  # Test mute
  exec(:mute, true)
  expect_http_request do |request, response|
    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("setAudioMute")
      data["params"][0]["status"].should eq(true)
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [0], "id": 5}.to_json
  end

  expect_http_request do |request, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [[{"target": "speaker", "volume": 75, "mute": true, "maxVolume": 100, "minVolume": 0}]], "id": 6}.to_json
  end

  status[:mute].should eq(true)

  # Test input switching
  exec(:switch_to, "hdmi1")
  expect_http_request do |request, response|
    request.path.should eq("/sony/avContent")

    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("setPlayContent")
      data["params"][0]["uri"].should eq("extInput:hdmi?port=1")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [] of String, "id": 7}.to_json
  end

  expect_http_request do |request, response|
    if io = request.body
      data = JSON.parse(io.gets_to_end)
      data["method"].should eq("getPlayingContentInfo")
    end

    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [{"uri": "extInput:hdmi?port=1", "source": "extInput:hdmi", "title": "HDMI 1"}], "id": 8}.to_json
  end

  status[:input].should eq("Hdmi1")

  # Test volume query, older firmware may return volume as a string
  exec(:volume?)
  expect_http_request do |request, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"result": [[{"target": "speaker", "volume": "65", "mute": true}]], "id": 4}.to_json
  end

  status[:volume].should eq(65)

  # Commands rejected by the device arrive as HTTP 200 with an error body
  # and must not update state (e.g. volume while the display is in standby)
  exec(:volume, 30)
  expect_http_request do |request, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"error": [40005, "Display Is Turned off"], "id": 3}.to_json
  end

  status[:volume].should eq(65)

  exec(:power, true)
  expect_http_request do |request, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/json"
    response.output << {"error": [3, "Illegal Argument"], "id": 1}.to_json
  end

  status[:power].should eq(false)
end

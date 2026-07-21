require "placeos-driver/spec"

DriverSpecs.mock_driver "AWS::EventReport" do
  settings({
    api_key:             "test-api-key-123",
    default_encoding:    "plain",
    fetch_delay_seconds: 0,
    timezone:            "America/Los_Angeles",
    cached_report:       {
      report:     "CACHED: 8:00 AM - Setup, Main Hall",
      encoding:   "plain",
      fetched_at: 1700000000,
    },
  })

  # ==========================================================================
  # Test: cached report restored from settings on load (nonvolatile memory)
  # ==========================================================================
  sleep 200.milliseconds

  status[:report].should eq "CACHED: 8:00 AM - Setup, Main Hall"
  status[:report_encoding].should eq "plain"
  status[:report_fetched_at].should eq 1700000000

  # ==========================================================================
  # Test: run_refresh issues POST /run with api key and JSON content type
  # ==========================================================================
  retval = exec(:run_refresh)

  expect_http_request do |request, response|
    request.method.should eq "POST"
    request.path.should eq "/run"
    request.headers["x-api-key"]?.should eq "test-api-key-123"
    request.headers["Content-Type"]?.should eq "application/json"

    response.status_code = 200
    response << %({"status":"started"})
  end

  retval.get.should eq %({"status":"started"})
  status[:last_run_at].should_not be_nil

  # ==========================================================================
  # Test: fetch_report defaults to the configured encoding (plain)
  # ==========================================================================
  report_body = "9:00 AM - Keynote, Grand Ballroom\n10:30 AM - Workshop, Room 210"
  retval = exec(:fetch_report)

  expect_http_request do |request, response|
    request.method.should eq "GET"
    request.path.should eq "/report"
    request.query_params["encoding"]?.should eq "plain"
    request.headers["x-api-key"]?.should eq "test-api-key-123"

    response.status_code = 200
    response << report_body
  end

  retval.get.should eq report_body
  status[:report].should eq report_body
  status[:report_encoding].should eq "plain"
  status[:report_fetched_at].should_not eq 1700000000

  # ==========================================================================
  # Test: fetch_report with explicit base64 encoding
  # ==========================================================================
  encoded = "OTowMCBBTSAtIEtleW5vdGU="
  retval = exec(:fetch_report, encoding: "base64")

  expect_http_request do |request, response|
    request.method.should eq "GET"
    request.path.should eq "/report"
    request.query_params["encoding"]?.should eq "base64"
    request.headers["x-api-key"]?.should eq "test-api-key-123"

    response.status_code = 200
    response << encoded
  end

  retval.get.should eq encoded
  status[:report].should eq encoded
  status[:report_encoding].should eq "base64"

  # ==========================================================================
  # Test: nightly_refresh runs the report then fetches it
  # ==========================================================================
  retval = exec(:nightly_refresh)

  expect_http_request do |request, response|
    request.method.should eq "POST"
    request.path.should eq "/run"
    request.headers["x-api-key"]?.should eq "test-api-key-123"

    response.status_code = 200
    response << %({"status":"started"})
  end

  expect_http_request do |request, response|
    request.method.should eq "GET"
    request.path.should eq "/report"
    request.query_params["encoding"]?.should eq "plain"
    request.headers["x-api-key"]?.should eq "test-api-key-123"

    response.status_code = 200
    response << "NIGHTLY: 7:00 PM - Banquet, Terrace Room"
  end

  retval.get.should eq "NIGHTLY: 7:00 PM - Banquet, Terrace Room"
  status[:report].should eq "NIGHTLY: 7:00 PM - Banquet, Terrace Room"

  # ==========================================================================
  # Test: invalid encoding is rejected without making a request
  # ==========================================================================
  expect_raises(PlaceOS::Driver::RemoteException) do
    exec(:fetch_report, encoding: "hex").get
  end

  # ==========================================================================
  # Test: API error surfaces as a raised error and exposes error state
  # ==========================================================================
  retval = exec(:fetch_report)

  expect_http_request do |request, response|
    response.status_code = 403
    response << %({"message":"Forbidden"})
  end

  expect_raises(PlaceOS::Driver::RemoteException) { retval.get }
  status[:report_error].should_not be_nil
end

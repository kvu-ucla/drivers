require "placeos-driver/spec"

DriverSpecs.mock_driver "AWS::EventReport" do
  settings({
    api_key:          "test-api-key-123",
    default_encoding: "plain",
    timezone:         "America/Los_Angeles",
    cached_report:    {
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
  # Test: run_refresh issues POST /run then immediately fetches the report
  # ==========================================================================
  refreshed_body = "REFRESHED: 8:30 AM - Registration, Lobby"
  retval = exec(:run_refresh)

  expect_http_request do |request, response|
    request.method.should eq "POST"
    request.path.should eq "/run"
    request.headers["x-api-key"]?.should eq "test-api-key-123"
    request.headers["Content-Type"]?.should eq "application/json"

    response.status_code = 200
    response << %({"status":"started"})
  end

  expect_http_request do |request, response|
    request.method.should eq "GET"
    request.path.should eq "/report"
    request.query_params["encoding"]?.should eq "plain"
    request.headers["x-api-key"]?.should eq "test-api-key-123"

    response.status_code = 200
    response << refreshed_body
  end

  retval.get.should eq refreshed_body
  status[:last_run_at].should_not be_nil
  status[:run_response].should eq %({"status":"started"})
  status[:report].should eq refreshed_body

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

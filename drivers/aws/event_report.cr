require "placeos-driver"

# Fetches a scheduled-events report from an AWS API Gateway REST API.
# A frontend polls this driver's state to display conference centre event data.
class AWS::EventReport < PlaceOS::Driver
  descriptive_name "Event Report Service"
  generic_name :EventReport
  description "Pulls a scheduled event report from an API Gateway endpoint for frontend display"

  # Set the actual gateway URI on the module, including the stage path
  # e.g. https://<api-id>.execute-api.<region>.amazonaws.com/<stage>
  uri_base "https://example.execute-api.us-west-2.amazonaws.com/stage"

  default_settings({
    api_key:             "",      # Sent as the x-api-key header
    default_encoding:    "plain", # "plain" or "base64"
    refresh_cron:        "30 1 * * *",
    timezone:            "America/Los_Angeles",
    fetch_delay_seconds: 30, # Wait for the gateway to regenerate before fetching
  })

  ENCODINGS = {"plain", "base64"}

  # Report cache persisted to settings so state survives module restarts
  alias CachedReport = NamedTuple(report: String, encoding: String, fetched_at: Int64)

  @api_key : String = ""
  @default_encoding : String = "plain"
  @fetch_delay : Int32 = 30

  def on_update
    @api_key = setting?(String, :api_key) || ""
    @default_encoding = setting?(String, :default_encoding) || "plain"
    @fetch_delay = setting?(Int32, :fetch_delay_seconds) || 30
    refresh_cron = setting?(String, :refresh_cron) || "30 1 * * *"
    timezone = setting?(String, :timezone) || "America/Los_Angeles"

    restore_cached_report

    location = begin
      Time::Location.load(timezone)
    rescue err
      logger.warn(exception: err) { "invalid timezone #{timezone.inspect}, falling back to local" }
      Time::Location.local
    end

    schedule.clear
    schedule.cron(refresh_cron, location) { nightly_refresh }
  end

  # Triggers the gateway to regenerate the report
  def run_refresh
    response = post("/run",
      headers: {
        "x-api-key"    => @api_key,
        "Content-Type" => "application/json",
      },
      body: "{}"
    )

    if response.success?
      self[:last_run_at] = Time.utc.to_unix
      self[:run_response] = response.body
      response.body
    else
      error = "report refresh failed: #{response.status_code} - #{response.body[0..500]}"
      self[:run_error] = error
      logger.error { error }
      raise error
    end
  end

  # Fetches the current report, exposing it as driver state for frontend binding
  def fetch_report(encoding : String? = nil)
    encoding ||= @default_encoding
    unless ENCODINGS.includes?(encoding)
      raise "invalid encoding #{encoding.inspect}, must be one of: #{ENCODINGS.join(", ")}"
    end

    response = get("/report",
      params: {"encoding" => encoding},
      headers: {"x-api-key" => @api_key}
    )

    if response.success?
      cache = CachedReport.new(
        report: response.body,
        encoding: encoding,
        fetched_at: Time.utc.to_unix
      )
      expose_report(cache)
      define_setting(:cached_report, cache)
      response.body
    else
      error = "report fetch failed: #{response.status_code} - #{response.body[0..500]}"
      self[:report_error] = error
      logger.error { error }
      raise error
    end
  end

  # Regenerates the report then pulls the result, scheduled nightly
  def nightly_refresh
    run_refresh
    sleep @fetch_delay.seconds unless @fetch_delay.zero?
    fetch_report
  end

  private def restore_cached_report
    return unless cached = setting?(CachedReport, :cached_report)
    expose_report(cached)
  end

  private def expose_report(cache : CachedReport)
    self[:report] = cache[:report]
    self[:report_encoding] = cache[:encoding]
    self[:report_fetched_at] = cache[:fetched_at]
  end
end

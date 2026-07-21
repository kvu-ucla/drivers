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
    api_key:          "",      # Sent as the x-api-key header
    default_encoding: "plain", # "plain" or "base64"
  })

  ENCODINGS = {"plain", "base64"}

  @api_key : String = ""
  @default_encoding : String = "plain"

  def on_update
    @api_key = setting?(String, :api_key) || ""
    @default_encoding = setting?(String, :default_encoding) || "plain"
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
      self[:report] = response.body
      self[:report_encoding] = encoding
      self[:report_fetched_at] = Time.utc.to_unix
      response.body
    else
      error = "report fetch failed: #{response.status_code} - #{response.body[0..500]}"
      self[:report_error] = error
      logger.error { error }
      raise error
    end
  end
end

require "placeos-driver"
require "json"

# PlaceOS driver for Instagram Business Account feed
# Fetches posts, manages token refresh, exposes slides state for frontend consumption
class Meta::Instagram < PlaceOS::Driver
  descriptive_name "Instagram Feed Slideshow"
  generic_name :Instagram
  description "Fetches Instagram business account posts and manages access token lifecycle"

  uri_base "https://graph.instagram.com"

  default_settings({
    access_token:          "",    # Long-lived token (60-day), refreshed automatically
    token_expires_at:      0_i64, # Epoch seconds, maintained by driver
    poll_interval_minutes: 30,    # Feed poll cadence
    api_version:           "v25.0",
    media_limit:           25,    # Number of posts to fetch
    media_types:           "all", # Filter: "all", "image" (includes carousel), or "video"
  })

  # State exposed to frontend and monitoring
  @access_token : String = ""
  @token_expires_at : Int64 = 0
  @poll_interval_minutes : Int32 = 30
  @api_version : String = "v25.0"
  @media_limit : Int32 = 25
  @media_types : String = "all"

  def on_load
    on_update
  end

  def on_update
    # Load settings
    @access_token = setting?(String, :access_token) || ""
    @token_expires_at = setting?(Int64, :token_expires_at) || 0_i64
    @poll_interval_minutes = setting?(Int32, :poll_interval_minutes) || 30
    @api_version = setting?(String, :api_version) || "v25.0"
    @media_limit = setting?(Int32, :media_limit) || 25
    @media_types = setting?(String, :media_types) || "all"

    # Clear existing schedules
    schedule.clear

    # Schedule feed poll
    schedule.every(@poll_interval_minutes.minutes) { fetch_feed }

    # Schedule token refresh (every 30 days)
    schedule.every(30.days) { refresh_token }

    # Initial fetch and token check
    spawn { fetch_feed }
    spawn { check_and_refresh_token }
  end

  # ============================================================================
  # Feed fetching
  # ============================================================================

  def fetch_feed
    if @access_token.empty?
      logger.warn { "No access token configured, skipping feed fetch" }
      self[:poll_state] = "no_token"
      return
    end

    logger.debug { "Fetching Instagram feed..." }

    # Build hydrated API request with all fields in one call
    fields = [
      "id",
      "media_type",
      "media_url",
      "thumbnail_url",
      "permalink",
      "caption",
      "timestamp",
      "username",
      "children{media_type,media_url,thumbnail_url,id}",
    ].join(",")

    response = get("/#{@api_version}/me/media", params: {
      "fields"       => fields,
      "limit"        => @media_limit.to_s,
      "access_token" => @access_token,
    })

    if response.success?
      data = JSON.parse(response.body)
      slides = map_to_slides(data["data"].as_a)

      self[:slides] = slides
      self[:poll_state] = "success"
      self[:last_poll_at] = Time.utc.to_unix
      logger.info { "Feed fetched successfully: #{slides.size} slides" }
    else
      logger.error { "Feed fetch failed: #{response.status_code} - #{response.body}" }
      self[:poll_state] = "failed"
      self[:poll_error] = {
        code: response.status_code,
        body: response.body[0..500], # Truncate for safety
      }
    end
  rescue ex
    logger.error(exception: ex) { "Exception during feed fetch" }
    self[:poll_state] = "error"
    self[:poll_error] = ex.message
  end

  # ============================================================================
  # Slide projection mapping
  # ============================================================================

  def map_to_slides(media_items : Array(JSON::Any))
    media_items.compact_map do |item|
      map_single_item(item)
    end
  end

  private def map_single_item(item : JSON::Any)
    media_type = item["media_type"]?.try(&.as_s?)
    return nil unless media_type

    # Filter out posts without valid IDs
    id = item["id"]?.try(&.as_s?)
    return nil unless id && !id.empty?

    # Filter by media type based on settings
    case @media_types
    when "image"
      return nil if media_type == "VIDEO"
    when "video"
      return nil unless media_type == "VIDEO"
    end

    base = {
      "id"        => id,
      "caption"   => item["caption"]?.try(&.as_s?),
      "permalink" => item["permalink"]?.try(&.as_s?) || "",
      "username"  => item["username"]?.try(&.as_s?) || "",
      "timestamp" => item["timestamp"]?.try(&.as_s?) || "",
    }

    case media_type
    when "IMAGE"
      url = item["media_url"]?.try(&.as_s?)
      return nil unless url

      base.merge({
        "type" => "image",
        "url"  => url,
      })

    when "VIDEO"
      url = item["media_url"]?.try(&.as_s?)
      return nil unless url

      base.merge({
        "type"      => "video",
        "url"       => url,
        "thumbnail" => item["thumbnail_url"]?.try(&.as_s?),
      })

    when "CAROUSEL_ALBUM"
      children_data = item["children"]?.try(&.["data"]?.try(&.as_a))
      return nil unless children_data

      children = children_data.compact_map do |child|
        map_carousel_child(child)
      end

      return nil if children.empty?

      base.merge({
        "type"     => "carousel",
        "children" => children,
      })

    else
      logger.warn { "Unknown media_type: #{media_type}" }
      nil
    end
  end

  private def map_carousel_child(child : JSON::Any)
    child_type = child["media_type"]?.try(&.as_s?)
    url = child["media_url"]?.try(&.as_s?)
    return nil unless child_type && url

    {
      "id"        => child["id"]?.try(&.as_s?) || "",
      "type"      => child_type.downcase,
      "url"       => url,
      "thumbnail" => child["thumbnail_url"]?.try(&.as_s?),
    }
  end

  # ============================================================================
  # Token refresh
  # ============================================================================

  def refresh_token
    if @access_token.empty?
      logger.warn { "No access token configured, skipping refresh" }
      self[:token_state] = "no_token"
      return
    end

    # Check 24-hour floor: token must be e24h old to refresh
    if @token_expires_at > 0
      token_age_seconds = Time.utc.to_unix - (@token_expires_at - 60.days.total_seconds.to_i64)
      if token_age_seconds < 24.hours.total_seconds
        logger.info { "Token is less than 24h old, skipping refresh" }
        return
      end
    end

    logger.info { "Refreshing Instagram access token..." }

    response = get("/refresh_access_token", params: {
      "grant_type"   => "ig_refresh_token",
      "access_token" => @access_token,
    })

    if response.success?
      data = JSON.parse(response.body)
      new_token = data["access_token"]?.try(&.as_s?)
      expires_in = data["expires_in"]?.try(&.as_i64?) || 5184000_i64 # Default 60 days

      if new_token
        new_expires_at = Time.utc.to_unix + expires_in

        # Write back to settings (persists across restarts)
        define_setting(:access_token, new_token)
        define_setting(:token_expires_at, new_expires_at)

        # Update instance variables
        @access_token = new_token
        @token_expires_at = new_expires_at

        # Expose state
        self[:token_state] = "valid"
        self[:token_expires_at] = new_expires_at
        self[:last_token_refresh] = Time.utc.to_unix

        logger.info { "Token refreshed successfully, expires at #{Time.unix(new_expires_at)}" }
      else
        logger.error { "Token refresh succeeded but no access_token in response" }
        self[:token_state] = "invalid_response"
      end
    else
      logger.error { "Token refresh failed: #{response.status_code} - #{response.body}" }
      self[:token_state] = "failed"
      self[:token_error] = {
        code: response.status_code,
        body: response.body[0..500],
      }

      # Alert: retry in a few hours (not 30 days)
      schedule.in(6.hours) { refresh_token }
    end
  rescue ex
    logger.error(exception: ex) { "Exception during token refresh" }
    self[:token_state] = "error"
    self[:token_error] = ex.message

    # Retry in a few hours
    schedule.in(6.hours) { refresh_token }
  end

  # Check and refresh token on load if needed
  private def check_and_refresh_token
    return if @access_token.empty?

    # Set initial state
    if @token_expires_at > 0
      self[:token_expires_at] = @token_expires_at
      days_remaining = (@token_expires_at - Time.utc.to_unix) / 86400

      if days_remaining <= 0
        self[:token_state] = "expired"
        logger.error { "Access token has expired! Operator must re-seed." }
      elsif days_remaining <= 30
        # Token is in the second half of its life, try to refresh
        logger.info { "Token expires in #{days_remaining} days, refreshing..." }
        refresh_token
      else
        self[:token_state] = "valid"
        logger.info { "Token valid for #{days_remaining} more days" }
      end
    else
      # No expiry tracking yet, assume valid but refresh to establish baseline
      self[:token_state] = "unknown"
      refresh_token
    end
  end

  # ============================================================================
  # Manual triggers
  # ============================================================================

  def trigger_feed_fetch
    spawn { fetch_feed }
    "Feed fetch triggered"
  end

  def trigger_token_refresh
    spawn { refresh_token }
    "Token refresh triggered"
  end

  def status
    {
      poll_state:        self[:poll_state]?,
      token_state:       self[:token_state]?,
      token_expires_at:  @token_expires_at,
      last_poll_at:      self[:last_poll_at]?,
      slides_count:      self[:slides]?.try(&.as_a.size) || 0,
      poll_interval_min: @poll_interval_minutes,
    }
  end
end

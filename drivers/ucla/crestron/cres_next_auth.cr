# UCLA-maintained copy of drivers/crestron/cres_next_auth.cr (vendored 2026-08-30 from ucla-dev @ ce19af2a18)
require "uri"

module Crestron::CresNextAuth
  protected getter xsrf_token : String = ""

  getter? authenticated : Bool = false

  abstract def on_authenticated : Nil

  # `lifecycle: false` isolates a failed login from the connection lifecycle:
  # the error is still raised (and the authenticated/auth_error statuses still
  # publish) but queue.set_connected(false) is NOT called, so a transient
  # refresh failure cannot drive `disconnected` on a still-open transport.
  # All existing callers default to the full lifecycle behavior.
  def authenticate(lifecycle : Bool = true) : Nil
    logger.debug { "Authenticating" }
    was_authenticated = @authenticated
    @authenticated = false

    # some devices require referer and origin to accept the login
    uri = URI.parse config.uri.not_nil!
    host = uri.host

    password = setting(String, :password)
    response = begin
      post("/userlogin.html", headers: {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Referer"      => "https://#{host}/userlogin.html",
        "Origin"       => "https://#{host}",
      }, body: URI::Params.build { |form|
        form.add("login", setting(String, :username))
        form.add("passwd", password)
      })
    rescue ex
      # the request produced no response (timeout, refused connection, TLS
      # failure): publish the failure so the exported statuses cannot go stale,
      # then re-raise unchanged. The connection lifecycle stays untouched here —
      # queue.set_connected(false) applies only to response-carrying failures
      # below, where it remains gated by `lifecycle`.
      message = "Authentication request failed: #{ex.message.presence || ex.class.name}"
      self[:authenticated] = false
      self[:auth_error] = message
      logger.error(exception: ex) { message }
      raise ex
    end

    case response.status_code
    when 200, 302
      auth_cookies = %w(AuthByPasswd iv tag userid userstr)
      if (auth_cookies - response.cookies.to_h.keys).empty? || password.empty?
        @xsrf_token = response.headers["CREST-XSRF-TOKEN"]? || ""
        @authenticated = true
        begin
          queue.set_connected(true)
          spawn(name: "on-authenticated") { on_authenticated } unless was_authenticated
        rescue
        end
        logger.debug { "Authenticated" }
      else
        error = "Device did not return all auth information, cookies returned: #{response.cookies.to_h.keys}, redirect: #{response.headers["Location"]?}"
      end
    when 403
      error = "Invalid credentials"
    else
      error = "Unexpected response (HTTP #{response.status})"
    end

    self[:authenticated] = @authenticated
    self[:auth_error] = error

    if error
      logger.error { error }
      queue.set_connected(false) if lifecycle
      raise error
    end
  end

  def logout
    response = post "/logout"

    case response.status
    when 302
      logger.debug { "Logout successful" }
      @authenticated = false
      true
    else
      logger.warn { "Unexpected response (HTTP #{response.status})" }
      false
    end
  ensure
    @xsrf_token = ""
    transport.cookies.clear
    schedule.clear
    disconnect
  end
end

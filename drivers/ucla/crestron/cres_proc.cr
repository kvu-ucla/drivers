# UCLA-maintained copy of drivers/crestron/cres_proc.cr (vendored 2026-08-30 from ucla-drivers @ 4de617d9c7)
# Version 2.0.1 — documentation: cres_proc_readme.md
require "placeos-driver"
require "placeos-driver/interface/device_info"
require "json"

class Crestron::SIMPLInterface < PlaceOS::Driver
  include Interface::DeviceInfo

  descriptive_name "Crestron - SIMPL Interface (UCLA)"
  generic_name :CrestronInterface
  tcp_port 9001

  # Private, authoritative state cache
  @state : Bool? = nil

  def on_load
    queue.delay = 100.milliseconds
    on_update
  end

  def on_update
    publish_state
  end

  def connected
    transport.tokenizer = Tokenizer.new("\r\n")
    do_poll
    schedule.every(50.seconds) do
      logger.debug { "-- Polling Crestron Processor" }
      do_poll
    end
  end

  def do_poll
    query
  end

  def query
    send("query\r\n", name: "query")
  end

  def received(bytes : Bytes, task)
    line = String.new(bytes).rstrip("\r\n")
    data = JSON.parse(line)

    incoming = extract_bool?(data["digital-io1"])
    if incoming.nil?
      logger.warn { "unrecognized boolean payload: #{line.inspect}" }
      task.try(&.abort)
      return
    end

    if incoming != @state
      @state = incoming
      publish_state
    end

    task.try(&.success)
  rescue error
    logger.warn(exception: error) { "failed to process inbound state" }
    task.try(&.abort)
  end

  # Public accessor for scripting
  def state : Bool?
    @state
  end

  # ====== DeviceInfo Interface ======

  # the SIMPL bridge program only exposes digital I/O state, so a mostly-nil
  # descriptor is the honest answer here
  def device_info : Descriptor
    Descriptor.new(
      make: "Crestron",
      model: "SIMPL Interface",
      ip_address: config.ip,
    )
  end

  private def publish_state
    val = @state
    return if val.nil?
    self[:state] = val.not_nil! # publish false/true correctly
  end

  # Accepts true/false, "true"/"false"/"1"/"0"/"on"/"off", or 1/0
  private def extract_bool?(any : JSON::Any) : Bool?
    any.as_bool? ||
      (if s = any.as_s?
        case s.strip.downcase
        when "1", "true", "t", "yes", "y", "on"  then true
        when "0", "false", "f", "no", "n", "off" then false
        else                                          nil
        end
      elsif i = any.as_i64?
        i == 0 ? false : true
      else
        nil
      end)
  end
end

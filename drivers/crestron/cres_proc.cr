require "placeos-driver"
require "json"

class Crestron::SIMPLInterface < PlaceOS::Driver
  descriptive_name "Crestron - SIMPL Interface"
  generic_name :CrestronInterface
  tcp_port 9001

  default_settings({normally_open: true})

  @state : Bool? = nil
  @normally_open : Bool? = true

  def on_load
    queue.delay = 100.milliseconds
    on_update
  end

  def on_update
    # Update no / nc setting
    @normally_open = setting?(Bool, :normally_open)
    do_poll

  end

  def connected
    transport.tokenizer = Tokenizer.new("\r\n")
    do_poll
    schedule.every(50.seconds) do
      logger.debug { "-- Polling Crestron Processor" }
      do_poll
    end
  end

  private def do_poll
    query
  end

  def query
    send("query\r\n", name: "query")
  end

  def received(bytes : Bytes, task)
    line = String.new(bytes)
    data = JSON.parse(line)

    incoming_str = data["digital-io1"]?.try &.as_s?
    incoming = incoming_str == "true" if incoming_str

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

  def state : Bool?
    @state
  end

  private def publish_state
    val = @state
    return if val.nil?
    
    # normally open: true from FLS => true state
    # normally closed: false from FLS => true state (inverted)
    self[:state] = @normally_open ? val : !val
  end
end
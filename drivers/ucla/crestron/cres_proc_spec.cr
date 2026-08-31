require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::SIMPLInterface" do
  it "polls on connect" do
    # Driver should send the initial poll on connect
    should_send "query\r\n"
  end

  it "updates :state when JSON contains a boolean" do
    responds %({"digital-io1": true}\r\n)
    status[:state].should eq(true)

    responds %({"digital-io1": false}\r\n)
    status[:state].should eq(false)
  end

  it "parses truthy/falsy strings" do
    responds %({"digital-io1":"on"}\r\n)
    status[:state].should eq(true)

    responds %({"digital-io1":"off"}\r\n)
    status[:state].should eq(false)
  end

  it "parses numeric 1/0" do
    responds %({"digital-io1":1}\r\n)
    status[:state].should eq(true)

    responds %({"digital-io1":0}\r\n)
    status[:state].should eq(false)
  end

  it "ignores payloads missing the key" do
    # capture current state
    prev = status[:state]?
    # send JSON without the expected field
    responds %({"other":true}\r\n)
    status[:state]?.should eq(prev)
  end

  it "exec(:query) triggers a send" do
    response = exec(:query)            # call the driver's public method
    should_send "query\r\n"             # verify it sent the right IO
    response.get.should be_nil          # method doesn't return a value
  end

  it "re-emits state after settings change (on_update)" do
    responds %({"digital-io1": true}\r\n)
    status[:state].should eq(true)

    settings({})                        # triggers on_update
    status[:state].should eq(true)      # state is re-published
  end
end

require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::SIMPLInterface" do
  # transmit some data
  transmit(%({"digital-io1": true}\r\n))

  # check that the state updated as expected
  status[:state].should eq(true)

  # transmit some data
  transmit(%({"digital-io1": false}\r\n))

  # check that the state updated as expected
  status[:state].should eq(false)
end

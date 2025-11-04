require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::Tsw1070" do
  # Test device info query
  it "should query device information" do
    result = exec(:query_device_info)

    # WebSocket query - driver sends null request for DeviceInfo
    transmit %({"Device":{"DeviceInfo":null}})

    # Simulate device response with actual API structure
    should_send %({"Device":{"DeviceInfo":{"Model":"TSW-1070","Category":"TouchPanel","Manufacturer":"Crestron","ModelId":"0x79FE","DeviceId":"@E-00107fda645f","SerialNumber":"1948JBH01948","Name":"TSW-1070-001","DeviceVersion":"3.002.0034","PufVersion":"3.002.0034.001","BuildDate":"Tue Jul  1 15:31:42 EDT 2025  (574110)","Devicekey":"No SystemKey Server","MacAddress":"00:10:7F:DA:64:5F","RebootReason":"unknown","Version":"2.3.1"}}})

    # Wait for completion
    result.get

    # Check status was updated with correct values
    status[:model].should eq("TSW-1070")
    status[:category].should eq("TouchPanel")
    status[:manufacturer].should eq("Crestron")
    status[:serial_number].should eq("1948JBH01948")
    status[:device_version].should eq("3.002.0034")
    status[:puf_version].should eq("3.002.0034.001")
    status[:mac_address].should eq("00:10:7F:DA:64:5F")
    status[:api_version].should eq("2.3.1")
  end
end

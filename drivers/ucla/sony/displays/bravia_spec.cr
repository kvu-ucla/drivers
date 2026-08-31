require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Displays::Bravia" do
  # one-time identity enquiry issued on connect (interface name right-padded
  # to the 16 byte parameter), answered so the MAC caches for device_info
  should_send("\x2A\x53\x45MADReth0############\n")
  responds("\x2A\x53\x41MADRAC9B0ABF2F77####\n")
  status[:mac_address].should eq("AC9B0ABF2F77")

  # device_info is a pure cache read - no protocol traffic
  info = exec(:device_info).get.not_nil!
  info["make"].should eq("Sony")
  info["model"].should eq("Bravia")
  info["mac_address"].should eq("AC9B0ABF2F77")

  exec(:power, true)
  should_send("\x2A\x53\x43POWR0000000000000001\n")
  responds("\x2A\x53\x41POWR0000000000000000\n")
  should_send("\x2A\x53\x45POWR################\n")
  responds("\x2A\x53\x41POWR0000000000000001\n")
  status[:power].should eq(true)

  exec(:switch_to, "hdmi1")
  should_send("\x2A\x53\x43INPT0000000100000001\n")
  responds("\x2A\x53\x41INPT0000000000000000\n")
  should_send("\x2A\x53\x45INPT################\n")
  responds("\x2A\x53\x41INPT0000000100000001\n")
  status[:input].should eq("Hdmi1")

  exec(:switch_to, "vga3")
  should_send("\x2A\x53\x43INPT0000000600000003\n")
  responds("\x2A\x53\x41INPT0000000000000000\n")
  should_send("\x2A\x53\x45INPT################\n")
  responds("\x2A\x53\x41INPT0000000600000003\n")
  status[:input].should eq("Vga3")

  exec(:volume, 99)
  should_send("\x2A\x53\x43VOLU0000000000000099\n")
  responds("\x2A\x53\x41VOLU0000000000000000\n")
  should_send("\x2A\x53\x45VOLU################\n")
  responds("\x2A\x53\x41VOLU0000000000000099\n")
  status[:volume].should eq(99)

  # Test failure
  exec(:mute)
  should_send("\x2A\x53\x43PMUT0000000000000001\n")
  responds("\x2A\x53\x41PMUT0000000000000000\n")
  should_send("\x2A\x53\x45PMUT################\n")
  responds("\x2A\x53\x41PMUT0000000000000001\n")
  status[:mute].should eq(true)

  exec(:unmute)
  should_send("\x2A\x53\x43PMUT0000000000000000\n")
  responds("\x2A\x53\x41PMUTFFFFFFFFFFFFFFFF\n")
  should_send("\x2A\x53\x45PMUT################\n")
  responds("\x2A\x53\x41PMUT0000000000000001\n")
  status[:mute].should eq(true)

  exec(:volume, 50)
  should_send("\x2A\x53\x43VOLU0000000000000050\n")
  responds("\x2A\x53\x4EPMUT0000000000000000\n") # mix in a notify
  responds("\x2A\x53\x41VOLU0000000000000000\n")
  should_send("\x2A\x53\x45VOLU################\n")
  responds("\x2A\x53\x41VOLU0000000000000050\n")
  status[:volume].should eq(50)
  status[:mute].should eq(false)
end

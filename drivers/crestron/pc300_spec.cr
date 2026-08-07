require "placeos-driver/spec"

# Response formats below were captured from a live PC-300 (172.17.198.39).

DriverSpecs.mock_driver "Crestron::PC300" do
  settings({
    username:      "admin",
    password:      "secret",
    poll_interval: 60,
  })

  # ====
  # login phase: device asks for credentials; driver sends both lines
  transmit "\r\nPlease enter your credentials to Login:"
  should_send "admin\r\nsecret\r\n"

  # banner + prompt: session ready, driver auto-queries outlets, hardware, version
  # (leading \xFF: the real console emits stray non-UTF-8 bytes; the driver must
  # tokenize and parse around them rather than crash in regex matching)
  transmit "\xFF\r\nPC-300 Control Console\r\n\r\nPC-300>"

  should_send "outlet\r\n"
  responds "\rOUTLet [<outlet #1-8>|ALL  OFF|ON]\r\n\r\nOutlets:\r\n\t1: ON\r\n\t2: OFF\r\n\t3: ON\r\n\t4: ON\r\n\t5: ON\r\n\t6: ON\r\n\t7: ON\r\n\t8: ON\r\n\r\nPC-300>"

  should_send "showhw\r\n"
  responds "\rCurrent Hardware Configuration\r\n\tSystem type:    \tPC-300\r\n\tBoard revision: \t1\r\n\tSystem revision:\t0\r\n\r\nNonvolatile settings\r\n\tCRC:                  FFFFFFFF\r\n\tfrontPanelLocked:     0\r\n\r\nPC-300>"

  should_send "ver\r\n"
  responds "\rPC-300 [v1.3275.00047, #9EE28AE5]\r\n\r\nPC-300>"

  should_send "monitor all -once\r\n"
  responds "\r## Time: 2026-08-07  4:28:06pm\r\n # External Temp: 37.9C, 100.2F\r\n # Internal Temp: 49.2C, 120.5F\r\n # Vbat: 3.02V\r\n # E. Mon OUTLET_1: 120.91 VRMS,  0.29 IRMS, 15.34 W,  185088.0 Wh\r\n # E. Mon OUTLET_2: 121.07 VRMS,  0.05 IRMS, 0.19 W,  53940.0 Wh\r\n # TOTAL:            120.68 VRMS   1.07 IRMS  82.78 W\r\n\r\nPC-300>"

  sleep 500.milliseconds
  status[:ready].should eq(true)

  # temperatures and unit totals surfaced as top-level numeric status
  status[:external_temperature].should eq(37.9)
  status[:internal_temperature].should eq(49.2)
  status[:total_voltage].should eq(120.68)
  status[:total_current].should eq(1.07)
  status[:total_power].should eq(82.78)

  # per-outlet object combines on/off state with the energy readings
  energy = status[:outlet_monitor]
  energy["outlet_1"]["state"].should eq(true)
  energy["outlet_1"]["power"].should eq(15.34)
  energy["outlet_1"]["voltage"].should eq(120.91)
  energy["outlet_2"]["state"].should eq(false)
  energy["outlet_2"]["energy_wh"].should eq(53940.0)
  status[:outlet_1].should eq(true)
  status[:outlet_2].should eq(false)
  status[:outlet_8].should eq(true)

  # device info assembled from showhw (model) and ver (firmware, id)
  device = status[:device_info]
  device["make"].should eq("Crestron")
  device["model"].should eq("PC-300")
  device["firmware"].should eq("1.3275.00047")
  device["serial"].should eq("9EE28AE5")

  # ====
  # switching an outlet reconciles state from the device afterwards
  result = exec(:outlet, 2, true)
  should_send "outlet 2 on\r\n"
  responds "\r\r\nPC-300>"
  result.get

  should_send "outlet\r\n"
  responds "\rOUTLet [<outlet #1-8>|ALL  OFF|ON]\r\n\r\nOutlets:\r\n\t1: ON\r\n\t2: ON\r\n\t3: ON\r\n\t4: ON\r\n\t5: ON\r\n\t6: ON\r\n\t7: ON\r\n\t8: ON\r\n\r\nPC-300>"
  sleep 200.milliseconds
  status[:outlet_2].should eq(true)

  # ====
  # all outlets off
  result = exec(:all_outlets, false)
  should_send "outlet all off\r\n"
  responds "\r\r\nPC-300>"
  result.get

  should_send "outlet\r\n"
  responds "\rOUTLet [<outlet #1-8>|ALL  OFF|ON]\r\n\r\nOutlets:\r\n\t1: OFF\r\n\t2: OFF\r\n\t3: OFF\r\n\t4: OFF\r\n\t5: OFF\r\n\t6: OFF\r\n\t7: OFF\r\n\t8: OFF\r\n\r\nPC-300>"
  sleep 200.milliseconds
  status[:outlet_1].should eq(false)
  status[:outlet_8].should eq(false)
  # state embedded in outlet_monitor stays in sync with the outlet poll
  status[:outlet_monitor]["outlet_1"]["state"].should eq(false)

  # ====
  # monitor returns key/value sensor data (leading "# " stripped from keys)
  result = exec(:monitor)
  should_send "monitor all -once\r\n"
  responds "\r## Time: 2026-08-07  4:28:06pm\r\n # External Temp: 37.9C, 100.2F\r\n # Internal Temp: 49.2C, 120.5F\r\n # Vbat: 3.02V\r\n # E. Mon OUTLET_1: 120.91 VRMS,  0.29 IRMS, 15.34 W,  185088.0 Wh\r\n # SURGE:        12.216 J/Ohm, 2250.000 Limit, 2932.500 Surge\r\n\r\nPC-300>"
  sensors = result.get.not_nil!
  sensors["External Temp"].should eq("37.9C, 100.2F")
  sensors["Vbat"].should eq("3.02V")
  status[:sensors]["Internal Temp"].should eq("49.2C, 120.5F")
end

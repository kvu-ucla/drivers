# UCLA-added regression spec for signal-graph node reference parsing (no
# upstream equivalent covers mod.cr/node.cr parsing; stub layout mirrors
# drivers/place/router/signal_graph_spec.cr). Lives at the router/ level —
# signal_graph.cr glob-requires signal_graph/*, so specs must not go in there.
abstract class PlaceOS::Driver; end

require "spec"
require "placeos-driver/driver_model"
require "./signal_graph/node"

alias SigNode = Place::Router::SignalGraph::Node
alias SigMod = Place::Router::SignalGraph::Mod

abstract class PlaceOS::Driver
  class Proxy::System
    # Unlike the upstream spec's always-succeeding mock, mirror production:
    # only modules that exist in the system resolve to an id; anything else is
    # nil, which Mod#initialize converts to a raise. The mis-parse regression
    # below depends on this.
    KNOWN_MODULES = {"Switcher", "Display"}

    def self.module_id?(sys, name, idx) : String?
      return nil unless name.in? KNOWN_MODULES
      "mod-#{ {sys, name, idx}.hash }"
    end

    def self.driver_metadata?(id) : DriverModel::Metadata?
      DriverModel::Metadata.new
    end
  end
end

describe Place::Router::SignalGraph::Node::Ref do
  describe ".resolve?" do
    # Regression: Mod.parse?'s greedy module-name group matched through ':',
    # so this ref mis-parsed as module "Switcher_1:Zoom_Output" idx 1 and
    # Mod#initialize raised (module does not exist), aborting the interpretation
    # chain before DeviceInput.parse? could produce the correct reading.
    it "resolves a device input ref whose input name ends in _<digits>" do
      ref = SigNode::Ref.resolve? "Switcher_1:Zoom_Output_1", "sys-abc"
      ref.should be_a(SigNode::DeviceInput)
      input = ref.as(SigNode::DeviceInput)
      input.mod.sys.should eq("sys-abc")
      input.mod.name.should eq("Switcher")
      input.mod.idx.should eq(1)
      input.input.should eq("Zoom_Output_1")
    end

    it "resolves the same ref when already system-qualified" do
      ref = SigNode::Ref.resolve? "sys-abc/Switcher_1:Zoom_Output_1"
      ref.should be_a(SigNode::DeviceInput)
      ref.as(SigNode::DeviceInput).input.should eq("Zoom_Output_1")
    end

    it "still resolves a plain device input ref" do
      ref = SigNode::Ref.resolve? "Display_1:hdmi", "sys-abc"
      ref.should be_a(SigNode::DeviceInput)
      input = ref.as(SigNode::DeviceInput)
      input.mod.name.should eq("Display")
      input.input.should eq("hdmi")
    end

    it "still resolves a plain device ref" do
      ref = SigNode::Ref.resolve? "Display_1", "sys-abc"
      ref.should be_a(SigNode::Device)
      mod = ref.as(SigNode::Device).mod
      mod.name.should eq("Display")
      mod.idx.should eq(1)
    end
  end
end

describe Place::Router::SignalGraph::Mod do
  it "does not parse a ref carrying an input component" do
    SigMod.parse?("sys-abc/Switcher_1:Zoom_Output_1").should be_nil
  end

  it "parses a canonical module ref" do
    mod = SigMod.parse?("sys-abc/Switcher_1").not_nil!
    mod.sys.should eq("sys-abc")
    mod.name.should eq("Switcher")
    mod.idx.should eq(1)
  end
end

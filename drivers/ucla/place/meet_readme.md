# Meeting room logic (UCLA)

**Version:** 2.0.0 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/place/meet.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18), together with its helpers (`meet/help.cr`, `meet/tab.cr`, `meet/qsc_phone_dialing.cr`) and the router library tree (`router/*`) it requires — the vendored copy is self-contained.

## Overview

Room-level logic driver (no transport): provides the high-level API for tabbed control UIs across workplace collaboration spaces — signal routing via the router library, room power state, master audio and microphones, lighting, room accessories, VC camera management, room joining, and QSC phone dialing. Also implements `Interface::ChatFunctions` for LLM voice/chat control, plus `Interface::Powerable` and `Interface::Muteable`. Generic name `System`.

## Settings

The `Default` column reproduces the value declared in `default_settings`; where the `setting?` read applies a different fallback when the key is absent, both are shown as "shipped …; absent-key fallback …". Keys not in `default_settings` show the absent-key fallback only.

| Key | Type | Default | Description |
|---|---|---|---|
| `connections` | Settings::Connections::Map | — (**required**) | Router signal topology: output → input connection map (see the Routing guide below). Read by the router library with `setting` — the driver cannot load a signal graph without it. |
| `inputs` | Settings::IOMeta | nil | Input node metadata (names, icons, `type: cam`, `presentable`, …) — see the guide. |
| `outputs` | Settings::IOMeta | nil | Output node metadata (names, `followers`, `hide_on_join`, …) — see the guide. |
| `help` | Hash | shipped `{"help-id" => {"title" => "Video Conferencing", "content" => "markdown"}}`; absent-key fallback `{}` | Help pages, id → `{title, content}` (markdown/HTML). |
| `tabs` | Array | shipped `[{name: "VC", icon: "conference", inputs: ["VidConf_1"], help: "help-id", controls: "vidconf-controls", merge_on_join: false}]`; absent-key fallback `[]` | Tab layout for the UI (see guide). |
| `local_outputs` | Array(String) | shipped `["Display_1"]`; absent-key fallback `[]` | Outputs displayed on the panel; merged when rooms join. |
| `preview_outputs` | Array(String) | shipped `["Display_2"]`; absent-key fallback `[]` | Preview monitor(s) showing the currently selected input. |
| `local_cameras` | Array(String) | shipped `["Camera_1"]`; absent-key fallback `[]` | Cameras local to this room (required in joining rooms). |
| `local_vidconf` | String | `"VidConf_1"` | The VC module (hung up on shutdown, camera-select target). |
| `vc_camera_in` | String \| Array(String) | shipped `"switch_camera_output_id"`; absent-key fallback nil | Output(s) the selected camera is routed to. |
| `vc_camera_module` | String | `"Camera"` | Module class powered on at startup for camera defaults. |
| `screens` | Hash(String, String) | shipped `{"Projector_1" => "Screen_1"}`; absent-key fallback `{}` | Display module → screen module; screen follows display power. |
| `default_routes` | Hash(String, String) | `{}` | Output id → input id, applied at system startup. |
| `master_audio` | Object | nil | Front-of-house audio configuration (see guide). |
| `local_microphones` | Array | `[]` | Microphone fader/mute definitions (see guide). |
| `room_accessories` | Array | `[]` | Blinds/AC/etc. accessory controls (see guide). |
| `lighting_scenes` | Array | shipped `[{name: "Full", id: 1, icon: "lightbulb", opacity: 1.0}, {name: "Medium", id: 2, icon: "lightbulb", opacity: 0.5}, {name: "Off", id: 3, icon: "lightbulb_outline", opacity: 0.8}]`; absent-key fallback nil | Lighting scenes (see guide). |
| `lighting_area` | Object | shipped `{id: 34, join: 0x01}`; absent-key fallback nil | Lighting area for this room (see guide). |
| `lighting_levels` | Array | shipped `[{name: "Spot light left", area: {id: 123}}]`; absent-key fallback nil | Lighting fader definitions (see guide). |
| `lighting_independent` | Bool | `true` | When false, lighting areas join with linked rooms. |
| `lighting_module` | String | `"Lighting_1"` | Lighting module reference. |
| `join_modes` | Object | nil | Room joining configuration (see guide). |
| `join_lockout_secondary` | Bool | shipped `true`; absent-key fallback `false` | UI lockout of secondary rooms during a join. |
| `join_hide_button` | Bool | `false` | Hide the join button on the UI. |
| `unjoin_on_shutdown` | Bool | shipped `false`; absent-key fallback nil (shutdown then honours the `unlink` argument) | When set, overrides whether shutdown also unlinks joined rooms. |
| `mute_on_unlink` | Bool | shipped `true`; absent-key fallback `false` | Unroute local + preview outputs when the room is unlinked (only while powered on). |
| `auto_route_on_join` | Bool | `false` | On join (master side), re-send the selected input to all outputs. |
| `startup_exec` | Array(Exec) | nil | Functions executed on power **on**: `[{module, function_name, arguments}]`. Unindexed module names fan out to all instances. |
| `shutdown_exec` | Array(Exec) | nil | Functions executed on power **off**, same shape. **Backwards compatibility:** falls back to the legacy misspelled key `shutown_exec` when `shutdown_exec` is unset. |
| `shutdown_devices` | Array(String) | nil | Modules powered off on shutdown; when unset, everything implementing `Powerable` is powered off. |
| `voice_control` | Bool | `false` | Exposed to the UI as the `voice_control` status. |
| `channel_details` | Array | nil (shipped disabled as `_channel_details`) | IPTV channel list `{name, icon, channel}`. |
| `qsc_phone` | Object | nil | QSC phone dialing bindings (see guide — note the key is `qsc_phone`). |
| `active_state`, `join_master`, `join_selected` | — | — | Driver-persisted state (written back via `define_setting`); not user configuration. |

## Status keys

| Key | Description |
|---|---|
| `active` | Room power state. |
| `name` | System display name. |
| `tabs` / `local_tabs` / `help` / `local_help` | Merged (join-aware) and local UI definitions. |
| `local_inputs` / `available_inputs` | Inputs across the configured tabs (`local_inputs` kept for older UIs). |
| `available_outputs` / `local_outputs` / `preview_outputs` / `local_preview_outputs` | Output sets, join-aware. |
| `available_cameras` / `local_cameras` / `selected_camera` | Camera sets and current selection. |
| `selected_input` / `selected_tab` | Currently selected input and its tab. |
| `has_master_audio` / `volume` / `mute` | Master audio presence, level (0–100) and mute (from mixer feedback subscriptions). |
| `microphones` | Merged microphone definitions for the UI. |
| `lighting_scenes` / `lighting_scene` / `lighting_levels` | Available scenes, current scene id, merged fader list. |
| `room_accessories` | Merged accessory definitions. |
| `join_modes` / `joined` / `join_master` / `join_confirmed` / `join_lockout_secondary` / `join_hide_button` | Joining state. |
| `voice_control` / `channel_details` | UI feature flags/data. |
| `qsc_dial_number` / `qsc_dial_bindings` | QSC dialing state. |
| `inputs` / `outputs`, `input/<id>` / `output/<id>` | Published by the router library: id lists and per-node metadata/route state. |
| `routes_changed` | Debounced counter published by the router library, incremented when routes change — useful for integrations watching for routing activity. |

## Exec methods

| Method | Description |
|---|---|
| `power(state, unlink)` / `set_power_state(state)` / `power?` | Room power. Startup applies audio/camera/route/mic defaults and runs `startup_exec`; shutdown mutes, unroutes, powers devices off, hangs up VC and runs `shutdown_exec`. |
| `route_input(input_id, output_id)` / `route(input, output, …)` | Route a source to a display (powers the room on; join-aware). |
| `route_all(input_id)` / `unroute(output)` / `unroute_all` | Present to all displays / blank one / blank all (`MUTE` route). |
| `inputs_and_outputs` | Lists routable ids with display names (LLM helper). |
| `selected_input(name, simulate)` | Sets the selected input/tab, powers the source, routes previews. |
| `apply_default_routes` | Re-applies `default_routes`. |
| `set_volume(level)` / `volume(level, input_or_output)` / `volume?` | Master volume (0–100, mapped into the configured fader range). |
| `audio_mute(state)` / `audio_muted?` / `mute(state, index, layer)` | Master mute. |
| `set_microphone(level, mute)` / `microphone_volume(name, level)` / `microphone_mute(name, mute)` / `mute_microphones(mute)` | Microphone control. |
| `mic_room_selection(mic_name, room_name, selected)` | Routes/unroutes a shared mic into a room (exec or mute-binding based). |
| `select_lighting_scene(scene)` / `set_lighting_scene(scene)` / `lighting_scenes` / `lighting_scene?` | Lighting scene control/query. |
| `accessory_exec(accessory, control)` | Runs an accessory control (executes on the room it came from when joined). |
| `selected_camera(camera)` / `apply_camera_defaults` / `add_preset(preset, camera)` / `remove_preset(preset, camera)` | VC camera selection and presets. |
| `join_mode(mode_id, master)` / `unlink_systems` / `unlink_internal_use` / `linked?` | Room joining. |
| `qsc_dial_pad(number)` / `qsc_dial_pad_clear` / `qsc_dial_makecall` / `qsc_dial_hangup` | QSC phone dialing. |

---

# Configuration guide

Docs on how to configure a tabbed control UI

* available icons for controls are: https://fonts.google.com/icons?selected=Material+Icons

## Routing

The router is designed to graph signal paths in a system between devices.
https://docs.google.com/document/d/1DG2s9jjMVhiW65YGPDkUnOYYpFDeW42SkGvHyp1BEjQ/

* devices can be represented by modules `Display_1`
* virutal devices can be representated by a `*`: `*Laptop_HDMI`

Connections are then defined by a flat map of Output => Inputs
There are two styles of switching supported:

* `switch_to`: an output that multiple inputs
* `switch`: multiple outputs and multiple inputs

NOTE:: when an input is presented to an output via `route("Input_id", "Output_id")`
if the input and output support the `Powerable` interface, they will be powered on

### Examples

A basic single display system

```yaml

# A switch_to style of output where the inputs are virtual devices
# virtual devices as no modules in the system represent the inputs
connections:
  Display_1:
    hdmi: '*HDMI_Cable'
    hdmi2: '*Wireless_Presenter'

```

A switcher and multiple displays

* Switcher outputs are represented by `.` i.e. `Switcher_1.2` (output 2)
* Switcher inputs can be represented by `:` i.e. `Switcher_1:2` (input 2)
  * Switcher inputs in this format are only required if chaining multiple switchers

```yaml

# A typical single switcher setup
connections:
  # Display 1 is connected to Switcher 1 ouput 1
  Display_1:
    hdmi: Switcher_1.1
  Display_2:
    hdmi: Switcher_1.2

  # We have a virtual output connected to output 5
  '*AUX_Output': Switcher_1.5

  # The switcher inputs are hooked up using a hash
  Switcher_1:
    '1': '*Wireless_Presenter' # always on, wireless presenter
    '2': IPTV_1         # set top box or streaming input that can be powered on
    '5': '*Desk_HDMI_1' # i.e. laptop inputs on a table in the room
    '6': '*Desk_HDMI_2'

```

If you have a situation where audio and video need to be switched separately then you can also define layers on the switcher outputs.

```yaml

# A weird audio setup
connections:
  # Front of house audio split from the camera video input (real world example!)
  Display_1:
    hdmi: Switcher_1.12
  '*VC_Camera_1': Switcher_1.1!video
  '*FOH_Audio': Switcher_1.1!audio

  # The switcher inputs are hooked up using a hash
  Switcher_1:
    '1': '*Wireless_Presenter' # always on, wireless presenter
    '2': IPTV_1         # set top box or streaming input that can be powered on
    '5': '*Desk_HDMI_1' # i.e. laptop inputs on a table in the room
    '6': '*Desk_HDMI_2'

# as we also want the audio to follow anything being presented to the display
# you can ensure the sources follow one another
outputs:
  Display_1:
    name: Projector
    followers: ["FOH_Audio"]

```

### Default routes

these are applied at system startup

```yaml

# output id => input id (as defined in the router)
default_routes:
  VC_Camera_1: Camera_1
  VC_Camera_2: Camera_2

```

## Naming Inputs and Outputs

Inputs and outputs are all referenced from their IDs which are either:

* DeviceMod_1
* Virtual_Device

However you can apply metadata to these inputs and outputs, such as name for display on the user interface. This configuration is split between the inputs and outputs.

```yaml

# Input meta data
inputs:
  Desk_HDMI_1:
    name: Table Box HDMI Cable
    icon: input
  Wireless_Presenter:
    name: Wireless
    icon: connected_tv

  # Inputs of type cam are collected for camera control
  # index is optional (only where a single module controls multiple cameras)
  Camera_1:
    name: Camera 1
    icon: video_camera_front
    type: cam
    mod: Camera_1
    index: 1 # only use this index on VC systems, single mod, mutliple cameras

  # Inputs that have `presentable: false` are ignored as possible inputs for VC presenations
  VidConf_1:
    name: Video Conference
    icon: video_camera_front
    presentable: false

```

Output config is typically less interesting

```yaml

outputs:
  Display_1:
    name: Display Left
  Display_2:
    name: Display Right

  # this display is hidden on the UI when the room is joined, preventing its use
  Display_3:
    name: Middle of room
    hide_on_join: true

```

## Laying out Tabs

Spaces can have more inputs and outputs defined then you want to display on the panel. Some things are auto switched etc so you need define you tab layouts.

```yaml

# a single tab UI with the optional help link
tabs:
  - name: Laptop
    icon: computer
    help: laptop-help

    # Multiple inputs can be on a single tab
    inputs:
      - HDMI_Cable
      - Wireless_Presenter

```

### Cisco Video Conferencing

Configuring a tab with Cisco VC controls

```yaml

tabs:
  - name: Conference
    icon: video_camera_front
    # The controls we want to see on the tab
    controls: vidconf-controls
    # this defines the switch output representing the presentation input on the VC
    presentation_source: Virtual_VC_Presentation_Output
    inputs:
      - VidConf_1

```

configuring camera switching where cameras are connected via a switcher (single input on the VC unit)

```yaml

connections:
  # outputs:
  '*VC_Camera_Input': Switcher_1.1!video
  '*Recorder_Camera_Input': Switcher_1.2!video
  Switcher_1: # inputs:
    '35': Camera_1
    '36': Camera_2

# specify which input on the VC unit the inputs are connected
inputs:
  Camera_1:
    name: Camera 1
    icon: video_camera_front
    type: cam
    mod: Camera_1
    presentable: false # don't appear as VC content
  Camera_2:
    name: Karijini I Camera 2
    icon: video_camera_front
    type: cam # this indicated we want to have this camera manually controllable
    mod: Camera_2
    presentable: false  # don't appear as VC content

# When camera 1 or 2 is selected, we'll switch it to this output
vc_camera_in: VC_Camera_Input

# If the camera needs to be switched to multiple sources (i.e. a recording device and a VC system)
vc_camera_in:
  - VC_Camera_Input
  - Recorder_Camera_Input

# where there are joining rooms you must define which cameras are local to the system
local_cameras: 
  - Camera_1
  - Camera_2
```

configuring camera switching where cameras are connected via a switcher but also multiple cameras are connected to the VC at once

```yaml

# Configure the camera inputs and outputs on the switcher
connections:
  # outputs:
  '*VC_Camera_1': Switcher_1.1!video
  '*VC_Camera_2': Switcher_1.2!video
  Switcher_1: # inputs:
    '35': Camera_1
    '36': Camera_2

# auto switch these these to the VC on startup
default_routes:
  VC_Camera_1: Camera_1
  VC_Camera_2: Camera_2

# specify which input on the VC unit the inputs are connected
inputs:
  Camera_1:
    name: Camera 1
    icon: video_camera_front
    type: cam
    mod: Camera_1
    presentable: false
    vc_camera_input: 1 # This is input on the VC codec we want to select
  Camera_2:
    name: Karijini I Camera 2
    icon: video_camera_front
    type: cam # this indicated we want to have this camera manually controllable
    mod: Camera_2
    presentable: false  # don't appear as VC content
    vc_camera_input: 2

```

### IPTV Control

Configuring IPTV controls for a page

```yaml

tabs:
  - name: TV
    icon: live_tv

    # the controls we want to show (expects IPTV_1 mod to expose channel details)
    controls: tv-channels
    mod: IPTV_1
    inputs:
      - IPTV_1

```

example channel detail config (see [Exterity M93xx](https://github.com/PlaceOS/drivers/blob/master/drivers/exterity/avedia_player/m93xx.cr#L15) for an example driver)

```yaml
channel_details:
  - name: Al Jazeera
    channel: 'udp://239.192.10.170:5000?hwchan=0'
    icon: 'https://os.place.tech/placeos.com/16335767803641925864.svg'
```

## Help pages

This is custom HTML content that is embedded on the UI.
The help key (`laptop-help` in the example below) is used to link the help to a tab

* Help pages are inlined onto tabs when there are no controls defined.
* Where there are controls defined a button is placed on the tab that links to the help pop-up

```yaml

help:
  laptop-help:
    title: Swytch
    icon: computer
    content: >
      Follow the instructions below on how to connect your laptop in a meeting
      room:

      1. Plug the ‘Y’ shaped connector into the USB-C port on your laptop.

      <img
      src="https://os.place.tech/placeos.pwc.com.au/1632888427183509679.png"
      alt="Swytch" title="Swytch help" style="max-width: 760px" />


```

You can drag and drop images and videos into backoffice so they are available for embedding.

## Defining Outputs to display

You need to define which ouputs will be displayed on the panel.

* when there is a single output, it'll automatically be switched
* where there are two outputs, the user must manually switch by selecting the output

```yaml

# named local outputs as when joining rooms we'll merge these with joined rooms
local_outputs:
  - Display_1
  - Display_2

```

Where you have Preview Monitor(s) for previewing sources before presenting them, you configure them using:

```yaml

# these will show the currently selected input
preview_outputs:
  - Display_3

```

NOTE:: there is a setting `mute_on_unlink: true` that can be set to ensure outputs are muted when rooms are unlinked - ensuring routes are reset

## Front of House Audio

By default the first display in the output list is assumed to be managing audio
However you may want to configure defaults or use Mixer controls instead of the output device

```yaml

# This is a mixer configuration
master_audio:
  name: FOH Speakers
  level_id: ["FOH-1234", "FOH-1235"]
  mute_id: 'FOH-123-45-mute'

  level_index: 4,
  mute_index: 4,
  level_feedback: 'faderFOH-1234'
  mute_feedback: 'faderFOH-1234_mute'
  module_id: 'Mixer_2'

  default_muted: false
  default_level: 60

  min_level: 40
  max_level: 90

```

You can just customise defaults if you want to continue using the default output

```yaml

master_audio:
  default_muted: false
  default_level: 60

```

## Projector Screen Linking

Linking a projector screen to a displays power state

```yaml

screens:
 Karijini_IV_Projector_1: Screen_1

```

## QSC Phone Dialing controls

The places a dialing phone icon at the top of the screen that can be used to dial a phone number. Does not effect other aspects of the UI / Switching.

NOTE:: the settings key read by this driver is `qsc_phone`.

```yaml

qsc_phone:
    number_id: "Status/Control16-17-VoIPCallControlDialString",
    dial_id: "Status/Control16-17-VoIPCallControlConnect",
    hangup_id: "Status/Control16-17-VoIPCallControlDisconnect",
    status_id: "Status/Control16-17-VoIPCallStatusProgress",
    ringing_id: "Status/Control16-17-VoIPCallStatusRinging(state)",
    offhook_id: "Status/Control16-17-VoIPCallStatusOffHook",
    dtmf_id: "16.17:dtmftx1"

```

Then in the QSC driver you want to define which controls QSC should poll and report changes:

```yaml

# keeps the phone status in sync
change_groups: {
  "room123_phone" => {
    id:       1,
    controls: ["VoIPCallStatusProgress", "VoIPCallStatusRinging", "VoIPCallStatusOffHook"],
  },
},

```

## Microphone configuration

A basic list of fader and mute values that represent the microphones available

```yaml

local_microphones:
  - name: Hand Held Microphone
    level_id: ["HH-1234", "HH-1235"]
    mute_id: 'HH-123-45-mute'

    # optional keys
    level_index: 4,
    mute_index: 4,
    level_feedback: 'faderHH-1234'
    mute_feedback: 'faderHH-1234_mute'
    module_id: 'Mixer_2'

    default_muted: true
    default_level: 55.8

    min_level: 40
    max_level: 90

```

Where a microphone might be shared between rooms or spill into a lobby, you can add a rooms configuration with mute ids that when unmuted will route the microphone audio to various spaces.

```yaml

local_microphones:
  - name: Hand Held Microphone
    # as above

    rooms:
      - name: "Room 1"
        binding: "hh_room1_mute_id_mute"
        control: "hh_room1_mute_id"
        # this uses the `mute` function

      - name: "Room 2"
        binding: "hh_room2_mute_id_mute"
        route:
          - module_id: Mixer_1
            function_name: trigger
            arguments: ["hh_room2_add"]
        unroute:
          - module_id: Mixer_1
            function_name: trigger
            arguments: ["hh_room2_remove"]

```

Microphones with the same name in a room join will be merged (level and mute ids).

## Startup / shutdown executes

Arbitrary module functions run on room power on / power off:

```yaml

startup_exec:
  - module: Recorder_1
    function_name: power
    arguments: [true]

shutdown_exec:
  - module: Recorder   # unindexed: sent to all Recorder modules
    function_name: power
    arguments: [false]

```

NOTE:: `shutown_exec` (a historical misspelling) is still honoured when `shutdown_exec` is not set.

## Joining Config

Where systems can be merged you can define the various modes that are supported between the rooms.

* there are two types `fully_aware` or `independent` (default)
  * fully_aware: (typically something like 4 rooms where you can have independent, 1:3, 2:2 or all 4 etc)
    * rooms that are not technically part of the join are aware of the join (1:3 combination for example)
    * this might be because the DSP has a preset for each join combination (to combine microphones)
  * independent: (typically something like 3 rooms that share a video switcher)
    * only rooms part of the join are notified of the join
    * this makes sense where audio and video come off an output of a shared switch
    * so if room1 wants to present in room2 all it has to do is present to both outputs and keep audio levels in sync

```yaml

join_modes:
  type: fully_aware
  modes:
    # id links mode across rooms.
    # useful in fully linked where joining room_ids might differ between systems
    - id: unlinked
      name: Independent
      room_ids: []
      # join actions are optional
      join_actions:
        - module_id: Mixer_1
          function_name: trigger
          # supports named arguments too
          arguments: ["UnjoinAll"]
    - id: join-all
      name: All Rooms
      room_ids: ["sys-Cia-PnmTLC", "sys-Cia-ehhm8h", "sys-Cia-_e0jWQ"]
      # input 1 in both rooms is merged (versus becoming a seperate input)
      merge_outputs: true # default true, set per mode
      join_actions:
        - module_id: Mixer_1
          function_name: trigger
          arguments: ["Join-all"]
      
      # sometimes you may need to run an action to break a join (typically not required)
      breakdown:
        - module_id: Mixer_1
          function_name: trigger
          arguments: ["UnjoinAll"]

```

## Lighting Config

There are two lighting modes:

* independent rooms (even when linked, each room controls it's lighting area, we manually sync them)
* joining rooms (a single request will change the scene in all linked rooms)

```yaml

# scenes are often the same across many rooms, so should be applied to a zone
lighting_scenes:
  - id: 1
    name: "Full"
    icon: lightbulb
    opacity: 1.0
  - id: 2
    name: "Medium"
    icon: lightbulb
    opacity: 0.5
  - id: 3
    name: "Off"
    icon: lightbulb_outline
    opacity: 0.8

# Each room typically will have its own area or grouping, so apply this at the system level
lighting_area:
  id: 23
  # join: 0xFF (only if required by the driver)
  # channel: 3 (only if required by the driver)
  # component: "Lighting" (only if required by the driver)

# Typically set to false if using the `join` field in `lighting_area`
lighting_independent: true
```

## Additional Room Accessories

These are things like blinds or air-conditioning that usually have limited controls and obsucre interfaces

```yaml

room_accessories:
  - name: Shade blind
    module: Blinds_1
    controls:
      - name: Up
        icon: vertical_align_top
        function_name: position
        arguments: [1, "up"]
      - name: Down
        icon: vertical_align_bottom
        function_name: position
        arguments: [1, "down"]

```

If a control performs multiple actions you can use the `exec` block

```yaml

room_accessories:
  - name: Projector Screen
    controls:
      - name: Up
        icon: vertical_align_top
        exec: 
          - module: Screen_1
            function_name: position
            arguments: [1, "up"]
          - module: Projector_1
            function_name: power
            arguments: [false]
      - name: Down
        icon: vertical_align_bottom
        exec: 
          - module: Screen_1
            function_name: position
            arguments: [1, "down"]

```

---

## 2.0.0 (2026-08-31)

- Vendored unchanged copies of `drivers/place/meet.cr` + spec, the meet helpers (`help.cr`, `tab.cr`, `qsc_phone_dialing.cr`), and the router library tree it requires, from ucla-dev @ ce19af2a18. Logic driver — the DeviceInfo work applied to the vendored device drivers is out of scope here.
- Readme adapted from the branch-local `drivers/place/meet_readme.md` with corrections verified against the source: the QSC dialing settings key is `qsc_phone` (the base doc showed `phone_settings`, which the driver never reads), `merge_outputs` documented per join **mode** (where the source defines it), and a new startup/shutdown executes section covering `startup_exec` / `shutdown_exec` including the legacy `shutown_exec` fallback.

## Pre-2.0 (upstream history)

- Upstream `place/meet.cr` as of ucla-dev @ ce19af2a18: the full room-logic feature set documented above (routing, tabs, audio, microphones, lighting, accessories, joining, VC cameras, QSC dialing, LLM chat functions).

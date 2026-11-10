# Melodics Maschine Bridge

Use a Native Instruments Maschine as a 4×4 pad controller for Melodics on macOS. The bridge sends pad strikes and releases to Melodics and mirrors lesson cues on the physical pads. It runs in a small macOS window with Start, Stop, and Open Log controls.

## What works

- All 16 pads send note-on and note-off events with strike velocity.
- The pad LEDs show blue for the left hand, yellow for the right hand, and white for the Preview cue.
- Early, late, and missed-note messages have separate color mappings when the Melodics profile sends them. Missed-note feedback during a performance has not been independently verified.
- The bridge works with MIDI and the Native Instruments host integration service. It does not capture the screen.

## Requirements

- This preview build targets Apple silicon and macOS 15 or later. It uses the system Python 3 launcher, which may require Apple's Command Line Tools or Xcode. Python 3.9 or later is required.
- Melodics desktop for macOS, initialized at least once.
- A USB-connected Maschine+ in Controller mode, with the Native Instruments Host Integration Agent installed and running. The code recognizes Maschine MK3, but the physical workflow was tested on Maschine+.
- A local Melodics Maschine+ LED profile at `~/Library/Application Support/Melodics/Melodics/devices/ni_maschine_plus.json` or an already configured `maschine_4x4.json`. The bridge creates the latter from the former when needed. When upgrading from v0.1.0, the bridge can also copy the existing profile to the new name. A stock installation without a compatible LED profile cannot currently complete setup.

## Install and run

1. Download the app ZIP from the release, unzip it, and move the app to Applications if desired. The preview is locally signed and is not notarized by Apple.
2. Quit Melodics and stop any other bridge session. Connect the Maschine over USB and switch a Maschine+ to Controller mode.
3. Open **Melodics Maschine Bridge** and click **Start Bridge**.
4. When the app shows **Running · Maschine 4x4**, open Melodics. Select **Pads**, then choose **Maschine 4x4** under **Connected Instruments**.
5. Open a Pads lesson and start **Preview**. To check input, strike a pad outside Preview or start a performance.

Melodics handles audio separately. To listen through Maschine+, select **Maschine Plus** under Melodics audio settings and choose output pair **1–2**. On the Maschine+, **Outputs Main → + Phones** mirrors the main signal to headphones.

## Troubleshooting

- After upgrading from v0.1.0, select **Maschine 4x4** in Melodics. The previous profile file is preserved.
- If the profile does not appear, quit and reopen Melodics after the bridge shows **Running**.
- If the bridge stops, click **Open Log**. The latest run is saved under `~/Library/Logs/Melodics Maschine Bridge/bridge.log`. Review the log before sharing it because it can include device diagnostics.
- Connect exactly one supported Maschine over USB. Close other apps using Maschine hardware control while testing.
- To uninstall the bridge, delete the app. To remove its custom Melodics profile, remove `maschine_4x4.json` from the Melodics devices folder while Melodics is closed.

## Build from source

On macOS with Xcode or its Command Line Tools and Python 3, run:

```sh
./macapp/build-app.sh
```

The app is built in `dist/`. To test the virtual MIDI source with a synthetic hit and release:

```sh
printf '1 12 64\n1 12 0\n' | ./launchpad-probe --self-test --pad-input
```

## Version history

See [CHANGELOG.md](CHANGELOG.md). Each downloadable app is tied to a Git tag. In the 0.x series, patch releases fix bugs and minor releases add features.

Independent project. Melodics, Maschine, and Native Instruments are names of their respective owners.

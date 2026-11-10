# Melodics Maschine Bridge

Use a Native Instruments Maschine MK3/Plus as a 4×4 pad controller for Melodics on macOS. The bridge sends pad strikes and releases to Melodics and mirrors lesson cues on the physical pads. It runs in a small macOS window with Start, Stop, and Open Log controls.

## What works

- All 16 pads send note-on and note-off events with strike velocity.
- The pad LEDs show blue for the left hand, yellow for the right hand, and white for the Preview cue.
- Early, late, and missed-note messages have separate color mappings when the Melodics profile sends them. Missed-note feedback during a performance has not been independently verified.
- The bridge works with MIDI and the Native Instruments host integration service. It does not capture the screen.

## Requirements

- This preview build targets Apple silicon and macOS 15 or later. It uses the system Python 3 launcher, which may require Apple's Command Line Tools or Xcode. Python 3.9 or later is required.
- Melodics desktop for macOS, initialized at least once.
- A USB-connected Maschine MK3/Plus with the Native Instruments Host Integration Agent installed and running. Physical testing covered the Plus model.
- The Melodics LED profile `ni_maschine_plus.json` in `~/Library/Application Support/Melodics/Melodics/devices/`. On first start, the bridge uses it to create `maschine_4x4.json` automatically.

## Install and run

1. Download the app ZIP from the release, unzip it, and move the app to Applications if desired. The preview is locally signed and is not notarized by Apple.
2. Quit Melodics and stop any other bridge session. Connect the Maschine MK3/Plus over USB. If the Plus is running standalone, switch it to Controller mode.
3. Open **Melodics Maschine Bridge** and click **Start Bridge**.
4. When the app shows **Running · Maschine 4x4**, open Melodics. Select **Pads**, then choose **Maschine 4x4** under **Connected Instruments**.
5. Open a Pads lesson and start **Preview**. To check input, strike a pad outside Preview or start a performance.

## Troubleshooting

- If the profile does not appear, quit and reopen Melodics after the bridge shows **Running**.
- If the bridge stops, click **Open Log**. The latest run is saved under `~/Library/Logs/Melodics Maschine Bridge/bridge.log`. Review the log before sharing it because it can include device diagnostics.
- Connect exactly one Maschine MK3/Plus over USB. Close other apps controlling the hardware while testing.
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

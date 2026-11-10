#!/bin/sh
set -eu
cd "$(dirname "$0")"
xcrun clang -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Wno-deprecated-declarations \
  -framework CoreMIDI -framework CoreFoundation probe.c -o launchpad-probe
xcrun clang -O2 -fobjc-arc -fblocks -framework Foundation -framework CoreFoundation -framework IOKit \
  ipc/DisplayProbe.m ipc/NativePadLights.m ipc/PadInspector.m ipc/DeviceMonitor.m -o ni-led-helper

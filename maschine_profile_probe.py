#!/usr/bin/env python3
"""Capture Melodics' native Maschine+ MIDI output without forwarding it."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent
PROFILE = (Path.home() / "Library/Application Support/Melodics/Melodics/devices"
           / "ni_maschine_plus.json")
BRIDGE_PORT = "Maschine 4x4"
BRIDGE_PROFILE = PROFILE.with_name("maschine_4x4.json")
NOTE = re.compile(r"90 ([0-7][0-9A-F]) ([0-7][0-9A-F])")


def profile_states(profile):
    states = {}
    for pad, entries in profile["outputs"].items():
        for entry in entries:
            for message in entry["midi"]:
                if message["type"] == "NoteOn" and message["channel"] == 1:
                    states[message["note"], message["velocity"]] = (pad, entry["state"])
    return states


def packet_states(line, states):
    _, marker, payload = line.partition(" RX packet ")
    if not marker:
        return
    for match in NOTE.finditer(payload):
        state = states.get(tuple(int(value, 16) for value in match.groups()))
        if state:
            yield state


def decode_packet(line, states):
    for pad, state in packet_states(line, states):
        yield f"PROFILE {pad} {state}"


def main():
    profile = json.loads(PROFILE.read_bytes())
    states = profile_states(profile)
    name = profile["outports"]["mac"]
    binary = ROOT / "launchpad-probe"
    destinations = subprocess.check_output([binary, "--list-outputs"], text=True)
    if name in destinations.splitlines():
        print(f"The {name} port is already in use. Disconnect the physical Maschine for this diagnostic.")
        return 1
    command = [binary, "--name", name, "--no-reply"]
    with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as monitor:
        try:
            for line in monitor.stdout:
                print(line.rstrip(), flush=True)
                for decoded in decode_packet(line, states):
                    print(decoded, flush=True)
            return monitor.wait()
        except KeyboardInterrupt:
            if monitor.poll() is None:
                monitor.terminate()
            return 130


if __name__ == "__main__":
    raise SystemExit(main())

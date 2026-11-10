#!/usr/bin/env python3
"""Combine Melodics lesson hand colors with the live MIDI cue."""
import argparse
import json
from pathlib import Path
from queue import Empty, Queue
import subprocess
import threading
import time

from install_4x4_profile import install_profile
from maschine_profile_probe import BRIDGE_PORT, BRIDGE_PROFILE, packet_states, profile_states

ROOT = Path(__file__).resolve().parent


CACHE = Path.home() / "Library/Application Support/Melodics/Melodics"
WHITE = 17 << 2
LEFT_BLUE = (11 << 2) | 2
RIGHT_YELLOW = (5 << 2) | 2


def lessons():
    found = {}
    for path in CACHE.glob("*/data/**/*.json"):
        if path.parent.name == "data":
            continue
        try:
            document = json.loads(path.read_bytes())
        except (OSError, ValueError):
            continue
        data = document.get("data") if isinstance(document, dict) else None
        if not isinstance(data, dict) or not isinstance(data.get("fingers"), dict):
            continue
        title = data.get("title")
        identifier = data.get("uid") or data.get("ulid") or path.stem
        if not isinstance(title, str) or not isinstance(identifier, str) or not data["fingers"]:
            continue
        modified = path.stat().st_mtime
        if identifier not in found or modified > found[identifier][0]:
            found[identifier] = (modified, data)
    return found


def hand_colors(data, group, layout):
    layouts = data["fingers"].get(group)
    if not isinstance(layouts, dict):
        raise ValueError(f"No finger group {group!r}; available: {', '.join(data['fingers'])}")
    mapping = layouts.get(layout)
    if not isinstance(mapping, dict):
        raise ValueError(f"No layout {layout!r} in group {group!r}; available: {', '.join(layouts)}")
    colors = {}
    for address, finger in mapping.items():
        if len(address) != 2 or any(digit not in "1234" for digit in address):
            continue
        if not isinstance(finger, str) or finger[:1] not in ("L", "R"):
            continue
        row, column = map(int, address)
        colors[(row - 1) * 4 + column - 1] = LEFT_BLUE if finger[0] == "L" else RIGHT_YELLOW
    if not colors:
        raise ValueError("No L/R assignments in the lower-left 4×4 grid.")
    return colors


def devices():
    response = subprocess.check_output([ROOT / "ni-led-helper", "--list-devices"], text=True)
    try:
        return {(item["pid"], item["serial"]) for item in json.loads(response)["devices"] if item["serial"]}
    except (ValueError, KeyError, TypeError) as error:
        raise RuntimeError("The native USB device list could not be read.") from error


def send(helper, pads, request_id):
    helper.stdin.write(json.dumps({"request_id": request_id, "pad_leds": pads}) + "\n")
    helper.stdin.flush()


# The Melodics profile also uses Perfect during Preview, where we want a white cue.
NATIVE_COLORS = {
    "Off": 0, "Active_Left": LEFT_BLUE, "Active_Right": RIGHT_YELLOW, "Perfect": 71,
    "Early": 11, "Late": 55, "Missed": 7,
}


def native_updates(line, states):
    for pad, state in packet_states(line, states):
        if state not in NATIVE_COLORS or not pad.startswith("Pad") or len(pad) != 5:
            continue
        row, column = pad[3:]
        if row in "1234" and column in "1234":
            yield (int(row) - 1) * 4 + int(column) - 1, NATIVE_COLORS[state]


def launchpad_updates(line, colors):
    fields = line.split()
    if fields[1:4] == ["MK3", "DRY", "RUN"]:
        _, note, color = fields[4:]
        pad = int(note, 16) - 36
        yield pad, {"2E": WHITE | 3, "06": colors.get(pad, WHITE | 1), "00": 0}[color]


def profile_inputs(profile):
    inputs = {}
    for assignment in profile["inputs"]:
        if assignment.get("instrument") != "pads" or "note" not in assignment:
            continue
        for event in assignment["events"]:
            label = event.get("message", "")
            if event["type"] == "NoteOn" and len(label) == 5 and label.startswith("Pad"):
                row, column = label[3:]
                if row in "1234" and column in "1234":
                    inputs[(int(row) - 1) * 4 + int(column)] = (
                        assignment["channel"], assignment["note"])
    return inputs


def pad_input(event, inputs):
    if event.get("event") != "pad_decoded" or event.get("pad") not in inputs:
        return None
    channel, note = inputs[event["pad"]]
    if event["kind"] == "hit_candidate":
        velocity = min(127, max(1, round(event["raw_value"] * 127)))
    elif event["kind"] == "release_candidate":
        velocity = 0
    else:
        return None
    return f"{channel} {note} {velocity}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--demo", action="store_true", help="run generated two-pad sample")
    parser.add_argument("--dry-run", action="store_true", help="skip the NI helper")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--native-4x4", action="store_true", help="use the MLP Maschine 4x4 MIDI profile")
    selection.add_argument("--lesson", help="exact cached lesson title or ID")
    selection.add_argument("--list-lessons", metavar="SEARCH", help="find cached lesson titles")
    parser.add_argument("--finger-group", default="default")
    parser.add_argument("--finger-layout", default="default")
    args = parser.parse_args()
    colors = {}
    states = None
    inputs = {}
    if args.native_4x4:
        if args.demo:
            parser.error("--demo uses Launchpad test messages. Use live Preview for --native-4x4.")
        try:
            install_profile()
            profile = json.loads(BRIDGE_PROFILE.read_bytes())
            states = profile_states(profile)
            inputs = profile_inputs(profile)
            if len(inputs) != 16:
                parser.error("The native profile must assign all 16 pad inputs.")
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            parser.error(str(error))
    if args.lesson is not None or args.list_lessons is not None:
        catalog = lessons()
        if args.list_lessons is not None:
            matches = sorted((d["title"], i) for i, (_, d) in catalog.items()
                             if args.list_lessons.casefold() in d["title"].casefold())
            for title, identifier in matches:
                print(f"{identifier}  {title}")
            if not matches:
                print("No matching cached lessons.")
            return 0
        matches = [(identifier, data) for identifier, (_, data) in catalog.items()
                   if args.lesson == identifier or args.lesson.casefold() == data["title"].strip().casefold()]
        if len(matches) != 1:
            parser.error("Lesson missing or ambiguous. Use --list-lessons and select the exact ID.")
        identifier, data = matches[0]
        try:
            colors = hand_colors(data, args.finger_group, args.finger_layout)
        except ValueError as error:
            parser.error(str(error))
        print(f"Lesson: {data['title']} ({identifier}), fingers: {args.finger_group}/{args.finger_layout}",
              flush=True)
        print("Hand colors:", ", ".join(f"pad {pad + 1} {'blue' if value == LEFT_BLUE else 'yellow'}"
                                        for pad, value in sorted(colors.items())), flush=True)
    helper = monitor = None
    acknowledgements = Queue()
    pads = [0] * 16  # Keep inactive pads dark.
    try:
        if states is not None:
            ports = subprocess.check_output([ROOT / "launchpad-probe", "--list-outputs"], text=True)
            if BRIDGE_PORT in ports.splitlines():
                raise RuntimeError(f"{BRIDGE_PORT} is already in use.")
        if not args.dry_run:
            candidates = devices()
            if len(candidates) != 1:
                parser.error("Connect exactly one Maschine MK3 or Plus over USB.")
            pid, serial = candidates.pop()
            print(f"NI IPC: selected product {pid:04x}", flush=True)
            helper = subprocess.Popen(
                [ROOT / "ni-led-helper", "--led-only", f"{pid:x}", serial, "/dev/null"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            )
            for line in helper.stdout:
                print(line.rstrip(), flush=True)
                if json.loads(line).get("event") == "ready":
                    break
            else:
                raise RuntimeError("The NI agent did not open a LED session.")

            def report():
                for line in helper.stdout:
                    print(line.rstrip(), flush=True)
                    event = json.loads(line)
                    if monitor and monitor.stdin and (message := pad_input(event, inputs)):
                        try:
                            monitor.stdin.write(message)
                            monitor.stdin.flush()
                        except OSError:
                            monitor.terminate()
                            break
                    if event.get("event") == "pad_led_update":
                        acknowledgements.put(event)
                acknowledgements.put(None)
                if monitor and monitor.poll() is None:
                    monitor.terminate()

            threading.Thread(target=report, daemon=True).start()

        command = [ROOT / "launchpad-probe", "--ipc-grid" if colors else "--mk3-dry-run"]
        if states is not None:
            command = [ROOT / "launchpad-probe", "--name", BRIDGE_PORT, "--no-reply", "--pad-input"]
        if args.demo:
            command.append("--self-test")
        monitor = subprocess.Popen(command, stdin=subprocess.PIPE if inputs else None,
                                   stdout=subprocess.PIPE, text=True)
        request_id = 0
        for line in monitor.stdout:
            print(line.rstrip(), flush=True)
            updates = native_updates(line, states) if states is not None else launchpad_updates(line, colors)
            for pad, value in updates:
                if pads[pad] == value:
                    continue
                pads[pad] = value
                request_id += 1
                print(f"NI LED request {request_id}: pad {pad + 1}, value {value}", flush=True)
                if helper:
                    send(helper, pads, request_id)
                    try:
                        result = acknowledgements.get(timeout=6)
                    except Empty as error:
                        raise RuntimeError("No LED acknowledgement from the NI helper.") from error
                    if not result or result.get("request_id") != request_id or not result.get("transport_success"):
                        raise RuntimeError("NI IPC LED send failed.")
                    if args.demo:
                        time.sleep(0.75)
        return monitor.wait()
    except KeyboardInterrupt:
        return 130
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Bridge error: {error}", flush=True)
        return 1
    finally:
        if monitor and monitor.poll() is None:
            monitor.terminate()
            monitor.wait()
        if helper:
            try:
                helper.stdin.write('{"quit":true}\n')
                helper.stdin.close()
                helper.wait(timeout=6)
            except (OSError, subprocess.TimeoutExpired):
                if helper.poll() is None:
                    helper.terminate()
                    helper.wait()


if __name__ == "__main__":
    raise SystemExit(main())

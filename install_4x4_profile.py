#!/usr/bin/env python3
"""Create a separately named profile from an existing local Melodics profile."""
import json

from maschine_profile_probe import BRIDGE_PORT, BRIDGE_PROFILE, PROFILE


def install_profile():
    if BRIDGE_PROFILE.is_file():
        return
    if not PROFILE.is_file():
        raise RuntimeError(
            "The local Melodics Maschine+ LED profile is missing "
            "(ni_maschine_plus.json). See the setup requirements in the README."
        )
    profile = json.loads(PROFILE.read_bytes())
    profile["name"] = BRIDGE_PORT
    for field in ("ports", "outports"):
        profile[field] = {"mac": BRIDGE_PORT, "win": BRIDGE_PORT}
    try:
        with BRIDGE_PROFILE.open("x", encoding="utf-8") as file:
            json.dump(profile, file, indent=2, ensure_ascii=False)
            file.write("\n")
    except FileExistsError:
        if not BRIDGE_PROFILE.is_file():
            raise


if __name__ == "__main__":
    install_profile()
    print(BRIDGE_PROFILE)

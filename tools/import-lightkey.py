#!/usr/bin/env python3
"""Turn a Lightkey project into Hope Lights' starting show.

    python3 -I tools/import-lightkey.py "Hope NEW - FINAL copy.lightkeyproj" > \
        Packages/LightsCore/Sources/LightsCore/Resources/DefaultShow.json

A .lightkeyproj is an NSKeyedArchiver plist. Each cue holds a list of
presets, and each preset's `fpStore` is another plist with, per fixture UUID,
the colour (16 bits per channel, packed into one integer) and the intensity.

Within a cue, intensity merges highest-takes-precedence and colour is the
last preset's that sets one. Lightkey names presets like "Pink, 0%": a colour
recorded at zero, with the level coming from a separate dimmer preset, so
reading them last-wins would leave most songs dark.

Only the Sunday cues are taken, in the order the church asked for. The first
of each duplicated name (WALK IN, MESSAGE…) is Sunday's; the second set is
Wednesday's.
"""
import json
import plistlib
import sys
import uuid

# Our light groups, by the fixture names in the Lightkey patch. Kept in step
# with Rig.hope in Rig.swift.
GROUPS = {
    "screenSlimpars": [f"U{i}" for i in range(1, 9)],
    "ceilingSlimpars": [f"U{i}" for i in range(9, 13)],
    "floorSlimpars": [f"U{i}" for i in range(13, 17)],
    "pixelStix": [f"P{i}" for i in range(1, 17)],
    "wallWash": ["B1", "B2", "B3", "B4"],
    "house": ["H36"] + [f"H{i}" for i in range(2, 36)],
    "frontWash": [f"DW{i}" for i in range(1, 7)],
    "rearWash": ["DW7", "DW8"],
    "stageSpots": ["E1", "E4"],
    "floorSpots": ["E2", "E3"],
    "blinders": ["BL1", "BL2", "BL3", "BL4"],
}
BRIGHTNESS_ONLY = {"frontWash", "rearWash", "stageSpots", "floorSpots", "blinders"}

# (Lightkey cue, our name, Screens position, Screens' default note).
# Screens' notes are LightingCueTable.defaults; a custom row added after them
# takes 73.
CUES = [
    ("WALK IN", "Walk-in", "walkIn", 60),
    ("COUNTDOWN", "Countdown", "countdown", 61),
    ("SONG 1", "Song 1", "song1", 62),
    ("WELCOME", "Announcements", "announcements", 67),
    ("SONG 2", "Song 2", "song2", 63),
    ("SONG 3", "Song 3", "song3", 64),
    ("SONG 4", "Song 4", "song4", 65),
    ("MESSAGE", "Message", "message", 68),
    ("SONG 5", "Song 5", "song5", 66),
    ("CLOSING", "Closing", "closing", 69),
    ("WALK OUT", "Walk Out", "walkout", 70),
    ("COMMUNION", "Communion", "communion", 72),
    ("BAPTISMS", "Baptisms", "baptism", 71),
    # No Recognition cue in Lightkey; Child Dedications is the nearest look.
    ("Child Dedications", "Recognition", "custom:Recognition", 73),
]


def main(path):
    archive = plistlib.load(open(path, "rb"))
    objects = archive["$objects"]

    def obj(ref):
        return objects[ref.data] if isinstance(ref, plistlib.UID) else ref

    def text(ref):
        value = obj(ref)
        if isinstance(value, dict) and "NS.string" in value:
            return obj(value["NS.string"])
        return value if isinstance(value, str) else None

    def items(ref):
        return [obj(x) for x in obj(ref)["NS.objects"]]

    def class_name(value):
        return objects[value["$class"].data]["$classname"] if isinstance(value, dict) and "$class" in value else None

    def uuid_of(ref):
        return str(uuid.UUID(bytes=obj(ref)["NS.uuidbytes"])).upper()

    fixture_names = {
        uuid_of(o["UUID"]): text(o["shortName"])
        for o in objects if class_name(o) == "LXDMXFixture"
    }

    def preset_values(preset):
        store = plistlib.loads(obj(preset["fpStore"]))["umbrellaContainers"]
        out = {}
        for fixture_uuid, container in store.items():
            features = container["definedFeatures"]
            if not features:
                continue
            segment = (container.get("segmentContainers") or [{}])[0]
            values = {}
            if "Color" in features:
                packed = segment.get("color", [0])[0]
                values["color"] = "#%02X%02X%02X" % ((packed >> 40) & 255, (packed >> 24) & 255, (packed >> 8) & 255)
            if "Intensity" in features:
                values["level"] = segment.get("intensity", container["fixtureContainer"].get("intensity", 0.0))
            out[fixture_names.get(fixture_uuid.upper(), fixture_uuid)] = values
        return out

    def cue_look(cue):
        presets = items(cue["presets"])
        orphans = obj(cue["orphanPresetsGroup"])
        presets += [p for p in items(orphans["childNodes"]) if class_name(p) == "LXPreset"]
        look = {}
        for preset in presets:
            for name, values in preset_values(preset).items():
                fixture = look.setdefault(name, {})
                if "color" in values:
                    fixture["color"] = values["color"]
                if "level" in values:
                    fixture["level"] = max(fixture.get("level", 0.0), values["level"])
        return look

    lightkey_cues = {}
    for o in objects:
        if class_name(o) == "LXCue":
            lightkey_cues.setdefault(text(o["name"]), o)

    show = {"version": 1, "cues": []}
    for lightkey_name, name, position, note in CUES:
        cue = lightkey_cues[lightkey_name]
        look = cue_look(cue)
        groups = {}
        for group, members in GROUPS.items():
            # The groups are uniform in this show; the first member speaks for all.
            values = look.get(members[0], {})
            entry = {"level": round(values.get("level", 0.0) * 100) / 100}
            if group not in BRIGHTNESS_ONLY:
                entry["color"] = values.get("color", "#FFFFFF")
            groups[group] = entry
        show["cues"].append({
            "id": position, "name": name, "screensPosition": position, "note": note,
            "fade": cue["fadeInDuration"], "looks": groups,
        })
    show["cues"].append({
        "id": "blackout", "name": "Blackout", "fade": 0.0,
        "looks": {g: ({"level": 0.0} if g in BRIGHTNESS_ONLY else {"level": 0.0, "color": "#FFFFFF"}) for g in GROUPS},
    })
    json.dump(show, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1])

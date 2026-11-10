# Hope Lights

Hope Church's lighting app for the Mac. It replaces Lightkey for Sunday
services: one cue per part of the service, each with a colour and brightness
per group of lights and a fade time. Screens changes the cue as the service
moves.

## Using it

- **Go to a cue:** click ▶ next to it, or select it and press **Go** (⌘↩).
  The live cue is marked LIVE.
- **Change a cue:** select it, then set each group's colour and brightness.
  If the cue is live, the room changes as you drag.
- **Colour:** click a group's swatch for the church's colours, type a hex
  value (`#FF00E5`), or use More for the system colour picker. "Use on all
  SlimPARs" copies the colour to all three SlimPAR groups.
- **Match a slide:** drop a worship background or sermon slide (a picture or
  a video) on a cue, in the list or on the Picture box. The SlimPARs take its
  strongest colour, and the colours found in it appear beside the picture;
  click another one to use it instead.
- **Fade:** how long the cue takes to come up from whatever was showing.
- **Blackout:** the moon button in the toolbar (⇧⌘B).
- **Add Cue** starts a copy of the selected cue's look. Right-click a cue to
  duplicate or delete it, and drag cues to reorder them.

Lightkey must be closed while Hope Lights runs. Two programs sending to the
same lights make them flicker between the two. If the app hears another
console on the network, an orange bar names it.

Opening the app sends nothing until a cue is fired, so it never blacks out
a room something else is lighting. After a restart it fades back to the cue
that was live.

## Screens

Screens already sends a MIDI note when each plan item goes live: Walk-in 60,
Countdown 61, Song 1–5 62–66, Announcements 67, Message 68, Closing 69,
Walkout 70, Baptism 71, Communion 72. A row the church adds (Recognition)
gets 73. Hope Lights uses the same notes, so in Screens:

1. Open **Settings › Lightkey & MIDI**.
2. Choose **This Mac** if Hope Lights runs on the Screens Mac. Otherwise
   choose **Another Mac** and enter the address and port from Hope Lights'
   Settings › Screens.
3. Turn on **Change Lightkey scenes with the service**.
4. Use **Add Cue…** to add a **Recognition** row.

A cue's note shows under its name. **Learn** sets it from the next note that
arrives (press Send on that row in Screens). Songs past Song 5 use the
Song 5 cue; Screens does that itself.

## The rig

From the Lightkey project "Hope NEW - FINAL", sent as sACN (E1.31) on
universes 1 and 2, multicast on every network by default (Settings › Lights
picks one network or adds unicast node addresses).

| Group | Fixtures | Universe / address |
| --- | --- | --- |
| Screen SlimPARs | U1–U8, SlimPAR Pro H 12-ch | 1 / 90–185 |
| Ceiling SlimPARs | U9–U12 | 1 / 186–233 |
| Floor SlimPARs | U13–U16 | 1 / 234–281 |
| Pixel Stix | FX1 driver (7-ch) + P1–P16 (RGB) | 1 / 1–55 |
| Wall Wash | B1–B4, ProBar AR1.d | 1 / 60–83 |
| Blinders | BL1–BL4, ProBlind4 | 1 / 290–305 |
| Front Wash | DW1–DW6, ProWashPlus | 1 / 310–315 |
| Rear Wash | DW7–DW8 | 1 / 316–317 |
| Stage Spots | E1, E4, EVE E-50Z | 1 / 318, 327 |
| Floor Spots | E2, E3 | 1 / 321, 324 |
| House Lights | H36, H2–H35, COB Cannon Wash 5-ch | 2 / 1–175 |

The patch is `Rig.hope` in `Packages/LightsCore/Sources/LightsCore/Rig.swift`.

## Building

```bash
swift test --package-path Packages/LightsCore
```

```bash
xcodegen generate && open HopeLights.xcodeproj
```

```bash
scripts/release-dmg.sh
```

The DMG lands in `build/dist`. It is signed with the church's Developer ID
and notarized when a `notarization-profile` keychain profile exists.

The starting show (`Packages/LightsCore/Sources/LightsCore/Resources/DefaultShow.json`)
is generated from the Lightkey project:

```bash
python3 -I tools/import-lightkey.py "Hope NEW - FINAL copy.lightkeyproj" > Packages/LightsCore/Sources/LightsCore/Resources/DefaultShow.json
```

The running show is saved in `~/Library/Application Support/Hope Lights/`.

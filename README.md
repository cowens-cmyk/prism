# Prism

Hope Church's lighting app for the Mac. It replaces Lightkey for Sunday
services: one cue per part of the service, each with a colour and brightness
per group of lights and a fade time. Screens changes the cue as the service
moves.

## Using it

- **Saving:** every change saves by itself; there is no Save. The toolbar
  shows when it last saved. The show is also written to **Prism Show.json**
  on the Desktop each time, to back up or carry to another Mac: a Mac with
  no show of its own opens that file. macOS asks once to let Prism use the
  Desktop folder.

- **Go to a cue:** click ▶ next to it, or select it and press **Go** (⌘↩).
  The live cue is marked LIVE, and the right side switches to it whenever a
  cue goes up, from Screens or by hand.
- **Change a cue:** select it, then set each group's colour and brightness.
  If the cue is live, the room changes as you drag.
- **Colour:** click a group's swatch for the church's colours, type a hex
  value (`#FF00E5`), or use More for the system colour picker. "Use on all
  SlimPARs" copies the colour to all three SlimPAR groups.
- **Colour from a slide:** drop a worship background or sermon slide (a picture or
  a video) on a cue, in the list or on its drop box. The SlimPARs take its
  strongest colour, and the colours found in it appear beside the picture;
  click another one to use it instead.
- **Songs match Screens:** while a matching cue is live, the SlimPARs take
  the colour of Screens' live background, and follow it when the slide or
  its media changes (Prism reads what's live in Screens under a second
  apart; the background is fetched only when it changes) (a motion background's frame
  included) at the levels the cue sets. A dark or black-and-white
  background leaves the cue's own colour up. It isn't saved into the cue, since
  next week's song has another background; **Keep This Colour** saves it. A SlimPAR
  colour you pick yourself on a matching cue (a swatch, a dropped picture,
  Keep This Colour) is yours to keep: matching switches off for that cue,
  so the colour is still there the next time it goes up instead of going
  back to Screens' background. The cue's **Match Screens' background**
  switch turns it on again.
  It's on for the Song cues and the Countdown, and only those can match: the
  walk-in, announcements, message, closing, walk-out, Communion, baptisms,
  Recognition and Blackout keep their own colours. It needs
  Screens' access key in Settings, and the cue says so when it's missing; the switch under "Colour
  from a slide" turns it off or on for a song or the Countdown, on the live cue at once. A new key or
  address in Settings is used at once too. Go on the song that's already up
  (or Screens sending its note again) keeps Screens' colour. Needs Screens'
  Local API (see below).
- **Fade:** how long the cue takes to come up from whatever was showing.
- **Blackout:** the moon button in the toolbar (⇧⌘B) turns everything off
  at once, with no fade.
- **Add Cue** starts a copy of the selected cue's look. Right-click a cue to
  duplicate or delete it, and drag cues to reorder them. Delete asks first
  and names the Screens note that will stop working; there's no undo. The
  live cue and Blackout can't be deleted.

The window is dark grey, lit by a gradient of the colours on in the room,
and fades with the lights. Settings › Look switches to light.

Quitting while a cue is up asks first.

Lightkey must be closed while Prism runs. Two programs sending to the
same lights make them flicker between the two. If the app hears another
console on the network, an orange bar names it.

Opening the app sends nothing until a cue is fired, so it never blacks out
a room something else is lighting. After a restart it puts the cue that was
live straight back up, with no fade, so the room doesn't dip to black.

## Screens

Screens already sends a MIDI note when each plan item goes live: Walk-in 60,
Countdown 61, Song 1–5 62–66, Announcements 67, Message 68, Closing 69,
Walkout 70, Baptism 71, Communion 72. A row the church adds (Recognition)
gets 73. Prism uses the same notes, so in Screens:

1. Open **Settings › Integrations › Lightkey & MIDI**.
2. Choose **This Mac** if Prism runs on the Screens Mac. Otherwise
   choose **Another Mac** and enter the address and port from Prism's
   Settings › Screens.
3. Turn on **Change Lightkey scenes with the service**.
4. Use **Add Cue…** to add a **Recognition** row.
5. Prism listens on MIDI channel 16, Screens' default; Settings ›
   Screens › MIDI channel changes it. Notes on other channels are ignored,
   so a keyboard on the network can't fire Walk-in.

Screens sends a note only when a plan item goes live while presenting, not
when it's clicked in the plan. To check the link on its own, press **Send** on
a row of Screens' cue table: Prism should go to that cue. The status at the
top of Prism's window names the last cue Screens sent, or the channel Screens
is using if it isn't the one Prism listens on.

For songs to match their backgrounds, Prism reads the live
background from Screens' Local API (`GET /v1/show/frames/background`, in
Screens 0.28.0; Screens after 0.28.0 also skips a video's black opening):

1. In Screens: **Settings › Integrations › Remote & API**, turn it on.
2. **Manage Keys…**, create a **Watch** key named Prism.
3. In Prism: **Settings › Songs match Screens' background**, enter the
   Screens Mac (`127.0.0.1` on the same Mac, otherwise its address or
   `name.local`) and the key, and press **Check**. The key is kept in the
   keychain.

A cue's note shows beside it in the list. **Learn** sets it from the next
note that arrives (press Send on that row in Screens); it gives up after 30
seconds. Songs past Song 5 use the
Song 5 cue; Screens does that itself.

## Claude

Claude can run Prism: list and read cues, put one up, set colours,
brightness and fades, add, copy, move and delete cues, and turn following
Screens or sending to the lights on or off. Prism serves these as MCP tools
at `http://<this Mac>.local:6990/mcp`, behind a key.

1. In Prism: **Settings › Claude**, turn on **Let Claude control Prism**.
2. **Copy Setup Command**, and run it in Terminal on the Mac with Claude
   Code. It adds Prism for every folder (`--scope user`).
3. Ask Claude, e.g. "make the Song 2 SlimPARs purple at 70%".

The key is in the copied command; anyone with it can change the lights.
**New Key…** shuts out the old one. If the Mac's firewall is on, allow
Prism's incoming connections when macOS asks. Deleting a cue asks Claude
to check with you first, and the live cue and Blackout can't be deleted.

The tools are in `PrismTools.swift`; `MCPHost.swift` is the HTTP server.

## Updates

Prism checks GitHub Releases (`cowens-cmyk/prism`) at launch and every six
hours. A newer release shows in the Prism menu and Settings › Updates;
**Update** asks first (Later is the default), then downloads it, checks it's
signed by Hope Church's Developer ID, quits, swaps the app and reopens on the
cue that was up. Nothing installs by
itself. To release: bump `MARKETING_VERSION` in `project.yml`, commit, and
run `scripts/release-dmg.sh --publish`.

## The rig

From the Lightkey project "Hope NEW - FINAL", sent as sACN (E1.31) on
universes 1 and 2 at priority 150 (Lightkey's setting), multicast on every
network by default (Settings › Lights picks one network or adds unicast node
addresses).

| Group | Fixtures | Universe / address |
| --- | --- | --- |
| Screen SlimPARs | U1–U8, SlimPAR Pro H 12-ch (10% in the songs) | 1 / 90–185 |
| Ceiling SlimPARs | U9–U12 | 1 / 186–233 |
| Floor SlimPARs | U13–U16 | 1 / 234–281 |
| Pixel Stix | FX1 driver (7-ch) + P1–P16 (RGB) | 1 / 1–55 |
| Wall Wash | B1–B4, ProBar AR1.d | 1 / 60–83 |
| Blinders | BL1–BL4, ProBlind4, 1% in every cue but Blackout | 1 / 290–305 |
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
xcodegen generate && open Prism.xcodeproj
```

```bash
scripts/release-dmg.sh
```

The DMG lands in `build/dist`. The icon is drawn by
`swift tools/make-icon.swift App/Assets.xcassets/AppIcon.appiconset`. It is signed with the church's Developer ID
and notarized when a `notarization-profile` keychain profile exists.

The starting show (`Packages/LightsCore/Sources/LightsCore/Resources/DefaultShow.json`)
is generated from the Lightkey project:

```bash
python3 -I tools/import-lightkey.py "Hope NEW - FINAL copy.lightkeyproj" > Packages/LightsCore/Sources/LightsCore/Resources/DefaultShow.json
```

The running show is saved in `~/Library/Application Support/Prism/`,
with `Show-previous.json` as it was when the app last opened. A show file
that won't read is set aside as `Show-unreadable-….json`, not overwritten.

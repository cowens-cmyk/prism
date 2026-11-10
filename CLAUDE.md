# Hope Lights

The church's Mac lighting app, replacing Lightkey. Read `README.md` for what
it does and the rig. The church's operator doesn't want lighting jargon:
user-facing text is short, plain and factual.

## Layout

- `Packages/LightsCore` — everything testable: `Rig.swift` (fixture types,
  channel layouts, Hope's patch), `Show.swift` (cues, Screens' notes),
  `Engine.swift` (render, crossfade, the 40 Hz engine), `SACN.swift`
  (packets, sender, the monitor that spots Lightkey), `ImagePalette.swift`
  (colours from a picture or video), `ShowStore.swift` (the show on disk,
  MIDI note decoding).
- `App` — SwiftUI and CoreMIDI only. `AppModel` owns the engine; every edit
  goes through `AppModel.update(_:)`.
- `tools/import-lightkey.py` — regenerates `DefaultShow.json` from a
  `.lightkeyproj`.

## Don't break these

- **Never send sACN multicast from a test on a Mac that may be on the
  church's lighting network** — it changes the real lights. Test the app
  with Settings › Network set to a name that doesn't exist and unicast
  `127.0.0.1` (`defaults write org.hopejc.lights network -string none;
  defaults write org.hopejc.lights unicast -string 127.0.0.1`), and listen
  on 127.0.0.1:5568.
- The patch in `Rig.hope` matches the Lightkey project. The tests check the
  addresses; a change in the room changes both.
- Default notes follow Screens' `LightingCueTable.defaults`
  (`mxu-slides-main/apps/mac/Packages/PresenterCore/.../ServicePosition.swift`).
  Screens is the authority on notes; Hope Lights follows it.
- Nothing is sent until a cue has been fired. Opening the app must never
  black out the room.
- Intensity merges highest-wins when importing Lightkey cues (see the
  importer's docstring); reading presets last-wins leaves the songs dark.
- `Show.version` stays 1; new cue fields are optional.

## Build and test

```bash
swift test --package-path Packages/LightsCore --scratch-path /tmp/hl-core
```

```bash
xcodegen generate && xcodebuild -project HopeLights.xcodeproj -scheme HopeLights -derivedDataPath /tmp/hl-dd build
```

Keep derived data outside ~/Desktop (iCloud breaks codesign). Debug builds
open the first SlimPAR colour picker by themselves with `HL_OPEN_COLOR=1`,
for screenshots without UI scripting.

Docs stay current: a change to behaviour, the rig or the Screens hookup
updates `README.md` in the same commit.

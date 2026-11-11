# Prism

The church's Mac lighting app, replacing Lightkey. Read `README.md` for what
it does and the rig. The church's operator doesn't want lighting jargon:
user-facing text is short, plain and factual.

## Layout

- `Packages/LightsCore` — everything testable: `Rig.swift` (fixture types,
  channel layouts, Hope's patch), `Show.swift` (cues, Screens' notes),
  `Engine.swift` (render, crossfade, the 40 Hz engine), `SACN.swift`
  (packets, sender, the monitor that spots Lightkey), `ImagePalette.swift`
  (colours from a picture or video), `ShowStore.swift` (the show on disk,
  MIDI note decoding), `ScreensFollower.swift` (keeps a matching cue on
  Screens' live background), `PrismTools.swift` (Claude's MCP tools, over the
  `PrismControl` protocol the app model adopts), `MCPServer.swift` (JSON-RPC)
  and `MCPHost.swift` (the HTTP server on port 6990 and its key).
- `App` — SwiftUI and CoreMIDI only. `AppModel` owns the engine; every edit
  goes through `AppModel.update(_:)`.
- `tools/import-lightkey.py` — regenerates `DefaultShow.json` from a
  `.lightkeyproj`.

## Don't break these

- **Never send sACN multicast from a test on a Mac that may be on the
  church's lighting network** — it changes the real lights. Test the app
  with Settings › Network set to a name that doesn't exist and unicast
  `127.0.0.1` (`defaults write org.hopejc.prism network -string none;
  defaults write org.hopejc.prism unicast -string 127.0.0.1`), and listen
  on 127.0.0.1:5568.
- The patch in `Rig.hope` matches the Lightkey project. The tests check the
  addresses; a change in the room changes both.
- Default notes follow Screens' `LightingCueTable.defaults`
  (`mxu-slides-main/apps/mac/Packages/PresenterCore/.../ServicePosition.swift`).
  Screens is the authority on notes; Prism follows it.
- Nothing is sent until a cue has been fired. Opening the app must never
  black out the room. A relaunch restores the live cue with fade 0: the
  engine starts from a dark frame, so any fade dips the room to black first.
- Intensity merges highest-wins when importing Lightkey cues (see the
  importer's docstring); reading presets last-wins leaves the songs dark.
- `Show.version` stays 1; new cue fields are optional and decode
  leniently (`Cue.init(from:)`).
- The blinders sit at 1% in every cue but Blackout (`Show.blinderFloor`;
  the importer does the same, and a saved show is lifted once per Mac).
- The songs' SlimPARs start at 10% (`Show.songSlimparLevel`; the importer
  too). A saved show's songs still at Lightkey's 25% drop once per Mac.
- Claude's server answers nothing without the key, and is off until
  Settings › Claude turns it on. Every tool edits through
  `AppModel.editShow`, the same path as the window.
- Screens' colour on a matched song (`AppModel.screensColor`) is never
  written into the cue unless the operator presses Keep This Colour.
- Prism reads Screens' live slide while any cue is up, not only a matching
  one (`ScreensFollower.watch`), so a matching cue's note that lands before
  Screens changes slide doesn't take the previous slide's background.
- Blackout (id `blackout`) can't be deleted: the toolbar button and ⇧⌘B
  go to it.

## Build and test

```bash
swift test --package-path Packages/LightsCore --scratch-path /tmp/hl-core
```

```bash
xcodegen generate && xcodebuild -project Prism.xcodeproj -scheme Prism -derivedDataPath /tmp/hl-dd build
```

Keep derived data outside ~/Desktop (iCloud breaks codesign). UI scripting
isn't allowed on the dev Mac, so Debug builds take launch switches for
screenshots and tests: `HL_OPEN_COLOR=1` opens the first SlimPAR colour
picker, `HL_WINDOW=1300x1000` sizes the window, `HL_SCREENS_KEY=…` sets the
Screens key without the keychain, `HL_CLAUDE_KEY=…` and `HL_CLAUDE_PORT=…`
set Claude's key and port the same way. Quitting asks first while a cue is up, so
a test harness stops the app with `pkill -x "Prism"`.

Song matching needs Screens' `GET /v1/show/frames/background` (Screens
after 0.27.0, `LocalAPIBridgeAdapter.liveBackgroundJPEG`).

To test against the real Screens without touching the church library or
your phone-remote key, run Screens' Debug build with
`SCREENS_LIBRARY_ROOT=<empty folder> MXU_SKIP_KEYCHAIN=1` and
`-localAPI.enabled YES -lightkey.followService YES`, seed
`<folder>/local-api-tokens.json` with keys (salt hex + "$" +
sha256(salt + secret)), and drive it through `/mcp` and `/v1/show/slide`.
Export Screens' defaults first and put them back after.

Releases: bump `MARKETING_VERSION` in `project.yml`, commit, then
`scripts/release-dmg.sh --publish` (pushes main to github.com/cowens-cmyk/prism
and creates the release installed copies update from). Only when Cameron
asks for an update to go out.

Docs stay current: a change to behaviour, the rig or the Screens hookup
updates `README.md` in the same commit.

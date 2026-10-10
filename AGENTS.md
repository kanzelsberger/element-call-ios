# Mango engine distribution

This branch packages only ElementCallKit, ElementCallMatrix, and the existing logging port from ElementCallHost. Mango supplies its own call UI. The package can be linked by iOS 17 applications, but every media and transport declaration requires iOS 18. Hosts must guard initialization and use with an availability check. The upstream UI, design tokens, example app, and snapshot suites are excluded from this distribution. Joined-membership tests remain included.

The upstream guidance below describes the full distribution. Preserve its source boundaries when updating the engine subset.

# AGENTS.md — element-call-ios

> A native MatrixRTC call implementation for iOS, consumed by [element-x-ios] as a SwiftPM package.
> Written with substantial AI assistance, reviewed by a person before landing.
>
> **Keep this file current.** If a change makes a fact here wrong, fix the fact in the same pull
> request. If a change is not described here, leave the file alone.

[element-x-ios]: https://github.com/element-hq/element-x-ios

Read [CONTRIBUTING.md](CONTRIBUTING.md) too. This file is what an agent needs that a human already
knows, and what tends to go wrong.

---

## The four boundaries. Do not cross these.

| Module | May import | Contents |
| --- | --- | --- |
| `ElementCallKit` | the RTC core only | media, session, capture, render, keys |
| `ElementCallHost` | nothing beyond the above | call lifecycle, Picture in Picture, **the ports** |
| `ElementCallUI` | `CompoundDesignTokens` | stage, tiles, controls, minimized bar |
| `ElementCallMatrix` | `MatrixRustSDK` | turnkey transport, widget-driver stopgap |

1. **`MatrixRustSDK` only in `ElementCallMatrix`.** Everywhere else, go through
   `ElementCallMatrixTransportProtocol`.
2. **Never `import Compound`, in any module.** Its colours live on one shared instance the host
   re-brands at runtime; a copy linked here would never see the override and a re-branded host would
   get a stock-coloured call screen. `CompoundDesignTokens` is fine, being static values.
3. **No host logger, settings or strings.** Use `ElementCallLoggingProtocol`, `ElementCallOptions`,
   `ElementCallStrings`.
4. **Theme members are computed properties**, read at draw time. Never capture a colour.

SwiftLint enforces 1 and 2 at error severity. **If you need something from the host, add a port. Never
add a dependency.**

A fifth target, **`ElementCall`**, exists only to `@_exported import` the four above so a host takes
one dependency and writes one import. It contains no code and must never contain any: it is a product
convenience, not a fifth layer, and putting anything in it would put that thing outside every boundary
in the table. Note the lint rules read comments too — they have no `match_kinds` — so naming the Matrix
SDK in a comment anywhere outside `ElementCallMatrix` fails the build, and `Sources/ElementCall/` is
not on the excluded path.

**The bare name belongs to the umbrella, not to a layer.** It used to be the other way round — the
lifecycle-and-ports module was `ElementCall` and the umbrella was `ElementCallAll` — and hosts kept
asking why they had to import a name with no meaning. Do not undo that: `import ElementCall` is the
one line an integrating app writes. `ElementCallHost` is *not* the host's own module; it is the module
holding the ports a host implements, and `ElementCallCore` was rejected for it because `ElementCallKit`
sits below rather than above.

---

## Building and testing

```bash
# Once per machine: snapshots only compare on the pinned device, and there may be none yet.
xcrun simctl create "ElementCall Snapshots" "iPhone SE (3rd generation)" \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5

cd Tools/Sourcery && sourcery --config PreviewTestsConfig.yml && cd ../..

xcodebuild test -scheme ElementCall-Package \
  -destination "id=$SIMULATOR_UDID" \
  -testLanguage en -testRegion GB \
  OTHER_LDFLAGS='$(inherited) -ObjC'
```

Three flags are not optional, and each fails in a way that does not name its own cause:

- **`-ObjC`.** Library targets never link, so `swift build` passes without it and proves nothing. The
  test bundle links, then dies on launch with an unrecognised selector on `UIDevice`.
- **A concrete simulator by id.** A generic destination also builds an architecture the media
  xcframework has no slice for, and the link fails on missing symbols.
- **`-testLanguage en -testRegion GB`.** Snapshot names carry the locale. The harness asserts this and
  tells you what to pass.

`swift build` alone will fail: the package is iOS-only. Always go through `xcodebuild`.

**Lint before every commit, the way CI does, and in this order:**

```bash
swiftformat --lint .          # formatting; `swiftformat .` fixes it
swiftlint                     # the boundary rules at error severity; warnings are tolerated
```

CI runs both before it builds anything (`tests.yml`, "Lint"), on the same `brew` versions, and a
formatting difference fails the whole run before a single test has spoken. Neither is run for you
by a build or by Xcode, so a change that compiles and passes every test locally still fails CI if
this step was skipped. `swiftformat --lint` should report `0/N files require formatting`; if it
names a file, run `swiftformat .` and commit the result with the change, not as a follow-up.

The pinned device and OS live in `Tests/ElementCallTests/Support/SnapshotEnvironment.swift`. The
harness reads them and fails loudly when the simulator does not match. **The workflows do not read
them**, despite the comment in `tests.yml` saying so: `XCODE_APP`, `SIMULATOR_NAME` and
`SIMULATOR_RUNTIME` are duplicated literals in both workflow files, so changing the pinned device is
three edits, not one. `release.yml` is deliberately not a fourth: it runs on Linux and gates on the
`Tests` run for the commit rather than testing anything itself, and the example harness below is not
a fourth either: it is a step in the same `Tests` job and reuses the simulator that job creates.

### The example harness and the UI tests

`Example/` is a sample app over the port fakes, and the UI tests that drive it. It exists for one
reason: **a gesture is the one thing the package's own tests cannot reach.** Everything else runs
in-process, but a double tap that is declared correctly and never arrives, because something above
the tile claimed the touch first, looks identical to a working one from inside. Only a real touch
tells them apart, and only XCUITest can send one, which needs an application and so a project.

```bash
brew install xcodegen                       # once per machine
cd Example && xcodegen generate && cd ..
xcodebuild test -project Example/ElementCallExample.xcodeproj \
  -scheme ElementCallExample \
  -destination "id=$SIMULATOR_UDID"
```

- **The project is generated, not committed.** `Example/project.yml` is what gets reviewed and
  `Example/*.xcodeproj` is ignored, for the same reason `GeneratedPreviewTests.swift` is regenerated
  in CI: nobody reads a pbxproj and everybody conflicts on one. The app target needs the same
  `-ObjC` the package's test bundle does, for the same reason.
- **No server, no camera, no call.** The app builds its connected screens from
  `ElementCallPreviewFixtures` through `ElementCallHarnessScreen`, which is the seam the previews
  have always used, made public. `ElementCallController.fake(...)` cannot serve for those: it never
  joins, so it produces no tiles and the screen would be a spinner. It serves for everything else,
  though — the connecting states run a real `ElementCallScreenViewModel` over one, and the minimized
  bar is drawn from one, which needs only a room name, a style and a duration. Two things a fake
  cannot know: the mic glyph reads through `call`, which is nil, so the bar always shows unmuted;
  and `connectedAt` has to be passed in, which is why `fake(...)` takes it.
- **The app opens on a catalogue of fixtures, and minimizes back to it.** `-fixture <key>`
  skips the catalogue and opens that fixture directly, and `-scenario <name>` plays a scenario
  file, so a test starts where it means to rather than tapping its way there — with the argument
  present the view hierarchy is what it was before the catalogue existed, which is what keeps the older UI tests looking at the tree they were
  written against. The argument used to fall back to the group arrangement on anything it did not
  recognise, so a typo failed a grid test with "this tile is not hittable", true and about nothing;
  an unrecognised name now names itself on screen instead, where the failure screenshot catches it.
  **The fixture list is shared with Android's sample**: keys, rosters and flags come from
  `element-call-feature-hq/harness/fixtures.md`, so one key opens the same call on both phones.
  Change a fixture there first, then here and on Android.
- **Minimizing goes to `ElementCallMinimizedBar`, not to a system window, and that is honest rather
  than a shortcut.** `ElementCallPictureInPictureController` builds its `AVPictureInPictureController`
  only in `bind(call:spotlightProvider:)`, and that needs a live call which cannot exist here, so
  `isPossible` is false, `requestMinimize()` takes its `else` branch and reports
  `pictureInPictureUnavailable` — the documented path a host takes when the window is not available.
  The harness is the only place that path, and that public view, are exercised at all. **Do not add
  `UIBackgroundModes` to `Example/project.yml` trying to make real Picture in Picture work here**: it
  would not, without a call, and simulator Picture in Picture is unreliable besides. Note this is
  where iOS and Android differ rather than where iOS is behind: Android's `enterPictureInPictureMode`
  shrinks the whole Activity, so the fixture list behind it is revealed for free, while AVKit leaves
  our window alone and renders a separate one — so taking the call screen down is the host's job
  either way, and only the minimized representation would change.
- **Put a test here only if it needs a real touch.** Arrangement belongs in
  `ElementCallStageLayoutTests`, appearance in the snapshots, and geometry in a unit test: a UI test
  is twenty seconds against their twenty milliseconds. What earns its place is gesture arbitration —
  the scroller's pan against the spotlight's swipe and a tile's pan, and the `Button` inside a tile — and the minimize
  round trip, which is three real-touch questions at once: whether the identifier reaches a view at
  all, whether the button in the top bar wins the touch, and whether the bar is hittable where a
  host puts it. Which branch the controller takes when asked to minimize is *not* one of them; that
  is `MinimizeRoutingTests`, in process, in milliseconds.
- **Every tile with video draws real frames**, from `MatrixRTCTestPattern` (the `video` fixture is
  the one built for looking at them): colour bars with a
  heavy border, because the questions are geometric. A border running off the edges is a crop, a
  border with black beside it is a letterbox, and a border that changes thickness partway through a
  move is the picture being stretched rather than redrawn. Some members are portrait sources and
  some landscape, so both answers are on the stage at once. It reaches the tiles through
  `ElementCallPreviewVideo`, an environment value consulted only where there is no call — nil in
  every shipping build.
  
  Keep it honest, or it is worse than nothing. The pattern is generated a row at a time, one frame
  per size is shared by every tile that wants it, and frames are made on a dispatch timer off the
  main thread, as a decoder's are. A run loop timer on main either stopped during a touch or
  charged every scroll with work the app never does.
- **`twoHundred` is the scale fixture, and `ScrollPerformanceUITests` flings it.** The test runs only
  on a device, in a Release build (`-configuration Release`); on the simulator it skips. It reports
  the system's scroll hitch metrics and asserts nothing. For attribution, record an `xctrace` Time
  Profiler or Animation Hitches trace with `--all-processes` while it runs.
- **Exact geometry is still pinned by `VideoPresentationTests`**, which asserts on the vertex
  transform. The harness is for looking; a test that compares pictures would only be approximate
  where that one is exact.
- **The spotlight's swipe is a UIKit pan, on purpose.** A SwiftUI `DragGesture`, high priority or
  not, does not stop the scroller's pan: the UI test that drags the spotlight and expects the grid
  to stay put moved it by a screen. `ElementCallSpotlightPanGesture` is a
  `UIGestureRecognizerRepresentable` whose delegate makes the scroll view's pan wait for it to
  fail, which is the only thing that keeps a drag starting on the spotlight off the grid.

- **A glass button is interactive glass, always.** Plain `glassEffect` is not wired for touch: a
  plain-glass button drawn over the stage's content took no taps, on the simulator and on a phone,
  and the double tap fell through to the tile beneath. Outside the scroller it happened to work,
  which is why the control bar did not show it. `elementCallGlass(..., isInteractive: true)`.

### The scenario dumps

Every hard rule in the layout spec is a transition — a promotion while scrolled, a hero leaving, a
tile crossing the band edge — or a claim about what the media plane was asked for during one, and
neither is visible in a still. `Tests/ElementCallTests/Scenarios/*.txt` is a corpus of timelines
vendored from feature-hq (`plans/003.call_layout/scenarios/`, whose README has the grammar; hq is
the source of truth and a copy that differs is a review finding). `StageDumpScenarioTests` runs
each one through the real call over `MatrixRTCScriptedSession`, a real `ElementCallScreenViewModel`
and the real arrangement, on `MatrixRTCManualClock`, and snapshots one text block per frame with
the declared detail window, what is composed and subscribed, and one line per tile. **Read a
recorded dump against the scenario's comments before accepting it**; a diff in `slot`, `vis`,
`detail`, `window` or `constraints` is a finding, a point or two in `rect` is rounding.

Re-record one by deleting its `.txt` under `__Snapshots__/StageDumpScenarioTests/` and running the
suite with a **fresh build**: `test-without-building` reuses the previously bundled corpus, so an
edited scenario records the old text. The marker file works for these too. **Delete, never
rewrite by hand**: macOS tags a file with the provenance of the application that created it, and
the simulator's test runner cannot open a reference written by another application — a dump
copied into place from an agent's shell fails every run with "you don't have permission to view
it", while the same bytes recorded by the runner pass. That includes `git` run from such a shell:
a checkout or rebase there rewrites the references with the shell's provenance, and the whole
suite fails on identical bytes until the runner has recorded them once. `git diff` on the directory
after that recording run tells the two apart: empty means provenance, anything else is a finding.

The call's timers — the share intent timeout, the release linger, the audio level flush, the stats
poll, and the video source's idle linger in `VideoFrameSlot.swift` — all sleep on the injected
clock. A new `Task.sleep` in the Kit is a timer the scenarios cannot step past.

#### Running it by hand, and watching a move frame by frame

Open `Example/ElementCallExample.xcodeproj` and run it, or from the command line:

```bash
xcrun simctl install "$SIMULATOR_UDID" \
  "$(find ~/Library/Developer/Xcode/DerivedData -name ElementCallExample.app -path '*Debug-iphonesimulator*' | head -1)"
xcrun simctl launch "$SIMULATOR_UDID" io.element.call.example.ElementCallExample -fixture listen_mode
xcrun simctl launch "$SIMULATOR_UDID" io.element.call.example.ElementCallExample -scenario 002_listen_mode
```

Leave the flag off to get the catalogue and pick by hand; it is the bypass, not the only way in.

**This is the answer to "do I have to join a real call to see it?"** — you do not, for anything the
layout does. Which is most of what goes wrong: the arrangements, the chrome, and every animation
between them are the same code in the harness as in a host.

An animation is worth *seeing*, and the snapshots cannot: they are end states. Record the simulator
across a run and make a contact sheet of the moment:

```bash
xcrun simctl io "$SIMULATOR_UDID" recordVideo -f /tmp/run.mp4 &
xcodebuild test-without-building -project Example/ElementCallExample.xcodeproj \
  -scheme ElementCallExample -destination "id=$SIMULATOR_UDID" \
  -only-testing:ElementCallExampleUITests/TileFullscreenUITests/testDoubleTappingAgainComesBackToTheStage
kill -INT %1
ffmpeg -ss 9.4 -t 1.2 -i /tmp/run.mp4 -vf "fps=25,scale=260:-1,tile=6x5" -frames:v 1 /tmp/move.png
```

`build-for-testing` first, then `test-without-building`, or the recording is mostly a build. This is
how the z-order of the growing tile was checked: a tile going full screen has to be **above** the
ones it replaces, because they are leaving and a leaving view keeps its z position for as long as
its transition runs. At the grid's own zero the spotlight faded out on top of it all the way up.
`ElementCallStageLayout.fullscreenZIndex` and the test that pins it are what stop that returning.

### Re-recording snapshots

Touch the marker file and run the tests; the harness overwrites whatever no longer matches.

```bash
touch Tests/ElementCallTests/.record-snapshots
# then the xcodebuild command above, then remove the marker
```

**Prefer that to deleting the directory.** Deleting also works — the harness records whatever is
missing — but it re-records all 93 images rather than the few that changed, and PNG re-encoding is
not byte-identical across Xcode versions. The references are ordinary blobs rather than Git LFS
pointers (see CONTRIBUTING.md for why they must stay that way), so a wholesale re-record puts 6 MB
of new blobs in the repository permanently and buries the images a reviewer has to look at.

**Not `RECORD_FAILURES=true` on the command line.** The harness reads it from its own environment,
and nothing on an `xcodebuild` command line gets there: not a build setting, not the `TEST_RUNNER_`
prefix, not the calling shell. It works when set in a scheme, which is why it works from inside
Xcode. On the command line it does nothing, silently, and you conclude your change had no visual
effect. The marker file is what `record-snapshots.yml` uses, for this reason.

**The references show the flat control bar, not liquid glass.** `PreviewTests` renders every
preview with `elementCallGlassEnabled` off: an offscreen render of glass in a landscape frame comes
out entirely blank (every landscape image with the bar in it was white for a day before anyone
looked), and a reference of the fallback at least pins where the buttons are. Glass is checked on
a device. Do not "fix" a blank landscape reference by re-recording it.

`SnapshotEnvironment.renderDevices` is what each preview is rendered as, and the orientation is part
of it. Note the **iPad entry has always been landscape**: the snapshot library's bare `iPad10_2`
means `iPad10_2(.landscape)` while its bare `iPhoneX` means portrait. There is no iPad portrait
coverage.

---

## Releasing

A release is a **tag**, nothing more. Bare semver — `0.1.0`, `0.2.0-rc.1` — because that is what
SwiftPM matches a host's `exactVersion` against, and **nothing is bumped in a pull request**: there
is no `MARKETING_VERSION` and nobody edits a version by hand.

There is one version constant, `ElementCallVersion.current`, which the call screen shows so a bug
report can quote it. **`scripts/release.sh` stamps it**, in the same step that closes the
`## Unreleased` heading, so it lands inside the commit the release tags and a host resolving that tag
gets a tree that describes itself. The script fails the release if the rewrite does not take, and
`release.yml` names the file in its `git add` — the commit is path-explicit, not `git add -A`, so a
new generated file has to be named there or it never reaches the tag. On `main` between releases the
constant reads as the previous release, which is only ever visible in a build made from this
repository rather than from a tag.

The pipeline is `.github/workflows/release.yml` plus `scripts/release.sh`, which holds all of the
validation and never touches the remote so it can be rehearsed locally. Release notes come from the
`pr-` labels via `.github/release.yml`, and land in `CHANGES.md` inside the tagged commit.

Three things about it are easy to break by tidying:

- **Releases are cut from a `release/<version>` branch, never from `main`.** That is what keeps the
  whole pipeline on the built-in `GITHUB_TOKEN`: it pushes only to that unprotected branch and a new
  tag, and the changelog reaches `main` through an ordinary pull request. Pointing it at `main` would
  need a token that can bypass branch protection.
- **The newest release tag is read with `git tag --merged HEAD` and `versionsort.suffix=-`.** The
  first scopes it to the branch's own line of history, so a fix to an older line is neither refused
  for going backwards nor given notes generated against a release it does not contain. The second
  stops git ranking `0.2.0-rc.1` above `0.2.0`, which would make `previous_tag_name` the rc.
- **`CHANGES.md` keeps a `## Unreleased` heading**, which the release renames to `## <version> -
  <date>` before opening a fresh one. Hand-written entries there are carried into the released
  section above the generated list. Do not delete the heading; the release refuses without it.

**This package ships source, not a binary**, and that is a decision with reasons rather than a
limitation — `matrix-rust-rtc` ships an xcframework because it contains Rust, not because that is how
Swift packages are released. Do not add a `binaryTarget` or a build-and-attach step to the release
workflow. [RELEASING.md](RELEASING.md) has the reasoning and the trigger that would justify revisiting
it.

## What is temporary

`Sources/ElementCallMatrix/Widget/` drives the SDK's widget driver in process as a stand-in for
bindings the released SDK lacks: delayed events, a room-state feed, to-device messaging. It is
**scheduled for deletion**, and `WidgetMatrixBridge.swift`'s header lists the exact bindings that
retire it and the removal steps. Do not build new features on it, and do not let it leak past
`ElementCallSDKTransport`.

`openBridge` is the **only** place a bridge is created, deliberately. An earlier version had two
creation paths and only one wired up the to-device pump, so media keys reached nobody and every remote
tile went black. The bridge and its pump are one value now so the type system forbids that. Keep it
that way.

---

## Conventions

- Swift 6.2, main-actor isolation by default in every module, so do not add redundant `@MainActor`.
- **`@unchecked Sendable` is confined to `ElementCallKit/Media`**, where it appears about a dozen times
  and is deliberate: audio render callbacks, capture delegates and Metal draws run on threads the
  compiler cannot reason about, and actor hops there cost frames. Those types synchronise by hand.
  **Anywhere else it is banned**, including the other three modules. If concurrency fights you outside
  the media layer, the design is wrong.
- Never store a function value directly in a generic `Mutex`. Each `withLock` reabstracts and writes
  back one more thunk, so a per-frame callback overflows the stack after a few minutes. Box it in a
  struct.
- **Orientation is the shape of the space, never the size class.** `ElementCallStageLayout.Metrics`
  and `ElementCallView` both decide on `width > height` and must keep agreeing. An iPad in landscape
  has a *regular* vertical size class, so a size-class branch would lay its tiles out in portrait
  rows while its width says landscape.
- Follow the [Swift API Design Guidelines]: `ID` not `Id`, `URL` not `Url`.
- **Every port protocol ends in `Protocol`**, and this is a deliberate exception to those
  guidelines, which would have `ElementCallSystemProvidingProtocol` be `ElementCallSystemProviding`
  and `ElementCallRoomContextProtocol` be `ElementCallRoomContext`. The host asked for it: element-x-ios
  suffixes every protocol it owns, its Sourcery mock template derives a mock name by stripping
  `Protocol`, and the package's ports were the only unsuffixed protocols in files that otherwise
  carry the suffix throughout. Uniform rather than selective, so the rule can be stated in one line
  — including on the four that read as capabilities and so double up a little. **Do not "correct"
  these back**; the concrete types that implement them (`ElementCallTokenTheme`,
  `ElementCallSDKTransport`, the `ElementCallFake*` family) keep plain names, which is what makes the
  suffix carry information. So does a port that is a plain value rather than something a host
  implements — `ElementCallOptions` and `ElementCallStrings` are structs with every member defaulted,
  and the suffix would be a lie on them.
- `MatrixRTC*` prefixed types name **protocol** concepts and keep that prefix. `ElementCall*` names our
  own API. Note the casing: the initialism is uniform, per the API design guidelines below. The
  bindings' own module is `MatrixRtc`, spelled exactly that way, and `import MatrixRtc` plus the
  `MatrixRtc.`-qualified uses in `VideoFrameSlot.swift` are references to *it* rather than to us —
  a bulk re-casing must leave those alone, along with the bindings' `MatrixRtcFFI` and
  `MatrixRtcFfiError`. Nothing of ours may be called `MatrixRtc`.
- File headers come from `.swiftpm/xcode/xcshareddata/IDETemplateMacros.plist`. One copyright line.
- Previews for every main state, `PreviewProvider` not `#Preview`, conforming to `TestablePreview` so
  the snapshot cases generate.
- Accessibility identifiers on the call UI are **public API**: an external interop rig pins against
  them, and the UI tests in `Example/` now do too. A rename is a breaking change and its test will
  tell you so. Note that `control(for:)` derives a control's identifier from its *icon*, so a button
  borrowing another's glyph must set its own identifier explicitly or the two collide — which
  `AccessibilityIdentifierTests.distinctness` does not catch, since it only walks icons. **The top
  bar's buttons set theirs by hand**, because `control(for:)` is called only from
  `ElementCallControlsView.controlButton` and the top bar does not use it: a constant can exist, be
  pinned by name in the identifier tests, and still reach no view, so that nothing can find the
  button. That has now happened twice, to `more` and to `minimize`, and the spelling test cannot see
  it either time — only a UI test that taps the thing can.

[Swift API Design Guidelines]: https://www.swift.org/documentation/api-design-guidelines/

## Comments

Comment the **why**, never the what. Where a decision is not obvious from the code, the reason sits
next to it, including the reasons that were got wrong first, because those are the ones that get
re-broken. Several comments here are longer than usual for that reason; do not shorten them into
restatements of the code.

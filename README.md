# Rise & Grind

Rise & Grind is a native SwiftUI alarm app for iPhone. It uses AlarmKit to schedule app-owned alarms, EventKit to inspect the next operational morning, and an App Intent that a daily Shortcuts Personal Automation can run while the app is closed.

The default policy is:

- Grind Time: 5:30 AM
- Lock In: on
- Active days: every day
- Attack stack: six alarms, ten-minute cadence, with a final warning three minutes before Grind Time
- Sound pool: all 100 loop-authored, 29-second vocal tracks selected by default

## How the next Grind morning is decided

The operational-day boundary is one minute before Grind Time. Before that boundary, including after midnight, the current calendar morning remains the target. At the boundary, the target advances to the following morning. This prevents a post-midnight app launch from accidentally pushing the stack ahead by 24 hours.

Each automatic reconciliation follows one wake policy:

1. Check whether the next Grind morning is one of the configured Active Days. If it is not, cancel any stale Rise & Grind alarms.
2. Find that morning’s earliest future timed, non-cancelled Calendar event.
3. If it begins before Grind Time, anchor the attack stack to that meeting.
4. Otherwise, anchor the complete attack stack to Grind Time when **Lock In** is enabled.
5. Otherwise, cancel any stale Rise & Grind alarms because no attack stack is needed.

Six alarms with ten-minute spacing and a three-minute Final Warning fire at `T−50`, `T−40`, `T−30`, `T−20`, `T−10`, and `T−3`. The Final Warning can be one minute through the spacing interval; setting it equal to the interval produces a fully regular cadence. Each alarm rotates through a shuffled copy of the active sound pool.

After onboarding, the app reconciles automatically on launch or foreground, every 15 minutes while active, and shortly after any Grind Time, Lock In, Active Day, stack, or sound-pool change. Each run replaces the alarms and dismissal-recovery chains from the previous plan. On success, a changed Calendar leaves only the newly computed wake plan armed; if AlarmKit cannot clear an older alarm, the run reports that failure instead of silently claiming replacement. The nightly automation also posts its result: an earlier meeting reports the adjusted Grind Time, an ordinary Lock In run reports the armed Grind Time, and skipped or failed runs explain why no plan was armed.

The Grind tab can mute attacks for the next operational morning, seven operational mornings, or indefinitely. While muted, the app still computes the hypothetical stack for Calendar’s Upcoming Attacks list, renders those entries struck through, and keeps them out of AlarmKit.

## Product surfaces

- **Grind:** Grind Time and Lock In controls, Active Day selectors, a one-off Power Nap alarm, and the timed or indefinite Mute control.
- **Calendar:** next-morning preview, wake-target explanation, one chronological Upcoming Attacks list of armed, test, and struck-through muted attacks, and a control that clears armed alarms.
- **Stack:** alarm count, spacing, and Final Warning offset.
- **Sounds:** 100 built-in songs with fictional artist credits, compact genre labels, pool membership, continuous looping previews, and custom imports.
- **Setup:** required-access status, Shortcuts handoff, nightly-notification status, the last successful automatic run, and isolated one-minute-interval alarm tests.

Every alert presents a **WAKE UP, LOSER!** action. A system Stop-slider dismissal preserves that attack’s retry chain and schedules a replacement three seconds later; while the app process is observing AlarmKit updates, the same recovery applies to hardware-button dismissals. **WAKE UP, LOSER!** gives a non-final attack five seconds to foreground the app, then hands continuous playback to the squat challenge. A final attack has no foreground timeout, and its challenge sound cannot be stopped before the configured squat count is complete.

## Required onboarding

The app is gated until all operational setup is complete:

- AlarmKit authorization
- Calendar full access
- notification authorization for nightly results
- Motion & Fitness access and a usable squat calibration

If any required permission is later revoked, the app returns to the access gate. Photos imports use Apple’s scoped video picker, so broad Photo Library permission is neither requested nor required.

Apple does not let an app silently create or inspect a user’s Personal Automations. The automation is strongly recommended, but onboarding can be completed without it after acknowledging that late Calendar changes may be missed while the app is closed. The lowest-effort supported setup is presented inside onboarding:

1. Open Shortcuts from the in-app link.
2. Create a Daily, 9:00 PM, Run Immediately automation.
3. Add Rise & Grind’s **Prepare Tomorrow’s Barrage** action.
4. Return and confirm setup.

Rise & Grind also requests a best-effort `BGAppRefreshTask` opportunity about once per hour. iOS decides whether and when that task runs, so it supplements rather than replaces the nightly Personal Automation.

The intent records its last successful run so Setup can show whether it has ever executed, and it posts a notification with the resulting Grind Time or the reason no alarms were armed. Apple’s [Personal Automation guide](https://support.apple.com/guide/shortcuts/intro-to-personal-automation-apd690170742/ios) describes the system-owned workflow.

## Sound library

The checked-in library contains 100 original tracks generated with Google’s `lyria-3-clip-preview` model. Each track has a title, fictional artist, one-to-three-word genre label, complete authored lyrics, and a compact performed excerpt. The catalog ranges across abrasive or high-energy metal, punk, hardcore, hip hop, EDM, techno, disco, ska, big band, and experimental jazz. Twelve entries are explicitly adult, consensual female slut-pride anthems centered on sexual agency.

Every runtime asset in `RiseAndGrind/Resources/Sounds` is exactly 29 seconds and authored as a continuous loop instead of a song with a final cadence. Post-processing crossfades the boundary so AlarmKit can repeat it naturally, and the Sounds tab uses the same file for a continuous preview until playback is stopped or the user changes tabs. The compact phone-speaker format is mono, 44.1 kHz IMA4 audio in a CAF container, with each file under 800 KiB (the validator caps files at 800,000 bytes). All 100 tracks are selected by default.

There is deliberately no `RiseAndGrind/Resources/SoundMasters` directory or separate preview-master collection. The single validated CAF asset is the alarm and preview source for each built-in track.

The library’s reproducibility and provenance artifacts are:

- `RiseAndGrind/Resources/Sounds/manifest.json`: the runtime manifest, audio format, loop flags, titles, fictional artists, genres, lyrics, and default selection.
- `GeneratedSamples/RiseAndGrind_100_Alarm_Catalog.json`: the complete authored generation catalog and vocal direction for all 100 tracks.
- `GeneratedSamples/LyriaResponses/*.json`: per-track non-secret Lyria interaction metadata and timed-lyric evidence.
- `GeneratedSamples/LyriaResponses/verification.json`: duration, codec, sample count, file size, loudness, loop-seam, checksum, and generation evidence for every installed asset.

The reproducible generator uses the Gemini Interactions REST API documented in [Google’s Lyria documentation](https://ai.google.dev/gemini-api/docs/music-generation). Its validation requires the exact track count and duration, IMA4/CAF encoding, mono 44.1 kHz audio, bounded loudness and peak, the size limit, a bounded loop seam, and matching timed-lyric generation evidence.

Validate the checked-in library without an API call:

```sh
python3 scripts/generate_lyria_sounds.py --verify-only
```

Regenerate missing or invalid assets with a configured `GEMINI_API_KEY`:

```sh
python3 scripts/generate_lyria_sounds.py
```

Use `--force` to replace already-valid files, `--only SOUND_ID` to target one catalog entry, or `--workers N` to set generation concurrency. A complete generation run rewrites the manifest, catalog, and verification report and removes obsolete WAV, MP3, and text-only response artifacts.

## Custom imports

The Import menu offers two scoped sources:

- **Photos:** Apple’s picker is filtered to videos. A trim sheet lets the user choose the starting point and up to 29 seconds of video audio.
- **Files:** the document picker is limited to audio files.

Both paths copy security-scoped media into a temporary location, decode it with AVFoundation/Core Audio, and write an alarm-safe mono 44.1 kHz PCM WAV into the app’s `Library/Sounds` directory. DRM-protected or unreadable sources are rejected. Imported sounds are added to the active pool automatically.

## Build and verify

Requirements:

- Xcode 26.1 or newer with a compatible iOS 26 SDK
- XcodeGen 2.46 or newer
- iPhone running iOS 26.1 or newer

Run the complete local verification:

```sh
./scripts/verify_project.sh
```

That command regenerates the Xcode project, validates plists and asset catalogs, builds the portable core, runs behavioral checks, parses and format-lints every Swift source, delegates full CAF/library validation to the generator, checks every installed CAF with Apple’s audio tooling, and performs an unsigned iOS build.

The core suite verifies:

- the configurable Final Warning breaks cadence at the requested offset
- sound-pool rotation is deterministic for a supplied pool
- default and selected Active Day scheduling behavior
- a meeting exactly at Grind Time is not considered early
- a meeting one minute before Grind Time is early
- invalid/past plans fail as a complete transaction

To build and install from Xcode, open `RiseAndGrind.xcodeproj`, select the RiseAndGrind target, choose the development team, select the connected iPhone, and press Run. The deterministic source of project settings is `project.yml`; regenerate after changing it:

```sh
xcodegen generate --spec project.yml
```

## Platform boundaries

- Rise & Grind schedules its own AlarmKit alarms. It cannot create, edit, or enumerate alarms inside Apple’s Clock app.
- Alarm playback and alert loudness are system-controlled. The app cannot force maximum volume or disable hardware dismissal controls. Instead, its Stop intent schedules a replacement after three seconds, and `alarmUpdates` supplies the same fallback for observable external dismissals while the app process is running.
- AlarmKit accepts its default sound or a named local supported file, not an unattended Apple Music or Spotify stream.
- The nightly wall-clock trigger belongs to Shortcuts. iOS background tasks do not guarantee an exact daily execution time, and apps cannot silently create Personal Automations.
- No conventional snooze is supplied: Stop is deliberately wired as a three-second false snooze.

See Apple’s [AlarmKit documentation](https://developer.apple.com/documentation/alarmkit), [EventKit documentation](https://developer.apple.com/documentation/eventkit/ekeventstore), and [App Intent background-mode documentation](https://developer.apple.com/documentation/appintents/appintent/supportedmodes).

## Source layout

```text
RiseAndGrind/
├── Core/
│   ├── Checks/                  # dependency-free planning checks
│   ├── Sources/RiseAndGrindCore # models and date planning
│   └── Tests/                   # XCTest coverage
├── RiseAndGrind/
│   ├── App/                     # entry point, observable model, theme
│   ├── Intents/                 # nightly background App Intent
│   ├── Resources/               # artwork and 100 AlarmKit-ready CAF loops
│   ├── Services/                # AlarmKit, EventKit, media, persistence
│   ├── Views/                   # onboarding and five product tabs
│   └── PrivacyInfo.xcprivacy
├── GeneratedSamples/            # authored catalog and Lyria/verification evidence
├── scripts/                     # Lyria catalog, generator, and verification
├── Package.swift
├── RiseAndGrind.xcodeproj       # generated by XcodeGen
└── project.yml                  # project source of truth
```

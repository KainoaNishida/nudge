# Nudge

Nudge is a macOS-first conversation assistant prototype. This repository currently contains the native SwiftPM vertical slice: a menu bar app, onboarding/settings, local SQLite persistence, Apple Messages read-only import, bundled sample conversation import, permission health, goal-aware managed AI behind invited access, and local suggestion lifecycle actions.

The managed implementation, verification commands, and remaining deployment inputs are documented in [Managed AI rollout](docs/managed-ai-rollout.md).

## Current Build Slice

- `Nudge`: macOS menu bar executable.
- `MinderCore`: models, SQLite store, Messages/sample importers, permission/profile state, Gemini client, fallback suggestion generator, and suggestion lifecycle.
- `MinderCoreTests`: import, persistence, state transition, permission/profile, source connector, and Gemini structured-output parser tests.
- `docs/`: product and technical planning documents.

## Using Nudge

Nudge runs as a menu bar app with a tiny pixel cat on the desktop. Click either the cat or the menu bar item to open the movable queue window. Drag the cat anywhere on a screen; it can also appear over other apps' full-screen Spaces.

For realistic first-run behavior, use the packaged development app instead of `swift run`:

```sh
scripts/build-dev-app.sh
```

This builds and opens `.build/NudgeDev/Nudge.app`. Keep using that same app bundle when granting macOS permissions so Full Disk Access, Notifications, Contacts, Calendar, and Reminders attach to `Nudge.app`.

### First Setup

1. Launch Nudge.
2. Open the setup window if it is not already visible.
3. In `Settings`, follow the setup steps from `Welcome` through `Summary`.
4. In `Messages`, click `Open System Settings`, then enable Nudge in `Privacy & Security > Full Disk Access`.
5. Reopen Nudge if macOS asks you to restart the app.
6. Return to `Settings > Messages` and click `Import Messages`.
7. Optional: request Contacts access so imported Messages can show names instead of phone numbers or email addresses.
8. In `Pixel cat`, choose the screen, edge, alert timing, and quiet hours. `Quiet` keeps background refreshes on without making the cat alert.
9. Click `Finish Setup`.

Messages import is read-only. Nudge copies the last 30 days of local Messages into its own SQLite cache, then focuses active alerts on recent conversations that may need a reply, reminder, deadline follow-up, or other completion.

### Working the Queue

- Use `Refresh` to recheck Apple Messages and regenerate alerts.
- The `Queue` tab shows one active item at a time. Use the left and right arrow buttons to move through the queue.
- Each alert card shows the conversation, suggested action, and recent message context.
- Click `Open in Messages` on a conversation card or completed thread to open it in the Mac’s Messages app. Opening a conversation leaves its Done status unchanged. Sample items without an original Messages identifier have this button disabled.
- Group conversation links use an undocumented macOS Messages route, so navigation can vary between macOS versions.
- Click `Done` when the conversation no longer needs action.
- The `Done` tab shows recently completed items for 48 hours and lets you undo a completion.
- The status button in the footer opens the setting most likely to fix missing or degraded setup.
- Use the power button in the header to quit Nudge.

After setup, Nudge also runs a background refresh every 15 minutes while the app is open. The cat shows a generic “New updates!” bubble only when an actionable conversation is newly accepted or substantively updated. It does not show names or message text. Mac notifications are disabled while the pet is the notifier.
Hover over the cat to reveal its X. The X hides it until you turn **Show the pixel cat** back on in Settings; the menu bar item still opens Nudge.

### Settings and Privacy

- `Status` summarizes whether Messages import and core permissions are healthy.
- `Messages` manages Full Disk Access, recent import, and optional Contacts access.
- `Pixel cat` controls visibility, size, screen, optional edge placement, manual screen-sharing pause, a one-hour hide, cadence, and quiet hours. Size changes take effect immediately. Dragging the cat moves it freely and saves its position.
- `AI` offers local-only compatibility mode and invited managed AI with an optional goal, email-code sign-in, and explicit data-sharing consent.
- `Theme` changes the accent color used by the queue and setup screens.
- `Privacy` can delete generated suggestions, imported Messages cache, or all local Nudge data.

## Development Prerequisite

Swift/Xcode commands on this machine currently require accepting the Xcode license:

```sh
sudo xcodebuild -license
```

After accepting the license, run:

```sh
swift test
swift run Nudge
```

For realistic macOS permission prompts, build and launch the development app bundle:

```sh
scripts/build-dev-app.sh
```

The script creates `.build/NudgeDev/Nudge.app`, includes the SwiftPM resources and usage-description metadata, ad-hoc signs when possible, and launches it with `open`. Use this app bundle when granting Full Disk Access or testing Notifications, Calendar, and Reminders prompts.

## Managed AI Configuration

The app requires `NUDGE_SUPABASE_URL` and `NUDGE_SUPABASE_PUBLISHABLE_KEY` at development launch or packaging time. The Gemini key stays in Supabase Edge Function secrets. Users sign in with an invited email and accept the new disclosure in AI settings. Local-only mode remains available without credentials.

See [managed AI rollout](docs/managed-ai-rollout.md) for development/alpha setup, SMTP, spending controls, synthetic evaluation and release gates. Old `.nudge.env` Gemini credentials are retained for legacy diagnostics; they do not enable the managed pipeline.

## Alpha Packaging

The trusted-alpha channel uses a separate bundle ID and local data path:

```sh
NUDGE_DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
NUDGE_NOTARYTOOL_PROFILE="nudge-notary" \
scripts/build-alpha-dmg.sh
```

Without signing/notary environment variables, the script still builds `.build/NudgeAlpha/Nudge.app` and packages `.build/NudgeAlpha/Nudge-alpha.dmg` with ad-hoc signing for local verification. Alpha data is stored under `~/Library/Application Support/NudgeAlpha/`.

## Onboarding and Permissions

First launch opens a setup window for the user profile and core permission health. The current SwiftPM build performs best-effort checks for:

- Full Disk Access / Apple Messages: validated by attempting to read `~/Library/Messages/chat.db`; import is read-only. Managed AI scans the selected local history window (50 days by default, adjustable from 7 to 180 days) and sends a bounded recent excerpt per thread; local-only compatibility retains its earlier heuristics.
- Contacts: optional local-only name matching so Messages can show names instead of phone numbers or email handles.
- System notifications: no longer used for queue alerts; the pixel cat replaces them in this version.
- Calendar: status is checked through EventKit; in-app prompts are disabled under `swift run` and should be requested from a packaged app.
- Reminders: status is checked through EventKit; in-app prompts are disabled under `swift run` and should be requested from a packaged app.

`swift run Nudge` remains useful for quick development, but macOS APIs that require a real bundle either report unsupported or behave as best-effort checks. Use `scripts/build-dev-app.sh` for realistic prompts and Full Disk Access assignment to `Nudge.app`.

## Dev Data

The app stores local development data at:

```text
~/Library/Application Support/NudgeDev/nudge.sqlite
```

On first launch after the rename, Nudge copies existing development data from `~/Library/Application Support/LoopDev/loop.sqlite`, then falls back to `~/Library/Application Support/MinderDev/minder.sqlite`, if the new database does not exist yet.

The alpha app uses:

```text
~/Library/Application Support/NudgeAlpha/nudge.sqlite
```

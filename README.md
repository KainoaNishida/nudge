# Nudge

Nudge is a macOS-first conversation assistant prototype. This repository currently contains the native SwiftPM vertical slice: a menu bar app, onboarding/settings, local SQLite persistence, Apple Messages read-only import, bundled sample conversation import, permission health, optional Gemini structured suggestion generation, and local suggestion lifecycle actions.

## Current Build Slice

- `Nudge`: macOS menu bar executable.
- `MinderCore`: models, SQLite store, Messages/sample importers, permission/profile state, Gemini client, fallback suggestion generator, and suggestion lifecycle.
- `MinderCoreTests`: import, persistence, state transition, permission/profile, source connector, and Gemini structured-output parser tests.
- `docs/`: product and technical planning documents.

## Using Nudge

Nudge runs as a menu bar app. After launch, click the checklist icon or the `Nudge` title in the macOS menu bar to open the queue.

For realistic first-run behavior, use the packaged development app instead of `swift run`:

```sh
scripts/build-dev-app.sh
```

This builds and opens `.build/NudgeDev/Nudge.app`. Keep using that same app bundle when granting macOS permissions so Full Disk Access, Notifications, Contacts, Calendar, and Reminders attach to `Nudge.app`.

### First Setup

1. Launch Nudge.
2. Open the menu bar popover if it is not already visible.
3. In `Settings`, follow the setup steps from `Welcome` through `Summary`.
4. In `Messages`, click `Open System Settings`, then enable Nudge in `Privacy & Security > Full Disk Access`.
5. Reopen Nudge if macOS asks you to restart the app.
6. Return to `Settings > Messages` and click `Import Messages`.
7. Optional: request Contacts access so imported Messages can show names instead of phone numbers or email addresses.
8. Optional: enable Notifications and choose an alert timing. `Quiet` keeps background refreshes on but suppresses system notifications.
9. Click `Finish Setup`.

Messages import is read-only. Nudge copies the last 30 days of local Messages into its own SQLite cache, then focuses active alerts on recent conversations that may need a reply, reminder, deadline follow-up, or other completion.

### Working the Queue

- Use `Refresh` to recheck Apple Messages and regenerate alerts.
- The `Queue` tab shows one active item at a time. Use the left and right arrow buttons to move through the queue.
- Each alert card shows the conversation, suggested action, and recent message context.
- Click `Done` when the conversation no longer needs action.
- The `Done` tab shows recently completed items for 48 hours and lets you undo a completion.
- The status button in the footer opens the setting most likely to fix missing or degraded setup.
- Use the power button in the header to quit Nudge.

After setup, Nudge also runs a background refresh every 15 minutes while the app is open. Background notifications appear only for genuinely new alerts when notifications are enabled.

### Settings and Privacy

- `Status` summarizes whether Messages import, permissions, and notifications are healthy.
- `Messages` manages Full Disk Access, recent import, and optional Contacts access.
- `Notifications` controls notification permission, cadence, and quiet hours.
- `AI` keeps local suggestions on by default. Gemini is used only after credentials are saved and Cloud AI is enabled.
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

## Gemini Configuration

Gemini is optional for the first slice. If `GEMINI_API_KEY` is missing, Nudge uses local heuristic suggestions. If credentials are present, cloud suggestions still remain off until the user enables Cloud AI in onboarding.

```sh
export GEMINI_API_KEY="..."
export GEMINI_MODEL="gemini-2.5-flash" # optional; defaults to gemini-2.5-flash
swift run Nudge
```

For local development, the app also reads `GEMINI_API_KEY` and `GEMINI_MODEL` from a repo-local `.env` file or `~/.nudge.env`. `.env` files are ignored by git. Existing `~/.loop.env` and `~/.minder.env` files are still read as legacy fallbacks.

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

- Full Disk Access / Apple Messages: validated by attempting to read `~/Library/Messages/chat.db`; import is read-only, keeps 30 days for context, and focuses active alerts on the last 7 days.
- Contacts: optional local-only name matching so Messages can show names instead of phone numbers or email handles.
- Notifications: shown as unsupported under `swift run` because UserNotifications requires a packaged `.app` bundle.
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

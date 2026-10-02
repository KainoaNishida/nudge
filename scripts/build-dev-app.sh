#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/debug"
APP_DIR="$ROOT_DIR/.build/NudgeDev/Nudge.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_STAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

quit_running_nudge_dev() {
  if ! command -v pgrep >/dev/null 2>&1; then
    return
  fi

  local pids
  pids="$(running_nudge_dev_pids)"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "Closing running NudgeDev before rebuilding..."
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'tell application id "com.kainoanishida.nudge.dev" to quit' >/dev/null 2>&1 || true
    osascript -e 'tell application id "com.kainoanishida.loop.dev" to quit' >/dev/null 2>&1 || true
  fi

  for _ in {1..30}; do
    pids="$(running_nudge_dev_pids)"
    if [[ -z "$pids" ]]; then
      return
    fi
    sleep 0.1
  done

  pids="$(running_nudge_dev_pids)"
  if [[ -n "$pids" ]]; then
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      kill "$pid" >/dev/null 2>&1 || true
    done <<< "$pids"
  fi
}

running_nudge_dev_pids() {
  while read -r pid; do
    [[ -n "$pid" ]] || continue

    local command_path
    command_path="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    command_path="${command_path%% *}"

    case "$command_path" in
      */Nudge.app/Contents/MacOS/Nudge)
        local app_path
        app_path="${command_path%/Contents/MacOS/Nudge}"

        local bundle_id
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$bundle_id" == "com.kainoanishida.nudge.dev" ]]; then
          echo "$pid"
        fi
        ;;
      */Loop.app/Contents/MacOS/Loop)
        local app_path
        app_path="${command_path%/Contents/MacOS/Loop}"

        local bundle_id
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$bundle_id" == "com.kainoanishida.loop.dev" ]]; then
          echo "$pid"
        fi
        ;;
    esac
  done < <({ pgrep -x Nudge 2>/dev/null || true; pgrep -x Loop 2>/dev/null || true; } | sort -u)
}

cd "$ROOT_DIR"
if [[ "${NUDGE_SKIP_QUIT:-0}" != "1" ]]; then
  quit_running_nudge_dev
fi
swift build --product Nudge -Xswiftc -DNUDGE_INTERNAL_DIAGNOSTICS

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/Nudge" "$MACOS_DIR/Nudge"
if [[ -d "$BUILD_DIR/Nudge_MinderCore.bundle" ]]; then
  cp -R "$BUILD_DIR/Nudge_MinderCore.bundle" "$RESOURCES_DIR/Nudge_MinderCore.bundle"
elif [[ -d "$BUILD_DIR/Minder_MinderCore.bundle" ]]; then
  cp -R "$BUILD_DIR/Minder_MinderCore.bundle" "$RESOURCES_DIR/Minder_MinderCore.bundle"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Nudge</string>
  <key>CFBundleIdentifier</key>
  <string>com.kainoanishida.nudge.dev</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Nudge</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NudgeReleaseChannel</key>
  <string>dev</string>
  <key>NudgeDevBuildStamp</key>
  <string>$BUILD_STAMP</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Nudge creates calendar events only after you confirm a suggested event.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Nudge creates calendar events only after you confirm a suggested event.</string>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
  <string>Nudge asks for write-only calendar access to save confirmed event drafts.</string>
  <key>NSContactsUsageDescription</key>
  <string>Nudge uses Contacts locally to show names instead of phone numbers or email handles in imported Messages.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Nudge creates reminders only after you confirm a suggested reminder.</string>
</dict>
</plist>
PLIST

python3 "$ROOT_DIR/scripts/configure-managed-build.py" "$CONTENTS_DIR/Info.plist"

chmod +x "$MACOS_DIR/Nudge"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "Built $APP_DIR"
if [[ "${NUDGE_SKIP_OPEN:-${MINDER_SKIP_OPEN:-0}}" != "1" ]]; then
  open -n "$APP_DIR"
fi

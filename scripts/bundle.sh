#!/bin/bash
# Builds MeetingNotes.app so macOS attributes mic / system-audio permissions
# to the app itself (bare SwiftPM executables get TCC-attributed to the
# launching terminal/IDE, which breaks the permission prompts).
#
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

APP="MeetingNotes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/MeetingNotes" "$APP/Contents/MacOS/"

# SwiftPM resource bundles (MLX metal shaders, model assets, …) — the generated
# accessors look in Bundle.main.resourceURL.
# (-L: .build/<config> is a symlink to .build/arm64-apple-macosx/<config>)
find -L ".build/$CONFIG" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>MeetingNotes</string>
	<key>CFBundleDisplayName</key>
	<string>MeetingNotes</string>
	<key>CFBundleIdentifier</key>
	<string>com.spritle.meetingnotes</string>
	<key>CFBundleExecutable</key>
	<string>MeetingNotes</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.4</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Records your side of the meeting.</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Uses your calendar event's title and attendees to name meetings and speakers. Read-only.</string>
	<key>NSCalendarsUsageDescription</key>
	<string>Uses your calendar event's title and attendees to name meetings and speakers. Read-only.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Records meeting audio from other apps (Zoom, Meet, Teams).</string>
</dict>
</plist>
PLIST

# Ad-hoc signature — gives the app a stable identity for TCC permissions.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Launch with: open $APP"

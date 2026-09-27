#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app_destination="${1:-Codex Usage Tracker.app}"
mkdir -p "$app_destination/Contents/MacOS" "$app_destination/Contents/Resources"
cp Info.plist "$app_destination/Contents/Info.plist"
cp Assets/smoky-quartz.png "$app_destination/Contents/Resources/smoky-quartz.png"
/usr/bin/swiftc -swift-version 5 -O -module-cache-path "${TMPDIR:-/tmp}/usage-tracker-swift-cache" \
  -framework AppKit -framework CoreImage -framework QuartzCore -framework ApplicationServices \
  WeeklyUsage.swift OrbInteraction.swift main.swift -o "$app_destination/Contents/MacOS/CodexUsageTracker"
/usr/bin/codesign --force --sign - "$app_destination"
"$app_destination/Contents/MacOS/CodexUsageTracker" --self-test

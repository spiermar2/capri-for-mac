#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Keep development builds out of normal Finder/Spotlight discovery. Launched
# test bundles should still be unregistered and archived after validation.
destination="${1:-./.build.noindex}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
bundle="$destination/Capri for Mac.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/assets"
swiftc -O -swift-version 6 -target arm64-apple-macos26.0 -parse-as-library Main.swift Brain.swift CapriPersona.swift CapriReplyQuality.swift ChatGPTAuth.swift ChatGPTClient.swift ChatGPTSettings.swift CharacterView.swift IdleAnimationDirector.swift WindowInteraction.swift Voice.swift ElevenLabsVoice.swift PCMStreamingAudio.swift SummonShortcut.swift -o "$bundle/Contents/MacOS/Capri" -framework AppKit -framework FoundationModels -framework Speech -framework AVFoundation -framework Carbon -framework Security -framework ApplicationServices -framework Network -framework CryptoKit
cp Info.plist "$bundle/Contents/Info.plist"
test -d assets || { echo "Missing bundled assets directory" >&2; exit 1; }
ditto --norsrc --noextattr assets "$bundle/Contents/Resources/assets"
if [ -f Capri.icns ]; then cp Capri.icns "$bundle/Contents/Resources/Capri.icns"; fi
for notice in LICENSE THIRD_PARTY_NOTICES.md PRIVACY.md; do
  if [ -f "$notice" ]; then cp "$notice" "$bundle/Contents/Resources/$notice"; fi
done
codesign --force --deep --sign - "$bundle"
printf '%s\n' "Built: $bundle"

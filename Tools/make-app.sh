#!/bin/sh
# Builds "Hermes Bot.app" into build/.
#
#   Tools/make-app.sh                     signed for this Mac only (ad hoc)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Tools/make-app.sh
#                                         signed to give to other people
#   NOTARY_PROFILE=name                   with a Developer ID: also has Apple notarise
#                                         it, so it opens on other Macs without a warning,
#                                         and makes build/Hermes Bot.dmg to hand out.
#                                         Make the profile once with
#                                         `xcrun notarytool store-credentials name`.
#   VERSION=1.2.3 BUILD=42                the version shown, and a build number that only
#                                         ever goes up (default: commits on this branch)
#   ARCHS="arm64"                         one architecture only (default: both)
set -eu
cd "$(dirname "$0")/.."

NAME="Hermes Bot"
BUNDLE_ID="${BUNDLE_ID:-com.dantemoon1.hermes-bot}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${SIGN_IDENTITY:--}"
ARCHS="${ARCHS:-arm64 x86_64}"

flags=""
for arch in $ARCHS; do flags="$flags --arch $arch"; done
# shellcheck disable=SC2086
swift build -c release --package-path App --product HermesBot $flags
# shellcheck disable=SC2086
BIN="$(swift build -c release --package-path App --product HermesBot $flags --show-bin-path)/HermesBot"

APP="build/$NAME.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HermesBot"

# The app draws its own icon; see App/Sources/HermesBot/AppIcon.swift.
"$BIN" --write-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>HermesBot</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- A Hermes gateway is the person's own server, most often plain http on their
         network or over a private one such as Tailscale, by address or by name. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Hermes Bot connects to your Hermes gateway, which may be on your local network.</string>
</dict>
</plist>
PLIST

# The hardened runtime is what notarising asks for; it costs nothing otherwise.
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP" 2>/dev/null \
    || codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ "$IDENTITY" = "-" ]; then
        echo "NOTARY_PROFILE needs SIGN_IDENTITY set to a Developer ID Application identity." >&2
        exit 1
    fi
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    ditto -c -k --keepParent "$APP" "build/$NAME.zip"
    xcrun notarytool submit "build/$NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "build/$NAME.zip"
    # A disk image with the app and a way to Applications beside it, signed and
    # notarised itself, so it opens without a warning wherever it is downloaded.
    DMG="build/$NAME.dmg"
    STAGE="$(mktemp -d)"
    ditto "$APP" "$STAGE/$NAME.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
    rm -rf "$STAGE"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    shasum -a 256 "$DMG" | tee "$DMG.sha256"
    echo "Notarised: $DMG is ready to give to other people."
fi

echo "Made $APP ($VERSION, build $BUILD, signed as: $IDENTITY)"

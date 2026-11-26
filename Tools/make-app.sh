#!/bin/sh
# Builds "Hermes Bot.app" into build/.
#
#   Tools/make-app.sh                     signed for this Mac only (ad hoc), updates off
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Tools/make-app.sh
#                                         signed to give to other people
#   NOTARY_PROFILE=name                   with a Developer ID: also has Apple notarise
#                                         it, so it opens on other Macs without a warning,
#                                         and makes build/Hermes Bot.dmg to hand out.
#                                         Make the profile once with
#                                         `xcrun notarytool store-credentials name`.
#   VERSION=1.2.3 BUILD=42                the version shown, and a build number that only
#                                         ever goes up from one release to the next.
#                                         Sparkle compares BUILD. Required with a
#                                         SIGN_IDENTITY; otherwise commits on this branch.
#   SPARKLE_PUBLIC_ED_KEY=...             the public half of the EdDSA key that signs
#                                         updates (`generate_keys -p`). Turns updates on;
#                                         required with a SIGN_IDENTITY.
#   SPARKLE_FEED_URL=https://...          where the app looks for updates (default: the
#                                         appcast.xml of the latest GitHub release)
#   ARCHS="arm64"                         one architecture only (default: both)
set -eu
cd "$(dirname "$0")/.."

NAME="Hermes Bot"
BUNDLE_ID="${BUNDLE_ID:-com.dantemoon1.hermes-bot}"
VERSION="${VERSION:-0.2.0}"
IDENTITY="${SIGN_IDENTITY:--}"
ARCHS="${ARCHS:-arm64 x86_64}"
KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
FEED="${SPARKLE_FEED_URL:-https://github.com/dantemoon1/hermes-bot/releases/latest/download/appcast.xml}"

fail() { echo "$1" >&2; exit 1; }
# Whether all of a value, one line, matches: grep alone passes a value whose first line does.
whole() { case "$2" in *"
"*) return 1 ;; esac; printf '%s' "$2" | grep -Eq "$1"; }

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$IDENTITY" = "-" ]; then
    fail "NOTARY_PROFILE needs SIGN_IDENTITY set to a Developer ID Application identity."
fi
whole '^[A-Za-z0-9.-]+$' "$BUNDLE_ID" || fail "BUNDLE_ID must be letters, digits, dots and dashes."

# A build for other people needs a build number chosen for it: the commit count is
# different in every clone and repository, and Sparkle installs only a higher one.
if [ "$IDENTITY" != "-" ] && [ -z "${BUILD:-}" ]; then
    fail "SIGN_IDENTITY needs BUILD set: a whole number higher than the last release's."
fi
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
whole '^[1-9][0-9]{0,8}$' "$BUILD" || fail "BUILD must be a whole number from 1, not \"$BUILD\"."
whole '^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$' "$VERSION" || fail "VERSION must be numbers with dots between, such as 1.2.3."

# Without the key a copy for other people could never be updated, so it is refused.
if [ "$IDENTITY" != "-" ] && [ -z "$KEY" ]; then
    fail "SIGN_IDENTITY needs SPARKLE_PUBLIC_ED_KEY, the public EdDSA key for updates (generate_keys -p)."
fi
UPDATES=""
if [ -n "$KEY" ]; then
    case "$KEY" in *[!A-Za-z0-9+/=]*) fail "SPARKLE_PUBLIC_ED_KEY is not base64." ;; esac
    [ "$(printf '%s' "$KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] \
        || fail "SPARKLE_PUBLIC_ED_KEY is not a 32-byte EdDSA public key."
    # https only, and nothing that could end the plist's string.
    whole '^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/%+=,;:@-]*$' "$FEED" \
        || fail "SPARKLE_FEED_URL must be a plain https address."
    # The archive's signature is checked before it is unpacked, the feed itself must be
    # signed, always (Sparkle otherwise stops insisting after 20 days of feeds that fail
    # to check), and the app looks once a day (Sparkle's default) without asking first.
    UPDATES="
    <key>SUFeedURL</key><string>$FEED</string>
    <key>SUPublicEDKey</key><string>$KEY</string>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
    <key>SUEnableAutomaticChecks</key><true/>"
fi

flags=""
for arch in $ARCHS; do flags="$flags --arch $arch"; done
# shellcheck disable=SC2086
swift build -c release --package-path App --product HermesBot $flags
# shellcheck disable=SC2086
PRODUCTS="$(swift build -c release --package-path App --product HermesBot $flags --show-bin-path)"
BIN="$PRODUCTS/HermesBot"

APP="build/$NAME.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/HermesBot"

# Sparkle, beside the app's code. Its XPC services are for sandboxed apps, which this
# is not, so they are left out (Sparkle's sandboxing guide allows it); symlinks are kept.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$PRODUCTS/Sparkle.framework" "$FRAMEWORK"
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/B/XPCServices"
# Sparkle is found in Contents/Frameworks. The linker also leaves the build machine's
# own toolchain folders as places to look, ahead of that; they are taken out, so the
# framework is looked for only in the system's Swift and beside the app.
EXE="$APP/Contents/MacOS/HermesBot"
otool -l "$EXE" | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | sort -u | while IFS= read -r path; do
    case "$path" in /usr/lib/*|@*) ;; *) install_name_tool -delete_rpath "$path" "$EXE" ;; esac
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"

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
    <string>Hermes Bot connects to your Hermes gateway, which may be on your local network.</string>$UPDATES
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

# Signed from the inside out, never with --deep: Sparkle's helpers, then Sparkle, then
# the app. The hardened runtime is what notarising asks for, and notarising also wants a
# secure timestamp on every one of them, so any Developer ID copy has both. An ad hoc
# copy goes without the hardened runtime: under it, macOS loads only frameworks from the
# app's own team, and an ad hoc signature has none.
if [ "$IDENTITY" = "-" ]; then RUNTIME=""; STAMP="--timestamp=none"; else RUNTIME="--options=runtime"; STAMP="--timestamp"; fi
sign() { codesign --force $RUNTIME "$STAMP" --sign "$IDENTITY" "$1"; }
sign "$FRAMEWORK/Versions/B/Autoupdate"
sign "$FRAMEWORK/Versions/B/Updater.app"
sign "$FRAMEWORK"
sign "$APP"
codesign --verify --deep --strict "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" "build/$NAME.zip"
    xcrun notarytool submit "build/$NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "build/$NAME.zip"
    # A disk image with the app and a way to Applications beside it, signed and
    # notarised itself, so it opens without a warning wherever it is downloaded. It is
    # also what Sparkle downloads: Tools/make-appcast.sh signs it for the feed.
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
    # Named as GitHub names the upload (a dot for the space), so `shasum -c` works on
    # the two files downloaded side by side.
    printf '%s  %s\n' "$(shasum -a 256 < "$DMG" | cut -d ' ' -f 1)" "$(printf '%s' "$NAME.dmg" | tr ' ' '.')" | tee "$DMG.sha256"
    echo "Notarised: $DMG is ready to give to other people."
fi

if [ -n "$KEY" ]; then UPDATING="updates from $FEED"; else UPDATING="updates off"; fi
echo "Made $APP ($VERSION, build $BUILD, signed as: $IDENTITY, $UPDATING)"

#!/bin/sh
# Writes build/appcast.xml, the feed Sparkle reads, for a release made by
# `Tools/make-app.sh` (signed, notarised and stapled first: stapling changes the disk
# image, so it is signed for the feed only afterwards).
#
#   NOTES="What changed, in a line or two." Tools/make-appcast.sh [disk image]
#
# The disk image (default build/Hermes Bot.dmg) is opened read-only to read the
# version, build and public key of the app inside it, so the feed always says what is in
# the file. The image and then the feed are signed with Sparkle's `sign_update`, which
# reads the private EdDSA key from this Mac's Keychain itself; the key is never printed.
#
# It refuses a release that Sparkle would not install or that would break updating:
# a build number not higher than the published feed's, a published feed not signed with
# the same key, an app without updates turned on, or an app whose public key is not the
# one signing it, or anything but a Developer ID app in a notarised, stapled image.
# When no feed is published (the first release with Sparkle), say what
# the last release's build was with PUBLISHED_BUILD; a missing feed is never taken as
# "nothing published".
#
#   PUBLISHED_BUILD=n     the build number now published (first release with Sparkle: 3)
#   TAG=v1.2.3            the GitHub release the image is uploaded to (default v<version>)
#   REPO=owner/name       where releases are published (default dantemoon1/hermes-bot)
#   SPARKLE_ACCOUNT=name  the Keychain account of the key (default: Sparkle's own)
#   SPARKLE_KEY_FILE=path a private key in a file instead of the Keychain (for tests)
#   PUBLISHED_FEED=path   a copy of the published feed instead of fetching it, or
#                         "missing" for none (for tests)
#   TEST_IMAGE=1          take an image that is not notarised and an app that is not
#                         signed with a Developer ID (for tests with a throwaway key)
set -eu
cd "$(dirname "$0")/.."

NAME="Hermes Bot"
DMG="${1:-build/$NAME.dmg}"
OUT="${OUT:-build/appcast.xml}"
REPO="${REPO:-dantemoon1/hermes-bot}"
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
# GitHub turns the space in an uploaded file's name into a dot.
ASSET="$(basename "$DMG" | tr ' ' '.')"

fail() { echo "$1" >&2; exit 1; }
# Whether all of a value, one line, matches: grep alone passes a value whose first line does.
whole() { case "$2" in *"
"*) return 1 ;; esac; printf '%s' "$2" | grep -Eq "$1"; }

[ -f "$DMG" ] || fail "No disk image at $DMG. Make it first with SIGN_IDENTITY and NOTARY_PROFILE set (Tools/make-app.sh)."
[ -n "${NOTES:-}" ] || fail "Say what changed in NOTES, in a line or two; it is shown in the update window."
case "$NOTES" in *"]]>"*) fail "NOTES cannot hold ]]>." ;; esac
whole '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' "$REPO" || fail "REPO must be owner/name."
[ -z "${PUBLISHED_BUILD:-}" ] || whole '^(0|[1-9][0-9]{0,8})$' "$PUBLISHED_BUILD" || fail "PUBLISHED_BUILD must be a whole number."

BIN="App/.build/artifacts/sparkle/Sparkle/bin"
[ -x "$BIN/sign_update" ] || swift package resolve --package-path App >/dev/null
[ -x "$BIN/sign_update" ] || fail "Sparkle's tools are not in $BIN."
signing() {
    if [ -n "${SPARKLE_KEY_FILE:-}" ]; then "$BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$@"
    else "$BIN/sign_update" --account "${SPARKLE_ACCOUNT:-ed25519}" "$@"; fi
}

# One folder for everything temporary, and the image detached however this ends.
WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
mkdir "$MOUNT"
cleanup() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT HUP TERM

# What is in the image.
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
APP="$MOUNT/$NAME.app"
[ -d "$APP" ] || fail "$DMG has no $NAME.app at its top."
codesign --verify --deep --strict "$APP" || fail "The app in $DMG is not validly signed."
# Only what make-app.sh made for other people goes in the feed: a Developer ID app in a
# notarised, stapled image. A local copy built with the same public key would otherwise
# pass every other check.
if [ "${TEST_IMAGE:-}" != 1 ]; then
    codesign -dv --verbose=2 "$APP" 2>&1 | grep -q '^Authority=Developer ID Application: ' \
        || fail "The app in $DMG is not signed with a Developer ID. Make it with SIGN_IDENTITY and NOTARY_PROFILE set."
    xcrun stapler validate -q "$DMG" >/dev/null 2>&1 || fail "$DMG is not notarised and stapled."
fi
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION="$(read_key CFBundleShortVersionString)"
BUILD="$(read_key CFBundleVersion)"
MINIMUM="$(read_key LSMinimumSystemVersion)"
APP_KEY="$(read_key SUPublicEDKey)"
FEED_IN_APP="$(read_key SUFeedURL)"
POLICY="$(read_key SUVerifyUpdateBeforeExtraction) $(read_key SURequireSignedFeed) $(read_key SUSignedFeedFailureExpirationInterval)"
hdiutil detach -quiet "$MOUNT"

whole '^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$' "$VERSION" || fail "The app's version \"$VERSION\" is not plain numbers."
whole '^[1-9][0-9]{0,8}$' "$BUILD" || fail "The app's build \"$BUILD\" is not a whole number."
whole '^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$' "$MINIMUM" || fail "The app's minimum macOS \"$MINIMUM\" is not a version."
[ -n "$APP_KEY" ] || fail "The app in $DMG has updates off (no SUPublicEDKey). Make it with SPARKLE_PUBLIC_ED_KEY set."
[ "$FEED_IN_APP" = "$FEED" ] || fail "The app looks for updates at $FEED_IN_APP, not $FEED."
# The app would otherwise take an update it had not checked, or an unsigned feed in time.
[ "$POLICY" = "true true 0" ] || fail "The app in $DMG does not insist on signed updates and a signed feed. Make it with Tools/make-app.sh."
whole '^[A-Za-z0-9._-]+\.dmg$' "$ASSET" || fail "The disk image's name, $ASSET, is not plain letters, digits, dots and dashes."
TAG="${TAG:-v$VERSION}"
whole '^[A-Za-z0-9._-]+$' "$TAG" || fail "TAG must be letters, digits, dots, dashes or underscores."

# The key that signs must be the one the app checks with, or nobody could install it.
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    SIGNING_KEY="$(swift - "$SPARKLE_KEY_FILE" 2>/dev/null <<'SWIFT'
import CryptoKit
import Foundation
let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))!
print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())
SWIFT
    )" || fail "Couldn't read the key in $SPARKLE_KEY_FILE."
else
    SIGNING_KEY="$("$BIN/generate_keys" --account "${SPARKLE_ACCOUNT:-ed25519}" -p)" || fail "No Sparkle key in this Mac's Keychain."
fi
[ "$SIGNING_KEY" = "$APP_KEY" ] || fail "The key that would sign this is not the app's SUPublicEDKey."

# The published feed: signed with this same key (copies already installed check with the
# key that signed it, so a new key would leave them unable to update), and the highest
# build it offers. sign_update reads a feed's own signature only from a file named .xml.
PUBLISHED="$WORK/published.xml"
if [ "${PUBLISHED_FEED:-}" = missing ]; then
    STATUS=404
elif [ -n "${PUBLISHED_FEED:-}" ]; then
    cp "$PUBLISHED_FEED" "$PUBLISHED"
    STATUS=200
else
    STATUS="$(curl -sS -L --proto =https --proto-redir =https --max-time 30 -o "$PUBLISHED" -w '%{http_code}' "$FEED")" \
        || fail "Couldn't read the published feed at $FEED."
fi
case "$STATUS" in
    200)
        signing --verify "$PUBLISHED" >/dev/null 2>&1 \
            || fail "The published feed is not signed with this key, so installed copies would refuse this update."
        # Only the items' own build numbers, read as XML, never words in release notes.
        FOUND="$(xmllint --xpath "//*[local-name()='item']/*[local-name()='version']/text()" "$PUBLISHED" 2>/dev/null | tr -s ' \n' '\n\n' | grep -E '^[0-9]{1,9}$' | sed 's/^0*\([0-9]\)/\1/' | sort -n | tail -1 || true)"
        [ -n "$FOUND" ] || fail "The published feed at $FEED names no build."
        if [ -n "${PUBLISHED_BUILD:-}" ] && [ "$PUBLISHED_BUILD" -gt "$FOUND" ]; then FOUND="$PUBLISHED_BUILD"; fi
        PUBLISHED_BUILD="$FOUND" ;;
    404)
        [ -n "${PUBLISHED_BUILD:-}" ] || fail "No feed is published at $FEED. If this is the first release with Sparkle, set PUBLISHED_BUILD=3 (0.1.1); otherwise the latest release is missing its appcast.xml."
        echo "No feed is published yet; going by PUBLISHED_BUILD=$PUBLISHED_BUILD." ;;
    *) fail "The published feed at $FEED answered $STATUS." ;;
esac
[ "$BUILD" -gt "$PUBLISHED_BUILD" ] || fail "Build $BUILD is not higher than the published build $PUBLISHED_BUILD; make it again with a higher BUILD."

SIGNATURE="$(signing -p "$DMG")" || fail "Couldn't sign $DMG."
LENGTH="$(stat -f %z "$DMG")"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>$NAME</title>
        <link>https://github.com/$REPO/releases</link>
        <item>
            <title>Version $VERSION</title>
            <link>https://github.com/$REPO/releases/tag/$TAG</link>
            <pubDate>$DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
            <description sparkle:format="plain-text"><![CDATA[$NOTES]]></description>
            <enclosure url="https://github.com/$REPO/releases/download/$TAG/$ASSET" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
    </channel>
</rss>
XML
xmllint --noout "$OUT" || fail "The feed written is not well-formed XML."

# The app takes only a signed feed; the signature goes inside it, as a comment.
signing "$OUT" >/dev/null || fail "Couldn't sign $OUT."
signing --verify "$OUT" >/dev/null || fail "The feed's signature does not check."
signing --verify "$DMG" "$SIGNATURE" >/dev/null || fail "The disk image's signature does not check."

echo "Wrote $OUT: version $VERSION, build $BUILD (published: $PUBLISHED_BUILD), $LENGTH bytes."
echo "Upload \"$DMG\" (it becomes $ASSET), its .sha256 and $OUT to release $TAG of $REPO, as the latest release."

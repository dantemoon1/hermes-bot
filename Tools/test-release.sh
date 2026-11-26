#!/bin/sh
# Tries Tools/make-app.sh and Tools/make-appcast.sh without signing anything for real:
# a throwaway EdDSA key in a temporary file (never the Keychain), an ad hoc app with
# updates on, and an unsigned disk image. Checks what each refuses, the bundle's
# Info.plist and Sparkle in it, and the feed written. Builds the app once (arm64).
#
#   Tools/test-release.sh
set -eu
cd "$(dirname "$0")/.."
# Its own bundle id, so Sparkle's notes from the launch below never land in the real
# app's preferences.
export BUNDLE_ID=com.dantemoon1.hermes-bot.test-release

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true' EXIT
passed=0
ok() { passed=$((passed + 1)); }
no() { echo "FAILED: $1" >&2; exit 1; }
# Runs a command that must fail, and checks it says why.
refuses() {
    reason="$1"; shift
    if out="$("$@" 2>&1)"; then no "should have refused ($reason): $*"; fi
    case "$out" in *"$reason"*) ok ;; *) no "refused for another reason than \"$reason\": $out" ;; esac
}

# Two throwaway keys: the seed in a file, as sign_update takes it, and the public half.
key() {
    swift - "$1" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try (key.rawRepresentation.base64EncodedString() + "\n").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
}
PUBLIC="$(key "$WORK/key")"
key "$WORK/other" >/dev/null

echo "make-app.sh refusals"
refuses "needs BUILD" env SIGN_IDENTITY="Developer ID Application: Nobody (XXXXXXXXXX)" Tools/make-app.sh
refuses "needs SPARKLE_PUBLIC_ED_KEY" env SIGN_IDENTITY="Developer ID Application: Nobody (XXXXXXXXXX)" BUILD=4 Tools/make-app.sh
refuses "BUILD must be" env BUILD=0 Tools/make-app.sh
refuses "BUILD must be" env BUILD=4a Tools/make-app.sh
refuses "BUILD must be" env BUILD=-1 Tools/make-app.sh
refuses "VERSION must be" env VERSION=1.2.beta Tools/make-app.sh
refuses "not base64" env SPARKLE_PUBLIC_ED_KEY='abc<def' Tools/make-app.sh
refuses "not a 32-byte" env SPARKLE_PUBLIC_ED_KEY="$(printf 'short' | base64)" Tools/make-app.sh
refuses "plain https" env SPARKLE_PUBLIC_ED_KEY="$PUBLIC" SPARKLE_FEED_URL=http://example.com/appcast.xml Tools/make-app.sh
refuses "plain https" env SPARKLE_PUBLIC_ED_KEY="$PUBLIC" SPARKLE_FEED_URL='https://example.com/a"</string>' Tools/make-app.sh
refuses "needs SIGN_IDENTITY" env NOTARY_PROFILE=x Tools/make-app.sh
# A value whose first line is good and whose next line is not.
refuses "VERSION must be" env VERSION="1.2.3
</string><key>SUFeedURL</key><string>https://example.com/a" Tools/make-app.sh
refuses "plain https" env SPARKLE_PUBLIC_ED_KEY="$PUBLIC" SPARKLE_FEED_URL="https://example.com/a.xml
</string>" Tools/make-app.sh
refuses "BUNDLE_ID must be" env BUNDLE_ID='x</string><key>SUFeedURL</key><string>https://example.com/' Tools/make-app.sh

echo "make-app.sh with updates on (builds the app)"
ARCHS=arm64 VERSION=9.8.7 BUILD=41 SPARKLE_PUBLIC_ED_KEY="$PUBLIC" Tools/make-app.sh >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; no "make-app.sh"; }
APP="build/Hermes Bot.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ "$(plist CFBundleVersion)" = 41 ] && ok || no "CFBundleVersion"
[ "$(plist CFBundleShortVersionString)" = 9.8.7 ] && ok || no "CFBundleShortVersionString"
[ "$(plist SUPublicEDKey)" = "$PUBLIC" ] && ok || no "SUPublicEDKey"
[ "$(plist SUFeedURL)" = "https://github.com/dantemoon1/hermes-bot/releases/latest/download/appcast.xml" ] && ok || no "SUFeedURL"
[ "$(plist SUVerifyUpdateBeforeExtraction)" = true ] && ok || no "SUVerifyUpdateBeforeExtraction"
[ "$(plist SURequireSignedFeed)" = true ] && ok || no "SURequireSignedFeed"
[ "$(plist SUSignedFeedFailureExpirationInterval)" = 0 ] && ok || no "SUSignedFeedFailureExpirationInterval"
[ -f "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ] && ok || no "Sparkle.framework"
[ -x "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" ] && ok || no "Autoupdate"
[ ! -e "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" ] && ok || no "XPC services left in"
[ -L "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current" ] && ok || no "the framework's symlinks"
otool -l "$APP/Contents/MacOS/HermesBot" | grep -q "@executable_path/../Frameworks" && ok || no "rpath"
otool -l "$APP/Contents/MacOS/HermesBot" | awk '$1 == "path" { print $2 }' | grep -Eqv '^(/usr/lib/|@)' && no "a build machine's rpath is left" || ok
codesign --verify --deep --strict "$APP" && ok || no "signature"
# Sparkle loads: dyld stops a process at once if it cannot. Told not to check, so the
# test asks nothing of GitHub.
HERMES_URL=127.0.0.1:9 HERMES_TOKEN=x HERMES_BOT_STORE=test-release "$APP/Contents/MacOS/HermesBot" -SUEnableAutomaticChecks NO >"$WORK/run.log" 2>&1 &
pid=$!
sleep 4
if kill -0 "$pid" 2>/dev/null; then
    vmmap "$pid" 2>/dev/null | grep -q "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" && ok || { kill "$pid"; no "Sparkle not loaded"; }
    kill "$pid"
    wait "$pid" 2>/dev/null || true
else
    cat "$WORK/run.log"; no "the app did not stay open"
fi

echo "make-appcast.sh"
STAGE="$WORK/stage"
mkdir "$STAGE"
ditto "$APP" "$STAGE/Hermes Bot.app"
hdiutil create -quiet -volname "Hermes Bot" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$WORK/Hermes Bot.dmg"
# Never the real feed: none published unless a case gives one (PUBLISHED_FEED), and an
# ad hoc app in an image that is not notarised taken as it is (TEST_IMAGE).
appcast() { env OUT="$WORK/appcast.xml" SPARKLE_KEY_FILE="$WORK/key" PUBLISHED_FEED=missing PUBLISHED_BUILD=3 TEST_IMAGE=1 NOTES="Installs updates itself." "$@" Tools/make-appcast.sh "$WORK/Hermes Bot.dmg"; }
refuses "not signed with a Developer ID" appcast TEST_IMAGE=
refuses "No feed is published" appcast PUBLISHED_BUILD=
refuses "NOTES" appcast NOTES=
refuses "]]>" appcast NOTES="a ]]> b"
refuses "not higher than the published build 41" appcast PUBLISHED_BUILD=41
refuses "not the app's SUPublicEDKey" appcast SPARKLE_KEY_FILE="$WORK/other"
refuses "No disk image" env NOTES=x Tools/make-appcast.sh "$WORK/none.dmg"
appcast >"$WORK/appcast.log" 2>&1 || { cat "$WORK/appcast.log"; no "make-appcast.sh"; }
FEED="$WORK/appcast.xml"
xmllint --noout "$FEED" && ok || no "feed XML"
grep -q "<sparkle:version>41</sparkle:version>" "$FEED" && ok || no "sparkle:version"
grep -q "<sparkle:shortVersionString>9.8.7</sparkle:shortVersionString>" "$FEED" && ok || no "shortVersionString"
grep -q "<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>" "$FEED" && ok || no "minimumSystemVersion"
grep -q 'url="https://github.com/dantemoon1/hermes-bot/releases/download/v9.8.7/Hermes.Bot.dmg"' "$FEED" && ok || no "enclosure url"
grep -q "length=\"$(stat -f %z "$WORK/Hermes Bot.dmg")\"" "$FEED" && ok || no "enclosure length"
grep -q "sparkle-signatures" "$FEED" && ok || no "the feed is not signed"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$FEED")"
App/.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$WORK/key" --verify "$WORK/Hermes Bot.dmg" "$SIGNATURE" >/dev/null && ok || no "image signature"
App/.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$WORK/key" --verify "$FEED" >/dev/null && ok || no "feed signature"
# A feed changed after signing no longer checks.
sed 's/Installs updates itself/Something else/' "$FEED" >"$WORK/changed.xml"
App/.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$WORK/key" --verify "$WORK/changed.xml" >/dev/null 2>&1 && no "a changed feed checks" || ok
# The published feed. A copy of it stands in for GitHub's (PUBLISHED_FEED).
cp "$FEED" "$WORK/published-41.xml"
refuses "not higher than the published build 41" appcast PUBLISHED_FEED="$WORK/published-41.xml"
# Build 4 published, with release notes that quote a higher build: the item's counts.
python3 -I - "$FEED" "$WORK/published-4.xml" <<'PY'
import re, sys
text = re.sub(r"<!--.*?-->", "", open(sys.argv[1]).read(), flags=re.S)
text = text.replace("<sparkle:version>41</sparkle:version>", "<sparkle:version>4</sparkle:version>")
text = text.replace("Installs updates itself.", "Write <sparkle:version>999</sparkle:version> in a feed.")
open(sys.argv[2], "w").write(text)
PY
cp "$WORK/published-4.xml" "$WORK/unsigned.xml"
cp "$WORK/published-4.xml" "$WORK/other.xml"
App/.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$WORK/key" "$WORK/published-4.xml" >/dev/null
App/.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$WORK/other" "$WORK/other.xml" >/dev/null
appcast PUBLISHED_FEED="$WORK/published-4.xml" >"$WORK/appcast2.log" 2>&1 && ok || { cat "$WORK/appcast2.log"; no "a published build 4 with 999 in its notes"; }
grep -q "published: 4" "$WORK/appcast2.log" && ok || no "the published build read from the feed"
refuses "not signed with this key" appcast PUBLISHED_FEED="$WORK/other.xml"
refuses "not signed with this key" appcast PUBLISHED_FEED="$WORK/unsigned.xml"
# An app built without updates is refused.
ARCHS=arm64 BUILD=42 Tools/make-app.sh >"$WORK/build2.log" 2>&1 || { cat "$WORK/build2.log"; no "make-app.sh without a key"; }
rm -rf "$STAGE/Hermes Bot.app"
ditto "build/Hermes Bot.app" "$STAGE/Hermes Bot.app"
hdiutil create -quiet -volname "Hermes Bot" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$WORK/Hermes Bot.dmg"
refuses "updates off" appcast
[ -z "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "build/Hermes Bot.app/Contents/Info.plist" 2>/dev/null)" ] && ok || no "a build without a key has a feed"

echo "All $passed checks passed."

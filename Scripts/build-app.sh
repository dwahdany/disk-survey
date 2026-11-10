#!/bin/bash
# Builds dist/Disk Survey.app — a universal (arm64 + x86_64), code-signed app bundle — using nothing
# but SwiftPM and the Command Line Tools. No Xcode, no asset catalogs.
#
#   Scripts/build-app.sh [options]
#
#   --native     build only for this Mac's architecture (much faster; not for distribution)
#   --debug      debug configuration, symbols kept
#   --dmg        also create dist/DiskSurvey-<version>.dmg (compressed, with an /Applications link)
#   --zip        also create dist/DiskSurvey-<version>.zip
#   --notarize   notarize with Apple and staple the ticket (app, and the dmg if --dmg); needs a
#                Developer ID identity in CODESIGN_IDENTITY and NOTARY_PROFILE (see below)
#   --install    copy the app to /Applications (or ~/Applications if that is not writable)
#   --run        open the built (or installed) app when done
#   -h, --help   show this help
#
# Environment:
#   CODESIGN_IDENTITY   signing identity; default "-" (ad-hoc). Use a "Developer ID Application: …"
#                       identity for builds you intend to notarize (see README).
#   NOTARY_PROFILE      notarytool keychain profile for --notarize; default "disksurvey-notary".
#                       Create it once with: xcrun notarytool store-credentials disksurvey-notary
#   BUILD_NUMBER        CFBundleVersion; defaults to the contents of VERSION.
#
# Works from any directory. Uses its own SwiftPM scratch directories (.build-pkg-<arch>) so it
# never fights with another build running in the same checkout.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

APP_NAME="Disk Survey"        # bundle and display name (contains a space: keep every use quoted)
EXEC_NAME="DiskSurvey"        # CFBundleExecutable
PKG_NAME="DiskSurvey"         # stem of the .dmg / .zip file names
APP_PRODUCT="DiskSurveyApp"   # SwiftPM product; becomes Contents/MacOS/DiskSurvey
CLI_PRODUCT="disksurvey-cli"  # SwiftPM product; becomes Contents/Helpers/disksurvey
CLI_NAME="disksurvey"
MIN_MACOS="26.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

native=0; config=release; make_dmg=0; make_zip=0; do_install=0; do_run=0; notarize=0

usage() { sed -n '2,/^$/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^set -euo/d'; }
say()   { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --native)  native=1 ;;
        --debug)   config=debug ;;
        --dmg)     make_dmg=1 ;;
        --zip)     make_zip=1 ;;
        --notarize) notarize=1 ;;
        --install) do_install=1 ;;
        --run)     do_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

# --- Toolchain ------------------------------------------------------------------------------

# xcode-select may point at an Xcode that is missing or unlicensed; fall back to the CLT.
CLT=/Library/Developer/CommandLineTools
if ! swift --version >/dev/null 2>&1; then
    [ -x "$CLT/usr/bin/swift" ] || die "no working Swift toolchain; run: xcode-select --install"
    export DEVELOPER_DIR="$CLT"
fi
for tool in swift lipo codesign plutil ditto strip; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# --- Notarization preflight -----------------------------------------------------------------

NOTARY_PROFILE="${NOTARY_PROFILE:-disksurvey-notary}"
if [ "$notarize" -eq 1 ]; then
    # Fail before the (slow) build rather than after it.
    case "${CODESIGN_IDENTITY:-}" in
        "Developer ID Application:"*) ;;
        *) die "--notarize needs CODESIGN_IDENTITY set to a \"Developer ID Application: …\" identity" ;;
    esac
    [ "$native" -eq 0 ] && [ "$config" = release ] || die "--notarize is for universal release builds (drop --native/--debug)"
    xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found; it ships with Xcode"
    xcrun --find stapler >/dev/null 2>&1 || die "stapler not found; it ships with Xcode"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "notarytool profile '$NOTARY_PROFILE' is missing or invalid; run: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi

# Submits a file to Apple's notary service and waits; prints the log and stops on rejection.
notarize_file() { # <path to .zip or .dmg>
    local out id status
    out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || { echo "$out" >&2; die "notarytool failed for $(basename "$1")"; }
    id="$(printf '%s\n' "$out" | awk '/^ *id:/ {print $2; exit}')"
    status="$(printf '%s\n' "$out" | awk '/^ *status:/ {print $2}' | tail -n 1)"
    if [ "$status" != "Accepted" ]; then
        echo "$out" >&2
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        die "notarization of $(basename "$1") ended with status '${status:-unknown}'"
    fi
    printf '    notarized %s (submission %s)\n' "$(basename "$1")" "$id"
}

# --- Version --------------------------------------------------------------------------------

[ -f "$ROOT/VERSION" ] || die "VERSION file missing"
VERSION="$(tr -d ' \t\r\n' < "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "VERSION must look like 1.2.3 (got '$VERSION')"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"

# The engine reports its own version string (used by the CLI and the About panel); VERSION is the
# source of truth for the bundle, so flag it loudly if the two have drifted apart.
code_version="$(sed -n 's/.*static let string = "\([^"]*\)".*/\1/p' \
    "$ROOT/Sources/DiskSurveyCore/FileTree.swift" 2>/dev/null | head -n 1 || true)"
if [ -n "$code_version" ] && [ "$code_version" != "$VERSION" ]; then
    warn "VERSION is $VERSION but DiskSurveyVersion.string is $code_version — update one of them"
fi

# --- Build ----------------------------------------------------------------------------------

host_arch="$(uname -m)"
if [ "$native" -eq 1 ]; then archs="$host_arch"; else archs="arm64 x86_64"; fi

bin_dir_for() { # <arch> → SwiftPM's bin directory for that arch
    swift build -c "$config" --triple "$1-apple-macosx$MIN_MACOS" \
        --scratch-path "$ROOT/.build-pkg-$1" --show-bin-path
}

# Remove the previous outputs first, so a failed build never leaves a stale app that looks
# current — and no .dmg/.zip (of this or an older version) outlives the app it was made from,
# whether or not this run is asked to package.
rm -rf "$APP"
shopt -s nullglob
rm -f "$DIST/$PKG_NAME"-*.dmg "$DIST/$PKG_NAME"-*.zip
shopt -u nullglob

# Everything is assembled, signed and verified in a staging directory and only then moved to its
# final name, so nothing that failed half-way is ever found under dist/. The staging directory
# is inside dist/ to make that move a rename on one volume (which keeps the signature valid).
STAGE_DIR=""; DMG_STAGE=""
cleanup() {
    [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
    [ -z "$DMG_STAGE" ] || rm -rf "$DMG_STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for arch in $archs; do
    for product in "$APP_PRODUCT" "$CLI_PRODUCT"; do
        say "Building $product ($config, $arch)"
        swift build -c "$config" --triple "$arch-apple-macosx$MIN_MACOS" \
            --scratch-path "$ROOT/.build-pkg-$arch" --product "$product"
    done
done

# --- Assemble the bundle --------------------------------------------------------------------

say "Assembling $APP_NAME.app"
mkdir -p "$DIST"
STAGE_DIR="$(mktemp -d "$DIST/.stage.XXXXXX")"
# The bundle keeps its real name while it is signed; only its parent directory is temporary.
STAGE_APP="$STAGE_DIR/$APP_NAME.app"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Helpers" "$STAGE_APP/Contents/Resources"

app_slices=(); cli_slices=(); first_bin=""
for arch in $archs; do
    bin="$(bin_dir_for "$arch")"
    [ -x "$bin/$APP_PRODUCT" ] || die "missing build product: $bin/$APP_PRODUCT"
    [ -x "$bin/$CLI_PRODUCT" ] || die "missing build product: $bin/$CLI_PRODUCT"
    app_slices+=("$bin/$APP_PRODUCT"); cli_slices+=("$bin/$CLI_PRODUCT")
    [ -n "$first_bin" ] || first_bin="$bin"
done
lipo -create "${app_slices[@]}" -output "$STAGE_APP/Contents/MacOS/$EXEC_NAME"
lipo -create "${cli_slices[@]}" -output "$STAGE_APP/Contents/Helpers/$CLI_NAME"
chmod 755 "$STAGE_APP/Contents/MacOS/$EXEC_NAME" "$STAGE_APP/Contents/Helpers/$CLI_NAME"

# SwiftPM resource bundles (DiskSurvey_<Target>.bundle), if any target declares resources. They hold
# no architecture-specific code, so the first slice's copy serves both.
shopt -s nullglob
for bundle in "$first_bin"/*.bundle; do
    say "Copying resource bundle $(basename "$bundle")"
    ditto "$bundle" "$STAGE_APP/Contents/Resources/$(basename "$bundle")"
done
shopt -u nullglob

[ -f "$ROOT/Resources/AppIcon.icns" ] || die "Resources/AppIcon.icns missing; run: swift Scripts/make-icon.swift"
cp "$ROOT/Resources/AppIcon.icns" "$STAGE_APP/Contents/Resources/AppIcon.icns"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$STAGE_APP/Contents/Resources/LICENSE"

# Info.plist: the checked-in file is a template; stamp the version in, store as XML.
cp "$ROOT/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGE_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$STAGE_APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$STAGE_APP/Contents/Info.plist"
plutil -lint "$STAGE_APP/Contents/Info.plist" >/dev/null || die "Info.plist is not a valid property list"
printf 'APPL????' > "$STAGE_APP/Contents/PkgInfo"

# --- Strip ----------------------------------------------------------------------------------

if [ "$config" = release ]; then
    say "Stripping symbols"
    # -S: debug symbols, -x: local symbols. Global symbols stay so crash reports remain readable.
    strip -S -x "$STAGE_APP/Contents/MacOS/$EXEC_NAME" "$STAGE_APP/Contents/Helpers/$CLI_NAME" 2>/dev/null \
        || warn "strip reported a problem; continuing with unstripped binaries"
fi

# --- Sign -----------------------------------------------------------------------------------

IDENTITY="${CODESIGN_IDENTITY:--}"
# Hardened runtime is required for notarization and harmless for ad-hoc builds. A secure
# timestamp needs Apple's servers and a real identity, so ad-hoc builds skip it.
sign_opts=(--force --options runtime --sign "$IDENTITY")
if [ "$IDENTITY" = "-" ]; then
    say "Code signing (ad-hoc)"
    sign_opts+=(--timestamp=none)
else
    say "Code signing as: $IDENTITY"
    sign_opts+=(--timestamp)
fi
# Signed inside-out — the helper first, then the bundle that seals it — which is what Apple
# recommends over a blanket `--deep` (that would re-sign the helper and drop its identifier).
# SwiftPM resource bundles contain no code, so they are covered by the bundle's resource seal.
codesign "${sign_opts[@]}" --identifier "dev.disksurvey.cli" "$STAGE_APP/Contents/Helpers/$CLI_NAME" 2>&1 \
    | { grep -v 'replacing existing signature' || true; }
codesign "${sign_opts[@]}" "$STAGE_APP" 2>&1 | { grep -v 'replacing existing signature' || true; }

# --- Verify ---------------------------------------------------------------------------------

say "Verifying"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"
expected="$(echo $archs | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
for binary in "$STAGE_APP/Contents/MacOS/$EXEC_NAME" "$STAGE_APP/Contents/Helpers/$CLI_NAME"; do
    actual="$(lipo -archs "$binary" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
    [ "$actual" = "$expected" ] || die "$(basename "$binary") has architectures '$actual', expected '$expected'"
    printf '    %-12s %s\n' "$(basename "$binary")" "$actual"
done

# --- Notarize the app -----------------------------------------------------------------------

if [ "$notarize" -eq 1 ]; then
    say "Notarizing $APP_NAME.app (this usually takes a few minutes)"
    # The service takes an archive; the ticket is then stapled to the bundle itself, so the zip
    # and dmg made below carry an app that validates offline.
    ditto -c -k --sequesterRsrc --keepParent "$STAGE_APP" "$STAGE_DIR/notarize.zip"
    notarize_file "$STAGE_DIR/notarize.zip"
    rm -f "$STAGE_DIR/notarize.zip"
    xcrun stapler staple -q "$STAGE_APP"
    xcrun stapler validate -q "$STAGE_APP"
    spctl --assess --type execute "$STAGE_APP" || die "Gatekeeper rejects the notarized app"
fi

# --- Publish --------------------------------------------------------------------------------

rm -rf "$APP"
mv "$STAGE_APP" "$APP"
rm -rf "$STAGE_DIR"; STAGE_DIR=""
# Nudge LaunchServices/Finder to pick up a changed icon or Info.plist.
touch "$APP"

size_of() { du -sh "$1" | awk '{print $1}'; }
printf '    %s  %s  (version %s, build %s, %s)\n' "$APP" "$(size_of "$APP")" "$VERSION" "$BUILD_NUMBER" "$config"
if [ "$native" -eq 1 ]; then
    warn "--native build: runs only on $host_arch Macs; omit --native for a distributable universal build"
fi

# --- Optional packaging ---------------------------------------------------------------------

# Packages are built under a temporary name inside the staging directory and renamed when they
# are complete (and, for the dmg, signed and verified).
if [ "$make_zip" -eq 1 ] || [ "$make_dmg" -eq 1 ]; then
    STAGE_DIR="$(mktemp -d "$DIST/.stage.XXXXXX")"
fi

if [ "$make_zip" -eq 1 ]; then
    zip="$DIST/$PKG_NAME-$VERSION.zip"
    say "Creating $(basename "$zip")"
    # ditto (not zip) preserves the signature's extended attributes and symlinks.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE_DIR/$(basename "$zip")"
    mv -f "$STAGE_DIR/$(basename "$zip")" "$zip"
    printf '    %s  %s\n' "$zip" "$(size_of "$zip")"
fi

if [ "$make_dmg" -eq 1 ]; then
    command -v hdiutil >/dev/null 2>&1 || die "hdiutil not found"
    dmg="$DIST/$PKG_NAME-$VERSION.dmg"
    say "Creating $(basename "$dmg")"
    DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/disksurvey-dmg.XXXXXX")"
    ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGE/Applications"
    new_dmg="$STAGE_DIR/$(basename "$dmg")"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -fs HFS+ -format ULFO -ov "$new_dmg"
    if [ "$IDENTITY" != "-" ]; then
        codesign --force --sign "$IDENTITY" --timestamp "$new_dmg"
    fi
    hdiutil verify -quiet "$new_dmg"
    if [ "$notarize" -eq 1 ]; then
        say "Notarizing $(basename "$dmg")"
        notarize_file "$new_dmg"
        xcrun stapler staple -q "$new_dmg"
        xcrun stapler validate -q "$new_dmg"
    fi
    mv -f "$new_dmg" "$dmg"
    rm -rf "$DMG_STAGE"; DMG_STAGE=""
    printf '    %s  %s\n' "$dmg" "$(size_of "$dmg")"
fi

if [ -n "$STAGE_DIR" ]; then rm -rf "$STAGE_DIR"; STAGE_DIR=""; fi

# --- Optional install / run -----------------------------------------------------------------

launch_target="$APP"
if [ "$do_install" -eq 1 ]; then
    if [ -w /Applications ]; then dest_dir=/Applications; else dest_dir="$HOME/Applications"; fi
    mkdir -p "$dest_dir"
    say "Installing to $dest_dir/$APP_NAME.app"
    rm -rf "$dest_dir/$APP_NAME.app"
    ditto "$APP" "$dest_dir/$APP_NAME.app"
    launch_target="$dest_dir/$APP_NAME.app"
    echo "    To put the command line tool on your PATH: Scripts/install-cli.sh"
fi

if [ "$do_run" -eq 1 ]; then
    say "Opening $launch_target"
    open "$launch_target"
fi

say "Done"

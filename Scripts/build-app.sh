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
# Sandboxed variants (see DEVELOPMENT.md, "Sandboxed and App Store builds"). They never touch
# dist/Disk Survey.app or its dmg/zip, contain no command line tool, and cannot be combined with
# --dmg, --zip, --notarize or --install:
#   --sandbox    the same app signed with the App Sandbox entitlements
#                (Resources/DiskSurvey.sandbox.entitlements) → dist/Disk Survey (Sandbox).app
#   --sandbox-test-access
#                only with --sandbox, NEVER for distribution: adds a temporary exception that
#                lets the sandboxed app read and write the whole disk, so the headless harness
#                can exercise the sandboxed code without a person clicking an open panel
#                → dist/Disk Survey (Sandbox Test Access).app, a name of its own so that it is
#                never mistaken for (or left in place of) the real sandboxed build
#   --mas        Mac App Store package: universal release build, provisioning profile embedded,
#                signed with the distribution identity, wrapped in a signed installer package
#                → dist/DiskSurvey-<version>-<build>-mas.pkg (and dist/Disk Survey (App Store).app)
#   --mas-dry-run
#                everything --mas does up to the distribution signature, without certificates:
#                reports what is missing, signs ad hoc, builds an unsigned package to check the
#                steps, and leaves nothing in dist/
#
# Environment:
#   CODESIGN_IDENTITY   signing identity; default "-" (ad-hoc). Use a "Developer ID Application: …"
#                       identity for builds you intend to notarize (see README).
#   NOTARY_PROFILE      notarytool keychain profile for --notarize; default "disksurvey-notary".
#                       Create it once with: xcrun notarytool store-credentials disksurvey-notary
#   BUILD_NUMBER        CFBundleVersion; defaults to the contents of VERSION. With --mas: a whole
#                       number greater than the last one used (kept in Resources/mas-build-number);
#                       defaults to that number plus one.
#   BUNDLE_ID           bundle identifier of a sandboxed variant; default dev.disksurvey.app.
#                       Ignored without --sandbox / --mas.
#   MAS_APP_IDENTITY        --mas: "Apple Distribution: …" (or "3rd Party Mac Developer Application: …")
#   MAS_INSTALLER_IDENTITY  --mas: "3rd Party Mac Developer Installer: …"
#   MAS_PROFILE             --mas: path to the Mac App Store provisioning profile (.provisionprofile);
#                           a relative path is taken from the directory the script is called in
#
# Works from any directory. Uses its own SwiftPM scratch directories (.build-pkg-<arch>) so it
# never fights with another build running in the same checkout.

set -euo pipefail

# Where the script was called from: a relative path in the environment (MAS_PROFILE) is meant
# relative to that, not to the repository the script then moves into.
CALLER_DIR="$(pwd -P)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
if [ -n "${MAS_PROFILE:-}" ]; then
    case "$MAS_PROFILE" in
        /*) ;;
        "~/"*) MAS_PROFILE="$HOME/${MAS_PROFILE#\~/}" ;;
        *) MAS_PROFILE="$CALLER_DIR/$MAS_PROFILE" ;;
    esac
fi

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
sandbox=0; test_access=0; mas=0; mas_dry=0

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
        --sandbox) sandbox=1 ;;
        --sandbox-test-access) test_access=1 ;;
        --mas)     mas=1; sandbox=1 ;;
        --mas-dry-run) mas=1; mas_dry=1; sandbox=1 ;;
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

# Everything is assembled, signed and verified in a staging directory and only then moved to its
# final name, so nothing that failed half-way is ever found under dist/. The staging directory
# is inside dist/ to make that move a rename on one volume (which keeps the signature valid).
STAGE_DIR=""; DMG_STAGE=""; MAS_TMP=""
cleanup() {
    [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
    [ -z "$DMG_STAGE" ] || rm -rf "$DMG_STAGE"
    [ -z "$MAS_TMP" ] || rm -rf "$MAS_TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Sandboxed variants: options ------------------------------------------------------------

SANDBOX_ENTITLEMENTS="$ROOT/Resources/DiskSurvey.sandbox.entitlements"
TEST_ACCESS_ENTITLEMENTS="$ROOT/Resources/DiskSurvey.sandbox-test-access.entitlements"
MAS_BUILD_RECORD="$ROOT/Resources/mas-build-number"
PLISTBUDDY=/usr/libexec/PlistBuddy
BUNDLE_ID_IN_USE="dev.disksurvey.app"   # what Resources/Info.plist says; only sandboxed variants change it

if [ "$test_access" -eq 1 ] && [ "$sandbox" -eq 0 ]; then
    die "--sandbox-test-access is only valid together with --sandbox"
fi
if [ "$mas" -eq 1 ] && [ "$test_access" -eq 1 ]; then
    die "--sandbox-test-access must never go into an App Store build"
fi
if [ "$sandbox" -eq 1 ]; then
    [ "$notarize" -eq 0 ] || die "--notarize is for the Developer ID build; sandboxed builds are not notarized"
    [ "$make_dmg" -eq 0 ] && [ "$make_zip" -eq 0 ] || die "--dmg/--zip package the Developer ID build; use --mas for the App Store package"
    [ "$do_install" -eq 0 ] || die "--install is for the normal build; open a sandboxed build from dist/ (--run)"
    [ -f "$SANDBOX_ENTITLEMENTS" ] || die "missing $SANDBOX_ENTITLEMENTS"
    [ -x "$PLISTBUDDY" ] || die "required tool not found: $PLISTBUDDY"
    BUNDLE_ID_IN_USE="${BUNDLE_ID:-dev.disksurvey.app}"
    [[ "$BUNDLE_ID_IN_USE" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "BUNDLE_ID may contain only letters, digits, hyphens and periods (got '$BUNDLE_ID_IN_USE')"
    if [ "$mas" -eq 1 ]; then
        APP="$DIST/$APP_NAME (App Store).app"
    elif [ "$test_access" -eq 1 ]; then
        # Not the name of the plain sandboxed build: this one reads the whole disk unasked.
        APP="$DIST/$APP_NAME (Sandbox Test Access).app"
    else
        APP="$DIST/$APP_NAME (Sandbox).app"
    fi
fi
if [ "$test_access" -eq 1 ]; then
    [ -f "$TEST_ACCESS_ENTITLEMENTS" ] || die "missing $TEST_ACCESS_ENTITLEMENTS"
    printf '\033[1;31m%s\033[0m\n' \
        "################################################################################" \
        "#  --sandbox-test-access: this build may read and write the WHOLE DISK without  #" \
        "#  asking (temporary-exception entitlement for \"/\"). It exists for the headless #" \
        "#  harness only. NEVER distribute it and never submit it to the App Store.      #" \
        "################################################################################" >&2
fi

# --- Mac App Store preflight ----------------------------------------------------------------

# Everything that can be known before the (slow) build is checked here, and every problem is
# listed, not just the first. With --mas a problem stops the run; with --mas-dry-run it is
# reported and the run goes on with stand-ins, so the remaining steps can still be exercised.
MAS_TEAM=""; MAS_APP_IDENTIFIER=""; MAS_PROFILE_PLIST=""
mas_problems=()
mas_problem() { mas_problems+=("$1"); }

mas_preflight() {
    local tool
    for tool in productbuild pkgutil security xattr; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
    done
    if [ "$native" -eq 1 ] || [ "$config" != release ]; then
        mas_problem "the App Store build must be a universal release build (drop --native/--debug)"
    fi
    [ "$do_run" -eq 0 ] || die "--run cannot be combined with --mas: a distribution-signed build is not meant to be launched from dist/"

    # Signing identities. Installer identities are not code-signing identities, so they are
    # looked up without a policy.
    local app_identity="${MAS_APP_IDENTITY:-}" installer_identity="${MAS_INSTALLER_IDENTITY:-}"
    if [ -z "$app_identity" ]; then
        mas_problem "MAS_APP_IDENTITY is not set (the \"Apple Distribution: Name (TEAMID)\" identity that signs the app)"
    else
        case "$app_identity" in
            "Apple Distribution:"*|"3rd Party Mac Developer Application:"*) ;;
            *) [[ "$app_identity" =~ ^[0-9A-Fa-f]{40}$ ]] \
                   || mas_problem "MAS_APP_IDENTITY must be an \"Apple Distribution: …\" or \"3rd Party Mac Developer Application: …\" identity (a Developer ID identity cannot sign for the App Store)" ;;
        esac
        security find-identity -v -p codesigning 2>/dev/null | grep -qF -- "$app_identity" \
            || mas_problem "MAS_APP_IDENTITY is not a valid code-signing identity in the keychain (check: security find-identity -v -p codesigning)"
    fi
    if [ -z "$installer_identity" ]; then
        mas_problem "MAS_INSTALLER_IDENTITY is not set (the \"3rd Party Mac Developer Installer: Name (TEAMID)\" identity that signs the package)"
    else
        case "$installer_identity" in
            "3rd Party Mac Developer Installer:"*) ;;
            *) [[ "$installer_identity" =~ ^[0-9A-Fa-f]{40}$ ]] \
                   || mas_problem "MAS_INSTALLER_IDENTITY must be a \"3rd Party Mac Developer Installer: …\" identity (certificate type: Mac Installer Distribution)" ;;
        esac
        security find-identity -v 2>/dev/null | grep -qF -- "$installer_identity" \
            || mas_problem "MAS_INSTALLER_IDENTITY is not a valid identity in the keychain (check: security find-identity -v)"
    fi

    # Provisioning profile: a CMS-signed property list. The identifiers that go into the
    # entitlements are read from it rather than typed, because they have to match exactly.
    MAS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/disksurvey-mas.XXXXXX")"
    local profile="${MAS_PROFILE:-}"
    if [ -z "$profile" ]; then
        mas_problem "MAS_PROFILE is not set (path to the \"Mac App Store Connect\" provisioning profile)"
    elif [ ! -f "$profile" ]; then
        mas_problem "MAS_PROFILE: no such file: $profile"
    elif ! security cms -D -i "$profile" -o "$MAS_TMP/profile.plist" 2>/dev/null || ! plutil -lint "$MAS_TMP/profile.plist" >/dev/null 2>&1; then
        mas_problem "MAS_PROFILE is not a provisioning profile that 'security cms -D' can decode: $profile"
    else
        MAS_PROFILE_PLIST="$MAS_TMP/profile.plist"
        local pb=("$PLISTBUDDY" -c)
        local name expires now
        name="$("${pb[@]}" 'Print :Name' "$MAS_PROFILE_PLIST" 2>/dev/null || echo '?')"
        MAS_APP_IDENTIFIER="$("${pb[@]}" 'Print :Entitlements:com.apple.application-identifier' "$MAS_PROFILE_PLIST" 2>/dev/null || true)"
        MAS_TEAM="$("${pb[@]}" 'Print :Entitlements:com.apple.developer.team-identifier' "$MAS_PROFILE_PLIST" 2>/dev/null \
            || "${pb[@]}" 'Print :TeamIdentifier:0' "$MAS_PROFILE_PLIST" 2>/dev/null || true)"
        [ -n "$MAS_APP_IDENTIFIER" ] || mas_problem "the profile has no com.apple.application-identifier entitlement (is it a macOS App Store profile?)"
        [ -n "$MAS_TEAM" ] || mas_problem "the profile names no team identifier"
        if "${pb[@]}" 'Print :ProvisionedDevices' "$MAS_PROFILE_PLIST" >/dev/null 2>&1; then
            mas_problem "the profile lists devices: it is a development profile, not a \"Mac App Store Connect\" distribution profile"
        fi
        if [ "$("${pb[@]}" 'Print :ProvisionsAllDevices' "$MAS_PROFILE_PLIST" 2>/dev/null || true)" = true ]; then
            mas_problem "the profile provisions all devices: it is a Developer ID profile, not a \"Mac App Store Connect\" profile"
        fi
        if [ "$("${pb[@]}" 'Print :Entitlements:com.apple.security.get-task-allow' "$MAS_PROFILE_PLIST" 2>/dev/null || true)" = true ]; then
            mas_problem "the profile allows debugging (get-task-allow): it is a development profile"
        fi
        case "$("${pb[@]}" 'Print :Platform:0' "$MAS_PROFILE_PLIST" 2>/dev/null || true)" in
            OSX|"") ;;
            *) mas_problem "the profile is not for macOS" ;;
        esac
        # ISO 8601 in UTC compares correctly as text.
        expires="$(plutil -extract ExpirationDate raw -o - "$MAS_PROFILE_PLIST" 2>/dev/null || true)"
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [ -n "$expires" ] && [[ "$expires" < "$now" ]]; then
            mas_problem "the profile expired on $expires"
        fi
        if [ -n "$MAS_APP_IDENTIFIER" ] && [ -n "$MAS_TEAM" ] && [ "$MAS_APP_IDENTIFIER" != "$MAS_TEAM.$BUNDLE_ID_IN_USE" ]; then
            mas_problem "the profile is for '$MAS_APP_IDENTIFIER' but this build is '$MAS_TEAM.$BUNDLE_ID_IN_USE' (set BUNDLE_ID to the App ID's bundle identifier; a wildcard profile is not accepted)"
        fi
        # The profile must have been made for the certificate that signs. Advisory only: the
        # comparison depends on how the keychain prints the identity.
        if [ -n "$app_identity" ]; then
            local hash index=0 found=0 der
            hash="$(security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$app_identity" | awk 'NR==1 {print $2}' || true)"
            while der="$(plutil -extract "DeveloperCertificates.$index" raw -o - "$MAS_PROFILE_PLIST" 2>/dev/null)"; do
                if [ -n "$hash" ] && [ "$(printf '%s' "$der" | base64 -D 2>/dev/null | shasum -a 1 | awk '{print toupper($1)}')" = "$hash" ]; then found=1; fi
                index=$((index + 1))
            done
            if [ -n "$hash" ] && [ "$index" -gt 0 ] && [ "$found" -eq 0 ]; then
                warn "the profile does not seem to include the certificate of MAS_APP_IDENTITY; App Store Connect would reject the build"
            fi
        fi
        printf '    profile      %s (expires %s)\n' "$name" "${expires:-?}"
    fi

    # CFBundleVersion: App Store Connect refuses a build number it has seen, so it only ever
    # goes up. The last one used is kept in a file that belongs in the repository.
    local last=0
    if [ -f "$MAS_BUILD_RECORD" ]; then
        last="$(tr -d ' \t\r\n' < "$MAS_BUILD_RECORD")"
        [[ "$last" =~ ^[0-9]+$ ]] || die "$MAS_BUILD_RECORD must hold one whole number (got '$last')"
    fi
    if [ -n "${BUILD_NUMBER:-}" ]; then
        if ! [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
            mas_problem "BUILD_NUMBER must be a whole number for the App Store build (got '$BUILD_NUMBER')"
        elif [ "$BUILD_NUMBER" -le "$last" ]; then
            mas_problem "BUILD_NUMBER $BUILD_NUMBER is not greater than the last one used ($last, see Resources/mas-build-number)"
        fi
    else
        BUILD_NUMBER=$((last + 1))
    fi

    printf '    bundle id    %s\n' "$BUNDLE_ID_IN_USE"
    printf '    app id       %s\n' "${MAS_APP_IDENTIFIER:-(unknown: no profile)}"
    printf '    build        %s (last used: %s)\n' "$BUILD_NUMBER" "$last"

    if [ "${#mas_problems[@]}" -gt 0 ]; then
        if [ "$mas_dry" -eq 1 ]; then
            warn "a real --mas run would stop here:"
        else
            printf '\033[31merror:\033[0m the App Store build cannot start:\n' >&2
        fi
        local problem
        for problem in "${mas_problems[@]}"; do printf '    - %s\n' "$problem" >&2; done
        [ "$mas_dry" -eq 1 ] || exit 1
    fi
    # Stand-ins, so that a dry run can still assemble and check the bundle.
    if [ "$mas_dry" -eq 1 ]; then
        [ -n "$MAS_TEAM" ] || MAS_TEAM="DRYRUNTEAM"
        [ -n "$MAS_APP_IDENTIFIER" ] || MAS_APP_IDENTIFIER="$MAS_TEAM.$BUNDLE_ID_IN_USE"
        [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || BUILD_NUMBER=$((last + 1))
    fi
}

if [ "$mas" -eq 1 ]; then
    if [ "$mas_dry" -eq 1 ]; then say "Mac App Store preflight (dry run)"; else say "Mac App Store preflight"; fi
    mas_preflight
fi

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
# A sandboxed variant has outputs of its own and leaves the normal build's alone; a dry run
# leaves everything alone.
if [ "$sandbox" -eq 0 ]; then
    rm -rf "$APP"
    shopt -s nullglob
    rm -f "$DIST/$PKG_NAME"-*.dmg "$DIST/$PKG_NAME"-*.zip
    shopt -u nullglob
elif [ "$mas_dry" -eq 0 ]; then
    rm -rf "$APP"
    if [ "$mas" -eq 1 ]; then
        shopt -s nullglob
        rm -f "$DIST/$PKG_NAME"-*-mas.pkg
        shopt -u nullglob
    fi
fi

# The command line tool is not part of a sandboxed build: sandboxed, it could not read what a
# user names on the command line, and the App Store wants every executable in the bundle sandboxed.
if [ "$sandbox" -eq 1 ]; then products="$APP_PRODUCT"; else products="$APP_PRODUCT $CLI_PRODUCT"; fi

for arch in $archs; do
    for product in $products; do
        say "Building $product ($config, $arch)"
        swift build -c "$config" --triple "$arch-apple-macosx$MIN_MACOS" \
            --scratch-path "$ROOT/.build-pkg-$arch" --product "$product"
    done
done

# --- Assemble the bundle --------------------------------------------------------------------

say "Assembling $(basename "$APP")"
mkdir -p "$DIST"
STAGE_DIR="$(mktemp -d "$DIST/.stage.XXXXXX")"
# The bundle keeps its real name while it is signed; only its parent directory is temporary.
# (The App Store package installs "Disk Survey.app", so that variant is staged under the plain
# name and only its copy in dist/ is called "(App Store)".)
if [ "$sandbox" -eq 1 ] && [ "$mas" -eq 0 ]; then
    STAGE_APP="$STAGE_DIR/$(basename "$APP")"
else
    STAGE_APP="$STAGE_DIR/$APP_NAME.app"
fi
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
binaries=("$STAGE_APP/Contents/MacOS/$EXEC_NAME")
if [ "$sandbox" -eq 0 ]; then
    mkdir -p "$STAGE_APP/Contents/Helpers"
    binaries+=("$STAGE_APP/Contents/Helpers/$CLI_NAME")
fi

app_slices=(); cli_slices=(); first_bin=""
for arch in $archs; do
    bin="$(bin_dir_for "$arch")"
    [ -x "$bin/$APP_PRODUCT" ] || die "missing build product: $bin/$APP_PRODUCT"
    app_slices+=("$bin/$APP_PRODUCT")
    if [ "$sandbox" -eq 0 ]; then
        [ -x "$bin/$CLI_PRODUCT" ] || die "missing build product: $bin/$CLI_PRODUCT"
        cli_slices+=("$bin/$CLI_PRODUCT")
    fi
    [ -n "$first_bin" ] || first_bin="$bin"
done
lipo -create "${app_slices[@]}" -output "$STAGE_APP/Contents/MacOS/$EXEC_NAME"
if [ "$sandbox" -eq 0 ]; then
    lipo -create "${cli_slices[@]}" -output "$STAGE_APP/Contents/Helpers/$CLI_NAME"
fi
chmod 755 "${binaries[@]}"

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
if [ "$sandbox" -eq 1 ]; then
    plutil -replace CFBundleIdentifier -string "$BUNDLE_ID_IN_USE" "$STAGE_APP/Contents/Info.plist"
fi
if [ "$mas" -eq 1 ]; then
    # Without the first key App Store Connect asks the export-compliance questions at every
    # upload (the app uses no encryption); the second is the store category.
    plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$STAGE_APP/Contents/Info.plist" >/dev/null 2>&1 \
        || plutil -insert ITSAppUsesNonExemptEncryption -bool NO "$STAGE_APP/Contents/Info.plist"
    plutil -extract LSApplicationCategoryType raw -o - "$STAGE_APP/Contents/Info.plist" >/dev/null 2>&1 \
        || plutil -insert LSApplicationCategoryType -string "public.app-category.utilities" "$STAGE_APP/Contents/Info.plist"
    if [ -n "$MAS_PROFILE_PLIST" ]; then
        cp "$MAS_PROFILE" "$STAGE_APP/Contents/embedded.provisionprofile"
    fi
fi
plutil -lint "$STAGE_APP/Contents/Info.plist" >/dev/null || die "Info.plist is not a valid property list"
printf 'APPL????' > "$STAGE_APP/Contents/PkgInfo"

# --- Strip ----------------------------------------------------------------------------------

if [ "$config" = release ]; then
    say "Stripping symbols"
    # -S: debug symbols, -x: local symbols. Global symbols stay so crash reports remain readable.
    strip -S -x "${binaries[@]}" 2>/dev/null \
        || warn "strip reported a problem; continuing with unstripped binaries"
fi

# --- Sign -----------------------------------------------------------------------------------

IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$mas" -eq 1 ]; then
    # The App Store build is signed with the distribution identity; a dry run has none.
    if [ "$mas_dry" -eq 1 ]; then IDENTITY="-"; else IDENTITY="$MAS_APP_IDENTITY"; fi
fi
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
if [ "$sandbox" -eq 0 ]; then
    # Signed inside-out — the helper first, then the bundle that seals it — which is what Apple
    # recommends over a blanket `--deep` (that would re-sign the helper and drop its identifier).
    # SwiftPM resource bundles contain no code, so they are covered by the bundle's resource seal.
    codesign "${sign_opts[@]}" --identifier "dev.disksurvey.cli" "$STAGE_APP/Contents/Helpers/$CLI_NAME" 2>&1 \
        | { grep -v 'replacing existing signature' || true; }
    codesign "${sign_opts[@]}" "$STAGE_APP" 2>&1 | { grep -v 'replacing existing signature' || true; }
else
    # The sandbox is switched on by the entitlements in the signature. They go on the main
    # executable only (there is no other code in the bundle); the file must be plain XML.
    ENTITLEMENTS="$STAGE_DIR/app.entitlements"
    if [ "$test_access" -eq 1 ]; then
        cp "$TEST_ACCESS_ENTITLEMENTS" "$ENTITLEMENTS"
    else
        cp "$SANDBOX_ENTITLEMENTS" "$ENTITLEMENTS"
    fi
    if [ "$mas" -eq 1 ]; then
        # Must equal the embedded profile's values, which is where they come from.
        "$PLISTBUDDY" -c "Add :com.apple.application-identifier string $MAS_APP_IDENTIFIER" "$ENTITLEMENTS"
        "$PLISTBUDDY" -c "Add :com.apple.developer.team-identifier string $MAS_TEAM" "$ENTITLEMENTS"
        # Uploads are refused if any file carries a quarantine attribute.
        xattr -cr "$STAGE_APP"
    fi
    plutil -lint "$ENTITLEMENTS" >/dev/null || die "the entitlements file is not a valid property list"
    codesign "${sign_opts[@]}" --entitlements "$ENTITLEMENTS" "$STAGE_APP" 2>&1 | { grep -v 'replacing existing signature' || true; }
fi

# --- Verify ---------------------------------------------------------------------------------

say "Verifying"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"
expected="$(echo $archs | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
for binary in "${binaries[@]}"; do
    actual="$(lipo -archs "$binary" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
    [ "$actual" = "$expected" ] || die "$(basename "$binary") has architectures '$actual', expected '$expected'"
    printf '    %-12s %s\n' "$(basename "$binary")" "$actual"
done

if [ "$sandbox" -eq 1 ]; then
    # What the signature really carries, read back from the signed bundle.
    SIGNED_ENTITLEMENTS="$STAGE_DIR/signed.entitlements"
    codesign -d --entitlements - --xml "$STAGE_APP" > "$SIGNED_ENTITLEMENTS" 2>/dev/null \
        || die "cannot read the entitlements back from the signed app"
    entitlement() { "$PLISTBUDDY" -c "Print :$1" "$SIGNED_ENTITLEMENTS" 2>/dev/null || true; }
    [ "$(entitlement com.apple.security.app-sandbox)" = true ] || die "the signed app is not sandboxed"
    [ "$(entitlement com.apple.security.files.user-selected.read-write)" = true ] || die "the signed app lacks files.user-selected.read-write"
    [ "$(entitlement com.apple.security.files.bookmarks.app-scope)" = true ] || die "the signed app lacks files.bookmarks.app-scope"
    if [ "$test_access" -eq 1 ]; then
        grep -q 'temporary-exception' "$SIGNED_ENTITLEMENTS" || die "the test-access exception is missing from the signature"
        printf '    %-12s %s\n' "sandbox" "on, WITH the whole-disk test exception (not for distribution)"
    else
        ! grep -q 'temporary-exception' "$SIGNED_ENTITLEMENTS" || die "the signed app carries a temporary exception; that must not ship"
        printf '    %-12s %s\n' "sandbox" "on (user-selected read-write, app-scope bookmarks)"
    fi
    [ ! -e "$STAGE_APP/Contents/Helpers" ] || die "a sandboxed build must not contain the command line tool"
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$STAGE_APP/Contents/Info.plist")" = "$BUNDLE_ID_IN_USE" ] || die "the bundle identifier was not stamped"
    printf '    %-12s %s\n' "bundle id" "$BUNDLE_ID_IN_USE"
fi

# --- Mac App Store package ------------------------------------------------------------------

if [ "$mas" -eq 1 ]; then
    [ "$(entitlement com.apple.application-identifier)" = "$MAS_APP_IDENTIFIER" ] || die "application-identifier in the signature is not '$MAS_APP_IDENTIFIER'"
    [ "$(entitlement com.apple.developer.team-identifier)" = "$MAS_TEAM" ] || die "team-identifier in the signature is not '$MAS_TEAM'"
    [ "$(plutil -extract CFBundleVersion raw -o - "$STAGE_APP/Contents/Info.plist")" = "$BUILD_NUMBER" ] || die "CFBundleVersion was not stamped"
    [ "$(plutil -extract ITSAppUsesNonExemptEncryption raw -o - "$STAGE_APP/Contents/Info.plist")" = false ] || die "ITSAppUsesNonExemptEncryption is not false"
    [ -n "$(plutil -extract LSApplicationCategoryType raw -o - "$STAGE_APP/Contents/Info.plist")" ] || die "LSApplicationCategoryType is missing"
    if [ -n "$MAS_PROFILE_PLIST" ]; then
        cmp -s "$MAS_PROFILE" "$STAGE_APP/Contents/embedded.provisionprofile" || die "the provisioning profile was not embedded"
    fi
    ! xattr -lr "$STAGE_APP" 2>/dev/null | grep -q 'com.apple.quarantine' || die "a file in the bundle carries a quarantine attribute"

    pkg_name="$PKG_NAME-$VERSION-$BUILD_NUMBER-mas.pkg"
    if [ "$mas_dry" -eq 1 ]; then
        say "Packaging (dry run: unsigned, discarded)"
        productbuild --component "$STAGE_APP" /Applications "$STAGE_DIR/$pkg_name" >/dev/null
        pkgutil --payload-files "$STAGE_DIR/$pkg_name" | grep -q "^\./$APP_NAME.app/Contents/MacOS/$EXEC_NAME\$" \
            || die "the package does not contain $APP_NAME.app"
        printf '    %s would install /Applications/%s.app (version %s, build %s)\n' "$pkg_name" "$APP_NAME" "$VERSION" "$BUILD_NUMBER"
        say "Dry run complete"
        echo "    Checked: build, bundle layout without the command line tool, Info.plist keys, entitlements"
        echo "    with application and team identifier, ad-hoc signature with those entitlements, package layout."
        echo "    NOT done: signing with the distribution identity, signing the package, validation by Apple."
        if [ "${#mas_problems[@]}" -gt 0 ]; then
            echo "    Still missing for a real --mas run:"
            for problem in "${mas_problems[@]}"; do printf '      - %s\n' "$problem"; done
        fi
        echo "    Nothing was left in dist/ and Resources/mas-build-number was not changed."
        exit 0
    fi

    say "Packaging $pkg_name"
    productbuild --sign "$MAS_INSTALLER_IDENTITY" --component "$STAGE_APP" /Applications "$STAGE_DIR/$pkg_name"
    pkgutil --check-signature "$STAGE_DIR/$pkg_name" >/dev/null || die "the package signature does not verify"
    mv -f "$STAGE_DIR/$pkg_name" "$DIST/$pkg_name"
    # Only now is the number used up.
    printf '%s\n' "$BUILD_NUMBER" > "$MAS_BUILD_RECORD"
fi

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
if [ "$test_access" -eq 1 ]; then
    warn "this build carries the whole-disk test exception: for the harness only, never distribute it"
fi
if [ "$mas" -eq 1 ]; then
    printf '    %s  %s\n' "$DIST/$pkg_name" "$(size_of "$DIST/$pkg_name")"
    echo "    Build number $BUILD_NUMBER is recorded in Resources/mas-build-number; commit that file."
    echo "    Next (needs an App Store Connect API key, see DEVELOPMENT.md):"
    echo "      xcrun altool --validate-app \"$DIST/$pkg_name\" --api-key <key id> --api-issuer <issuer id>"
    echo "      xcrun altool --upload-package \"$DIST/$pkg_name\" --api-key <key id> --api-issuer <issuer id> --wait"
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

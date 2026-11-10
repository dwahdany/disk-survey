#!/bin/bash
# Puts the `disksurvey` command line tool on your PATH by symlinking the copy inside Disk Survey.app.
#
#   Scripts/install-cli.sh [--app "/path/to/Disk Survey.app"] [--dir BIN_DIR] [--uninstall]
#
#   --app PATH    the Disk Survey.app to link to. Default: the first of /Applications/Disk Survey.app,
#                 ~/Applications/Disk Survey.app, dist/Disk Survey.app (this checkout).
#   --dir PATH    where to create the link. Default: /usr/local/bin if it is writable,
#                 otherwise ~/.local/bin (created if needed). Never uses sudo.
#   --uninstall   remove the link (only if it points into a Disk Survey.app).
#
# A symlink (rather than a copy) means updating the app updates the tool too.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
NAME="disksurvey"
app=""; dir=""; uninstall=0

usage() { sed -n '2,/^$/p' "$0" | sed -e 's/^# \{0,1\}//'; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --app)       [ $# -ge 2 ] || die "--app needs a path"; app="$2"; shift ;;
        --dir)       [ $# -ge 2 ] || die "--dir needs a path"; dir="$2"; shift ;;
        --uninstall) uninstall=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

if [ -z "$dir" ]; then
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then dir=/usr/local/bin; else dir="$HOME/.local/bin"; fi
fi
link="$dir/$NAME"

if [ "$uninstall" -eq 1 ]; then
    if [ -L "$link" ]; then
        case "$(readlink "$link")" in
            *"/Disk Survey.app/Contents/Helpers/$NAME") rm "$link"; echo "Removed $link" ;;
            *) die "$link does not point into a Disk Survey.app; leaving it alone" ;;
        esac
    else
        echo "Nothing to remove at $link"
    fi
    exit 0
fi

if [ -z "$app" ]; then
    for candidate in "/Applications/Disk Survey.app" "$HOME/Applications/Disk Survey.app" "$ROOT/dist/Disk Survey.app"; do
        if [ -x "$candidate/Contents/Helpers/$NAME" ]; then app="$candidate"; break; fi
    done
    [ -n "$app" ] || die "Disk Survey.app not found; build it first (Scripts/build-app.sh --install) or pass --app"
fi
app="$(cd "$app" 2>/dev/null && pwd -P)" || die "no such app bundle"
target="$app/Contents/Helpers/$NAME"
[ -x "$target" ] || die "no command line tool at $target"

mkdir -p "$dir"
if [ -e "$link" ] && [ ! -L "$link" ]; then
    die "$link exists and is not a symlink; remove it yourself if you want it replaced"
fi
ln -sfn "$target" "$link"
echo "Linked $link -> $target"

case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "Note: $dir is not on your PATH. Add this to your shell profile:"
       echo "    export PATH=\"$dir:\$PATH\"" ;;
esac

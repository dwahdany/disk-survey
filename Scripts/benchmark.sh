#!/bin/bash
# Times a scan of one folder with Disk Survey's command line tool and with other disk-usage
# tools, then records each tool's peak memory. Needs hyperfine and the other tools on PATH:
#
#   nix-shell -p hyperfine ncdu gdu dust dua diskus --run 'Scripts/benchmark.sh <label> <path> [runs]'
#
# Writes <label>.json (hyperfine) and <label>.rss (peak resident memory in bytes) into the
# current directory. Build the app first (Scripts/build-app.sh).
set -euo pipefail
[[ $# -ge 2 ]] || { sed -n '2,9p' "$0" >&2; exit 2; }
label="$1"; P="$2"; runs="${3:-5}"
here="$(cd "$(dirname "$0")/.." && pwd)"
DS="${DISKSURVEY:-$here/dist/Disk Survey.app/Contents/Helpers/disksurvey}"
[[ -x "$DS" ]] || { echo "not found: $DS" >&2; exit 1; }

names=(disksurvey diskus dua dust gdu ncdu du)
cmds=("'$DS' '$P' -d 0" "diskus '$P'" "dua aggregate '$P'" "dust -P -d 0 '$P'" "gdu -npc '$P'"
      "ncdu -0 -o /dev/null '$P'" "du -sk '$P'")

# -i: unreadable folders make several of the tools exit non-zero. One warm-up run fills the cache.
args=()
for i in "${!names[@]}"; do args+=(-n "${names[$i]}" "${cmds[$i]}"); done
hyperfine -i -N --warmup 1 --runs "$runs" --export-json "$label.json" "${args[@]}"

for i in "${!names[@]}"; do
    rss=$(/usr/bin/time -l sh -c "exec ${cmds[$i]} >/dev/null 2>&1" 2>&1 | awk '/maximum resident set size/{print $1}')
    echo "${names[$i]} $rss"
done | tee "$label.rss"

# Developing Disk Survey

How to build, test, measure and release Disk Survey. For what the app does and how to use it,
see the [README](README.md).

- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Tests](#tests)
- [Checking the app without a person at the screen](#checking-the-app-without-a-person-at-the-screen)
- [Screenshots](#screenshots)
- [Performance measurements](#performance-measurements)
- [Signing and notarization](#signing-and-notarization)
- [Sandboxed and App Store builds](#sandboxed-and-app-store-builds)
- [Releasing on GitHub](#releasing-on-github)
- [Architecture](#architecture)

## Requirements

- The Command Line Tools (`xcode-select --install`) with Swift 6.2 or later. Xcode is not
  required, except for notarization. If `xcode-select` points at an Xcode whose license has not
  been accepted, the scripts fall back to the Command Line Tools by themselves; for bare `swift`
  commands set `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
- No third-party packages. Because the Command Line Tools lack SwiftUI's macro plugin, the app
  uses no `@State` or `#Preview` (it is built on `@Observable` models), and the tests use Swift
  Testing rather than XCTest.

## Build and run

```sh
Scripts/build-app.sh --native --run     # quick build for this Mac, then launch
Scripts/build-app.sh                    # universal build → dist/Disk Survey.app
Scripts/build-app.sh --install          # … and copy to /Applications (or ~/Applications)
Scripts/build-app.sh --dmg --zip        # … and package dist/DiskSurvey-<version>.dmg / .zip
```

| Option      | Effect                                                                 |
|-------------|------------------------------------------------------------------------|
| `--native`  | Build only this Mac's architecture. Faster; not for distribution.     |
| `--debug`   | Debug configuration, symbols kept.                                     |
| `--dmg`     | Compressed disk image with an `/Applications` shortcut.                |
| `--zip`     | Zip archive made with `ditto` (keeps the signature intact).            |
| `--install` | Copy the app to `/Applications`, or `~/Applications` if not writable.  |
| `--run`     | Open the app when the build finishes.                                  |
| `--sandbox`, `--sandbox-test-access`, `--mas`, `--mas-dry-run` | The sandboxed variants; see [Sandboxed and App Store builds](#sandboxed-and-app-store-builds). |

Every run starts by removing `dist/Disk Survey.app` and any `dist/DiskSurvey-*.dmg` / `.zip`,
and the new bundle and packages only appear under those names once they are complete, signed
and verified. So whatever is in `dist/` belongs to the last successful run: a failed build leaves
nothing behind, and a run without `--dmg`/`--zip` leaves no package from an earlier build.

The script builds each architecture into its own SwiftPM scratch directory
(`.build-pkg-arm64`, `.build-pkg-x86_64`), joins them with `lipo`, assembles the bundle, strips
symbols, signs it and verifies the result. The version comes from the `VERSION` file.

During development you can also run the targets straight from SwiftPM
(`swift run DiskSurveyApp`, `swift run disksurvey-cli`).

## Tests

```sh
Scripts/test.sh                                   # everything: 316 tests in five targets
Scripts/test.sh --filter TrashServiceTests        # one suite
DISKSURVEY_TEST_REAL_TRASH=1 Scripts/test.sh --filter TrashServiceTests
```

`Scripts/test.sh` wraps `swift test` so that Swift Testing works with only the Command Line
Tools. The scanner tests read real system folders (`/System/Library`, `/usr`) and assume an
APFS startup volume. The Move to Trash tests use a stand-in Trash in a temporary folder; only
with `DISKSURVEY_TEST_REAL_TRASH=1` does one test move a temporary fixture into the real Trash,
check that it arrived, and delete it from there again. The app itself has no test target;
its checks run inside the app with `DiskSurvey --self-test` (see
[the next section](#checking-the-app-without-a-person-at-the-screen)).

## Checking the app without a person at the screen

The app has a few hidden launch arguments that drive it into a state, write a PNG of its
window and exit. They work on the bare executable (`swift run DiskSurveyApp …`) and on the
bundle's; `DiskSurvey` below stands for `"dist/Disk Survey.app/Contents/MacOS/DiskSurvey"`
(quoted, because the bundle name contains a space):

```sh
DiskSurvey --scan ~/Library --snapshot out.png --window-size 1440x900 --appearance dark
DiskSurvey --snapshot start.png                         # the start screen
DiskSurvey --scan /usr --inspector largest --search lib --snapshot search.png
DiskSurvey --scan / --during-scan 2.5 --snapshot scanning.png
DiskSurvey --scan / --measure-stalls                    # worst main-thread stall per operation
DiskSurvey --synthetic 5000000 --measure-stalls         # a generated five-million-node tree
DiskSurvey --self-test                                  # in-app checks; prints PASS/FAIL, exit status 1 on failure
```

Other switches: `--select <path>`, `--zoom <path>`, `--color kind|age`,
`--style adaptive|framed|grouped|cushion`, `--depth 1…4|all`, `--hover <path>` (hover outline and
tooltip for that item), `--settings general|scanning|appearance`, `--trash-sheet`,
`--cancel-after <seconds>`, `--dump-menu`, and `--exercise-actions` (trash, undo and rescan
against a throwaway folder that must be named `disksurvey-action-test`; `--action-fixture` makes
one in the temporary folder and scans it), and `--sandbox-report` (what the process is and can
reach: sandbox, home, grants, Full Disk Access; results only, no file names). The picture comes from
the window server when it is available, which shows glass and vibrancy as on screen; while the
screen is locked it falls back to AppKit's display cache, which shows the layout but not the
materials (and, in the dark appearance, draws the inspector's text too dark; a window-server
capture of the same view taken earlier is correct, so this is believed to be an artifact of
the fallback). Harness runs use their own settings domain and leave
Recents alone.

`--self-test` scans a small fixture it creates in the temporary folder and a generated tree, and
checks things that need a running app: command enabling, the outline's row reuse, stale result
rows, icon caching, which views are re-evaluated by which change, the split view's limits, the
map's depth setting, that a drag onto the Trash acts on the dragged items rather than the selection, and
the access plumbing of the sandboxed edition (sandbox detection, the real home folder, and the
access manager with real security-scoped bookmarks for the fixture: adopt, share, release,
resolve after a "relaunch", no second record for a folder inside an allowed one, a folder's own
grant winning over a broader one in use, a location chosen again after its grant was removed,
a folder reached through a symbolic link or written in other letter case, a background check
that writes nothing, a bookmark that no longer resolves being dropped and one on a disk that
is not connected being kept). The scan
window's minimum width is 842 pt while the inspector is open and 760 pt otherwise.

## Screenshots

The pictures in the README show a made-up home folder, not anybody's disk.
`Scripts/make-demo-tree.py` writes it: about 19,000 files with invented names under
`Users/alex`, each one an APFS clone of a single 8 GB base file truncated to the wanted length.
Clones are counted at their full size (see [Accounting notes](README.md#accounting-notes)), so
the tree reports 823 GB while occupying 8 GB. Putting it on a disk image keeps the paths clean:

```sh
hdiutil create -type SPARSE -fs APFS -size 1t -volname Demo demo.sparseimage
hdiutil attach demo.sparseimage -nobrowse
Scripts/make-demo-tree.py /Volumes/Demo

R=/Volumes/Demo/Users/alex; S="--window-size 1440x900 --appearance light"
DiskSurvey --scan $R $S --snapshot docs/images/overview-light.png
DiskSurvey --scan $R --window-size 1440x900 --appearance dark --snapshot docs/images/overview-dark.png
DiskSurvey --scan $R $S --depth 2 --snapshot docs/images/depth-2.png
DiskSurvey --scan $R $S --color age --snapshot docs/images/by-age.png
DiskSurvey --scan $R $S --zoom $R/Developer \
    --hover $R/Developer/ledger-api/target/debug/deps/lib001.rlib --snapshot docs/images/zoom-hover.png

hdiutil detach /Volumes/Demo && rm demo.sparseimage
```

The generator is seeded, so the same tree comes out every time (file ages are relative to the
day it runs). Take the pictures with the screen unlocked, so that they come from the window
server.

## Performance measurements

All figures are from the machine this was developed on (Apple M6, 12 cores, macOS 27.2,
internal APFS SSD, release build, warm file-system cache). Your numbers will differ.

### Compared with other tools

`Scripts/benchmark.sh <label> <path> [runs]` times a scan of one folder with `disksurvey` and
with six other disk-usage tools using [hyperfine](https://github.com/sharkdp/hyperfine) (one
warm-up run, then the timed runs), and then records each tool's peak resident memory with
`/usr/bin/time -l`:

```sh
nix-shell -p hyperfine ncdu gdu dust dua diskus --run 'Scripts/benchmark.sh home ~ 5'
```

Each tool runs in its fastest sensible mode, with one thread per core where it supports that
(`ncdu -t`, `diskus -j`; `du` is single-threaded). Results of 10 November 2026 with a warm
file-system cache, mean of the timed runs (fastest–slowest) and peak resident memory:

| Tool             | `/Applications`, 511,000 files, 10 runs | Home folder, 1.7 M files, 5 runs | Peak memory, home folder |
|------------------|----------------------|-------------------------|--------|
| disksurvey 1.0.0 | 0.67 s (0.64–0.74)   | 5.4 s (5.1–5.8)         | 218 MB |
| dua 2.46         | 0.80 s (0.79–0.82)   | 13.1 s (12.1–15.2)      | 41 MB  |
| ncdu 2.12        | 1.56 s (1.51–1.59)   | 10.2 s (9.2–13.3)       | 131 MB |
| dust 1.2.7       | 1.61 s (1.58–1.64)   | 13.4 s (13.3–13.6)      | 935 MB |
| diskus 0.9       | 1.63 s (1.49–1.98)   | 14.1 s (13.3–15.1)      | 55 MB  |
| gdu 5.38         | 1.81 s (1.78–1.85)   | 12.8 s (11.1–16.1)      | 80 MB  |
| du (macOS)       | 4.06 s (3.79–4.90)   | 41.8 s (41.0–42.8)      | 28 MB  |

With nothing cached the picture is different. A generated tree of 500,000 files in 50,000
folders on a disk image, unmounted and mounted again before every scan (which made each scan
read the same 176 MB from disk), five rounds with the tool order changed each time:

| Tool        | First scan, median (fastest–slowest) | Same tree, cached |
|-------------|--------------------|--------|
| dua         | 4.9 s (4.2–5.6)    | 0.75 s |
| disksurvey  | 4.9 s (4.0–4.9)    | 0.75 s |
| gdu         | 5.0 s (4.8–5.4)    | 1.51 s |
| diskus      | 5.1 s (4.7–5.8)    | 1.22 s |
| ncdu        | 5.2 s (5.1–5.5)    | 1.40 s |
| dust        | 5.5 s (5.3–5.7)    | 1.39 s |
| du          | 8.8 s (8.4–12.1)   | 3.88 s |

What the comparison does and does not show:

- Disk Survey has no cache of its own; every run walks the folder again. Its entry counts
  match `find` and its sizes match `du -sk` on the folders checked, so it does the same work.
- Cached, it was the fastest tool on both real folders: about 1.2× ahead of dua on
  `/Applications`, about 1.9× ahead of ncdu on the home folder, 6–8× ahead of `du`. On the
  generated tree it tied with dua.
- On a first scan the disk sets the pace. Disk Survey is level with the other parallel tools
  there and about 1.8× faster than `du`.
- It uses more memory than every tool but dust, because it keeps every item's name, sizes
  and date for the map, while most of the others only add sizes up.
- Scan times vary with what else the machine is doing; an earlier run of the same benchmark
  on a busier machine gave 6.5 s for the home folder and 8.9 s for `du` on `/Applications`.
- Only command-line tools are in it. Graphical apps such as Disk Inventory X, GrandPerspective
  or DaisyDisk cannot be timed without someone operating them, and were not measured.

The chart in the README is drawn from these numbers.

### Disk Survey by itself

| What                                                        | Result                                   |
|-------------------------------------------------------------|------------------------------------------|
| Whole startup disk, `disksurvey /` (4.29 M files, 1.11 M folders, 613 GB) | 12.5 s, 433,000 entries/s, 473 MB peak memory |
| Home folder (1.89 M files, 0.30 M folders, 400 GB)          | 5.3–5.9 s, 370,000–414,000 entries/s, 229 MB peak memory |
| `~/Library` (793,000 files, 134 GB), command line           | 2.0–2.7 s, 350,000–466,000 entries/s, 101 MB peak memory |
| `/Applications` (511,000 files, 40 GB)                      | 0.65 s, 900,000 entries/s, 60 MB peak memory |
| Command Line Tools folder (86,000 files, 1.42 GB)           | 0.16–0.29 s                              |
| Whole startup disk in the app, to the finished map          | 13–14 s, 0.86–0.89 GB peak memory        |
| Treemap layout, 2,000,000 nodes at 3000×2000 px (adaptive frames) | 5.6–6.0 ms                         |
| Cushion rendering of that map, all cores / one thread       | 4.1–4.4 ms / 25–30 ms                    |
| The same map limited to 1–3 folder levels, layout + rendering | 14–15 ms + 2.5–2.9 ms the first time, also when one folder holds nearly everything (the layout walks the collapsed folders once, on all cores, for their dominant colour); under 0.1 ms + 2.5–2.9 ms for every further frame of the same tree (resize, zoom back), which reuses the answer |
| Hit test                                                    | under 100 ns                             |

The scan cost is almost entirely kernel time (`open` and `getattrlistbulk` per folder), so
small, cached trees reach higher rates than a whole disk. The figures above come only from runs
in which no folder took long to open. That qualification matters on this machine (macOS 27.2):
opening a folder inside another app's container (`~/Library/Containers`, `Group Containers`)
makes the kernel sandbox ask `sandboxd` for approval, and now and then the waiting thread is not
woken: the `open` sits for almost exactly 5 seconds, fails with `EINTR`, and succeeds at once
when retried. That is a defect in the system (a plain C directory walker reproduces it), and it
used to turn a 5.3 s scan of the home folder into 6–12 s in about half the runs. The scanner
now has a watchdog that interrupts a folder `open` stuck for more than 250 ms (doubling the
allowance each time it has to interrupt the same folder, and leaving it alone past 4 s), so
the same folder is opened by the same code, only sooner; nothing is skipped. Each occurrence
now costs about 0.25–0.3 s on one thread: in six consecutive scans of `~/Library` (814,000
files, 138 GB) the times were 2.0–2.3 s, with one interrupted open among them. Disk Survey still
reports it (`held up 0,25 s opening …` on the command line), and
`ScanOptions.interruptStalledOpens` turns the watchdog off for diagnosis.

Memory is about 88 bytes per scanned item at the peak of a command-line scan (105 for the home
folder). The app needs more while it scans, because the map and outline show partial trees:
each one is a second copy of what has been read so far. Up to a million items the picture
refreshes every 0.6 s or so, then less and less often, and beyond two million items it stops
refreshing until the scan is done (the counters keep running). With that the whole-disk scan
above peaks at 0.86–0.89 GB in the app; without any live picture it would be 0.68 GB.

In the app, the worst main-thread stall per operation, measured with `--measure-stalls` on the
home folder (2.19 M items) and the startup disk (5.43 M items): selecting 4–37 ms, zooming
1–5 ms, a search 18–42 ms, switching between on-disk and logical sizes 19–40 ms, opening the
Largest or Info tab 11–22 ms, and 71–81 ms once while the finished scan is taken over. Nothing
exceeded 100 ms. (Measured with the screen locked, so the window was not being composited;
scanning, layout, rendering, search and tree updates all run off the main thread.)

Totals were compared with `du -sk` on four folders (`/Library/Developer/CommandLineTools`,
`/usr/share`, `/System/Library/Frameworks` and a source tree of 7.2 GB): identical to the byte
in each case.

## Signing and notarization

By default the app is signed ad hoc with the hardened runtime enabled. That is all you need on
the Mac that built it. An ad-hoc build copied to another Mac is quarantined by Gatekeeper; the
recipient has to allow it under System Settings → Privacy & Security → "Open Anyway".

For a build that opens cleanly elsewhere you need an Apple Developer ID:

```sh
# once: store credentials for notarytool in the keychain
xcrun notarytool store-credentials disksurvey-notary --apple-id you@example.com --team-id TEAMID

export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
Scripts/build-app.sh --notarize --dmg --zip
```

`--notarize` submits the app to Apple, staples the ticket to the bundle, then packages it, and
notarizes and staples the dmg as well.

## Sandboxed and App Store builds

The Mac App Store only takes sandboxed apps. There is one code base: the App Sandbox is switched
on by the entitlements in the signature, and the app asks `AppSandbox.isSandboxed` at run time.
That answer comes from the process's own signature (`com.apple.security.app-sandbox`), not
from `APP_SANDBOX_CONTAINER_ID`: a normal build started from an environment that inherited the
variable is not confined and must not behave as if it were. The variable is consulted only if
the signature cannot be read.
Nothing is compiled differently, so the tests and the harness exercise the code that ships.
**The sandboxed build is out as a public TestFlight beta
(<https://testflight.apple.com/join/ku8sJmCv>); it has not been released on the Mac App Store.
See [Not tested](#not-tested).**

```sh
Scripts/build-app.sh --native --sandbox          # dist/Disk Survey (Sandbox).app, ad hoc
# harness only → dist/Disk Survey (Sandbox Test Access).app:
BUNDLE_ID=dev.disksurvey.sandbox Scripts/build-app.sh --native --sandbox --sandbox-test-access
Scripts/build-app.sh --mas-dry-run               # the App Store steps, without certificates
Scripts/build-app.sh --mas                       # the App Store package (needs the three MAS_* variables)
```

Give ad hoc and Developer ID signed sandboxed builds different `BUNDLE_ID`s. A sandboxed app's
container belongs to the signer that first created it; a build with the same bundle identifier
from another signer is held before `main()` on a macOS consent prompt, so a harness run hangs
without output.

| Option | Effect |
|--------|--------|
| `--sandbox` | The same bundle without the command line tool, signed (ad hoc, or with `CODESIGN_IDENTITY`) with `Resources/DiskSurvey.sandbox.entitlements`: `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`. |
| `--sandbox-test-access` | Only with `--sandbox`, never for distribution. Signs with `Resources/DiskSurvey.sandbox-test-access.entitlements`, which adds a temporary exception for `/` (read-write), so the harness can run the sandboxed code without anyone clicking an open panel. The result has a name of its own, `dist/Disk Survey (Sandbox Test Access).app`, and a red "Test build — not for distribution" card on its start screen, so it cannot pass for the plain sandboxed build. |
| `--mas` | Universal release build, profile embedded, `application-identifier` and `team-identifier` taken from the profile, `ITSAppUsesNonExemptEncryption=false`, signed with `MAS_APP_IDENTITY`, verified, wrapped with `productbuild` and `MAS_INSTALLER_IDENTITY` into `dist/DiskSurvey-<version>-<build>-mas.pkg`. |
| `--mas-dry-run` | The same up to the distribution signature: lists what is missing, signs ad hoc, builds an unsigned package to check the layout, leaves nothing in `dist/`. |

`BUNDLE_ID` sets the bundle identifier of a sandboxed variant (default `dev.disksurvey.app`).
The sandboxed variants never touch `dist/Disk Survey.app` or its dmg/zip and cannot be combined
with `--dmg`, `--zip`, `--notarize` or `--install`. `--mas` checks everything it can before
building and lists every problem at once (identities missing or of the wrong type, a profile
that is expired, for development, for another App ID or a wildcard). A relative `MAS_PROFILE` is
taken from the directory the script is called in. Its build number is a whole
number that only goes up: the last one used is kept in `Resources/mas-build-number` (created by
the first successful `--mas` run; commit it), `BUILD_NUMBER` must be greater, and defaults to
that number plus one.

### What differs when sandboxed

- **File access.** Every way of choosing a scan root (open panel, drop, Dock and open-document
  events, volume cards, folder buttons, recents, Rescan Everything, launch arguments) goes
  through `AppModel.scan(_:in:)` and `AccessManager`. A location needs the app's container, a
  grant in use, or a stored grant: a security-scoped app-scope bookmark (read-write) in the user
  defaults (`accessGrants`). A grant covers everything below it. If nothing covers the location,
  an open panel pointed at it asks ("Grant Access"). The start screen offers "Allow Access to
  ‹startup disk›" so that one choice covers everything; Settings › Scanning lists the allowed
  locations. The window keeps the scope started (`AccessLease`, counted, stopped once when the
  last window lets go) while it shows the scan. The rules, most of them in
  `AccessGrantTable` (DiskSurveyScan) and covered by `SandboxAccessTests`:
  - A grant is filed under the path its bookmark resolves to (symbolic links resolved, the
    disk's letter case), and a request is looked up as given and in that spelling
    (`GrantPath.canonical`). When only the resolved spelling is covered, that is what is
    scanned and noted in the recents. A symbolic link itself cannot be bookmarked; the folder
    it points at is stored instead. If a new bookmark does not lead back to the chosen item
    (a folder of the Data volume that no firmlink shows on the startup disk), nothing is
    stored and the choice holds until the app quits.
  - `/System/Volumes/Data/<path>` counts as `/<path>` only below a firmlink
    (`GrantPath.firmlinks`, checked against `/usr/share/firmlinks` by a test).
  - A choice that a stored grant already covers adds no record. Only "Grant Access…" after a
    refused scan stores a grant for a folder inside an allowed one; from then on the most
    specific stored grant is used, also while a broader one is in use by another window.
  - A grant that is merely in use (removed in Settings while a window shows it, or never
    storable) is not "stored": choosing the location again makes and stores a bookmark.
  - Bookmarks are resolved without user interface and without mounting. One that does not
    resolve is dropped, unless it is on `/Volumes/<name>` and that disk is not connected (told
    by the volume UUID kept with the record, else by the mount point): then it is kept. Two
    disks that mount under one name keep a record each. A stale bookmark is made again, and
    dropped if that fails. File › Open Recent refuses a location that is not there.
  - With 64 records the table is full; records inside a broader grant go first, then the least
    recently used.
  - The Full Disk Access check on activation only looks (`AccessGrantTable.peek`): it writes
    nothing, marks nothing as used and drops nothing. Mount and unmount events do not run it.
- **A scan root that macOS refuses** although a grant covers it gives an alert that says the
  folder is probably protected separately and needs Full Disk Access in addition, with "Open
  Privacy Settings…"; "Grant Access…" is offered only while the folder itself has not been
  chosen (`RootDenialAdvice`). Nothing in it promises that either remedy works. A protected
  folder can usually be examined but not listed, which the scanner reports as an empty folder
  with one issue (`ScanResult.rootWasRefused`); sandboxed, that gets the alert too, where the
  normal build shows the empty map with its notice.
- **Home folder.** From `getpwuid` (`AppSandbox.realHomeDirectory`); `NSHomeDirectory()` and `~`
  are the container.
- **Full Disk Access** is three-valued (`FullDiskAccess`): granted, not granted, or unknown
  while no grant reaches the locations the check probes. It is needed *in addition to* choosing
  the disk; the wording says so and does not promise more.
- **Actions.** Move to Trash, Put Back, Reveal, Quick Look, Open, Copy Path are unchanged.
  If a trashed item cannot be identified in the Trash, the toast says to use Put Back in the
  Finder instead of offering Undo. Open, Open in Terminal and the link into System Settings
  report a refusal instead of doing nothing.
- **No command line tool** in the bundle; `Scripts/install-cli.sh` says so.
- **Settings and recents** live in the container, apart from the normal build's.
- **Harness.** `--snapshot` output goes to the container's temporary folder under the same file
  name and the path is printed; `--action-fixture` makes the `--exercise-actions` folder
  there. A harness run never shows the open panel: a location nothing covers ends the run at
  once with `access: needs access …` and exit status 3. Harness runs keep their grants in a
  domain of their own (`--forget-grants` empties it).

### Checking a sandboxed build

Launch it through LaunchServices so that it is its own responsible process (run straight from a
terminal that has Full Disk Access, macOS attributes privacy decisions to the terminal); `open`
does not pass the exit status on, so read the output:

```sh
APP="$PWD/dist/Disk Survey (Sandbox).app"    # or "… (Sandbox Test Access).app"
open -W -n --stdout out.txt --stderr err.txt -a "$APP" --args --self-test
open -W -n --stdout out.txt -a "$APP" --args --sandbox-report --snapshot start.png
open -W -n --stdout out.txt -a "$APP" --args --action-fixture --exercise-actions --snapshot a.png
# with --sandbox-test-access: any path. Without: only what a grant covers. A folder passed to
# `open -a` arrives as an open-document event with access of its own and leaves a stored grant
# (in the harness's own domain), which the second command then uses:
open -W -n --stdout out.txt -a "$APP" /some/folder --args --snapshot a.png
open -W -n --stdout out.txt -a "$APP" --args --scan /some/folder/inside --snapshot b.png
```

### What was measured

On macOS 27.2 (Apple silicon), ad hoc signed, 10 November 2026, with the harness:

- With `--sandbox-test-access`: `--self-test` passes; `/usr` and `/Applications` scan to the
  same file counts, sizes and issue counts as the normal build; trash, undo and rescan work on
  a fixture in the container. A scan of `~/Library/Mail` is refused by macOS and ends with the
  alert described above.
- Without the exception: `--scan /usr` ends at once with `needs access` (no panel, no hang).
  A folder outside the container handed over by `open` is scanned, a security-scoped bookmark
  is stored, a later launch scans a subfolder through that bookmark without a panel, and its
  parent still needs access. Under that grant Move to Trash and Put Back both work (the
  folder was on the startup volume), and the file commands and the Quick Look panel are live.
  A later launch also finds the grant when the subfolder is named through a symbolic link, a
  folder handed over through a symbolic link is stored under its real path, and handing over
  a folder inside the stored one adds no record.
- A normal build started with `APP_SANDBOX_CONTAINER_ID` set in its environment scans as usual.
- The plain sandbox can `lstat` and `realpath` paths it may not list (so existence checks and
  the scanner's `realpath` of the root work), and the volume list with capacities is intact.

### Tried by hand

On macOS 27.2 with a Developer ID signed `--sandbox` build: the startup disk was chosen in the
open panel on the start screen, the bookmark of `/` was stored and resolved on later launches,
and Full Disk Access was switched on for the app in System Settings. After that the sandboxed
app, started through `open` so that it answers for itself, read the folders macOS protects
separately: `~/Library/Mail`, `~/Library/Messages`, `~/Library/Safari`
and `~/.Trash`, each with no unreadable folder, and its own check reported Full Disk Access as
granted. With the same disk grant but without Full Disk Access, `~/Library/Mail` scans as
0 files with one issue. So Full Disk Access is honoured for a sandboxed app on top of a chosen
disk.

### Not tested

Everything that needs a click in an open panel or a switch in System Settings:

- The open panel beyond choosing the startup disk (see below): "Grant Access" after a refused
  scan, and a bookmark of `/` on macOS 26.0/26.1, where Apple says it is broken (if it cannot be
  made the grant lasts until the app quits and is asked for again). Also which spelling the
  panel hands over for a folder of the Data volume (`open` hands over the system volume's
  folder of the same name), and the alert after a refused scan with its two buttons.
- Disks that come and go: a grant surviving the disk being away, two disks under one name, a
  bookmark on a network share that is not mounted. The rules are unit-tested with stand-ins
  for the system; no such disk was connected.
- Whether a grant for the startup disk reaches other volumes, and whether Desktop, Documents,
  Downloads, iCloud Drive and removable or network volumes raise consent prompts under it.
- Drag and drop onto a window or the Dock icon, the Dock's recent items, Open, Open in
  Terminal, Share and the link into System Settings in a sandboxed build. Quick Look: the panel
  opens and is driven by the window; what it shows was not looked at.
- App Review: whether it accepts the hidden harness arguments (including a run-time lookup of
  `CGWindowListCreateImage`) and the pointer to Full Disk Access. `--mas` itself has been run:
  build 1 of 1.0.0 passed `altool --validate-app` and was uploaded, so App Store Connect takes
  the hand-assembled bundle (no Xcode `DT*` keys in Info.plist, a plain `.icns`).
- macOS 26 and Intel.

### Submitting to the Mac App Store

Steps for a person; none has been done.

1. **Developer portal** (Certificates, Identifiers & Profiles; Account Holder or Admin).
   Create and install two certificates with their private keys in the login keychain: *Apple
   Distribution* (signs the app) and *Mac Installer Distribution* (signs the package; shows up
   as "3rd Party Mac Developer Installer: …" in `security find-identity -v`, without
   `-p codesigning`). The Developer ID certificate cannot be used. Register an explicit App ID
   for the bundle identifier (no extra capabilities). Create a *Mac App Store Connect*
   distribution profile for that App ID and the Apple Distribution certificate; download the
   `.provisionprofile` and keep it out of the repository.
2. **Decide the bundle identifier first**: it cannot be changed after the first upload. The
   same identifier as the Developer ID build means both cannot sensibly be installed side by
   side and do not share privacy grants; a distinct one keeps them apart.
3. **App Store Connect.** Accept the agreements; declare trader status for the EU; My Apps › +
   › New App › macOS with that bundle identifier and a SKU (permanent). Fill in category
   Utilities (matches `LSApplicationCategoryType`), age rating, App Privacy ("Data Not
   Collected"), privacy policy and support URLs, screenshots, description, price. Create an API
   key under Users and Access › Integrations (key file in `~/.appstoreconnect/private_keys`).
4. **Build and upload** (`altool` ships with Xcode; nothing is notarized):

   ```sh
   export MAS_APP_IDENTITY="Apple Distribution: Your Name (TEAMID)"
   export MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)"
   export MAS_PROFILE=~/path/to/DiskSurvey.provisionprofile BUNDLE_ID=your.bundle.id
   Scripts/build-app.sh --mas
   xcrun altool --validate-app dist/DiskSurvey-<version>-<build>-mas.pkg --api-key <id> --api-issuer <issuer>
   xcrun altool --upload-package dist/DiskSurvey-<version>-<build>-mas.pkg --api-key <id> --api-issuer <issuer> --wait
   ```

5. **TestFlight, then review.** Test the processed build (grant the startup disk, switch on
   Full Disk Access, scan) before submitting; in the review notes explain the folder choice
   and that Full Disk Access is optional.

## Releasing on GitHub

```sh
Scripts/release.sh            # notarized build, tag v<VERSION>, DRAFT release with dmg, zip, checksums
Scripts/release.sh --publish  # the same, published immediately
```

The script refuses to run with uncommitted changes, an unpushed HEAD or an existing tag; bump
`VERSION` (and `DiskSurveyVersion.string`) for each release.

`notarytool` and `stapler` ship with Xcode, not with the Command Line Tools, so this one step
needs a machine with Xcode installed. Note that every ad-hoc rebuild has a new code identity, so
macOS treats it as a different app for privacy permissions (see [Full Disk Access](README.md#full-disk-access)); a stable
signing identity avoids having to re-grant them.

## Architecture

A single Swift package (`Package.swift`, Swift 6 language mode with strict concurrency):

| Target              | Role                                                                                  |
|---------------------|---------------------------------------------------------------------------------------|
| `DiskSurveyCore`    | Foundation-only model: the struct-of-arrays `FileTree`, file-kind classification, formatting. |
| `DiskSurveyScan`    | Parallel filesystem scanner producing a `FileTree`; mount table, volume info, disk-access checks, sandbox detection and the table of access grants. |
| `DiskSurveyTreemap` | Squarified layout, hit-testing and the cushion rasteriser, drawing into plain pixel buffers. No AppKit. |
| `DiskSurveyMapView` | The AppKit treemap view: rendering, hover, selection, zoom.                           |
| `disksurvey-cli`    | The command line tool (installed as `disksurvey`). Uses Core and Scan only.           |
| `DiskSurveyApp`     | The SwiftUI/AppKit application.                                                       |

Tests use Swift Testing and live in `Tests/` (Core, Scan including the Move to Trash service,
Treemap, MapView offscreen rendering, and the CLI's parser and text helpers). Packaging lives in `Scripts/` and `Resources/`:

- `Scripts/build-app.sh` — builds, bundles, signs and packages the app.
- `Scripts/install-cli.sh` — links the command line tool onto your `PATH`.
- `Scripts/make-icon.swift` — draws the app icon with CoreGraphics and writes
  `Resources/AppIcon.icns` (run `swift Scripts/make-icon.swift` after changing it).
- `Scripts/test.sh` — runs the test suite with a Command-Line-Tools-only toolchain.
- `Resources/Info.plist` — bundle metadata template; the version is stamped in at build time.
- `Resources/DiskSurvey.sandbox.entitlements` — the entitlements of the sandboxed variants;
  `DiskSurvey.sandbox-test-access.entitlements` is the harness-only variant with the
  whole-disk exception.

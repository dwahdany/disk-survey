# Disk Survey

<img src="Resources/AppIcon-1024.png" width="128" alt="Disk Survey icon" align="right">

Disk Survey is a native macOS app that shows where your disk space went. It scans a folder or a
whole volume and draws it as a cushion treemap — every file is a tile whose area is its size —
next to a sortable outline, so the big things are obvious at a glance and one click away.

It is written in Swift for macOS 26 and later, has no third-party dependencies, builds with only
the Command Line Tools, and ships as a universal (Apple silicon + Intel) app with a headless
command line tool using the same engine.

## Features

- **Fast scanning.** A parallel scanner built on `getattrlistbulk` reads directory entries and
  their sizes in bulk, on all cores, into a compact struct-of-arrays tree. The UI stays responsive
  and the treemap fills in progressively while the scan runs.
- **Cushion treemap.** Squarified layout with cushion shading, animated zoom into folders,
  breadcrumb navigation and hover tooltips. Colour by file kind or by age.
- **Folders you can read.** Every folder large enough to carry it gets a frame with its name and
  size, however deep it lies: frames inside frames get slimmer title strips and a lighter tint,
  small folders get none, and a folder that fills its parent shares the parent's title
  (`Music/Albums/Live`), so the big folders inside big folders are named right on the
  map. The **Depth** control above the map (⌘− / ⌘+, ⌥⌘0 for all levels) limits how many folder
  levels are shown below the current folder: at 1 the map is just that folder's children as
  labelled blocks with size, share and item count, coloured by what mostly fills them;
  double-click a block or a folder's title to go straight into it. Pointing at a tile outlines
  its folder and the folders around it, and the tooltip and status bar list that chain with
  each folder's size. Settings › Appearance chooses adaptive frames, frames for the top two
  levels only, or none.
- **Outline and lists.** Size bars, percentages, item counts and modification dates, with selection
  kept in sync with the map in both directions; a kinds legend (by category or extension, with
  extensionless executables as "Unix Executable"); a "largest files" list; search and filtering.
- **Actions.** Reveal in Finder, Quick Look, Open, Copy Path, and Move to Trash (confirmed first;
  the tree and map update in place, the freed space is reported, and "Put Back" undoes it).
  Disk Survey only trashes what it scanned: the scanned location itself, volumes, mount points and
  folders that contain one are refused; a file whose type or length changed, and a folder whose
  contents no longer match the scan (including folders of a stopped scan and folders holding
  excluded items), are left alone until you rescan. Put Back only restores the item Disk Survey
  itself moved to the Trash. Rescan a folder or everything at any time.
- **Friendly start.** Volumes with capacity bars, common folders, recent scans, drag and drop of
  any folder (also onto the Dock icon), and guidance for granting Full Disk Access.
- **Careful accounting.** Allocated size first, logical size second; hard links counted once;
  firmlinks, mount points and cloud-only files handled without double counting or downloads.
  See [Accounting notes](#accounting-notes) for what the numbers do and do not mean.
- **At home on current macOS.** Standard toolbar, inspector and Settings (which pick up Liquid
  Glass from the system), light and dark appearance, a full menu bar with keyboard shortcuts,
  VoiceOver labels, Reduce Motion respected.

## Requirements

- macOS 26 or later (Apple silicon or Intel) to run.
- To build: the Command Line Tools (`xcode-select --install`) with Swift 6.2 or later.
  Xcode is not required. If `xcode-select` points at an Xcode whose license has not been
  accepted, the scripts fall back to the Command Line Tools by themselves; for bare `swift`
  commands set `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

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

Every run starts by removing `dist/Disk Survey.app` and any `dist/DiskSurvey-*.dmg` / `.zip`,
and the new bundle and packages only appear under those names once they are complete, signed
and verified. So whatever is in `dist/` belongs to the last successful run: a failed build leaves
nothing behind, and a run without `--dmg`/`--zip` leaves no package from an earlier build.

The script builds each architecture into its own SwiftPM scratch directory
(`.build-pkg-arm64`, `.build-pkg-x86_64`), joins them with `lipo`, assembles the bundle, strips
symbols, signs it and verifies the result. The version comes from the `VERSION` file.

During development you can also run the targets straight from SwiftPM
(`swift run DiskSurveyApp`, `swift run disksurvey-cli`).

### Tests

```sh
Scripts/test.sh                                   # everything: 284 tests in five targets
Scripts/test.sh --filter TrashServiceTests        # one suite
DISKSURVEY_TEST_REAL_TRASH=1 Scripts/test.sh --filter TrashServiceTests
```

`Scripts/test.sh` wraps `swift test` so that Swift Testing works with only the Command Line
Tools. The scanner tests read real system folders (`/System/Library`, `/usr`) and assume an
APFS startup volume. The Move to Trash tests use a stand-in Trash in a temporary folder; only
with `DISKSURVEY_TEST_REAL_TRASH=1` does one test move a temporary fixture into the real Trash,
check that it arrived, and delete it from there again. The app itself has no test target;
its checks run inside the app with `DiskSurvey --self-test` (see
[Checking the app without a person at the screen](#checking-the-app-without-a-person-at-the-screen)).

### Signing and notarization

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

### Releasing on GitHub

```sh
Scripts/release.sh            # notarized build, tag v<VERSION>, DRAFT release with dmg, zip, checksums
Scripts/release.sh --publish  # the same, published immediately
```

The script refuses to run with uncommitted changes, an unpushed HEAD or an existing tag; bump
`VERSION` (and `DiskSurveyVersion.string`) for each release.

`notarytool` and `stapler` ship with Xcode, not with the Command Line Tools, so this one step
needs a machine with Xcode installed. Note that every ad-hoc rebuild has a new code identity, so
macOS treats it as a different app for privacy permissions (see the next section); a stable
signing identity avoids having to re-grant them.

## Full Disk Access

macOS protects parts of your home folder and of the system (Mail, Messages, Safari data, other
apps' containers, Time Machine backups, …). Without permission Disk Survey cannot read those
folders: they are marked as inaccessible and their contents are missing from the totals, so a
scan of your whole disk will add up to less than the space actually in use.

To see everything, add Disk Survey under **System Settings → Privacy & Security → Full Disk
Access** and start the scan again. For Desktop, Documents, Downloads, removable and network
volumes, macOS asks the first time a scan reaches them. Disk Survey only reads names, sizes and
dates — never file contents — and makes no network connections.

The command line tool inherits the permissions of the terminal application it runs in, so grant
Full Disk Access to your terminal if you want complete results there.

## Command line

The same scanner is available without the GUI. The tool lives inside the app bundle at
`Disk Survey.app/Contents/Helpers/disksurvey`; put it on your `PATH` with:

```sh
Scripts/install-cli.sh              # symlinks into /usr/local/bin, or ~/.local/bin
Scripts/install-cli.sh --uninstall
```

```
disksurvey [scan] [path]             Tree of the largest folders and files (default command)
disksurvey top [path]                Largest individual files
disksurvey kinds [path]              Usage by category and file extension
disksurvey find <path> [query]       Search by name, size, kind and age
disksurvey volumes                   Mounted volumes with capacity bars
disksurvey export [path] -f FORMAT   Write the complete tree as json, csv or ncdu
disksurvey help | --help | --version
```

Every command except `export` takes `--json`; `disksurvey --help` is the authoritative reference
for options, the JSON schema and exit codes. `-n 0` lists everything in every command, and
`export -o FILE` replaces FILE only with a complete export (a failed or interrupted scan leaves
an existing file as it was). `--exclude PATH` leaves out exactly that entry — naming a symlink
excludes the link, not what it points to. A path that cannot be read at all is an error (exit
status 1); unreadable folders further down are counted as issues and listed by `--issues`.
When the system held a scan up (see [Performance](#performance)), a line on stderr and the
JSON fields `slowestOpenSeconds`, `slowOpens` and `slowestOpenPath` say so. Real output
(numbers follow your locale):

```
$ disksurvey /Library/Developer/CommandLineTools -d 1 -n 4
/Library/Developer/CommandLineTools  1,42 GB
668 MB  ███████▌          47,2%  ├─ SDKs/
641 MB  ███████▎          45,3%  ├─ usr/
106 MB  █▎                 7,5%  └─ Library/

86.485 files · 21.675 folders · 1,42 GB on disk (3,67 GB logical) · 0,28 s, 387K entries/s

$ disksurvey top /Library/Developer/CommandLineTools -n 3
Largest files in /Library/Developer/CommandLineTools  1,42 GB
70,7 MB  ▊                  5,0%  2 weeks ago  Library/PrivateFrameworks/LLDB.framework/Versions/A/LLDB
69,6 MB  ▊                  4,9%  2 weeks ago  usr/bin/swift-frontend
68,8 MB  ▊                  4,9%  2 weeks ago  usr/lib/sourcekitdInProc.framework/Versions/A/sourcekitdInProc

$ disksurvey find ~/Library --min-size 1G --older-than 6m --json
$ disksurvey export ~ -f ncdu -o home.json        # readable by ncdu -f home.json
```

## Performance

Measured on the machine this was developed on (Apple silicon, 12 cores, macOS 27.2, internal
APFS SSD, release build, warm file-system cache). Your numbers will differ.

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
against a throwaway folder that must be named `disksurvey-action-test`). The picture comes from
the window server when it is available, which shows glass and vibrancy as on screen; while the
screen is locked it falls back to AppKit's display cache, which shows the layout but not the
materials (and, in the dark appearance, draws the inspector's text too dark; a window-server
capture of the same view taken earlier is correct, so this is believed to be an artifact of
the fallback). Harness runs use their own settings domain and leave
Recents alone.

`--self-test` scans a small fixture it creates in the temporary folder and a generated tree, and
checks things that need a running app: command enabling, the outline's row reuse, stale result
rows, icon caching, which views are re-evaluated by which change, the split view's limits, the
map's depth setting, and that a drag onto the Trash acts on the dragged items rather than the selection. The scan
window's minimum width is 842 pt while the inspector is open and 760 pt otherwise.

## Architecture

A single Swift package (`Package.swift`, Swift 6 language mode with strict concurrency):

| Target              | Role                                                                                  |
|---------------------|---------------------------------------------------------------------------------------|
| `DiskSurveyCore`    | Foundation-only model: the struct-of-arrays `FileTree`, file-kind classification, formatting. |
| `DiskSurveyScan`    | Parallel filesystem scanner producing a `FileTree`; mount table, volume info, disk-access checks. |
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

## Accounting notes

Disk usage on APFS is not a single well-defined number. What Disk Survey reports, and where it can
differ from Finder or `df`:

- **Allocated vs logical size.** The primary figure is the *allocated* (physical) size: the
  blocks a file occupies on disk. The *logical* size — the file's length in bytes — is shown as
  a secondary figure. Sparse and transparently compressed files occupy less than their length;
  small files occupy more because of block rounding.
- **Hard links.** A file with several hard links is counted once, at the first link the scan
  encounters; the other links are shown but contribute no size. Which folder "owns" the bytes is
  therefore somewhat arbitrary, but totals are not inflated. The tree remembers which names
  belong to one file, so this stays true afterwards: rescanning one folder does not count the
  file a second time, and when the name that carried the size is trashed, another name takes
  the size over.
- **APFS clones.** Copies made by cloning (Finder's Duplicate, `cp -c`) share blocks until one
  of them is modified. macOS exposes no inexpensive way to discover which files share blocks, so
  each clone is counted at its full allocated size. Folders full of clones therefore look larger
  than the space they really consume, and deleting one clone may free little or nothing.
- **Snapshots.** Local snapshots (Time Machine, system updates) keep blocks of deleted or changed
  files alive. That space belongs to no file in the live filesystem, so it does not appear in the
  treemap, and trashing a file that is still referenced by a snapshot does not free its space
  until the snapshot expires.
- **Purgeable space.** Finder counts space that macOS can reclaim on demand as "available".
  Disk Survey shows what is allocated right now, so its totals can be higher than Finder suggests.
- **Cloud-only (dataless) files.** iCloud Drive and other File Provider items that are not
  downloaded occupy almost no local space and are reported that way. Scanning does not
  download them.
- **Firmlinks and mount points.** The system and data volumes are stitched together with
  firmlinks; Disk Survey follows each path once, so nothing is counted twice. A scan of `/` also
  includes the other local APFS volumes of the startup disk's container that are mounted
  outside `/Volumes` (VM, Preboot, Update, and for example a `/nix` volume), marked as mount
  points. Everything under `/Volumes`, other disks and network shares are not entered unless
  you turn on "Scan into other volumes" (`--cross-mounts`); scan those separately.
- **A whole-disk total is not "used space".** Because of clones, snapshots and purgeable space
  the sum of all files can be higher or lower than what the volume reports as used. The Info
  tab shows both figures side by side when a whole volume was scanned.
- **Inaccessible folders.** Anything Disk Survey is not allowed to read is flagged rather than
  silently treated as empty — see [Full Disk Access](#full-disk-access).
- **Freed space after Move to Trash.** The amount reported is by how much the scanned total
  shrank: the allocated size of what was moved, not counting files that still have another
  hard link in the scanned tree. (The confirmation sheet's "frees about" is the plain sum.) The space becomes available only once the Trash is emptied, and only to the extent that
  clones and snapshots do not still reference the blocks.

## Known limitations

- The interface is English only; numbers and byte units follow the system locale.
- APFS clones are counted once per copy (as `du` and Finder do), so clone-heavy folders look
  larger than the space they occupy.
- Memory use at the peak of a scan is about 90–105 bytes per scanned item on the command line
  (473 MB for a 5.4-million-item startup disk) and about 160 in the app (0.86–0.89 GB for the
  same disk), because the app keeps a partial tree on screen while the final one is built. For
  the same reason the map stops refreshing during a scan once two million items have been read.
- On the development machine, about every second scan of the home folder is held up for 5
  seconds by a single folder `open` that blocks in the system. The cause is unknown; it is
  reported, not avoided.
- Items whose names are not valid UTF-8 (possible on NFS and some foreign volumes) are shown
  and counted, and can be opened, revealed and previewed, but cannot be moved to the Trash,
  rescanned on their own or have their path copied. A scan *root* with such a name is not
  supported.
- Search ignores case but not diacritics ("istanbul" does not find "İstanbul.png", "resume"
  does not find "résumé").
- A partial rescan or a "Put Back" rescans the affected folder in full, and the tree keeps the
  replaced nodes' memory until the next full rescan.
- With the entry-count shortcut on APFS, an empty folder that is also unreadable is not
  reported as unreadable (sizes are unaffected).
- Modification dates before 1970 are shown as unknown.
- In the smallest window with the inspector open (842 pt) the outline's columns do not all
  fit (it scrolls sideways) and the hint in the status bar is truncated.
- The toolbar is not customizable, and search filters (size, age, kind) are chosen as chips in
  the Search tab rather than typed.
- The treemap's zoom into a folder that is too small to be drawn starts from the tile that
  contains it, not from the folder's exact rectangle.
- Network and non-APFS volumes use a slower `readdir` path that was only exercised through a
  diagnostic switch, not against real network shares.
- The app icon is a single rendered image; there is no layered Liquid Glass icon, because that
  needs Xcode's tooling.
- Ad-hoc builds are not notarized. The notarization and release scripts have not yet been run against Apple's notary service.
- Verification so far is automated (unit tests, the in-app self-test, the screenshot harness,
  scripted trash / undo / rescan runs). The most recent screenshots were taken with the screen
  locked, so glass, vibrancy and the dark appearance of the inspector were not checked as
  they appear on screen. Gestures, drag-out to Finder and VoiceOver have not been tried by a person.

## License

MIT — see [LICENSE](LICENSE).

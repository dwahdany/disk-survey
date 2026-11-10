import DiskSurveyCore

enum Help {
    static let text = """
        disksurvey \(DiskSurveyVersion.string) — fast disk-usage analysis for macOS

        USAGE
          disksurvey [scan] [path]             Tree of the largest folders and files (default command)
          disksurvey top [path]                Largest individual files
          disksurvey kinds [path]              Usage by category and file extension
          disksurvey find <path> [query]       Search by name, size, kind and age
          disksurvey volumes                   Mounted volumes with capacity bars
          disksurvey export [path] -f FORMAT   Write the complete tree as json, csv or ncdu
          disksurvey help | --help | --version

          The path defaults to the current directory. A folder that is named like a command
          can be scanned as `disksurvey scan top` or `disksurvey ./top`.

        SCAN
          -d, --depth N        Levels to show below the root (default 2; 0 = totals only)
          -n, --top N          Entries shown per folder (default 10, and 4 in nested folders; 0 = all)
              --min-size SIZE  Hide entries smaller than SIZE
              --logical        Rank and show logical sizes instead of space allocated on disk
              --packages       Show packages (.app, .photoslibrary, …) as single items

        TOP
          -n, --limit N        Number of files (default 25; 0 = all)
              --packages       Count packages as single files

        KINDS
          -n, --limit N        Number of extensions (default 15; with --json: all; 0 = all)
              --logical        Rank by logical size

        FIND
          query                Case-insensitive part of a name; optional when a filter is given
              --min-size SIZE, --max-size SIZE
              --kind EXT       File extension; repeat or separate with commas (--kind mp4,mov).
                               unix-executable: files without an extension that are executable
              --category NAME  video, audio, image, document, archive, code, application,
                               system, data, buildArtifact, diskImage, font, other
              --older-than AGE Not modified within AGE (12h, 30d, 2w, 6m, 1y) or since a date (2025-01-31)
              --newer-than AGE Modified within AGE or since a date
              --files, --dirs  Match only files / only folders
          -n, --limit N        Matches to show, largest first (default 50; 0 = all)

        VOLUMES
          -a, --all            Include hidden system volumes

        EXPORT
          -f, --format FORMAT  json  the scan schema below, complete and unlimited
                               csv   one row per entry: path,type,allocated_bytes,logical_bytes,
                                     file_count,modified,extension,category,depth,flags
                               ncdu  ncdu's export format; browse it with `ncdu -f FILE`
          -o, --output FILE    Destination (default or "-": standard output). FILE is replaced only
                               by a complete export: if the scan fails or is interrupted, an
                               existing FILE is left as it was. FILE itself is not listed.

        SCANNING OPTIONS (scan, top, kinds, find, export)
              --threads N      Scanner threads (default 0 = automatic)
              --cross-mounts   Descend into other mounted volumes (off: stay on one disk)
              --exclude PATH   Leave PATH out entirely; may be repeated. Naming a symlink leaves
                               out the link itself, not what it points to.
              --issues         List on stderr everything that could not be read
              --no-progress    No live progress line (it is shown only when stderr is a terminal)

        OUTPUT OPTIONS
              --json           Machine-readable JSON on stdout (every command except export)
              --no-color       No colours; also off when NO_COLOR is set, TERM=dumb, or stdout is
                               not a terminal.  --color forces colours on (as does CLICOLOR_FORCE=1).
              --ascii          ASCII bars and tree lines instead of Unicode

          SIZE is a number with an optional unit: 4096, 500K, 10MB, 1.5G (decimal, as displayed)
          or 2GiB (binary). Sizes are space allocated on disk unless noted. Hard links are counted
          once, symlinks are not followed, files that exist only in iCloud are never downloaded,
          and other volumes are not entered unless --cross-mounts is given.

        JSON (schemaVersion 1; sizes in bytes, times in Unix seconds, key order is stable)
          Every scanning command prints one object:
            disksurvey, schemaVersion, command, root, partial
            summary   {files, directories, symlinks, hardLinkDuplicates, datalessEntries,
                       mountPointsSkipped, allocatedBytes, logicalBytes, elapsedSeconds,
                       entriesPerSecond, threads, issues, slowestOpenSeconds, slowOpens,
                       slowestOpenPath}      the last three attribute a scan the system held up:
                       the longest single folder open, how many took 0.1 s or more, and where
            issues    [{path, errno, message}]            at most the first 1000
          followed by the command's own keys:
            scan      sortedBy, tree: NODE with nested children; --depth, --top and --min-size
                      apply, and every expanded folder has omitted {count, allocatedBytes, logicalBytes}
            top       files: [NODE]
            kinds     sortedBy, categories: [{category, name, allocatedBytes, logicalBytes, files}],
                      totalKinds, kinds: [{extension, name, category, allocatedBytes, logicalBytes,
                      files}]; name is ".png", "" for no extension, or "Unix Executable" for
                      executables without one (whose extension is "" as well)
            find      query {…}, totalMatches, matches: [NODE]
            export    tree: NODE, complete; only the root has a path
          NODE  {name, path, type: file|directory|package|symlink, allocatedBytes, logicalBytes,
                 fileCount, modified (or null), extension and category (not for plain folders),
                 flags: any of unixExecutable, hardLinkDuplicate, unreadable, mountPoint, dataless,
                 synthetic,
                 children: [NODE] (expanded folders only)}
          volumes prints {disksurvey, schemaVersion, command, volumes: [{name, mountPoint, device,
                 fileSystem, totalBytes, usedBytes, availableBytes, availableForImportantUsageBytes,
                 purgeableBytes, usedFraction, startup, internal, removable, ejectable, network,
                 readOnly, hidden}]}

        EXIT STATUS
          0    Success. Unreadable items do not fail a scan: they are counted in the summary
               (summary.issues in JSON) and listed by --issues.
          1    Error: the path does not exist or cannot be read at all (an unreadable folder
               further down is only an issue), or the output cannot be written.
          2    Invalid usage.
          130  Interrupted with Ctrl-C. What was scanned until then is still printed, marked
               partial ("partial": true in JSON); `export -o FILE` writes no file instead.
               A second Ctrl-C quits at once.

        EXAMPLES
          disksurvey ~                                   What is using my home folder?
          disksurvey / --depth 3 --min-size 1GB          Big picture of the startup disk
          disksurvey top ~/Downloads -n 10
          disksurvey find ~ --kind dmg,iso --older-than 6m
          disksurvey find ~/Library cache --dirs --min-size 500MB
          disksurvey kinds ~/Projects --json | jq '.categories[0]'
          disksurvey export / -f ncdu -o disk.json && ncdu -f disk.json

        """
}

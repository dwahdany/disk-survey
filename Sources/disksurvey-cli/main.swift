// disksurvey — the Disk Survey disk-usage engine on the command line.
//
// Everything lives in `CLI` so that no mutable state sits at file scope (top-level variables in
// main.swift are globals, which Swift 6 concurrency checking rightly dislikes).
import Darwin

exit(CLI.run(arguments: Array(CommandLine.arguments.dropFirst())))

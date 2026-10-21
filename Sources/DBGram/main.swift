import AppKit

if CommandLine.arguments.contains("--render") {
    exit(ImageExporter.runCommandLine(CommandLine.arguments))
}
// No window restoration: it would bring back stale and empty windows. Recent files are on the start screen.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
DBGramApp.main()

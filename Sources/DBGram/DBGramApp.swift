import AppKit
import DBMLKit
import SwiftUI

struct DBGramApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @FocusedValue(\.windowActions) private var actions

    var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            ContentView(fileURL: $url)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1400, height: 900)
        // File-open events are routed by AppDelegate/Opener; without this SwiftUI adds an extra empty window.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { actions?.open() }.keyboardShortcut("o")
                Button("Paste DBML from Clipboard") { actions?.paste() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Export PNG…") { actions?.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find Table…") { actions?.find() }.keyboardShortcut("f")
            }
            CommandGroup(before: .toolbar) {
                Button("Zoom In") { actions?.zoomIn() }.keyboardShortcut("=")
                Button("Zoom Out") { actions?.zoomOut() }.keyboardShortcut("-")
                Button("Zoom to Fit") { actions?.zoomFit() }.keyboardShortcut("0")
                Button("Actual Size") { actions?.zoomActual() }.keyboardShortcut("1")
                Divider()
                Button("Auto-Arrange Tables") { actions?.arrange(nil) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Menu("Auto-Arrange Style") {
                    ForEach(LayoutStyle.allCases, id: \.self) { style in
                        Button(style.title) { actions?.arrange(style) }
                    }
                }
                Button("Toggle Inspector") { actions?.toggleInspector() }.keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
        }

        WindowGroup("Pasted Schema", id: "paste") {
            PasteWindowView().frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1400, height: 900)
        .handlesExternalEvents(matching: [])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // `DBGram schema.dbml` from a terminal.
        for arg in CommandLine.arguments.dropFirst() where arg.lowercased().hasSuffix(".dbml") {
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) { Opener.open(url) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Opener.open(url) }
    }
}

/// Bridges AppKit file-open events (Finder, Dock, `open -a`) to SwiftUI windows.
@MainActor
enum Opener {
    private static var openWindow: OpenWindowAction?
    private static var pending: [URL] = []
    static var pendingPaste: String?

    static func takePaste() -> String? {
        defer { pendingPaste = nil }
        return pendingPaste
    }

    static func register(_ action: OpenWindowAction) {
        if openWindow == nil { openWindow = action }
    }

    /// Windows that show nothing yet; a file opened from Finder lands in one of these first.
    private static var emptyWindows: [(id: UUID, adopt: (URL) -> Void)] = []

    static func registerEmpty(_ id: UUID, adopt: @escaping (URL) -> Void) {
        emptyWindows.removeAll { $0.id == id }
        emptyWindows.append((id, adopt))
    }

    static func unregisterEmpty(_ id: UUID) {
        emptyWindows.removeAll { $0.id == id }
    }

    static func open(_ url: URL) {
        if !emptyWindows.isEmpty {
            emptyWindows.removeFirst().adopt(url)
        } else if let openWindow {
            openWindow(value: url)
        } else {
            pending.append(url)
        }
    }

    static func takePending() -> URL? {
        guard !pending.isEmpty else { return nil }
        let first = pending.removeFirst()
        for url in pending { openWindow?(value: url) }
        pending = []
        return first
    }
}

/// Menu commands for the focused window. A class created once per window: a struct of closures
/// rebuilt on every view update looks like a focus change to SwiftUI and loops layout forever.
final class WindowActions {
    var open: () -> Void = {}
    var paste: () -> Void = {}
    var export: () -> Void = {}
    var arrange: (LayoutStyle?) -> Void = { _ in }
    var find: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var zoomFit: () -> Void = {}
    var zoomActual: () -> Void = {}
    var toggleInspector: () -> Void = {}
}

struct WindowActionsKey: FocusedValueKey { typealias Value = WindowActions }

extension FocusedValues {
    var windowActions: WindowActions? {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

import AppKit
import CryptoKit
import DBMLKit
import Observation

/// State of one window: the open file, its parsed schema, table positions and selection.
@Observable
final class DocumentModel {
    var url: URL?
    var schema = Schema()
    /// The primary selected table (inspector, sidebar scrolling); always in `selectedTables` when set.
    var selection: String?
    var selectedTables: Set<String> = []
    /// Index into `schema.refs` of the selected relationship. Mutually exclusive with `selection`.
    var selectedRef: Int?
    var loadError: String?
    /// The auto-arrange style of this file: the last one used on it, else the last one used anywhere.
    var layoutStyle = DocumentModel.defaultLayoutStyle
    var isPasted = false
    /// Bumped on every new scene so the canvas knows to reload.
    private(set) var revision = 0
    /// Colors for the sidebar and inspector. Changes only when the schema changes.
    private(set) var style: SceneStyle?
    /// Not observed: table positions change on every drag and must not re-render SwiftUI views.
    @ObservationIgnored private(set) var scene: DiagramScene?

    @ObservationIgnored weak var canvas: DiagramCanvas?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var store: LayoutStore?
    @ObservationIgnored private var pendingViewport: LayoutStore.Viewport?
    /// Source of the schema on screen, to skip reloads when the file content didn't change.
    @ObservationIgnored private var lastSource: String?
    /// Every table position seen this session, including tables that are currently missing,
    /// so a table that disappears mid-edit comes back where it was.
    @ObservationIgnored private var rememberedPositions: [String: CGPoint] = [:]
    @ObservationIgnored private var emptyRecheck: DispatchWorkItem?
    /// Counts undo registrations, so a nudge only merges into the step registered just before it.
    @ObservationIgnored private var undoSerial = 0
    /// The undo step of the last arrow-key nudge while it can still absorb more presses.
    @ObservationIgnored private weak var lastNudge: MoveStep?

    var title: String {
        if let url { return url.lastPathComponent }
        return isPasted ? "Pasted Schema" : "DBGram"
    }

    var hasContent: Bool { url != nil || isPasted }

    // MARK: loading

    func open(_ url: URL) {
        if url != self.url { undoManager?.removeAllActions(withTarget: self) }
        self.url = url
        isPasted = false
        store = LayoutStore(for: url)
        pendingViewport = store?.load().viewport
        rememberedPositions = store?.load().positions ?? [:]
        layoutStyle = store?.load().style ?? Self.defaultLayoutStyle
        lastSource = nil
        RecentFiles.add(url)
        reload(initial: true)
        watcher = FileWatcher(url: url) { [weak self] in self?.reload(initial: false) }
    }

    func loadPasted(_ source: String) {
        undoManager?.removeAllActions(withTarget: self)
        url = nil
        watcher = nil
        store = nil
        isPasted = true
        rememberedPositions = [:]
        layoutStyle = Self.defaultLayoutStyle
        lastSource = source
        apply(DBML.parse(source), saved: [:], initial: true)
    }

    static func debugLog(_ s: String) {
        guard ProcessInfo.processInfo.environment["DBGRAM_DEBUG"] != nil else { return }
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    /// Reads the file and shows it. Keeps the current diagram when the file is missing, unchanged,
    /// or suddenly empty (an editor mid-save), so a hot reload never flashes or loses positions.
    func reload(initial: Bool, confirmEmpty: Bool = false) {
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "\(url.lastPathComponent) was moved or deleted. Waiting for it to come back…"
            return
        }
        let t0 = CACurrentMediaTime()
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "Can't read \(url.lastPathComponent) as UTF-8 text"
            return
        }
        loadError = nil
        if !initial, source == lastSource { return }
        if !initial, !confirmEmpty, source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           lastSource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            // Probably truncated before being rewritten; look again shortly before believing it.
            emptyRecheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reload(initial: false, confirmEmpty: true) }
            emptyRecheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            return
        }
        lastSource = source
        apply(DBML.parse(source), saved: rememberedPositions, initial: initial)
        Self.debugLog(String(format: "reload %@ tables=%d: %.1fms", url.lastPathComponent, schema.tables.count, (CACurrentMediaTime() - t0) * 1000))
    }

    private func apply(_ schema: Schema, saved: [String: CGPoint], initial: Bool) {
        var scene = DiagramScene(schema: schema, positions: [:])
        scene.positions = saved.isEmpty
            ? SchemaLayout.compute(schema: schema, sizes: scene.sizes, style: layoutStyle)
            : SchemaLayout.placeNew(schema: schema, sizes: scene.sizes, existing: saved, style: layoutStyle)
        self.schema = schema
        self.scene = scene
        self.style = scene.style
        rememberedPositions.merge(scene.positions) { _, new in new }
        selectedTables = selectedTables.filter { schema.table(id: $0) != nil }
        if let s = selection, schema.table(id: s) == nil { selection = nil }
        if let r = selectedRef, r >= schema.refs.count { selectedRef = nil }
        revision += 1
        if let canvas { push(to: canvas, fit: initial) }
    }

    /// Called by the canvas wrapper when it appears or the revision changes.
    func push(to canvas: DiagramCanvas, fit: Bool) {
        guard let scene else { return }
        let t0 = CACurrentMediaTime()
        // Set the viewport first so new table layers rasterize once, at the right resolution.
        var fitLater = false
        if fit {
            if let v = pendingViewport {
                pendingViewport = nil
                canvas.setViewport(zoom: v.zoom, offset: CGPoint(x: v.x, y: v.y))
            } else if canvas.bounds.width > 0 {
                canvas.fit(scene.contentBounds, maxZoom: 1.2, animated: false)
            } else {
                fitLater = true
            }
        }
        canvas.load(scene)
        Self.debugLog(String(format: "canvas load: %.1fms (%d tables)", (CACurrentMediaTime() - t0) * 1000, scene.schema.tables.count))
        if fitLater {
            // The view has no size yet; fit once it's laid out.
            DispatchQueue.main.async { canvas.zoomToFit(animated: false) }
        }
        if let path = ProcessInfo.processInfo.environment["DBGRAM_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak canvas] in canvas?.snapshot(to: URL(fileURLWithPath: path)) }
        }
        if ProcessInfo.processInfo.environment["DBGRAM_BENCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak canvas] in
                guard let canvas else { return }
                Self.debugLog(String(format: "hover: %.2fms per change; windows: %d", canvas.benchmarkHover(count: 30), NSApp.windows.filter(\.isVisible).count) + " " + NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)):\($0.title)" }.joined(separator: ", "))
            }
        }
    }

    /// Re-arranges every table in `style` (default: this file's style) and remembers the choice.
    func arrange(_ style: LayoutStyle? = nil) {
        guard let scene, let canvas else { return }
        let style = style ?? layoutStyle
        let old = scene.positions
        let oldViewport = (canvas.zoom, canvas.offset)
        let oldStyle = layoutStyle
        let new = SchemaLayout.compute(schema: schema, sizes: scene.sizes, style: style)
        setStyle(style)
        setPositions(new, animated: true)
        // Fit to where the tables end up, not where the slide starts.
        if let arranged = self.scene { canvas.fit(arranged.contentBounds, maxZoom: 1.2, animated: true) }
        // Arranging again in the same style changes nothing: an undo step for it would look like ⌘Z doing nothing.
        if new != old || style != oldStyle { registerArrangeUndo(restoring: old, viewport: oldViewport, style: oldStyle) }
    }

    private static let defaultStyleKey = "DefaultLayoutStyle"
    private static var defaultLayoutStyle: LayoutStyle {
        UserDefaults.standard.string(forKey: defaultStyleKey).flatMap(LayoutStyle.init(rawValue:)) ?? .leftRight
    }

    private func setStyle(_ style: LayoutStyle) {
        layoutStyle = style
        store?.save(style: style)
        UserDefaults.standard.set(style.rawValue, forKey: Self.defaultStyleKey)
    }

    // MARK: moving tables & undo

    /// The window's undo manager, so Edit → Undo / Redo (⌘Z / ⌘⇧Z) reach it.
    private var undoManager: UndoManager? { canvas?.window?.undoManager }

    /// Arrow-key presses less than a second apart, on the same tables, are one undo step.
    func tablesMoved(old: [String: CGPoint], new: [String: CGPoint], isNudge: Bool = false) {
        remember(new)
        if isNudge, let last = lastNudge, last.serial == undoSerial, Set(last.new.keys) == Set(new.keys),
           CACurrentMediaTime() - last.time < 1 {
            last.new = new
            last.time = CACurrentMediaTime()
            return
        }
        let step = MoveStep(old: old, new: new)
        registerMoveUndo(step)
        lastNudge = isNudge ? step : nil
    }

    /// Applies positions to the scene, the saved layout and the canvas.
    /// Tables that aren't in the schema right now (removed by an edit) are only remembered.
    private func setPositions(_ positions: [String: CGPoint], animated: Bool) {
        remember(positions)
        canvas?.movePositions(positions, animated: animated)
    }

    private func remember(_ positions: [String: CGPoint]) {
        guard var scene else { return }
        for (id, p) in positions where scene.positions[id] != nil { scene.positions[id] = p }
        self.scene = scene
        rememberedPositions.merge(positions) { _, new in new }
        store?.save(positions: rememberedPositions)
    }

    /// One undo step. A class so a merged nudge can update `new` after it was registered.
    private final class MoveStep {
        let old: [String: CGPoint]
        var new: [String: CGPoint]
        var time = CACurrentMediaTime()
        var serial = 0
        init(old: [String: CGPoint], new: [String: CGPoint]) { self.old = old; self.new = new }
    }

    private func registerMoveUndo(_ step: MoveStep) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.setPositions(step.old, animated: true)
            model.registerMoveUndo(MoveStep(old: step.new, new: step.old))
        }
        undoManager.setActionName(step.old.count == 1 ? "Move Table" : "Move \(step.old.count) Tables")
        undoSerial += 1
        step.serial = undoSerial
    }

    /// Undoing an arrange also brings back the zoom, scroll position and style from before it.
    private func registerArrangeUndo(restoring old: [String: CGPoint], viewport: (CGFloat, CGPoint), style: LayoutStyle) {
        guard let undoManager, let scene, let canvas else { return }
        let current = scene.positions
        let currentViewport = (canvas.zoom, canvas.offset)
        let currentStyle = layoutStyle
        undoManager.registerUndo(withTarget: self) { model in
            model.setStyle(style)
            model.setPositions(old, animated: true)
            model.canvas?.setViewport(zoom: viewport.0, offset: viewport.1, animated: true)
            model.registerArrangeUndo(restoring: current, viewport: currentViewport, style: currentStyle)
        }
        undoManager.setActionName("Auto-Arrange")
        undoSerial += 1
    }

    func viewportChanged(zoom: CGFloat, offset: CGPoint) {
        store?.save(viewport: .init(zoom: zoom, x: offset.x, y: offset.y))
    }

    func selectRef(_ i: Int?, reveal: Bool) {
        selectedRef = i
        if i != nil { selection = nil; selectedTables = [] }
        canvas?.selectRef(i, reveal: reveal)
    }

    func select(_ id: String?, focus: Bool) {
        selection = id
        selectedTables = id.map { [$0] } ?? []
        if id != nil { selectedRef = nil }
        guard let canvas else { return }
        if let id, focus { canvas.focus(table: id) } else { canvas.select(id) }
    }

    /// ⌘-click in the sidebar: add or remove a table without losing the rest of the selection.
    func toggle(_ id: String) {
        canvas?.toggle(id)
    }

    // MARK: export

    func exportPNG() {
        guard let scene, let window = canvas?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "schema") + ".png"
        let theme = Theme.current(window.effectiveAppearance)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url, let image = ImageExporter.render(scene, theme: theme) else { return }
            try? ImageExporter.writePNG(image, to: dest)
        }
    }
}

/// Table positions and viewport, stored per file in Application Support so the
/// .dbml file (often in a git repo) is never touched.
final class LayoutStore {
    struct Viewport: Codable { var zoom: CGFloat; var x: CGFloat; var y: CGFloat }
    struct Data: Codable {
        var positions: [String: [CGFloat]] = [:]
        var viewport: Viewport?
        /// A `LayoutStyle` raw value. A plain string so an unknown value never fails decoding
        /// (which would lose the saved positions).
        var style: String?
    }

    private let file: URL
    private var data: Data
    private var saveWork: DispatchWorkItem?

    init?(for document: URL) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("DBGram/Layouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Foundation.Data(document.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        file = dir.appendingPathComponent("\(hash).json")
        data = (try? JSONDecoder().decode(Data.self, from: Foundation.Data(contentsOf: file))) ?? Data()
    }

    func load() -> (positions: [String: CGPoint], viewport: Viewport?, style: LayoutStyle?) {
        (data.positions.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }, data.viewport,
         data.style.flatMap(LayoutStyle.init(rawValue:)))
    }

    func save(style: LayoutStyle) {
        data.style = style.rawValue
        scheduleWrite()
    }

    func save(positions: [String: CGPoint]) {
        data.positions = positions.mapValues { [$0.x, $0.y] }
        scheduleWrite()
    }

    func save(viewport: Viewport) {
        data.viewport = viewport
        scheduleWrite()
    }

    private func scheduleWrite() {
        saveWork?.cancel()
        let snapshot = data, file = file
        let work = DispatchWorkItem {
            if let encoded = try? JSONEncoder().encode(snapshot) { try? encoded.write(to: file, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// Watches a file for changes. Kernel file events give instant reloads; a once-a-second check of the
/// file's identity, size and modification time re-attaches after the file is replaced or recreated
/// (however late) and catches changes the events miss, e.g. on network or synced folders.
final class FileWatcher {
    private struct Stamp: Equatable {
        var inode: UInt64
        var size: Int64
        var modified: timespec

        static func == (a: Stamp, b: Stamp) -> Bool {
            a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var watchedInode: UInt64?
    private var lastStamp: Stamp?
    private var timer: Timer?
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        lastStamp = stamp()
        attach()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 0.3
        // .common so it keeps running while the user drags or scrolls.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        source?.cancel()
    }

    private func stamp() -> Stamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(inode: UInt64(st.st_ino), size: Int64(st.st_size), modified: st.st_mtimespec)
    }

    private func attach() {
        source?.cancel()
        source = nil
        watchedInode = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }  // Missing for now; check() attaches when it reappears.
        var st = stat()
        if fstat(fd, &st) == 0 { watchedInode = UInt64(st.st_ino) }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.intersection([.delete, .rename]).isEmpty {
                // Replaced by an atomic save: watch the new file once it is in place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.attach() }
            }
            self.fire()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func check() {
        let current = stamp()
        if let current, source == nil || current.inode != watchedInode { attach() }
        if current != lastStamp { fire() }
    }

    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastStamp = self.stamp()
            self.onChange()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}

enum RecentFiles {
    private static let key = "recentFiles"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: key)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}

import AppKit
import DBMLKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Binding var fileURL: URL?
    var initialPaste: String? = nil
    @State private var model = DocumentModel()
    @State private var search = ""
    @State private var showInspector = true
    @State private var showIssues = false
    @State private var windowID = UUID()
    @State private var actions = WindowActions()
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            ZStack(alignment: .bottomLeading) {
                CanvasRepresentable(model: model)
                    .ignoresSafeArea()
                if !model.hasContent { EmptyStateView(open: openPanel, paste: pasteFromClipboard, openRecent: open) }
                if let error = model.loadError { banner(error, systemImage: "exclamationmark.triangle.fill", color: .red) }
                else if !model.schema.diagnostics.isEmpty { issuesButton }
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 290, max: 420)
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.hasContent ? "\(model.schema.tables.count) tables · \(model.schema.refs.count) refs" : "")
        .toolbar { toolbar }
        .onAppear {
            Opener.register(openWindow)
            configureActions()
            DebugHooks.screenshotIfRequested(model)
            if let url = fileURL { DispatchQueue.main.async { model.open(url) } }
            else if let text = initialPaste { model.loadPasted(text) }
            else if let url = Opener.takePending() { fileURL = url }
            else { Opener.registerEmpty(windowID) { url in fileURL = url } }
        }
        .onDisappear { Opener.unregisterEmpty(windowID) }
        .onChange(of: fileURL) { _, url in
            if let url { Opener.unregisterEmpty(windowID); model.open(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { open(url) } }
            }
            return true
        }
        .focusedSceneValue(\.windowActions, actions)
    }

    // MARK: sidebar

    private var filteredGroups: [(name: String, color: Color?, tables: [DBMLKit.Table])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matches: (DBMLKit.Table) -> Bool = { t in
            q.isEmpty || t.displayName.lowercased().contains(q) || t.columns.contains { $0.name.lowercased().contains(q) }
        }
        let style = model.style
        var result: [(String, Color?, [DBMLKit.Table])] = []
        var grouped: Set<String> = []
        for g in model.schema.groups {
            let tables = g.tableIDs.compactMap { model.schema.table(id: $0) }
            grouped.formUnion(g.tableIDs)
            let shown = tables.filter(matches)
            if !shown.isEmpty { result.append((g.name, style?.groupColors[g.name].map(Color.init(nsColor:)), shown)) }
        }
        let rest = model.schema.tables.filter { !grouped.contains($0.id) && matches($0) }
        if !rest.isEmpty { result.append((model.schema.groups.isEmpty ? "Tables" : "Other", nil, rest)) }
        return result
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find table or column", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filteredGroups.first?.tables.first { model.select(first.id, focus: true) }
                    }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            .padding(.horizontal, 10).padding(.vertical, 8)

            // A lazy stack instead of List: stays smooth with thousands of tables.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(filteredGroups, id: \.name) { group in
                            Section {
                                ForEach(group.tables) { t in
                                    SidebarRow(table: t, color: model.style?.headerColors[t.id] ?? Palette.neutral,
                                               selected: model.selection == t.id) {
                                        model.select(t.id, focus: true)
                                    }
                                    .id(t.id)
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    if let c = group.color { Circle().fill(c).frame(width: 7, height: 7) }
                                    Text(group.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                                .background(.bar)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .onChange(of: model.selection) { _, id in
                    if let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    // MARK: toolbar & banners

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.canvas?.zoom(by: 0.8, animated: true) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
            Button { model.canvas?.zoom(by: 1.25, animated: true) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
            Button { model.canvas?.zoomToFit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Zoom to fit (⌘0)")
            Menu {
                Button("Open…", action: openPanel)
                Button("Paste DBML from Clipboard", action: pasteFromClipboard)
                Divider()
                Button("Auto-Arrange Tables", action: model.resetLayout)
                Button("Export PNG…", action: model.exportPNG)
            } label: { Label("More", systemImage: "ellipsis.circle") }
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }

    private var issuesButton: some View {
        Button { showIssues.toggle() } label: {
            Label("\(model.schema.diagnostics.count) issue\(model.schema.diagnostics.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .padding(14)
        .popover(isPresented: $showIssues) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.schema.diagnostics.enumerated()), id: \.offset) { _, d in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(d.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                            Text(d.message).font(.callout).foregroundStyle(d.severity == .error ? .red : .primary)
                        }
                    }
                }
                .padding(12)
            }
            .frame(width: 420, height: min(300, CGFloat(model.schema.diagnostics.count) * 24 + 30))
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(color)
            .padding(14)
    }

    // MARK: actions

    private func configureActions() {
        let model = model
        actions.open = openPanel
        actions.paste = pasteFromClipboard
        actions.export = { model.exportPNG() }
        actions.resetLayout = { model.resetLayout() }
        actions.find = { searchFocused = true }
        actions.zoomIn = { model.canvas?.zoom(by: 1.25, animated: true) }
        actions.zoomOut = { model.canvas?.zoom(by: 0.8, animated: true) }
        actions.zoomFit = { model.canvas?.zoomToFit() }
        actions.zoomActual = { model.canvas?.zoom(by: 1 / (model.canvas?.zoom ?? 1), animated: true) }
        actions.toggleInspector = { showInspector.toggle() }
    }

    private func open(_ url: URL) {
        if fileURL == nil && !model.isPasted { fileURL = url } else { openWindow(value: url) }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dbml") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if model.hasContent {
            Opener.pendingPaste = text
            openWindow(id: "paste")
        } else {
            Opener.unregisterEmpty(windowID)
            model.loadPasted(text)
        }
    }
}

/// Window for DBML pasted from the clipboard.
struct PasteWindowView: View {
    @State private var url: URL?
    @State private var text = Opener.takePaste()
    var body: some View {
        ContentView(fileURL: $url, initialPaste: text)
    }
}

private struct SidebarRow: View {
    let table: DBMLKit.Table
    let color: NSColor
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: color)).frame(width: 10, height: 10)
            Text(table.displayName).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(table.columns.count)").font(.caption).monospacedDigit()
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let model: DocumentModel

    func makeNSView(context: Context) -> DiagramCanvas {
        let canvas = DiagramCanvas(frame: .zero)
        canvas.onSelect = { [weak model] id in
            if model?.selection != id { model?.selection = id }
        }
        canvas.onSelectRef = { [weak model] i in
            if model?.selectedRef != i { model?.selectedRef = i }
        }
        canvas.onTablesMoved = { [weak model] in model?.tablesMoved($0) }
        canvas.onViewportChanged = { [weak model] z, o in model?.viewportChanged(zoom: z, offset: o) }
        model.canvas = canvas
        model.push(to: canvas, fit: true)
        return canvas
    }

    func updateNSView(_ canvas: DiagramCanvas, context: Context) {}
}

struct EmptyStateView: View {
    let open: () -> Void
    let paste: () -> Void
    let openRecent: (URL) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Open a DBML schema").font(.title2.weight(.semibold))
                Text("Drop a .dbml file here, open one, or paste DBML from the clipboard.\nThe diagram reloads automatically when the file changes.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Open File…", action: open).keyboardShortcut("o").controlSize(.large).buttonStyle(.borderedProminent)
                Button("Paste DBML", action: paste).controlSize(.large)
            }
            let recents = RecentFiles.all
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 8)
                    ForEach(recents.prefix(6), id: \.self) { url in
                        Button {
                            openRecent(url)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 440)
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: inspector

struct InspectorView: View {
    let model: DocumentModel

    var body: some View {
        if let i = model.selectedRef, i < model.schema.refs.count {
            RelationInspector(model: model, index: i, ref: model.schema.refs[i])
        } else if let id = model.selection, let table = model.schema.table(id: id) {
            TableInspector(model: model, table: table)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if let p = model.schema.project {
                    Text(p.name.isEmpty ? "Project" : p.name).font(.title3.weight(.semibold))
                    if let db = p.databaseType { Label(db, systemImage: "cylinder.split.1x2").foregroundStyle(.secondary) }
                    if let note = p.note { Text(note).textSelection(.enabled).font(.callout) }
                    Divider()
                }
                Text("Select a table to see its columns, notes and relationships.")
                    .foregroundStyle(.secondary).font(.callout)
                VStack(alignment: .leading, spacing: 6) {
                    shortcut("Pan", "two-finger scroll / drag background")
                    shortcut("Zoom", "pinch / ⌘ + scroll / mouse wheel")
                    shortcut("Fit", "⌘0 or F")
                    shortcut("Find", "⌘F")
                    shortcut("Focus table", "double-click")
                    shortcut("Relationship", "click a line; double-click to show both ends")
                }
                .font(.caption)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shortcut(_ a: String, _ b: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(a).fontWeight(.medium).frame(width: 74, alignment: .leading)
            Text(b).foregroundStyle(.secondary)
        }
    }
}

private struct TableInspector: View {
    let model: DocumentModel
    let table: DBMLKit.Table

    var body: some View {
        let refs = model.schema.refs.enumerated().filter { $0.element.from.tableID == table.id || $0.element.to.tableID == table.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: model.style?.headerColors[table.id] ?? Palette.neutral))
                        .frame(width: 14, height: 14)
                    Text(table.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
                if let g = model.style?.groupOf[table.id] {
                    Label(g, systemImage: "square.dashed").font(.callout).foregroundStyle(.secondary)
                }
                if let note = table.note {
                    Text(note).font(.callout).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                }

                section("Columns")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, c in
                        ColumnRow(column: c, enumValues: model.schema.enums.first { $0.name == c.type || $0.id == c.type }?.values)
                        Divider().opacity(0.5)
                    }
                }

                if !table.indexes.isEmpty {
                    section("Indexes")
                    ForEach(Array(table.indexes.enumerated()), id: \.offset) { _, idx in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("(\(idx.columns.joined(separator: ", ")))").font(.system(.callout, design: .monospaced))
                            if idx.isPrimaryKey { Badge(text: "pk") }
                            if idx.isUnique { Badge(text: "unique") }
                            if let t = idx.type { Badge(text: t) }
                            Spacer()
                        }
                        if let n = idx.name { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                }

                if !refs.isEmpty {
                    section("Relationships")
                    ForEach(refs, id: \.offset) { index, r in
                        let other = r.from.tableID == table.id ? r.to : r.from
                        let mine = r.from.tableID == table.id ? r.from : r.to
                        Button { model.selectRef(index, reveal: true) } label: {
                            HStack(spacing: 6) {
                                Text(mine.columns.joined(separator: ", ")).font(.system(.callout, design: .monospaced))
                                Text(symbol(mine.cardinality, other.cardinality)).foregroundStyle(.secondary)
                                Text("\(other.tableID).\(other.columns.joined(separator: ", "))")
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private func symbol(_ a: Cardinality, _ b: Cardinality) -> String {
        switch (a, b) {
        case (.many, .one): return "→"
        case (.one, .many): return "←"
        case (.one, .one): return "—"
        case (.many, .many): return "⇄"
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }
}

private struct RelationInspector: View {
    let model: DocumentModel
    let index: Int
    let ref: Ref

    var body: some View {
        let text = RelationText(ref)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                    Text(ref.name ?? "Relationship").font(.title3.weight(.semibold))
                }
                HStack(spacing: 6) {
                    Badge(text: text.kind)
                    Text(text.op).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text("line \(ref.line)").font(.caption).foregroundStyle(.tertiary)
                }
                Text(text.sentence).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                EndpointCard(model: model, end: ref.from)
                HStack {
                    Spacer()
                    Image(systemName: ref.from.cardinality == .many && ref.to.cardinality == .one ? "arrow.down" :
                            ref.from.cardinality == .one && ref.to.cardinality == .many ? "arrow.up" : "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                EndpointCard(model: model, end: ref.to)

                if ref.onDelete != nil || ref.onUpdate != nil {
                    Text("ACTIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    if let d = ref.onDelete { Label("on delete: \(d)", systemImage: "trash").font(.callout) }
                    if let u = ref.onUpdate { Label("on update: \(u)", systemImage: "arrow.triangle.2.circlepath").font(.callout) }
                }

                Button { model.selectRef(index, reveal: true) } label: {
                    Label("Show Both Tables", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }
}

/// One side of a relationship: its table (click to jump there), cardinality and column details.
private struct EndpointCard: View {
    let model: DocumentModel
    let end: RefEndpoint

    var body: some View {
        let table = model.schema.table(id: end.tableID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: model.style?.headerColors[end.tableID] ?? Palette.neutral))
                    .frame(width: 10, height: 10)
                Button { model.select(end.tableID, focus: true) } label: {
                    Text(table?.displayName ?? end.tableID).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Go to table")
                Spacer()
                Text(RelationText.side(end)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ForEach(end.columns, id: \.self) { name in
                let column = table?.columnIndex(named: name).map { table!.columns[$0] }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if column?.isPrimaryKey == true { Image(systemName: "key.fill").font(.caption2).foregroundStyle(.orange) }
                        else if column?.isForeignKey == true { Image(systemName: "link").font(.caption2).foregroundStyle(.blue) }
                        Text(name).font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text(column?.type ?? "missing column").font(.system(.caption, design: .monospaced))
                            .foregroundStyle(column == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    if let c = column {
                        let flags = [c.isNotNull || c.isPrimaryKey ? "not null" : "nullable", c.isUnique ? "unique" : nil].compactMap { $0 }
                        Text(flags.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
                        if let note = c.note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

private struct ColumnRow: View {
    let column: Column
    let enumValues: [EnumValue]?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if column.isPrimaryKey { Image(systemName: "key.fill").font(.caption2).foregroundStyle(.orange) }
                else if column.isForeignKey { Image(systemName: "link").font(.caption2).foregroundStyle(.blue) }
                Text(column.name).fontWeight(column.isPrimaryKey ? .semibold : .regular).textSelection(.enabled)
                Spacer()
                Text(column.type).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            let flags = [column.isNotNull ? "not null" : nil, column.isUnique ? "unique" : nil, column.isIncrement ? "increment" : nil,
                         column.defaultValue.map { "default \($0)" }].compactMap { $0 }
            if !flags.isEmpty {
                Text(flags.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
            }
            if let enumValues {
                Text(enumValues.map(\.name).joined(separator: " | ")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let note = column.note {
                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Small pill label. A struct, not a `badge(_:)` function: inside a View that name resolves to
/// SwiftUI's `.badge` modifier on `self`, which nests the view in itself until the stack overflows.
private struct Badge: View {
    let text: String

    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }
}

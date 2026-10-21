import Foundation

public enum DBML {
    /// Parses DBML source. Never throws: anything it can't understand is reported in
    /// `Schema.diagnostics` and skipped, so a partially broken file still renders.
    public static func parse(_ source: String) -> Schema {
        var lexer = Lexer(source)
        let tokens = lexer.tokenize()
        var parser = Parser(tokens: tokens)
        var schema = parser.parse()
        schema.diagnostics.insert(contentsOf: lexer.diagnostics, at: 0)
        return schema
    }
}

private struct ParseError: Error {
    var line: Int
    var message: String
}

/// A setting inside `[...]`: either a flag (`pk`, `not null`) or `key: value`.
private struct Setting {
    var key: String
    var value: [Token]
    var line: Int

    var stringValue: String? {
        guard !value.isEmpty else { return nil }
        return value.map(\.text).joined(separator: value.count > 1 ? " " : "")
    }
}

private struct PendingRef {
    var name: String?
    var from: (path: [String], columns: [String])
    var op: String
    var to: (path: [String], columns: [String])
    var settings: [Setting]
    var line: Int
}

private struct PendingTable {
    var table: Table
    /// Column list with `~partial` injection points kept in source order.
    var items: [Item]
    var settings: [Setting]

    enum Item {
        case column(Column)
        case partial(String, line: Int)
    }
}

private struct Partial {
    var columns: [Column]
    var indexes: [Index]
    var headerColor: String?
    var note: String?
}

private struct Parser {
    let tokens: [Token]
    var p = 0
    var schema = Schema()
    var pendingTables: [PendingTable] = []
    var pendingRefs: [PendingRef] = []
    var inlineRefs: [(tableIndex: Int, column: String, ref: PendingRef)] = []
    var partials: [String: Partial] = [:]
    var pendingGroups: [(group: TableGroup, names: [(String, Int)])] = []

    init(tokens: [Token]) { self.tokens = tokens }

    // MARK: token helpers

    var cur: Token { tokens[p] }
    func peek(_ n: Int = 1) -> Token { tokens[min(p + n, tokens.count - 1)] }

    mutating func advance() -> Token {
        let t = tokens[p]
        if p < tokens.count - 1 { p += 1 }
        return t
    }

    mutating func skipNewlines() {
        while cur.kind == .newline || cur.isPunct(";") { p += 1 }
    }

    mutating func expect(_ punct: String) throws {
        guard cur.isPunct(punct) else { throw ParseError(line: cur.line, message: "Expected '\(punct)' but found '\(display(cur))'") }
        p += 1
    }

    func display(_ t: Token) -> String {
        switch t.kind {
        case .newline: return "end of line"
        case .eof: return "end of file"
        default: return t.text
        }
    }

    mutating func name() throws -> String {
        guard cur.kind == .ident || cur.kind == .string else {
            throw ParseError(line: cur.line, message: "Expected a name but found '\(display(cur))'")
        }
        return advance().text
    }

    /// `a`, `a.b`, `a.b.c` (quoted segments allowed).
    mutating func dottedName() throws -> [String] {
        var parts = [try name()]
        while cur.isPunct("."), peek().kind == .ident || peek().kind == .string {
            p += 1
            parts.append(try name())
        }
        return parts
    }

    // MARK: top level

    mutating func parse() -> Schema {
        while true {
            skipNewlines()
            if cur.kind == .eof { break }
            let start = p
            do {
                try topLevel()
            } catch let e as ParseError {
                schema.diagnostics.append(Diagnostic(severity: .error, line: e.line, message: e.message))
                recover(from: start)
            } catch {}
        }
        resolve()
        return schema
    }

    /// Skips the rest of a broken top-level element: its `{ ... }` body if it has one, else the line.
    mutating func recover(from start: Int) {
        p = start
        while cur.kind != .eof, cur.kind != .newline, !cur.isPunct("{") { p += 1 }
        if cur.isPunct("{") { skipBlock() }
        if p == start { p += 1 }
    }

    /// Assumes `cur` is `{`; leaves `p` after the matching `}`.
    mutating func skipBlock() {
        var depth = 0
        repeat {
            if cur.isPunct("{") { depth += 1 }
            if cur.isPunct("}") { depth -= 1 }
            p += 1
        } while depth > 0 && cur.kind != .eof
    }

    mutating func topLevel() throws {
        let t = cur
        guard t.kind == .ident, !t.quoted else {
            throw ParseError(line: t.line, message: "Unexpected '\(display(t))' at top level")
        }
        switch t.text.lowercased() {
        case "table": p += 1; try table()
        case "tablepartial": p += 1; try tablePartial()
        case "ref": p += 1; try refDefinition()
        case "enum": p += 1; try enumDefinition()
        case "tablegroup": p += 1; try tableGroup()
        case "project": p += 1; try project()
        case "note": p += 1; try stickyNote()
        case "records":
            p += 1
            while cur.kind != .eof, !cur.isPunct("{"), cur.kind != .newline { p += 1 }
            if cur.isPunct("{") { skipBlock() }
        default:
            schema.diagnostics.append(Diagnostic(severity: .warning, line: t.line, message: "Unknown element '\(t.text)' skipped"))
            recover(from: p)
        }
    }

    // MARK: settings

    mutating func settingsIfPresent() throws -> [Setting] {
        guard cur.isPunct("[") else { return [] }
        p += 1
        var result: [Setting] = []
        var item: [Token] = []
        func flush() {
            guard let first = item.first else { return }
            if item.count >= 2, item[1].isPunct(":") {
                result.append(Setting(key: first.text.lowercased(), value: Array(item.dropFirst(2)), line: first.line))
            } else {
                let key = item.map { $0.text.lowercased() }.joined(separator: " ")
                result.append(Setting(key: key, value: [], line: first.line))
            }
            item = []
        }
        var depth = 0
        while true {
            let t = cur
            if t.kind == .eof || t.isPunct("{") || t.isPunct("}") {
                throw ParseError(line: t.line, message: "Unclosed '[' in settings")
            }
            p += 1
            if t.isPunct("(") { depth += 1 }
            if t.isPunct(")") { depth -= 1 }
            if depth == 0, t.isPunct("]") { break }
            if depth == 0, t.isPunct(",") { flush(); continue }
            if t.kind == .newline { continue }
            item.append(t)
        }
        flush()
        return result
    }

    // MARK: table

    mutating func table() throws {
        let line = cur.line
        let parts = try dottedName()
        let tableSchema = parts.count > 1 ? parts.dropLast().joined(separator: ".") : nil
        let tableName = parts.last!
        var alias: String?
        if cur.isKeyword("as") {
            p += 1
            alias = try name()
        }
        let settings = try settingsIfPresent()
        skipNewlines()
        try expect("{")

        let normalizedSchema = (tableSchema?.lowercased() == "public") ? nil : tableSchema
        var table = Table(
            id: normalizedSchema.map { "\($0).\(tableName)" } ?? tableName,
            schema: normalizedSchema, name: tableName, alias: alias, line: line)
        for s in settings {
            switch s.key {
            case "headercolor": table.headerColor = s.stringValue
            case "note": table.note = s.value.first?.text
            default: break
            }
        }

        let tableIndex = pendingTables.count
        var items: [PendingTable.Item] = []
        try tableBody(table: &table, items: &items, tableIndex: tableIndex, allowPartials: true)
        pendingTables.append(PendingTable(table: table, items: items, settings: settings))
    }

    mutating func tablePartial() throws {
        let partialName = try name()
        let settings = try settingsIfPresent()
        skipNewlines()
        try expect("{")
        var table = Table(id: partialName, name: partialName, line: cur.line)
        var items: [PendingTable.Item] = []
        try tableBody(table: &table, items: &items, tableIndex: nil, allowPartials: false)
        var partial = Partial(
            columns: items.compactMap { if case .column(let c) = $0 { c } else { nil } },
            indexes: table.indexes, note: table.note)
        for s in settings where s.key == "headercolor" { partial.headerColor = s.stringValue }
        partials[partialName] = partial
    }

    /// Parses the inside of a table (after `{`, through `}`).
    mutating func tableBody(table: inout Table, items: inout [PendingTable.Item], tableIndex: Int?, allowPartials: Bool) throws {
        while true {
            skipNewlines()
            let t = cur
            if t.isPunct("}") { p += 1; return }
            if t.kind == .eof { throw ParseError(line: table.line, message: "Table '\(table.name)' is missing a closing '}'") }

            if t.isPunct("~") {
                p += 1
                let partialName = try name()
                if allowPartials { items.append(.partial(partialName, line: t.line)) }
                continue
            }
            if t.isKeyword("note"), peek().isPunct(":") || peek().isPunct("{") {
                p += 1
                table.note = try noteValue()
                continue
            }
            if t.isKeyword("indexes"), peek().isPunct("{") || peek().kind == .newline {
                p += 1
                skipNewlines()
                table.indexes += try indexesBlock()
                continue
            }
            if t.isKeyword("records"), peek().isPunct("{") || peek().isPunct("(") || peek().isPunct("[") {
                while cur.kind != .eof, !cur.isPunct("{") { p += 1 }
                skipBlock()
                continue
            }
            do {
                let column = try columnDefinition(tableIndex: tableIndex)
                items.append(.column(column))
            } catch let e as ParseError {
                // Lose only this line, keep the rest of the table.
                schema.diagnostics.append(Diagnostic(severity: .error, line: e.line, message: e.message))
                while cur.kind != .newline, cur.kind != .eof, !cur.isPunct("}") { p += 1 }
            }
        }
    }

    /// `Note: 'text'` or `Note { 'text' }`, with `cur` on the `:` or `{`.
    mutating func noteValue() throws -> String {
        if cur.isPunct(":") {
            p += 1
            guard cur.kind == .string || cur.kind == .ident else { throw ParseError(line: cur.line, message: "Expected note text") }
            return advance().text
        }
        try expect("{")
        skipNewlines()
        var text = ""
        while !cur.isPunct("}") {
            if cur.kind == .eof { throw ParseError(line: cur.line, message: "Unclosed Note block") }
            if cur.kind == .string { text += (text.isEmpty ? "" : "\n") + cur.text }
            p += 1
        }
        p += 1
        return text
    }

    mutating func columnDefinition(tableIndex: Int?) throws -> Column {
        let line = cur.line
        let columnName = try name()
        // The type runs until settings, end of line, or the closing brace.
        var typeParts = ""
        var last: Token?
        while true {
            let t = cur
            if t.kind == .newline || t.kind == .eof || t.isPunct("}") { break }
            if t.isPunct("[") {
                if peek().isPunct("]") { typeParts += "[]"; p += 2; last = tokens[p - 1]; continue }
                break
            }
            if let l = last, t.spaceBefore, l.kind == .ident, t.kind == .ident { typeParts += " " }
            typeParts += t.text
            last = t
            p += 1
        }
        guard !typeParts.isEmpty else { throw ParseError(line: line, message: "Column '\(columnName)' has no type") }
        var column = Column(name: columnName, type: typeParts)
        for s in try settingsIfPresent() {
            switch s.key {
            case "pk", "primary key": column.isPrimaryKey = true
            case "not null": column.isNotNull = true
            case "null": column.isNotNull = false
            case "unique": column.isUnique = true
            case "increment": column.isIncrement = true
            case "note": column.note = s.value.first?.text
            case "default": column.defaultValue = defaultText(s.value)
            case "ref":
                guard let tableIndex else { break }
                var tokens = s.value
                guard let op = tokens.first, op.kind == .op else {
                    throw ParseError(line: s.line, message: "Inline ref needs a relation (<, >, -, <>)")
                }
                tokens.removeFirst()
                let target = try endpoint(from: tokens, line: s.line)
                inlineRefs.append((tableIndex, columnName, PendingRef(
                    name: nil, from: ([], [columnName]), op: op.text, to: target, settings: [], line: s.line)))
            default: break
            }
        }
        return column
    }

    func defaultText(_ value: [Token]) -> String {
        value.map { t in
            switch t.kind {
            case .string: return "'\(t.text)'"
            case .expression: return "`\(t.text)`"
            default: return t.text
            }
        }.joined()
    }

    mutating func indexesBlock() throws -> [Index] {
        try expect("{")
        var result: [Index] = []
        while true {
            skipNewlines()
            if cur.isPunct("}") { p += 1; return result }
            if cur.kind == .eof { throw ParseError(line: cur.line, message: "Unclosed indexes block") }
            var columns: [String] = []
            if cur.isPunct("(") {
                p += 1
                while !cur.isPunct(")") {
                    if cur.kind == .eof { throw ParseError(line: cur.line, message: "Unclosed '(' in index") }
                    let t = advance()
                    if t.kind == .ident { columns.append(t.text) }
                    if t.kind == .expression { columns.append("`\(t.text)`") }
                }
                p += 1
            } else if cur.kind == .ident {
                columns.append(advance().text)
            } else if cur.kind == .expression {
                columns.append("`\(advance().text)`")
            } else {
                throw ParseError(line: cur.line, message: "Unexpected '\(display(cur))' in indexes")
            }
            var index = Index(columns: columns)
            for s in try settingsIfPresent() {
                switch s.key {
                case "pk": index.isPrimaryKey = true
                case "unique": index.isUnique = true
                case "name": index.name = s.value.first?.text
                case "type": index.type = s.value.first?.text
                case "note": index.note = s.value.first?.text
                default: break
                }
            }
            result.append(index)
        }
    }

    // MARK: refs

    /// `schema.table.column`, `table.column`, or `table.(a, b)` from a token list.
    func endpoint(from tokens: [Token], line: Int) throws -> (path: [String], columns: [String]) {
        var parts: [String] = []
        var columns: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.kind == .ident || t.kind == .string {
                parts.append(t.text)
            } else if t.isPunct("(") {
                i += 1
                while i < tokens.count, !tokens[i].isPunct(")") {
                    if tokens[i].kind == .ident { columns.append(tokens[i].text) }
                    i += 1
                }
            } else if !t.isPunct(".") {
                break
            }
            i += 1
        }
        if columns.isEmpty {
            guard parts.count >= 2 else { throw ParseError(line: line, message: "Ref target must be table.column") }
            columns = [parts.removeLast()]
        }
        guard !parts.isEmpty else { throw ParseError(line: line, message: "Ref target is missing a table") }
        return (parts, columns)
    }

    mutating func refDefinition() throws {
        let line = cur.line
        var refName: String?
        if cur.kind == .ident || cur.kind == .string { refName = advance().text }
        if cur.isPunct(":") {
            p += 1
            try refBody(name: refName, line: line)
            return
        }
        skipNewlines()
        try expect("{")
        while true {
            skipNewlines()
            if cur.isPunct("}") { p += 1; return }
            if cur.kind == .eof { throw ParseError(line: line, message: "Unclosed Ref block") }
            try refBody(name: refName, line: cur.line)
        }
    }

    /// `endpoint op endpoint [settings]` up to the end of the line.
    mutating func refBody(name: String?, line: Int) throws {
        var left: [Token] = []
        while cur.kind != .op {
            if cur.kind == .newline || cur.kind == .eof || cur.isPunct("}") {
                throw ParseError(line: line, message: "Ref is missing a relation (<, >, -, <>)")
            }
            left.append(advance())
        }
        let op = advance().text
        var right: [Token] = []
        while cur.kind != .newline, cur.kind != .eof, !cur.isPunct("}"), !cur.isPunct("[") {
            right.append(advance())
        }
        let settings = try settingsIfPresent()
        pendingRefs.append(PendingRef(
            name: name, from: try endpoint(from: left, line: line), op: op,
            to: try endpoint(from: right, line: line), settings: settings, line: line))
    }

    // MARK: other blocks

    mutating func enumDefinition() throws {
        let parts = try dottedName()
        _ = try settingsIfPresent()
        skipNewlines()
        try expect("{")
        var values: [EnumValue] = []
        while true {
            skipNewlines()
            if cur.isPunct("}") { p += 1; break }
            if cur.kind == .eof { throw ParseError(line: cur.line, message: "Unclosed Enum block") }
            var value = EnumValue(name: try name())
            for s in try settingsIfPresent() where s.key == "note" { value.note = s.value.first?.text }
            values.append(value)
        }
        let enumSchema = parts.count > 1 ? parts.dropLast().joined(separator: ".") : nil
        schema.enums.append(Enum(
            id: parts.joined(separator: "."), schema: enumSchema, name: parts.last!, values: values))
    }

    mutating func tableGroup() throws {
        let groupName = try dottedName().joined(separator: ".")
        var group = TableGroup(name: groupName, tableIDs: [])
        for s in try settingsIfPresent() {
            if s.key == "color" { group.color = s.stringValue }
            if s.key == "note" { group.note = s.value.first?.text }
        }
        skipNewlines()
        try expect("{")
        var names: [(String, Int)] = []
        while true {
            skipNewlines()
            if cur.isPunct("}") { p += 1; break }
            if cur.kind == .eof { throw ParseError(line: cur.line, message: "Unclosed TableGroup block") }
            if cur.isKeyword("note"), peek().isPunct(":") || peek().isPunct("{") {
                p += 1
                group.note = try noteValue()
                continue
            }
            let line = cur.line
            names.append((try dottedName().joined(separator: "."), line))
        }
        pendingGroups.append((group, names))
    }

    mutating func project() throws {
        var proj = Project(name: "")
        if cur.kind == .ident || cur.kind == .string { proj.name = advance().text }
        skipNewlines()
        try expect("{")
        while true {
            skipNewlines()
            if cur.isPunct("}") { p += 1; break }
            if cur.kind == .eof { throw ParseError(line: cur.line, message: "Unclosed Project block") }
            let key = advance()
            if key.isKeyword("note"), cur.isPunct(":") || cur.isPunct("{") {
                proj.note = try noteValue()
            } else if cur.isPunct(":") {
                p += 1
                let value = advance()
                if key.text.lowercased() == "database_type" { proj.databaseType = value.text }
            }
        }
        schema.project = proj
    }

    mutating func stickyNote() throws {
        var noteName = ""
        if cur.kind == .ident || cur.kind == .string { noteName = advance().text }
        skipNewlines()
        guard cur.isPunct("{") || cur.isPunct(":") else {
            throw ParseError(line: cur.line, message: "Expected '{' after Note")
        }
        schema.stickyNotes.append(StickyNote(name: noteName, text: try noteValue()))
    }

    // MARK: resolution

    mutating func resolve() {
        // Tables, with partials injected in order. Local definitions win over partials.
        var seen: Set<String> = []
        var tables: [Table] = []
        for pending in pendingTables {
            var table = pending.table
            let local = pending.items.compactMap { if case .column(let c) = $0 { c.name } else { nil } }
            var columns: [Column] = []
            for item in pending.items {
                switch item {
                case .column(let c):
                    columns.append(c)
                case .partial(let name, let line):
                    guard let partial = partials[name] else {
                        schema.diagnostics.append(Diagnostic(severity: .error, line: line, message: "Unknown TablePartial '\(name)'"))
                        continue
                    }
                    for c in partial.columns where !local.contains(c.name) {
                        columns.removeAll { $0.name == c.name }
                        columns.append(c)
                    }
                    table.indexes += partial.indexes
                    if pending.settings.first(where: { $0.key == "headercolor" }) == nil, let color = partial.headerColor {
                        table.headerColor = color
                    }
                    if table.note == nil { table.note = partial.note }
                }
            }
            table.columns = columns
            for index in table.indexes where index.isPrimaryKey {
                for name in index.columns {
                    if let i = table.columnIndex(named: name) { table.columns[i].isPrimaryKey = true }
                }
            }
            if seen.contains(table.id) {
                schema.diagnostics.append(Diagnostic(severity: .warning, line: table.line, message: "Duplicate table '\(table.displayName)' ignored"))
                continue
            }
            seen.insert(table.id)
            tables.append(table)
        }

        var lookup: [String: Int] = [:]
        for (i, t) in tables.enumerated() {
            lookup[t.id.lowercased()] = i
            if t.schema == nil { lookup["public.\(t.name)".lowercased()] = i }
            if lookup[t.name.lowercased()] == nil { lookup[t.name.lowercased()] = i }
            if let alias = t.alias { lookup[alias.lowercased()] = i }
        }
        func findTable(_ path: [String]) -> Int? { lookup[path.joined(separator: ".").lowercased()] }

        func addRef(_ r: PendingRef, fromTable: Int?) {
            guard let fi = fromTable ?? findTable(r.from.path) else {
                schema.diagnostics.append(Diagnostic(severity: .error, line: r.line, message: "Ref: unknown table '\(r.from.path.joined(separator: "."))'"))
                return
            }
            guard let ti = findTable(r.to.path) else {
                schema.diagnostics.append(Diagnostic(severity: .error, line: r.line, message: "Ref: unknown table '\(r.to.path.joined(separator: "."))'"))
                return
            }
            for (ti2, cols) in [(fi, r.from.columns), (ti, r.to.columns)] {
                for c in cols where tables[ti2].columnIndex(named: c) == nil {
                    schema.diagnostics.append(Diagnostic(severity: .warning, line: r.line, message: "Ref: '\(tables[ti2].displayName)' has no column '\(c)'"))
                }
            }
            let (fromCard, toCard): (Cardinality, Cardinality)
            // `?` before the operator makes the source side optional, after it the referenced side.
            let fromOptional = r.op.hasPrefix("?"), toOptional = r.op.count > 1 && r.op.hasSuffix("?")
            switch r.op.trimmingCharacters(in: CharacterSet(charactersIn: "?")) {
            case ">": (fromCard, toCard) = (.many, .one)
            case "<": (fromCard, toCard) = (.one, .many)
            case "<>": (fromCard, toCard) = (.many, .many)
            default: (fromCard, toCard) = (.one, .one)
            }
            var ref = Ref(
                name: r.name,
                from: RefEndpoint(tableID: tables[fi].id, columns: r.from.columns, cardinality: fromCard, isOptional: fromOptional),
                to: RefEndpoint(tableID: tables[ti].id, columns: r.to.columns, cardinality: toCard, isOptional: toOptional),
                line: r.line)
            for s in r.settings {
                switch s.key {
                case "delete": ref.onDelete = s.stringValue
                case "update": ref.onUpdate = s.stringValue
                case "color": ref.color = s.stringValue
                default: break
                }
            }
            // The referencing side is the FK: the "many" side, or the left side of a one-to-one.
            let fkSide = (fromCard == .one && toCard == .many) ? (ti, r.to.columns) : (fi, r.from.columns)
            for c in fkSide.1 {
                if let ci = tables[fkSide.0].columnIndex(named: c) { tables[fkSide.0].columns[ci].isForeignKey = true }
            }
            schema.refs.append(ref)
        }

        // Inline refs point at pendingTables indices; map those onto the deduplicated table list.
        for (tableIndex, _, ref) in inlineRefs {
            let id = pendingTables[tableIndex].table.id
            addRef(ref, fromTable: tables.firstIndex { $0.id == id })
        }
        for ref in pendingRefs { addRef(ref, fromTable: nil) }

        var grouped: Set<String> = []
        for (pendingGroup, names) in pendingGroups {
            var group = pendingGroup
            for (name, line) in names {
                guard let i = lookup[name.lowercased()] else {
                    schema.diagnostics.append(Diagnostic(severity: .warning, line: line, message: "TableGroup '\(group.name)': unknown table '\(name)'"))
                    continue
                }
                let id = tables[i].id
                if grouped.insert(id).inserted { group.tableIDs.append(id) }
            }
            schema.groups.append(group)
        }
        schema.tables = tables
    }
}

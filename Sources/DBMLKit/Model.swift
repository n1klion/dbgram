import Foundation

public struct Schema: Sendable, Equatable {
    public var project: Project?
    public var tables: [Table] = [] { didSet { reindex() } }
    private var tableIndex: [String: Int] = [:]
    public var refs: [Ref] = []
    public var enums: [Enum] = []
    public var groups: [TableGroup] = []
    public var stickyNotes: [StickyNote] = []
    public var diagnostics: [Diagnostic] = []

    public init() {}

    public func table(id: String) -> Table? { tableIndex[id].map { tables[$0] } }

    /// Only the tables of one `TableGroup` and the refs between them; nil when there is no such group.
    /// Everything else (project, enums, diagnostics) is kept, so the subset still describes the whole file.
    public func subset(group name: String) -> Schema? {
        guard let group = groups.first(where: { $0.name == name }) else { return nil }
        let ids = Set(group.tableIDs)
        var s = self
        s.tables = tables.filter { ids.contains($0.id) }
        s.refs = refs.filter { ids.contains($0.from.tableID) && ids.contains($0.to.tableID) }
        s.groups = [group]
        return s
    }

    private mutating func reindex() {
        tableIndex = Dictionary(tables.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

public struct Project: Sendable, Equatable {
    public var name: String
    public var databaseType: String?
    public var note: String?
}

public struct Table: Sendable, Equatable, Identifiable {
    /// Unique key: `schema.name` when a non-public schema is given, plain `name` otherwise.
    public var id: String
    public var schema: String?
    public var name: String
    public var alias: String?
    public var columns: [Column] = []
    public var indexes: [Index] = []
    public var headerColor: String?
    public var note: String?
    public var line: Int

    public var displayName: String { schema.map { "\($0).\(name)" } ?? name }

    public func columnIndex(named name: String) -> Int? {
        columns.firstIndex { $0.name == name } ?? columns.firstIndex { $0.name.lowercased() == name.lowercased() }
    }
}

public struct Column: Sendable, Equatable {
    public var name: String
    public var type: String
    public var isPrimaryKey = false
    public var isNotNull = false
    public var isUnique = false
    public var isIncrement = false
    /// Set during resolution when any ref uses this column on its "many" or "one" side as a foreign key.
    public var isForeignKey = false
    public var defaultValue: String?
    public var note: String?
}

public struct Index: Sendable, Equatable {
    public var columns: [String]
    public var isPrimaryKey = false
    public var isUnique = false
    public var name: String?
    public var type: String?
    public var note: String?
}

public enum Cardinality: Sendable, Equatable {
    case one, many
}

public struct RefEndpoint: Sendable, Equatable {
    public var tableID: String
    public var columns: [String]
    public var cardinality: Cardinality
    /// Marked with `?` in DBML: rows on this side don't have to have a match.
    public var isOptional = false
}

public struct Ref: Sendable, Equatable {
    public var name: String?
    public var from: RefEndpoint
    public var to: RefEndpoint
    public var onDelete: String?
    public var onUpdate: String?
    public var color: String?
    public var line: Int

    /// The side that owns the key being pointed at (the "one" side), used for layout direction.
    public var parent: RefEndpoint {
        if from.cardinality == .one && to.cardinality == .many { return from }
        return to
    }

    public var child: RefEndpoint {
        if from.cardinality == .one && to.cardinality == .many { return to }
        return from
    }
}

public struct Enum: Sendable, Equatable {
    public var id: String
    public var schema: String?
    public var name: String
    public var values: [EnumValue]
}

public struct EnumValue: Sendable, Equatable {
    public var name: String
    public var note: String?
}

public struct TableGroup: Sendable, Equatable {
    public var name: String
    public var tableIDs: [String]
    public var color: String?
    public var note: String?
}

public struct StickyNote: Sendable, Equatable {
    public var name: String
    public var text: String
}

public struct Diagnostic: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var line: Int
    public var message: String

    public var description: String { "line \(line): \(message)" }
}

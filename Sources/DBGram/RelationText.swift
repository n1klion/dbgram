import DBMLKit

/// Human-readable pieces of a relationship, shared by the canvas tooltip and the inspector.
struct RelationText {
    let ref: Ref

    init(_ ref: Ref) { self.ref = ref }

    var from: String { Self.endpoint(ref.from) }
    var to: String { Self.endpoint(ref.to) }

    var kind: String {
        switch (ref.from.cardinality, ref.to.cardinality) {
        case (.many, .one): return "many-to-one"
        case (.one, .many): return "one-to-many"
        case (.one, .one): return "one-to-one"
        case (.many, .many): return "many-to-many"
        }
    }

    /// The DBML operator as written: `>`, `<`, `-` or `<>`.
    var op: String {
        switch (ref.from.cardinality, ref.to.cardinality) {
        case (.many, .one): return ">"
        case (.one, .many): return "<"
        case (.one, .one): return "-"
        case (.many, .many): return "<>"
        }
    }

    /// A plain-language explanation, e.g. "Each row of sessions points to one row of users;
    /// a row of users can have many rows of sessions."
    var sentence: String {
        let child = ref.child, parent = ref.parent
        switch (ref.from.cardinality, ref.to.cardinality) {
        case (.one, .one):
            return "Each row of \(ref.from.tableID) matches at most one row of \(ref.to.tableID), and the other way round."
        case (.many, .many):
            return "Rows of \(ref.from.tableID) and \(ref.to.tableID) can be linked in any combination."
        default:
            return "Each row of \(child.tableID) points to one row of \(parent.tableID); a row of \(parent.tableID) can have many rows of \(child.tableID)."
        }
    }

    static func endpoint(_ e: RefEndpoint) -> String {
        e.columns.count == 1 ? "\(e.tableID).\(e.columns[0])" : "\(e.tableID).(\(e.columns.joined(separator: ", ")))"
    }
}

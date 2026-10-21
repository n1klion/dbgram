import DBMLKit

/// Human-readable pieces of a relationship, shared by the canvas tooltip and the inspector.
struct RelationText {
    let ref: Ref

    init(_ ref: Ref) { self.ref = ref }

    var from: String { Self.endpoint(ref.from) }
    var to: String { Self.endpoint(ref.to) }

    var kind: String {
        let base: String
        switch (ref.from.cardinality, ref.to.cardinality) {
        case (.many, .one): base = "many-to-one"
        case (.one, .many): base = "one-to-many"
        case (.one, .one): base = "one-to-one"
        case (.many, .many): base = "many-to-many"
        }
        return ref.from.isOptional || ref.to.isOptional ? base + ", optional" : base
    }

    /// "one", "many", "zero or one", "zero or many".
    static func side(_ e: RefEndpoint) -> String {
        let base = e.cardinality == .many ? "many" : "one"
        return e.isOptional ? "zero or \(base)" : base
    }

    /// The DBML operator as written: `>`, `<`, `-` or `<>`.
    var op: String {
        let core: String
        switch (ref.from.cardinality, ref.to.cardinality) {
        case (.many, .one): core = ">"
        case (.one, .many): core = "<"
        case (.one, .one): core = "-"
        case (.many, .many): core = "<>"
        }
        return (ref.from.isOptional ? "?" : "") + core + (ref.to.isOptional ? "?" : "")
    }

    /// A plain-language explanation, e.g. "Each row of sessions points to one row of users;
    /// a row of users can have many rows of sessions."
    var sentence: String {
        // `?` on a side means that side may be absent, so rows on the *other* side may have no match.
        var notes: [String] = []
        if ref.to.isOptional { notes.append("A row of \(ref.from.tableID) may have no matching \(ref.to.tableID).") }
        if ref.from.isOptional { notes.append("A row of \(ref.to.tableID) may have no matching \(ref.from.tableID).") }
        return ([baseSentence] + notes).joined(separator: " ")
    }

    private var baseSentence: String {
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

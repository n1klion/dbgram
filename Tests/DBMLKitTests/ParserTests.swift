import Foundation
import Testing
@testable import DBMLKit

private let fixture = #"""
Project shop { database_type: 'PostgreSQL'
  Note: '''
    Multi-line
    project note
  '''
}

/* block
   comment */
TablePartial timestamps [headercolor: #111111] {
  created_at timestamp [default: `now()`]
}

Table public.users as U [headercolor: #3498DB, note: 'people'] {
  id integer [pk, increment] // trailing comment
  email varchar(255) [unique, not null]
  "full name" "character varying"
  tags text[]
  price decimal(10, 2) [default: -1]
  status order_status [null]
  note varchar [note: 'a column called note']
  ~timestamps
  Note: 'users table'
}

Table billing.invoices {
  id int
  user_id int [ref: > U.id]
  code varchar
  indexes {
    (id, code) [pk]
    user_id [name: 'ix_user']
    `lower(code)`
  }
  Records { 1, 2 }
}

Table broken {
  id int [pk
}

Table after_broken { id int }

Ref fk_name: billing.invoices.(id, code) - after_broken.(id, id) [delete: cascade]
Ref {
  users.id < billing.invoices.user_id
  users.id <> missing.id
}

Enum order_status {
  created [note: 'new']
  "in progress"
}

TableGroup g [color: #ff0000] {
  users
  billing.invoices
  Note: 'group note'
}

Note sticky { 'hello' }
"""#

@Test func parsesFixture() throws {
    let s = DBML.parse(fixture)
    #expect(s.project?.name == "shop")
    #expect(s.project?.note == "Multi-line\nproject note")
    #expect(s.tables.map(\.id) == ["users", "billing.invoices", "broken", "after_broken"])

    let users = try #require(s.table(id: "users"))
    #expect(users.alias == "U")
    #expect(users.headerColor == "#3498DB")
    #expect(users.note == "users table")
    #expect(users.columns.map(\.name) == ["id", "email", "full name", "tags", "price", "status", "note", "created_at"])
    #expect(users.columns[0].isPrimaryKey && users.columns[0].isIncrement)
    #expect(users.columns[1].type == "varchar(255)" && users.columns[1].isUnique && users.columns[1].isNotNull)
    #expect(users.columns[2].type == "character varying")
    #expect(users.columns[3].type == "text[]")
    #expect(users.columns[4].type == "decimal(10,2)" && users.columns[4].defaultValue == "-1")
    #expect(users.columns[6].note == "a column called note")
    #expect(users.columns[7].defaultValue == "`now()`")

    let inv = try #require(s.table(id: "billing.invoices"))
    #expect(inv.indexes.count == 3)
    #expect(inv.columns[0].isPrimaryKey && inv.columns[2].isPrimaryKey)
    #expect(inv.columns[1].isForeignKey)

    #expect(s.refs.count == 3)
    let inline = s.refs[0]
    #expect(inline.from.tableID == "billing.invoices" && inline.to.tableID == "users")
    #expect(inline.from.cardinality == .many && inline.to.cardinality == .one)
    let composite = s.refs[1]
    #expect(composite.name == "fk_name" && composite.from.columns == ["id", "code"] && composite.onDelete == "cascade")
    #expect(s.refs[2].parent.tableID == "users")

    #expect(s.enums.first?.values.map(\.name) == ["created", "in progress"])
    #expect(s.groups.first?.tableIDs == ["users", "billing.invoices"])
    #expect(s.groups.first?.color == "#ff0000" && s.groups.first?.note == "group note")
    #expect(s.stickyNotes.first?.text == "hello")

    // The broken table and the unknown ref target are reported, not fatal.
    #expect(s.diagnostics.contains { $0.message.contains("Unclosed '['") })
    #expect(s.diagnostics.contains { $0.message.contains("unknown table 'missing'") })
}

/// Example schemas are optional (they may be kept out of the repo); tests using them skip without them.
private let examplesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../examples")
private let hasExamples = FileManager.default.fileExists(atPath: examplesDir.appendingPathComponent("crafting.dbml").path)

@Test(.enabled(if: hasExamples, "examples/ not present"))
func parsesAllExamples() throws {
    let dir = examplesDir
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "dbml" }
    #expect(!files.isEmpty)
    for f in files {
        let s = DBML.parse(try String(contentsOf: f, encoding: .utf8))
        #expect(s.diagnostics.isEmpty, "\(f.lastPathComponent): \(s.diagnostics)")
        #expect(s.tables.count > 3)
        #expect(!s.refs.isEmpty)
    }
}

@Test(.enabled(if: hasExamples, "examples/ not present"))
func layoutHasNoOverlaps() throws {
    let dir = examplesDir.appendingPathComponent("crafting.dbml")
    let s = DBML.parse(try String(contentsOf: dir, encoding: .utf8))
    let sizes = Dictionary(uniqueKeysWithValues: s.tables.map { ($0.id, CGSize(width: 260, height: 40 + 26 * CGFloat($0.columns.count))) })
    let pos = SchemaLayout.compute(schema: s, sizes: sizes)
    #expect(pos.count == s.tables.count)
    let rects = s.tables.map { CGRect(origin: pos[$0.id]!, size: sizes[$0.id]!) }
    for i in rects.indices { for j in rects.indices where j > i { #expect(!rects[i].intersects(rects[j])) } }
}

@Test func overlapResolver() {
    let out = LayeredLayout.resolveOverlaps(desired: [0, 0, 100], heights: [50, 50, 50], gap: 10)
    #expect(out[1] - out[0] == 60 && out[2] - out[1] >= 60)
}

@Test func optionalRelationships() throws {
    let s = DBML.parse("""
    Table a { id int [pk]
      b_id int [ref: >? b.id] }
    Table b { id int [pk] }
    Ref: a.id ?> b.id
    Ref: b.id ?<? a.b_id
    Ref: a.id - b.id
    """)
    #expect(s.diagnostics.isEmpty, "\(s.diagnostics)")
    #expect(s.refs.count == 4)
    #expect(!s.refs[0].from.isOptional && s.refs[0].to.isOptional)    // >?
    #expect(s.refs[1].from.isOptional && !s.refs[1].to.isOptional)    // ?>
    #expect(s.refs[1].from.cardinality == .many && s.refs[1].to.cardinality == .one)
    #expect(s.refs[2].from.isOptional && s.refs[2].to.isOptional)     // ?<?
    #expect(s.refs[2].from.cardinality == .one && s.refs[2].to.cardinality == .many)
    #expect(!s.refs[3].from.isOptional && !s.refs[3].to.isOptional)   // -
}

@Test func recordsAreSkipped() {
    let s = DBML.parse("""
    Table users { id int
      name varchar
      records [example] { 1, 'Alice' } }
    records users(id, name) [example] {
      2, 'Bob'
    }
    """)
    #expect(s.diagnostics.isEmpty, "\(s.diagnostics)")
    #expect(s.tables.first?.columns.map(\.name) == ["id", "name"])
}

/// The samples ship with the repo, so they must always parse cleanly.
@Test func parsesSamples() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../samples")
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "dbml" }
    #expect(files.count >= 2)
    for f in files {
        let s = DBML.parse(try String(contentsOf: f, encoding: .utf8))
        #expect(s.diagnostics.isEmpty, "\(f.lastPathComponent): \(s.diagnostics)")
        #expect(!s.refs.isEmpty)
    }
}

import Foundation

enum TokenKind: Equatable {
    case ident          // bare identifier or "double quoted" identifier
    case string         // 'single' or '''triple''' quoted string
    case expression     // `backtick` expression
    case number
    case color          // #rrggbb
    case punct          // { } [ ] ( ) : , . ~ ;
    case op             // < > - <>, each optionally with ? on either side (?> >? ?<? ...)
    case newline
    case eof
}

struct Token: Equatable {
    var kind: TokenKind
    var text: String
    var line: Int
    var quoted = false
    /// Whitespace separated this token from the previous one.
    var spaceBefore = false

    func isPunct(_ p: String) -> Bool { kind == .punct && text == p }
    func isKeyword(_ k: String) -> Bool { kind == .ident && !quoted && text.lowercased() == k }
}

/// Converts DBML source to tokens. Newlines are significant (they end columns and refs),
/// except inside `[...]` and `(...)` where settings and type arguments may wrap.
struct Lexer {
    private let s: [UInt8]
    private var i = 0
    private var line = 1
    private var nesting = 0
    private(set) var diagnostics: [Diagnostic] = []

    init(_ source: String) { s = Array(source.utf8) }

    mutating func tokenize() -> [Token] {
        var out: [Token] = []
        var space = false
        while i < s.count {
            let c = s[i]
            switch c {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                i += 1; space = true; continue
            case UInt8(ascii: "\n"):
                if nesting == 0, out.last?.kind != .newline { out.append(Token(kind: .newline, text: "\n", line: line)) }
                line += 1; i += 1; space = true; continue
            case UInt8(ascii: "/") where peek(1) == UInt8(ascii: "/"):
                while i < s.count, s[i] != UInt8(ascii: "\n") { i += 1 }
                continue
            case UInt8(ascii: "/") where peek(1) == UInt8(ascii: "*"):
                i += 2
                while i < s.count, !(s[i] == UInt8(ascii: "*") && peek(1) == UInt8(ascii: "/")) {
                    if s[i] == UInt8(ascii: "\n") { line += 1 }
                    i += 1
                }
                i = min(i + 2, s.count); space = true; continue
            default: break
            }

            let startLine = line
            var tok: Token
            if c == UInt8(ascii: "'") {
                if peek(1) == UInt8(ascii: "'"), peek(2) == UInt8(ascii: "'") {
                    tok = Token(kind: .string, text: tripleString(), line: startLine)
                } else {
                    tok = Token(kind: .string, text: quoted(UInt8(ascii: "'")), line: startLine)
                }
            } else if c == UInt8(ascii: "\"") {
                tok = Token(kind: .ident, text: quoted(UInt8(ascii: "\"")), line: startLine, quoted: true)
            } else if c == UInt8(ascii: "`") {
                tok = Token(kind: .expression, text: quoted(UInt8(ascii: "`")), line: startLine)
            } else if c == UInt8(ascii: "#") {
                let start = i
                i += 1
                while i < s.count, isIdentByte(s[i]) { i += 1 }
                tok = Token(kind: .color, text: text(start, i), line: startLine)
            } else if isDigit(c) {
                let start = i
                while i < s.count, isDigit(s[i]) || s[i] == UInt8(ascii: ".") && i + 1 < s.count && isDigit(s[i + 1]) { i += 1 }
                if i < s.count, isIdentByte(s[i]) {
                    while i < s.count, isIdentByte(s[i]) { i += 1 }
                    tok = Token(kind: .ident, text: text(start, i), line: startLine)
                } else {
                    tok = Token(kind: .number, text: text(start, i), line: startLine)
                }
            } else if isIdentByte(c) {
                let start = i
                while i < s.count, isIdentByte(s[i]) { i += 1 }
                tok = Token(kind: .ident, text: text(start, i), line: startLine)
            } else if let op = relationOperator() {
                tok = Token(kind: .op, text: op, line: startLine)
            } else if "{}[]():,.~;".utf8.contains(c) {
                i += 1
                if c == UInt8(ascii: "[") || c == UInt8(ascii: "(") { nesting += 1 }
                if c == UInt8(ascii: "]") || c == UInt8(ascii: ")") { nesting = max(0, nesting - 1) }
                // A brace always resets wrapping: an unbalanced bracket must not swallow the rest of the file.
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "}") { nesting = 0 }
                tok = Token(kind: .punct, text: String(UnicodeScalar(c)), line: startLine)
            } else {
                // Skip one unknown scalar (could be a multi-byte UTF-8 sequence).
                let start = i
                i += 1
                while i < s.count, s[i] & 0xC0 == 0x80 { i += 1 }
                diagnostics.append(Diagnostic(severity: .warning, line: line, message: "Unexpected character '\(text(start, i))'"))
                continue
            }
            tok.spaceBefore = space
            space = false
            out.append(tok)
        }
        out.append(Token(kind: .eof, text: "", line: line))
        return out
    }

    private func peek(_ n: Int) -> UInt8? { i + n < s.count ? s[i + n] : nil }

    /// `<`, `>`, `-`, `<>`, each optionally marked optional with `?` before and/or after.
    private mutating func relationOperator() -> String? {
        let q = UInt8(ascii: "?")
        var j = i
        var text = ""
        if s[j] == q { text = "?"; j += 1 }
        guard j < s.count else { return nil }
        switch s[j] {
        case UInt8(ascii: "<"):
            if j + 1 < s.count, s[j + 1] == UInt8(ascii: ">") { text += "<>"; j += 2 } else { text += "<"; j += 1 }
        case UInt8(ascii: ">"), UInt8(ascii: "-"):
            text += String(UnicodeScalar(s[j])); j += 1
        default:
            return nil
        }
        if j < s.count, s[j] == q { text += "?"; j += 1 }
        i = j
        return text
    }

    private func text(_ a: Int, _ b: Int) -> String { String(decoding: s[a..<b], as: UTF8.self) }

    private func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    /// ASCII letters, digits, `_`, `$`, and any non-ASCII byte (so Cyrillic etc. identifiers work).
    private func isIdentByte(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || isDigit(c) || c == 95 || c == 36 || c >= 0x80
    }

    private mutating func quoted(_ q: UInt8) -> String {
        i += 1
        var bytes: [UInt8] = []
        while i < s.count, s[i] != q {
            if s[i] == UInt8(ascii: "\\"), i + 1 < s.count {
                let n = s[i + 1]
                switch n {
                case UInt8(ascii: "n"): bytes.append(10)
                case UInt8(ascii: "t"): bytes.append(9)
                default: bytes.append(n)
                }
                i += 2
                continue
            }
            if s[i] == UInt8(ascii: "\n") { line += 1 }
            bytes.append(s[i])
            i += 1
        }
        if i >= s.count { diagnostics.append(Diagnostic(severity: .error, line: line, message: "Unterminated string")) }
        i = min(i + 1, s.count)
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func tripleString() -> String {
        i += 3
        let start = i
        while i < s.count, !(s[i] == UInt8(ascii: "'") && peek(1) == UInt8(ascii: "'") && peek(2) == UInt8(ascii: "'")) {
            if s[i] == UInt8(ascii: "\n") { line += 1 }
            i += 1
        }
        let raw = text(start, min(i, s.count))
        i = min(i + 3, s.count)
        return Lexer.dedent(raw)
    }

    /// Multi-line strings drop the common leading indentation, like DBML does.
    static func dedent(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.count))) }.joined(separator: "\n")
    }
}

import Foundation

/// A correct RFC-4180 CSV parser — quoted fields, embedded commas/newlines, and escaped `""` quotes.
/// Passwords and notes routinely contain commas, quotes, and newlines, so a naive split would corrupt
/// imports. Pure/headless; unit-tested.
enum CSV {
    /// Parse into records of fields. A trailing newline does not produce a spurious empty record.
    ///
    /// Iterates **unicode scalars**, not `Character`s: Swift clusters `\r\n` into a single grapheme,
    /// which would otherwise never match the `\r`/`\n` delimiters and silently merge CRLF rows.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0

        let quote: Unicode.Scalar = "\"", comma: Unicode.Scalar = ",", cr: Unicode.Scalar = "\r", lf: Unicode.Scalar = "\n"
        func endField() { record.append(field); field = "" }
        func endRecord() { endField(); rows.append(record); record = [] }

        while i < scalars.count {
            let s = scalars[i]
            if inQuotes {
                if s == quote {
                    if i + 1 < scalars.count, scalars[i + 1] == quote { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1
                } else {
                    field.unicodeScalars.append(s); i += 1
                }
                continue
            }
            switch s {
            case quote: inQuotes = true; i += 1
            case comma: endField(); i += 1
            case lf: endRecord(); i += 1
            case cr:
                endRecord()
                i += (i + 1 < scalars.count && scalars[i + 1] == lf) ? 2 : 1   // CRLF or lone CR
            default: field.unicodeScalars.append(s); i += 1
            }
        }
        if !(field.isEmpty && record.isEmpty) { endRecord() }
        return rows
    }
}

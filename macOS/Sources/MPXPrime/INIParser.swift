import Foundation

enum INIParserError: Error {
    case unreadableFile(String)
}

struct INIParser {
    static func parseFile(_ path: String) throws -> [String: [String: String]] {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw INIParserError.unreadableFile(path)
        }
        return parse(data)
    }

    static func parse(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section = ""
        result[section] = [:]
        let lines = text.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            if line.hasPrefix(";") || line.hasPrefix("#") {
                continue
            }
            if let commentRange = line.range(of: ";") {
                line = String(line[..<commentRange.lowerBound]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }
            if line.hasPrefix("[") && line.hasSuffix("]") && line.count >= 2 {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if result[section] == nil {
                    result[section] = [:]
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            if key.isEmpty {
                continue
            }
            var bucket = result[section] ?? [:]
            bucket[key] = value
            result[section] = bucket
        }
        return result
    }
}

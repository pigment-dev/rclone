import Foundation

/// Client-side approximation of the daemon's filter evaluation (rclone glob semantics), used to answer
/// "would this path sync?" instantly in the wizard before the job exists. The daemon (`jobs.explain`) is authoritative.
public enum FilterEvaluator {
    /// Returns (included, matching rule) for a path relative to the job root (e.g. "src/.git/config").
    public static func explain(_ path: String, filters: Filters) -> ExplainResult {
        let rel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Custom rules first (so includes override presets), then presets.
        for rule in filters.rules where !rule.pattern.isEmpty {
            if matches(rule.pattern, path: rel) {
                return ExplainResult(included: rule.kind == .include, rule: (rule.kind == .include ? "+ " : "- ") + rule.pattern)
            }
        }
        for id in filters.presets {
            guard let preset = FilterPreset.named(id) else { continue }
            for pattern in preset.rules where matches(pattern, path: rel) {
                return ExplainResult(included: false, rule: "- \(pattern) (\(id))")
            }
        }
        return ExplainResult(included: true, rule: nil)
    }

    /// rclone-style glob: `**` spans directories, `*` and `?` stay within one segment.
    /// A pattern without a leading `/` matches at any directory depth. `dir/**` matches everything under dir.
    public static func matches(_ pattern: String, path: String) -> Bool {
        var p = pattern.replacingOccurrences(of: "\\r", with: "\r")
        let anchored = p.hasPrefix("/")
        if anchored { p.removeFirst() }
        guard let regex = try? NSRegularExpression(pattern: (anchored ? "^" : "(^|.*/)") + globToRegex(p) + "$") else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }

    static func globToRegex(_ glob: String) -> String {
        var out = ""
        var chars = Array(glob)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            switch c {
            case "*":
                if chars.first == "*" { chars = chars.dropFirst(); out += ".*" } else { out += "[^/]*" }
            case "?": out += "[^/]"
            case ".", "+", "(", ")", "^", "$", "|", "\\", "[", "]", "{", "}": out += "\\" + String(c)
            default: out += String(c)
            }
        }
        return out
    }

    /// Converts .gitignore lines to filter rules ("!pat" → include, trailing "/" → "pat/**").
    public static func rules(fromGitignore text: String) -> [FilterRule] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            var kind = FilterRule.Kind.exclude
            if line.hasPrefix("!") { kind = .include; line.removeFirst() }
            if line.hasSuffix("/") { line += "**" }
            return FilterRule(kind: kind, pattern: line)
        }
    }
}

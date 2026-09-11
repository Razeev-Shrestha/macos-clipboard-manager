import Foundation

/// A small, intentionally conservative classifier for developer-oriented clipboard text.
/// It examines only a bounded prefix because it runs on pasteboard copy events. This is a
/// heuristic for filtering, not a programming-language detector.
public enum ClipboardTextClassifier {
    private static let maximumPrefixLength = 8_192

    public static func isLikelyCode(_ text: String) -> Bool {
        let sample = String(text.prefix(maximumPrefixLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sample.isEmpty, !looksLikeWebURL(sample) else {
            return false
        }

        return isJSONContainer(sample)
            || isRecognizedShellCommand(sample)
            || isDeclarationOrSnippet(sample)
    }

    private static func looksLikeWebURL(_ text: String) -> Bool {
        let lowercaseText = text.lowercased()
        return lowercaseText.hasPrefix("http://") || lowercaseText.hasPrefix("https://")
    }

    private static func isJSONContainer(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last,
              (first == "{" && last == "}") || (first == "[" && last == "]")
        else {
            return false
        }

        guard let data = text.data(using: .utf8) else {
            return false
        }

        do {
            let value = try JSONSerialization.jsonObject(with: data)
            return value is [String: Any] || value is [Any]
        } catch {
            return false
        }
    }

    private static func isRecognizedShellCommand(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard let command = words.first.map(String.init)?.lowercased(), words.count > 1 else {
            return false
        }

        let subcommand = String(words[1]).lowercased()
        switch command {
        case "git":
            return ["add", "branch", "checkout", "clone", "commit", "diff", "fetch", "log", "merge", "pull", "push", "rebase", "reset", "status", "switch"].contains(subcommand)
        case "npm":
            return ["run", "install", "ci", "test", "start", "build", "exec", "init", "publish", "update", "uninstall"].contains(subcommand)
        case "yarn", "pnpm", "bun":
            return ["add", "install", "run", "test", "start", "build", "dev", "remove"].contains(subcommand)
        case "docker":
            return ["build", "compose", "container", "exec", "image", "logs", "ps", "pull", "push", "run", "start", "stop"].contains(subcommand)
        case "kubectl":
            return ["apply", "delete", "describe", "get", "logs", "rollout"].contains(subcommand)
        case "ssh":
            return !subcommand.isEmpty
        default:
            return false
        }
    }

    private static func isDeclarationOrSnippet(_ text: String) -> Bool {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let trimmedLine = firstLine.trimmingCharacters(in: .whitespaces)
        let lowercaseLine = trimmedLine.lowercased()

        if startsWithDeclaration(lowercaseLine, keyword: "let")
            || startsWithDeclaration(lowercaseLine, keyword: "var")
            || startsWithDeclaration(lowercaseLine, keyword: "const") {
            return trimmedLine.contains("=")
        }

        if startsWithDeclaration(lowercaseLine, keyword: "func")
            || startsWithDeclaration(lowercaseLine, keyword: "function")
            || startsWithDeclaration(lowercaseLine, keyword: "def") {
            return trimmedLine.contains("(")
        }

        if startsWithDeclaration(lowercaseLine, keyword: "class")
            || startsWithDeclaration(lowercaseLine, keyword: "struct")
            || startsWithDeclaration(lowercaseLine, keyword: "enum")
            || startsWithDeclaration(lowercaseLine, keyword: "interface") {
            return trimmedLine.contains("{") || trimmedLine.hasSuffix(":")
        }

        return (lowercaseLine.hasPrefix("if ") || lowercaseLine.hasPrefix("for ") || lowercaseLine.hasPrefix("while "))
            && (trimmedLine.contains("{") || trimmedLine.hasSuffix(":"))
    }

    private static func startsWithDeclaration(_ text: String, keyword: String) -> Bool {
        text == keyword || text.hasPrefix(keyword + " ") || text.hasPrefix(keyword + "\t")
    }
}

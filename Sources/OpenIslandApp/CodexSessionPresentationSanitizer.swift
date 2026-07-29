import Foundation

enum CodexSessionPresentationSanitizer {
    static func workspaceName(_ rawName: String?) -> String? {
        guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name == "/" ? "Codex" : name
    }

    /// Codex Desktop previews can include app-injected context blocks before
    /// the user's actual text. These are transport metadata, not a session
    /// topic, so strip the known blocks before presenting or persisting it.
    static func prompt(_ rawPrompt: String?) -> String? {
        guard var sanitized = rawPrompt else {
            return nil
        }

        let injectedBlockNames = [
            "recommended_plugins",
            "environment_context",
        ]

        for blockName in injectedBlockNames {
            let escapedName = NSRegularExpression.escapedPattern(for: blockName)
            let pattern = "(?is)<\(escapedName)\\b[^>]*>.*?</\(escapedName)\\s*>"
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        // A server-side preview may be truncated before the injected block's
        // closing tag. In that case showing no prompt is safer than exposing
        // the metadata as the user-visible session title.
        let lowercased = sanitized.lowercased()
        if injectedBlockNames.contains(where: { lowercased.hasPrefix("<\($0)") }) {
            return nil
        }

        sanitized = sanitized.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return sanitized.isEmpty ? nil : sanitized
    }
}

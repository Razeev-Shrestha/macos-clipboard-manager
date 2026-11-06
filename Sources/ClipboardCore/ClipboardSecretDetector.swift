import Foundation

/// Recognizes copied text that is very likely a credential, so it can be kept
/// out of clipboard history even when the source app sets no concealed marker
/// (terminals, editors, browsers showing a token once).
///
/// The patterns favour precision over recall: well-known token prefixes, PEM
/// private keys, JWTs and payment card numbers. Nothing is logged or reported;
/// the caller simply does not record the capture.
public enum ClipboardSecretDetector {
    /// Only the beginning of very large text is scanned to keep capture cheap.
    static let maximumScannedCharacters = 256 * 1024

    private static let tokenPatterns: [NSRegularExpression] = [
        // PEM / OpenSSH / PGP private keys.
        #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#,
        // AWS access key IDs.
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        // GitHub personal, OAuth, user-to-server, server-to-server and refresh tokens.
        #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{50,}\b"#,
        // GitLab personal access tokens.
        #"\bglpat-[A-Za-z0-9_-]{20,}\b"#,
        // Slack tokens.
        #"\bxox[abposr]-[A-Za-z0-9-]{10,}\b"#,
        // Stripe live secret and restricted keys.
        #"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}\b"#,
        // OpenAI / Anthropic style API keys.
        #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{32,}\b"#,
        // Google API keys.
        #"\bAIza[0-9A-Za-z_-]{35}\b"#,
        // JSON Web Tokens (header.payload.signature, both JSON parts base64url "{").
        #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let cardCandidate = try? NSRegularExpression(pattern: #"^[0-9][0-9 -]{11,22}[0-9]$"#)

    public static func isLikelySecret(_ text: String) -> Bool {
        let scanned = text.utf8.count > maximumScannedCharacters
            ? String(text.prefix(maximumScannedCharacters))
            : text
        let range = NSRange(scanned.startIndex..., in: scanned)
        for pattern in tokenPatterns where pattern.firstMatch(in: scanned, range: range) != nil {
            return true
        }
        return isPaymentCardNumber(scanned)
    }

    /// The whole (trimmed) copy is a 13–19 digit number, optionally grouped with
    /// spaces or dashes, that passes the Luhn checksum.
    static func isPaymentCardNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 23, let cardCandidate,
              cardCandidate.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
        else {
            return false
        }
        let digits = trimmed.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else {
            return false
        }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }
}

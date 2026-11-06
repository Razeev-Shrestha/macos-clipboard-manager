import XCTest
@testable import ClipboardCore

/// All "secrets" here are synthetic and assembled at runtime from fragments so
/// that no real credential, or a literal that secret scanners would flag, is
/// committed to the repository.
final class ClipboardSecretDetectorTests: XCTestCase {
    private func repeated(_ character: Character, _ count: Int) -> String {
        String(repeating: character, count: count)
    }

    func testRecognizesCommonCredentialShapes() {
        let samples = [
            "-----BEGIN " + "RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----",
            "-----BEGIN " + "PRIVATE KEY-----",
            "aws_access_key_id = " + "AKIA" + "IOSFODNN7EXAMPLE",
            "gh" + "p_" + repeated("a", 36),
            "github" + "_pat_" + repeated("b", 60),
            "gl" + "pat-" + repeated("c", 20),
            "xo" + "xb-" + "123456789012-" + repeated("d", 24),
            "sk" + "_live_" + repeated("e", 24),
            "sk" + "-ant-" + repeated("f", 40),
            "AI" + "za" + repeated("g", 35),
            "ey" + "J" + repeated("h", 12) + ".ey" + "J" + repeated("i", 12) + "." + repeated("j", 16)
        ]
        for sample in samples {
            XCTAssertTrue(ClipboardSecretDetector.isLikelySecret(sample), "expected a secret: \(sample.prefix(12))…")
        }
    }

    func testRecognizesLuhnValidCardNumbersOnlyAsWholeCopies() {
        // The well-known Visa test number, grouped and ungrouped.
        let testCard = "4111" + "1111" + "1111" + "1111"
        XCTAssertTrue(ClipboardSecretDetector.isLikelySecret(testCard))
        XCTAssertTrue(ClipboardSecretDetector.isLikelySecret("4111 1111 1111 1111"))
        XCTAssertTrue(ClipboardSecretDetector.isLikelySecret("  4111-1111-1111-1111\n"))

        // Luhn-invalid, too short, repeated digits, or embedded in prose: not a card copy.
        XCTAssertFalse(ClipboardSecretDetector.isLikelySecret("4111 1111 1111 1112"))
        XCTAssertFalse(ClipboardSecretDetector.isLikelySecret("123456"))
        XCTAssertFalse(ClipboardSecretDetector.isLikelySecret("0000 0000 0000 0000"))
        XCTAssertFalse(ClipboardSecretDetector.isLikelySecret("Order " + testCard + " shipped"))
    }

    func testOrdinaryTextIsNotASecret() {
        let ordinary = [
            "Meeting notes: ship the release on Friday.",
            "https://example.com/docs/getting-started",
            "let skipped = items.filter { $0.isEmpty }",
            "sk-short",
            "Phone: +1 415 555 0100",
            "2026-11-06 11:14:51",
            "-----BEGIN CERTIFICATE-----"
        ]
        for text in ordinary {
            XCTAssertFalse(ClipboardSecretDetector.isLikelySecret(text), "unexpected secret: \(text)")
        }
    }

    func testOnlyTheBeginningOfHugeTextIsScanned() {
        let filler = repeated("x", ClipboardSecretDetector.maximumScannedCharacters + 10)
        let lateSecret = filler + " gh" + "p_" + repeated("a", 36)
        XCTAssertFalse(ClipboardSecretDetector.isLikelySecret(lateSecret))
    }
}

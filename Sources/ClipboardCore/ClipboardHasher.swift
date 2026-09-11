import CryptoKit
import Foundation

/// SHA-256 identity helpers for clipboard payloads.  The digest is only an identity;
/// payload bytes are never printed or included in diagnostics by this module.
public enum ClipboardHasher {
    public static func hash(data: Data) -> String {
        sha256(data: data)
    }

    public static func hash(payload: ClipboardPayload) -> String {
        identity(for: payload)
    }

    public static func sha256(data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func identity(for payload: ClipboardPayload) -> String {
        var identityData = Data()
        appendField(Data(payload.primaryTypeIdentifier.utf8), to: &identityData)

        let representations = payload.representations.sorted {
            if $0.typeIdentifier != $1.typeIdentifier {
                return $0.typeIdentifier < $1.typeIdentifier
            }
            return $0.data.lexicographicallyPrecedes($1.data)
        }
        for representation in representations {
            appendField(Data(representation.typeIdentifier.utf8), to: &identityData)
            appendField(representation.data, to: &identityData)
        }

        if representations.isEmpty {
            if let plainText = payload.plainText {
                appendField(Data("text".utf8), to: &identityData)
                appendField(Data(plainText.utf8), to: &identityData)
            }
            if let url = payload.url {
                appendField(Data("url".utf8), to: &identityData)
                appendField(Data(url.absoluteString.utf8), to: &identityData)
            }
        }

        return sha256(data: identityData)
    }

    private static func appendField(_ bytes: Data, to output: inout Data) {
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { rawBytes in
            output.append(contentsOf: rawBytes)
        }
        output.append(bytes)
    }
}

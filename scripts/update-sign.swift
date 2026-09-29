// Ed25519 keys and signatures for in-app updates (run with `swift scripts/update-sign.swift ...`).
//
//   keygen        print a new private key (keep it secret) and its public key
//   sign FILE     print the base64 signature of FILE, using SIFT_UPDATE_KEY (base64 private key)
//
// sign refuses a key that doesn't pair with the public key built into the app,
// so a release can't ship updates the installed apps would reject.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private: \(key.rawRepresentation.base64EncodedString())")
    print("public:  \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    guard args.count == 2, let path = args.last else { fail("usage: sign FILE") }
    guard let raw = ProcessInfo.processInfo.environment["SIFT_UPDATE_KEY"],
          let bytes = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    else { fail("SIFT_UPDATE_KEY is missing or not a base64 Ed25519 private key") }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = (try? String(contentsOf: root.appendingPathComponent("menubar/Sift.swift"), encoding: .utf8)) ?? ""
    let pattern = try! NSRegularExpression(pattern: #"let updatePublicKey = "([A-Za-z0-9+/=]+)""#)
    guard let match = pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          let range = Range(match.range(at: 1), in: source)
    else { fail("updatePublicKey not found in menubar/Sift.swift") }
    guard key.publicKey.rawRepresentation.base64EncodedString() == String(source[range]) else {
        fail("SIFT_UPDATE_KEY does not pair with updatePublicKey in the app")
    }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    print(try! key.signature(for: data).base64EncodedString())
default:
    fail("usage: update-sign.swift keygen | sign FILE")
}

// EdDSA (Ed25519) release signing for the built-in updater (same scheme as Hush/KeepMeUp).
//   swift scripts/release-key.swift generate        # creates the private key, prints the public key for Info.plist (PDRClonePublicEDKey)
//   swift scripts/release-key.swift public          # prints the public key
//   swift scripts/release-key.swift sign <file>     # writes <file>.sig (base64 signature)
//   swift scripts/release-key.swift verify <file> <base64-public-key>
// Key path: $PDRCLONE_KEY or ~/.config/pdrclone/ed25519.key. In CI pass the key via the PDRCLONE_KEY_B64 secret.
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
let keyPath = env["PDRCLONE_KEY"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pdrclone/ed25519.key").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let text = env["PDRCLONE_KEY_B64"] ?? (try? String(contentsOfFile: keyPath, encoding: .utf8))
    guard let text, let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No signing key at \(keyPath). Run: swift scripts/release-key.swift generate")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    if FileManager.default.fileExists(atPath: keyPath) { fail("A key already exists at \(keyPath)") }
    let key = Curve25519.Signing.PrivateKey()
    let folder = (keyPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: keyPath, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]) else { fail("usage: release-key.swift sign <file>") }
    let signature = try loadKey().signature(for: data)
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: args[1] + ".sig"))
    print("Signed \(args[1])")
case "verify":
    guard args.count > 2, let data = FileManager.default.contents(atPath: args[1]),
          let sigText = try? String(contentsOfFile: args[1] + ".sig", encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let pub = Data(base64Encoded: args[2]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else {
        fail("usage: release-key.swift verify <file> <base64-public-key>")
    }
    print(key.isValidSignature(sig, for: data) ? "OK" : "BAD SIGNATURE")
default:
    fail("usage: release-key.swift generate | public | sign <file> | verify <file> <pubkey>")
}

import Foundation
import CryptoKit

// Verify with the key embedded in existing installations; never export the private key.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    fatalError("Usage: verify-update.swift <public-key> <signature> <archive>")
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
guard publicKey.isValidSignature(signature, for: data) else {
    fatalError("Update signature does not match the installed public key")
}
print("Update signature verified against the application public key")

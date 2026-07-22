import Darwin
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Shudo keychain unlock failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("expected KEYCHAIN_PATH and PASSPHRASE_FILE")
}

let keychainPath = CommandLine.arguments[1]
let passphrasePath = CommandLine.arguments[2]
var passphrase: Data

do {
    passphrase = try Data(contentsOf: URL(fileURLWithPath: passphrasePath), options: .uncached)
} catch {
    fail("could not read the owner-only passphrase file")
}

while passphrase.last == 0x0A || passphrase.last == 0x0D {
    passphrase.removeLast()
}
guard passphrase.count >= 32 else {
    passphrase.resetBytes(in: 0..<passphrase.count)
    fail("the passphrase file is invalid")
}

var keychain: SecKeychain?
let openStatus = keychainPath.withCString { path in
    SecKeychainOpen(path, &keychain)
}
guard openStatus == errSecSuccess, let keychain else {
    passphrase.resetBytes(in: 0..<passphrase.count)
    fail("could not open the dedicated Shudo keychain (status \(openStatus))")
}

let unlockStatus = passphrase.withUnsafeBytes { bytes in
    SecKeychainUnlock(
        keychain,
        UInt32(bytes.count),
        bytes.baseAddress,
        true
    )
}
passphrase.resetBytes(in: 0..<passphrase.count)

guard unlockStatus == errSecSuccess else {
    fail("the dedicated Shudo keychain rejected its credential (status \(unlockStatus))")
}

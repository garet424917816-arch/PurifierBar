// Pure token validation and stdin construction only. These tests never access Keychain.
import Foundation
import Testing
@testable import PurifierCore

private let tokenHex = "00112233445566778899aabbccddeeff"

@Test func tokenNormalizationAcceptsCanonicalUppercaseAndOuterWhitespace() throws {
    for input in [tokenHex, tokenHex.uppercased(), " \n\t\(tokenHex.uppercased())\r\n "] {
        #expect(try TokenStore.normalizedHex(input) == tokenHex)
    }
}

@Test func tokenValidationRejectsWrongLengthNonHexAndCommandInjection() {
    let invalid = [
        "", String(tokenHex.dropLast()), tokenHex + "0",
        String(tokenHex.dropLast()) + "g", String(tokenHex.dropLast()) + "\u{FF46}",
        String(tokenHex.prefix(16)) + " " + String(tokenHex.suffix(16)),
        tokenHex + "\nadd-generic-password -s unexpected",
        String(tokenHex.dropLast()) + ";",
    ]
    for input in invalid {
        #expect(throws: MiIOError.invalidToken) { try TokenStore.normalizedHex(input) }
        #expect(throws: MiIOError.invalidToken) { try TokenStore.securityInput(hex: input) }
    }
}

@Test func securityCommandUsesUpdateAndFixedKeychainIdentity() throws {
    let input = try TokenStore.securityInput(hex: " \(tokenHex.uppercased())\n")
    #expect(input == "add-generic-password -U -a purifier -s PurifierBar -w \(tokenHex)\n")
    #expect(input.split(separator: "\n").count == 1)
    #expect(TokenStore.saveArguments == ["-i"])
    #expect(!TokenStore.saveArguments.joined(separator: " ").contains(tokenHex))
}

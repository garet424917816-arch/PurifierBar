// Protocol layer adapted from lightbar-direct (https://github.com/19s94/lightbar-direct), MIT License, Copyright (c) 2026 19s94.
import Foundation
import Security

/// Device token from Keychain. The value is never logged or printed.
public enum TokenStore {
    private static let service = "PurifierBar"
    private static let account = "purifier"
    static let saveArguments = ["-i"]

    public enum SaveError: Error, Sendable {
        case writeFailed
    }

    /// Pure validation before any Keychain access.
    static func normalizedHex(_ hex: String) throws -> String {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.utf8.count == 32,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MiIOError.invalidToken
        }
        return normalized
    }

    /// Only validated ASCII hex reaches the command, so security -i command injection is impossible.
    static func securityInput(hex: String) throws -> String {
        let normalized = try normalizedHex(hex)
        return "add-generic-password -U -a \(account) -s \(service) -w \(normalized)\n"
    }

    /// Writes through stdin, never process arguments, then verifies the value through the existing read path.
    /// Run off the main thread: Keychain access can wait for user interaction.
    public static func save(hex: String) throws {
        let input = try securityInput(hex: hex)
        let expected = Data(hex: try normalizedHex(hex))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = saveArguments
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            throw SaveError.writeFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let stored = try? load(), stored.count == 16, stored == expected else {
            throw SaveError.writeFailed
        }
    }

    /// Reports presence without exposing the token to the UI.
    public static func hasToken() -> Bool {
        (try? load()) != nil
    }

    /// Reads the hex token from Keychain and returns 16 bytes.
    public static func load() throws -> Data {
        guard let data = readViaSecurityTool() ?? readViaSecItem(),
              let hex = String(data: data, encoding: .utf8),
              let token = Data(hex: hex.trimmingCharacters(in: .whitespacesAndNewlines)),
              token.count == 16 else {
            throw MiIOError.invalidToken
        }
        return token
    }

    /// The main path is via /usr/bin/security. The login keychain binds "Always Allow"
    /// to the item's partition list, and for a signature without an Apple Team ID that holds the cdhash
    /// of the specific build - every rebuild would ask again. /usr/bin/security has a
    /// stable apple-tool partition and is already in the item's ACL, so it reads without a dialog.
    /// This does not widen access: any user process can invoke security itself.
    /// The token goes only through a pipe into process memory; stderr is discarded.
    private static func readViaSecurityTool() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    /// Fallback path - the Security framework (may show an access dialog).
    private static func readViaSecItem() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}

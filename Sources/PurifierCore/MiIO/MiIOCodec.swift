// Protocol layer adapted from lightbar-direct (https://github.com/19s94/lightbar-direct), MIT License, Copyright (c) 2026 19s94.
import Foundation
import CommonCrypto
import CryptoKit

extension Data {
    /// Parsing a hex string into bytes. An even number of characters.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// Integer from bytes, big-endian.
    func integer(_ range: Range<Int>) -> UInt64 {
        self[range].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// Appends an integer with the given number of bytes, big-endian.
    mutating func appendInteger(_ value: UInt64, bytes: Int) {
        for shift in (0..<bytes).reversed() {
            append(UInt8(truncatingIfNeeded: value >> (shift * 8)))
        }
    }
}

/// miIO cryptography: MD5 and AES-128-CBC with PKCS7.
enum Crypto {
    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    /// AES-128-CBC. Encryption adds PKCS7 itself, decryption returns
    /// exactly the bytes that were encrypted (without removing the padding).
    static func aes(_ data: Data, key: Data, iv: Data, decrypt: Bool) throws -> Data {
        let input = decrypt ? data : pkcs7(data)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                0,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inputBytes.baseAddress, input.count,
                                out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MiIOError.badPacket }
        output.count = moved
        return output
    }

    private static func pkcs7(_ data: Data) -> Data {
        let padding = 16 - (data.count % 16)
        return data + Data(repeating: UInt8(padding), count: padding)
    }
}

/// Pure encoding/decoding of a miIO packet, without network.
public enum MiIOCodec {
    /// The hello handshake packet: 0x2131, length 0x20, 28 bytes of 0xff.
    public static let hello = Data([UInt8]([0x21, 0x31, 0x00, 0x20]) + [UInt8](repeating: 0xff, count: 28))

    /// Encrypts the plaintext with the device key.
    public static func encrypt(_ plain: Data, token: Data) throws -> Data {
        let (key, iv) = try keyAndIV(token)
        return try Crypto.aes(plain, key: key, iv: iv, decrypt: false)
    }

    /// Decrypts the packet body, strips PKCS7 and trailing zeros.
    public static func decrypt(_ cipher: Data, token: Data) throws -> Data {
        let (key, iv) = try keyAndIV(token)
        var plain = try Crypto.aes(cipher, key: key, iv: iv, decrypt: true)
        let padding = Int(plain.last ?? 0)
        if (1...16).contains(padding), plain.count >= padding,
           plain.suffix(padding).allSatisfy({ $0 == UInt8(padding) }) {
            plain.removeLast(padding)
        }
        while plain.last == 0 { plain.removeLast() }
        return plain
    }

    /// Assembles the full request packet: 16-byte header, MD5 checksum, ciphertext.
    public static func packet(json: Data, token: Data, deviceID: UInt32, stamp: UInt32) throws -> Data {
        guard token.count == 16 else { throw MiIOError.invalidToken }
        let cipher = try encrypt(json, token: token)
        var header = Data()
        header.appendInteger(0x2131, bytes: 2)
        header.appendInteger(UInt64(cipher.count + 32), bytes: 2)
        header.appendInteger(UInt64(deviceID), bytes: 8)
        header.appendInteger(UInt64(stamp), bytes: 4)
        let digest = Crypto.md5(header + token + cipher)
        return header + digest + cipher
    }

    /// Parses the reply packet and verifies the checksum.
    public static func open(_ packet: Data, token: Data) throws -> (deviceID: UInt32, stamp: UInt32, json: Data) {
        guard token.count == 16 else { throw MiIOError.invalidToken }
        let bytes = Data(packet)
        guard bytes.count > 32 else { throw MiIOError.badPacket }
        guard bytes.integer(0..<2) == 0x2131 else { throw MiIOError.badPacket }
        guard bytes.integer(2..<4) == UInt64(bytes.count) else { throw MiIOError.badPacket }
        let body = Data(bytes.dropFirst(32))
        let expected = Crypto.md5(Data(bytes.prefix(16)) + token + body)
        guard expected == Data(bytes[16..<32]) else { throw MiIOError.checksumMismatch }
        let deviceID = UInt32(truncatingIfNeeded: bytes.integer(4..<12))
        let stamp = UInt32(truncatingIfNeeded: bytes.integer(12..<16))
        let json = try decrypt(body, token: token)
        return (deviceID, stamp, json)
    }

    private static func keyAndIV(_ token: Data) throws -> (key: Data, iv: Data) {
        guard token.count == 16 else { throw MiIOError.invalidToken }
        let key = Crypto.md5(token)
        return (key, Crypto.md5(key + token))
    }
}

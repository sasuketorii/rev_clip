import Foundation
import XCTest

@testable import Revclip

final class RCStorageCipherTests: XCTestCase {
    private var cipher: RCStorageCipher!
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        cipher = RCStorageCipher(keyData: NSData(data: Data(repeating: 0x42, count: 32)))
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RCStorageCipherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        cipher = nil
        directoryURL = nil
        try super.tearDownWithError()
    }

    func testEncryptionRoundTripAndAuthenticationFailures() throws {
        let plaintext = Data("secret clipboard payload".utf8)
        var error: NSError?
        let encrypted = try XCTUnwrap(cipher.encrypt(data: plaintext as NSData, error: &error) as Data?)

        XCTAssertNil(error)
        XCTAssertTrue(RCStorageCipher.isEncryptedData(encrypted as NSData))

        let decrypted = try XCTUnwrap(cipher.decrypt(data: encrypted as NSData, error: &error) as Data?)
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertNil(error)

        var tampered = encrypted
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        error = nil
        XCTAssertNil(cipher.decrypt(data: tampered as NSData, error: &error))
        XCTAssertEqual(error?.domain, "com.revclip.storage")
        XCTAssertNotNil(error)

        let wrongCipher = RCStorageCipher(keyData: NSData(data: Data(repeating: 0x24, count: 32)))
        error = nil
        XCTAssertNil(wrongCipher.decrypt(data: encrypted as NSData, error: &error))
        XCTAssertNotNil(error)
    }

    func testEnvelopeHeaderAndTruncationAreRejected() throws {
        var error: NSError?
        let plaintext = Data("header test".utf8)
        let encrypted = try XCTUnwrap(cipher.encrypt(data: plaintext as NSData, error: &error) as Data?)

        let magicOnly = Data([0x52, 0x43, 0x45, 0x4e, 0x43, 0x01])
        XCTAssertTrue(RCStorageCipher.isEncryptedData(Data(magicOnly.prefix(5)) as NSData))
        XCTAssertTrue(RCStorageCipher.isEncryptedData(magicOnly as NSData))
        var unsupportedVersion = magicOnly
        unsupportedVersion[unsupportedVersion.index(before: unsupportedVersion.endIndex)] = 0x02
        XCTAssertTrue(RCStorageCipher.isEncryptedData(unsupportedVersion as NSData))
        error = nil
        XCTAssertNil(cipher.decrypt(data: unsupportedVersion as NSData, error: &error))
        XCTAssertNotNil(error)

        var invalidHeader = encrypted
        invalidHeader[0] ^= 0x01
        error = nil
        XCTAssertNil(cipher.decrypt(data: invalidHeader as NSData, error: &error))
        XCTAssertNotNil(error)

        let truncated = encrypted.dropLast()
        error = nil
        XCTAssertNil(cipher.decrypt(data: Data(truncated) as NSData, error: &error))
        XCTAssertNotNil(error)
    }

    func testDatabaseKeyUsesSQLCipherHexRepresentation() throws {
        var error: NSError?
        let databaseKey = try XCTUnwrap(cipher.databaseKey(error: &error) as Data?)
        XCTAssertNil(error)

        let representation = try XCTUnwrap(String(data: databaseKey, encoding: .utf8))
        XCTAssertEqual(representation.count, 67)
        XCTAssertTrue(representation.hasPrefix("x'"))
        XCTAssertTrue(representation.hasSuffix("'"))
        XCTAssertTrue(representation.dropFirst(2).dropLast().allSatisfy { $0.isHexDigit })
    }

    func testWriteReadAndMigrationUseBoundedRegularFiles() throws {
        let pathURL = directoryURL.appendingPathComponent("payload.rcclip")
        let plaintext = Data("migrated payload".utf8)
        var error: NSError?

        XCTAssertTrue(cipher.write(data: plaintext as NSData, toPath: pathURL.path, error: &error))
        XCTAssertNil(error)

        let attributes = try FileManager.default.attributesOfItem(atPath: pathURL.path)
        let permissions = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        XCTAssertEqual(permissions, 0o600)

        let readBack = try XCTUnwrap(
            cipher.readData(atPath: pathURL.path, allowPlaintext: false, error: &error) as Data?
        )
        XCTAssertEqual(readBack, plaintext)
        XCTAssertNil(error)

        let legacyURL = directoryURL.appendingPathComponent("legacy.rcclip")
        try plaintext.write(to: legacyURL, options: .atomic)
        error = nil
        XCTAssertTrue(cipher.migrate(fileAtPath: legacyURL.path, error: &error))
        XCTAssertNil(error)
        XCTAssertTrue(RCStorageCipher.isEncryptedData(try Data(contentsOf: legacyURL) as NSData))
        XCTAssertEqual(
            try XCTUnwrap(cipher.readData(atPath: legacyURL.path, allowPlaintext: false, error: &error) as Data?),
            plaintext
        )

        let encryptedBeforeRetry = try Data(contentsOf: legacyURL)
        error = nil
        XCTAssertTrue(cipher.migrate(fileAtPath: legacyURL.path, error: &error))
        XCTAssertNil(error)
        XCTAssertEqual(try Data(contentsOf: legacyURL), encryptedBeforeRetry)
    }

    func testReadRejectsPlaintextUnlessExplicitlyAllowed() throws {
        let pathURL = directoryURL.appendingPathComponent("plain.data")
        let plaintext = Data("plain".utf8)
        try plaintext.write(to: pathURL, options: .atomic)

        var error: NSError?
        XCTAssertNil(cipher.readData(atPath: pathURL.path, allowPlaintext: false, error: &error))
        XCTAssertNotNil(error)

        error = nil
        XCTAssertEqual(
            try XCTUnwrap(cipher.readData(atPath: pathURL.path, allowPlaintext: true, error: &error) as Data?),
            plaintext
        )
        XCTAssertNil(error)
    }

    func testReadRejectsSymlinkDirectoryAndOversizedFiles() throws {
        let outsideURL = directoryURL.deletingLastPathComponent()
            .appendingPathComponent("RCStorageCipherTests-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try Data("outside".utf8).write(to: outsideURL, options: .atomic)

        let symlinkURL = directoryURL.appendingPathComponent("link.data")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)
        var error: NSError?
        XCTAssertNil(cipher.readData(atPath: symlinkURL.path, allowPlaintext: true, error: &error))
        XCTAssertNotNil(error)

        let directoryPath = directoryURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryPath, withIntermediateDirectories: false)
        error = nil
        XCTAssertNil(cipher.readData(atPath: directoryPath.path, allowPlaintext: true, error: &error))
        XCTAssertNotNil(error)

        let oversizedURL = directoryURL.appendingPathComponent("oversized.data")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversizedURL.path, contents: nil))
        let oversizedFile = try FileHandle(forWritingTo: oversizedURL)
        try oversizedFile.truncate(atOffset: UInt64(64 * 1024 * 1024 + 1))
        try oversizedFile.close()
        error = nil
        XCTAssertNil(cipher.readData(atPath: oversizedURL.path, allowPlaintext: true, error: &error))
        XCTAssertNotNil(error)
    }

    func testDeleteKeyClearsInjectedKeyCache() throws {
        var error: NSError?
        let encrypted = try XCTUnwrap(cipher.encrypt(data: Data("secret".utf8) as NSData, error: &error) as Data?)
        XCTAssertNotNil(encrypted)
        XCTAssertTrue(cipher.deleteKey(error: &error))
        XCTAssertNil(cipher.decrypt(data: encrypted as NSData, error: &error))
        XCTAssertNotNil(error)
    }
}

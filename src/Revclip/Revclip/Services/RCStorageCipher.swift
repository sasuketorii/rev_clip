//
//  RCStorageCipher.swift
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

/// The common storage envelope used for clipboard payloads and thumbnails.
///
/// This type deliberately owns only the cryptographic and file primitives. The
/// caller is responsible for checking that a path belongs to Revclip's storage
/// root before calling the file methods.
@objc(RCStorageCipher)
final class RCStorageCipher: NSObject, @unchecked Sendable {
    private static let envelopeMagic = Data([0x52, 0x43, 0x45, 0x4e, 0x43, 0x01]) // "RCENC\u{01}"
    private static let envelopeMagicPrefix = Data([0x52, 0x43, 0x45, 0x4e, 0x43]) // "RCENC"
    private static let envelopeHeaderLength = envelopeMagic.count
    private static let gcmNonceLength = 12
    private static let gcmTagLength = 16
    private static let rootKeyLength = 32
    private static let maximumPlaintextLength = 64 * 1024 * 1024
    private static let maximumEnvelopeLength = envelopeHeaderLength
        + gcmNonceLength
        + maximumPlaintextLength
        + gcmTagLength

    private static let keychainAccount = "root-v1"
    private static let fileKeyPurpose = Data("revclip.file.v1".utf8)
    private static let databaseKeyPurpose = Data("revclip.database.v1".utf8)

    private enum ErrorCode: Int {
        case invalidInput = 1
        case keyUnavailable = 2
        case keychainFailure = 3
        case invalidKey = 4
        case tooLarge = 5
        case invalidEnvelope = 6
        case authenticationFailed = 7
        case fileFailure = 8
        case unsupported = 9
    }

    private static let errorDomain = "com.revclip.storage"

    private let keyLock = NSLock()
    private var injectedRootKey: Data?
    private var cachedRootKey: Data?
    private var cachedFileKey: SymmetricKey?
    private var cachedDatabaseKeyRepresentation: Data?

    private override init() {
        super.init()
    }

    /// Test-only constructor. Production callers must use `shared` and the
    /// Keychain-backed preparation method.
#if DEBUG
    @objc(initWithKeyData:)
    init(keyData: NSData) {
        self.injectedRootKey = Data(keyData)
        super.init()
    }
#endif

    @objc(shared)
    class func shared() -> RCStorageCipher {
        sharedInstance
    }

    private static let sharedInstance = RCStorageCipher()

    /// Install an in-memory key for the existing XCTest host. This is compiled
    /// only for Debug builds and never reads or writes the user's Keychain.
#if DEBUG
    @objc(installEphemeralSharedKeyForTesting:)
    class func installEphemeralSharedKeyForTesting(_ keyData: NSData) {
        let cipher = sharedInstance
        cipher.keyLock.lock()
        cipher.injectedRootKey = Data(keyData)
        cipher.cachedRootKey = nil
        cipher.cachedFileKey = nil
        cipher.cachedDatabaseKeyRepresentation = nil
        cipher.keyLock.unlock()
    }
#endif

    @objc(prepareAllowingCreation:error:)
    func prepare(allowingCreation: Bool, error: NSErrorPointer) -> Bool {
        keyLock.lock()
        defer { keyLock.unlock() }

        if let injectedRootKey {
            guard injectedRootKey.count == Self.rootKeyLength else {
                setError(error, code: .invalidKey, message: "The injected storage key has an invalid length.")
                return false
            }
            cachedRootKey = injectedRootKey
            return true
        }

        if cachedRootKey != nil {
            return true
        }

        guard let keychainKey = loadKeychainRootKey(allowingCreation: allowingCreation, error: error) else {
            return false
        }
        cachedRootKey = keychainKey
        return true
    }

    @objc(databaseKeyWithError:)
    func databaseKey(error: NSErrorPointer) -> NSData? {
        guard ensurePreparedKey(error: error) else {
            return nil
        }

        keyLock.lock()
        defer { keyLock.unlock() }

        if let cachedDatabaseKeyRepresentation {
            return cachedDatabaseKeyRepresentation as NSData
        }

        guard let rootKey = cachedRootKey ?? injectedRootKey,
              rootKey.count == Self.rootKeyLength else {
            setError(error, code: .invalidKey, message: "The storage key is unavailable.")
            return nil
        }

        let derivedKey = deriveKey(rootKey: rootKey, purpose: Self.databaseKeyPurpose)
        let hex = derivedKey.map { String(format: "%02x", $0) }.joined()
        // SQLCipher recognizes this literal as the raw 32-byte key. Keep the
        // representation in NSData so Objective-C callers cannot accidentally
        // log or interpolate the key as an ordinary Swift String.
        let representation = Data("x'\(hex)'".utf8)
        cachedDatabaseKeyRepresentation = representation
        return representation as NSData
    }

    @objc(encryptData:error:)
    func encrypt(data: NSData, error: NSErrorPointer) -> NSData? {
        let plaintext = Data(data)
        guard plaintext.count <= Self.maximumPlaintextLength else {
            setError(error, code: .tooLarge, message: "The data exceeds the storage size limit.")
            return nil
        }
        guard let fileKey = fileKey(error: error) else {
            return nil
        }

        do {
            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: fileKey,
                authenticating: Self.envelopeMagic
            )
            guard let combined = sealedBox.combined else {
                setError(error, code: .unsupported, message: "The encrypted payload has no combined representation.")
                return nil
            }

            var envelope = Self.envelopeMagic
            envelope.append(combined)
            guard envelope.count <= Self.maximumEnvelopeLength else {
                setError(error, code: .tooLarge, message: "The encrypted data exceeds the storage size limit.")
                return nil
            }
            return envelope as NSData
        } catch let caughtError {
            _ = caughtError
            setError(error, code: .unsupported, message: "The data could not be encrypted.")
            return nil
        }
    }

    @objc(decryptData:error:)
    func decrypt(data: NSData, error: NSErrorPointer) -> NSData? {
        let envelope = Data(data)
        guard envelope.count <= Self.maximumEnvelopeLength else {
            setError(error, code: .tooLarge, message: "The encrypted data exceeds the storage size limit.")
            return nil
        }
        guard Self.hasValidEnvelopeHeader(envelope) else {
            setError(error, code: .invalidEnvelope, message: "The storage envelope header is invalid.")
            return nil
        }
        guard envelope.count >= Self.envelopeHeaderLength + Self.gcmNonceLength + Self.gcmTagLength else {
            setError(error, code: .invalidEnvelope, message: "The storage envelope is truncated.")
            return nil
        }
        guard let fileKey = fileKey(error: error) else {
            return nil
        }

        let combined = envelope.dropFirst(Self.envelopeHeaderLength)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(
                sealedBox,
                using: fileKey,
                authenticating: Self.envelopeMagic
            )
            guard plaintext.count <= Self.maximumPlaintextLength else {
                setError(error, code: .tooLarge, message: "The decrypted data exceeds the storage size limit.")
                return nil
            }
            return plaintext as NSData
        } catch let cryptoError as CryptoKitError {
            _ = cryptoError
            setError(error, code: .authenticationFailed, message: "The storage envelope failed authentication.")
            return nil
        } catch let caughtError {
            _ = caughtError
            setError(error, code: .authenticationFailed, message: "The storage envelope failed authentication.")
            return nil
        }
    }

    @objc(isEncryptedData:)
    class func isEncryptedData(_ data: NSData) -> Bool {
        // Classify by the stable magic prefix only. Decryption still requires
        // the supported versioned header, so a future/unknown version cannot
        // be mistaken for legacy plaintext during migration.
        hasEnvelopeMagicPrefix(Data(data))
    }

    @objc(readDataAtPath:allowPlaintext:error:)
    func readData(atPath path: String, allowPlaintext: Bool, error: NSErrorPointer) -> NSData? {
        guard let rawData = readBoundedRegularFile(atPath: path, error: error) else {
            return nil
        }

        if Self.isEncryptedData(rawData) {
            return decrypt(data: rawData, error: error)
        }

        guard allowPlaintext else {
            setError(error, code: .invalidEnvelope, message: "The file is not an encrypted storage envelope.")
            return nil
        }
        return rawData
    }

    @objc(writeData:toPath:error:)
    func write(data: NSData, toPath path: String, error: NSErrorPointer) -> Bool {
        guard !path.isEmpty else {
            setError(error, code: .invalidInput, message: "The storage path is empty.")
            return false
        }
        guard validateDestinationPath(path, error: error) else {
            return false
        }
        guard let encrypted = encrypt(data: data, error: error) else {
            return false
        }
        guard let verified = decrypt(data: encrypted, error: error), verified as Data == Data(data) else {
            if error?.pointee == nil {
                setError(error, code: .authenticationFailed, message: "The encrypted payload failed verification.")
            }
            return false
        }

        return atomicallyReplaceFile(atPath: path, with: encrypted as Data, error: error)
    }

    @objc(migrateFileAtPath:error:)
    func migrate(fileAtPath path: String, error: NSErrorPointer) -> Bool {
        guard let rawData = readBoundedRegularFile(atPath: path, error: error) else {
            return false
        }

        if Self.isEncryptedData(rawData) {
            return decrypt(data: rawData, error: error) != nil
        }

        return write(data: rawData as NSData, toPath: path, error: error)
    }

    @objc(deleteKeyWithError:)
    func deleteKey(error: NSErrorPointer) -> Bool {
        keyLock.lock()
        defer { keyLock.unlock() }

        if injectedRootKey != nil {
            injectedRootKey = nil
            cachedRootKey = nil
            cachedFileKey = nil
            cachedDatabaseKeyRepresentation = nil
            return true
        }

        let status = SecItemDelete(keychainQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            setError(error, code: .keychainFailure, message: "The storage key could not be deleted.")
            return false
        }

        cachedRootKey = nil
        cachedFileKey = nil
        cachedDatabaseKeyRepresentation = nil
        return true
    }

    private func ensurePreparedKey(error: NSErrorPointer) -> Bool {
        keyLock.lock()
        let isPrepared = injectedRootKey != nil || cachedRootKey != nil
        keyLock.unlock()
        if isPrepared {
            return true
        }
        setError(error, code: .keyUnavailable, message: "The storage key has not been prepared.")
        return false
    }

    private func fileKey(error: NSErrorPointer) -> SymmetricKey? {
        guard ensurePreparedKey(error: error) else {
            return nil
        }

        keyLock.lock()
        defer { keyLock.unlock() }
        if let cachedFileKey {
            return cachedFileKey
        }
        guard let rootKey = cachedRootKey ?? injectedRootKey,
              rootKey.count == Self.rootKeyLength else {
            setError(error, code: .invalidKey, message: "The storage key is unavailable.")
            return nil
        }
        let key = deriveKey(rootKey: rootKey, purpose: Self.fileKeyPurpose)
        let fileKey = SymmetricKey(data: key)
        cachedFileKey = fileKey
        return fileKey
    }

    private func deriveKey(rootKey: Data, purpose: Data) -> Data {
        let root = SymmetricKey(data: rootKey)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: root,
            salt: Data("revclip.storage.hkdf.v1".utf8),
            info: purpose,
            outputByteCount: Self.rootKeyLength
        )
        return derived.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return Data()
            }
            return Data(bytes: baseAddress, count: buffer.count)
        }
    }

    private func loadKeychainRootKey(allowingCreation: Bool, error: NSErrorPointer) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(keychainQuery(returnData: true) as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == Self.rootKeyLength else {
                setError(error, code: .invalidKey, message: "The stored storage key has an invalid length.")
                return nil
            }
            return data
        }

        guard status == errSecItemNotFound else {
            setError(error, code: .keychainFailure, message: "The storage key could not be read.")
            return nil
        }

        guard allowingCreation else {
            setError(error, code: .keyUnavailable, message: "The storage key was not found.")
            return nil
        }

        var key = Data(count: Self.rootKeyLength)
        let randomStatus = key.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            setError(error, code: .keychainFailure, message: "A storage key could not be generated.")
            return nil
        }

        var attributes = keychainQuery()
        attributes[kSecValueData as String] = key
        guard let access = makeDefaultKeychainAccess() else {
            setError(error, code: .keychainFailure, message: "The storage key access policy could not be created.")
            return nil
        }
        attributes[kSecAttrAccess as String] = access
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return key
        }

        if addStatus == errSecDuplicateItem {
            var existing: CFTypeRef?
            let existingStatus = SecItemCopyMatching(keychainQuery(returnData: true) as CFDictionary, &existing)
            guard existingStatus == errSecSuccess,
                  let data = existing as? Data,
                  data.count == Self.rootKeyLength else {
                setError(error, code: .keychainFailure, message: "The existing storage key could not be read.")
                return nil
            }
            return data
        }

        setError(error, code: .keychainFailure, message: "The storage key could not be saved.")
        return nil
    }

    private func keychainService() -> String {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        return (bundleIdentifier?.isEmpty == false ? bundleIdentifier! : "com.revclip.Revclip") + ".storage-key"
    }

    private func keychainQuery(returnData: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService(),
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if returnData {
            query[kSecReturnData as String] = kCFBooleanTrue as Any
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private func makeDefaultKeychainAccess() -> SecAccess? {
        var access: SecAccess?
        // A nil trusted list means only the application creating the item is
        // trusted. Treat failure as fatal; falling back to SecItemAdd's ACL
        // would silently widen access to the login keychain item.
        let status = SecAccessCreate("Revclip storage key" as CFString, nil, &access)
        return status == errSecSuccess ? access : nil
    }

    private static func hasValidEnvelopeHeader(_ data: Data) -> Bool {
        data.count >= envelopeHeaderLength && data.prefix(envelopeHeaderLength) == envelopeMagic
    }

    private static func hasEnvelopeMagicPrefix(_ data: Data) -> Bool {
        data.count >= envelopeMagicPrefix.count && data.prefix(envelopeMagicPrefix.count) == envelopeMagicPrefix
    }

    private func validateDestinationPath(_ path: String, error: NSErrorPointer) -> Bool {
        let parentPath = (path as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty else {
            setError(error, code: .invalidInput, message: "The storage path has no parent directory.")
            return false
        }

        var parentStat = stat()
        guard parentPath.withCString({ lstat($0, &parentStat) == 0 }),
              (parentStat.st_mode & S_IFMT) == S_IFDIR else {
            setError(error, code: .fileFailure, message: "The storage parent directory is unavailable.")
            return false
        }

        var destinationStat = stat()
        let destinationStatus = path.withCString { lstat($0, &destinationStat) }
        if destinationStatus == 0 {
            let type = destinationStat.st_mode & S_IFMT
            guard type == S_IFREG, destinationStat.st_nlink == 1 else {
                setError(error, code: .fileFailure, message: "The storage destination is not a regular file.")
                return false
            }
        } else if errno != ENOENT {
            setError(error, code: .fileFailure, message: "The storage destination could not be inspected.")
            return false
        }

        return true
    }

    private func readBoundedRegularFile(atPath path: String, error: NSErrorPointer) -> NSData? {
        guard !path.isEmpty else {
            setError(error, code: .invalidInput, message: "The storage path is empty.")
            return nil
        }

        let descriptor = path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            setError(error, code: .fileFailure, message: "The storage file could not be opened.")
            return nil
        }
        defer { _ = Darwin.close(descriptor) }

        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_nlink == 1 else {
            setError(error, code: .fileFailure, message: "The storage file is not a regular file.")
            return nil
        }
        guard fileStat.st_size >= 0,
              UInt64(fileStat.st_size) <= UInt64(Self.maximumEnvelopeLength) else {
            setError(error, code: .tooLarge, message: "The storage file exceeds the size limit.")
            return nil
        }

        // Peek without moving the descriptor so the plaintext limit can stay
        // at 64 MiB while allowing the fixed envelope overhead on ciphertext.
        // This also makes an oversized legacy plaintext fail before allocation.
        var prefix = [UInt8](repeating: 0, count: Self.envelopeHeaderLength)
        var prefixCount = 0
        while prefixCount < prefix.count {
            let count = prefix.withUnsafeMutableBytes { bufferPointer in
                Darwin.pread(
                    descriptor,
                    bufferPointer.baseAddress!.advanced(by: prefixCount),
                    bufferPointer.count - prefixCount,
                    off_t(prefixCount)
                )
            }
            if count == 0 {
                break
            }
            if count < 0 && errno == EINTR {
                continue
            }
            guard count > 0 else {
                setError(error, code: .fileFailure, message: "The storage file could not be inspected.")
                return nil
            }
            prefixCount += count
        }
        let envelopeLike = Self.hasEnvelopeMagicPrefix(Data(prefix.prefix(prefixCount)))
        let maximumStoredLength = envelopeLike
            ? Self.maximumEnvelopeLength
            : Self.maximumPlaintextLength
        guard UInt64(fileStat.st_size) <= UInt64(maximumStoredLength) else {
            setError(error, code: .tooLarge, message: "The storage file exceeds the size limit.")
            return nil
        }

        var output = Data()
        output.reserveCapacity(Int(fileStat.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bufferPointer in
                Darwin.read(descriptor, bufferPointer.baseAddress, bufferPointer.count)
            }
            if count == 0 {
                break
            }
            if count < 0 && errno == EINTR {
                continue
            }
            guard count > 0 else {
                setError(error, code: .fileFailure, message: "The storage file could not be read.")
                return nil
            }
            output.append(contentsOf: buffer[0..<count])
            guard output.count <= maximumStoredLength else {
                setError(error, code: .tooLarge, message: "The storage file exceeds the size limit.")
                return nil
            }
        }
        var finalStat = stat()
        guard fstat(descriptor, &finalStat) == 0,
              finalStat.st_size == fileStat.st_size,
              finalStat.st_nlink == 1,
              output.count == Int(fileStat.st_size) else {
            setError(error, code: .fileFailure, message: "The storage file changed while it was being read.")
            return nil
        }
        return output as NSData
    }

    private func atomicallyReplaceFile(atPath path: String, with encrypted: Data, error: NSErrorPointer) -> Bool {
        let directoryPath = (path as NSString).deletingLastPathComponent
        let basename = (path as NSString).lastPathComponent
        let temporaryTemplate = (directoryPath as NSString).appendingPathComponent(".\(basename).tmp.XXXXXX")
        var template = Array(temporaryTemplate.utf8) + [0]
        var temporaryPath = ""
        let temporaryDescriptor = template.withUnsafeMutableBufferPointer { buffer in
            let descriptor = mkstemp(buffer.baseAddress)
            if descriptor >= 0, let baseAddress = buffer.baseAddress {
                temporaryPath = String(cString: baseAddress)
            }
            return descriptor
        }
        guard temporaryDescriptor >= 0 else {
            setError(error, code: .fileFailure, message: "The temporary storage file could not be created.")
            return false
        }

        var succeeded = false
        var descriptorOpen = true
        defer {
            if descriptorOpen {
                close(temporaryDescriptor)
            }
            if !succeeded {
                _ = temporaryPath.withCString { unlink($0) }
            }
        }

        guard fchmod(temporaryDescriptor, 0o600) == 0,
              writeAll(encrypted, to: temporaryDescriptor),
              fsync(temporaryDescriptor) == 0 else {
            setError(error, code: .fileFailure, message: "The encrypted storage file could not be written durably.")
            return false
        }

        let closeStatus = Darwin.close(temporaryDescriptor)
        descriptorOpen = false
        guard closeStatus == 0 else {
            setError(error, code: .fileFailure, message: "The temporary storage file could not be closed.")
            return false
        }

        let renameStatus = temporaryPath.withCString { temporaryCString in
            path.withCString { destinationCString in
                Darwin.rename(temporaryCString, destinationCString)
            }
        }
        guard renameStatus == 0 else {
            setError(error, code: .fileFailure, message: "The encrypted storage file could not be committed.")
            return false
        }

        succeeded = true

        let directoryDescriptor = directoryPath.withCString { directoryCString in
            Darwin.open(directoryCString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            setError(error, code: .fileFailure, message: "The storage directory could not be opened for durability.")
            return false
        }
        let directorySyncStatus = fsync(directoryDescriptor)
        _ = Darwin.close(directoryDescriptor)
        guard directorySyncStatus == 0 else {
            setError(error, code: .fileFailure, message: "The storage directory could not be synchronized.")
            return false
        }
        return true
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return data.isEmpty
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    return false
                }
                offset += count
            }
            return true
        }
    }

    private func setError(_ error: NSErrorPointer, code: ErrorCode, message: String) {
        error?.pointee = NSError(
            domain: Self.errorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

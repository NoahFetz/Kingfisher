//
//  DiskStorage.swift
//  Kingfisher
//
//  Created by Wei Wang on 2018/10/15.
//
//  Copyright (c) 2019 Wei Wang <onevcat@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation


/// Represents the concepts related to storage that stores a specific type of value in disk.
///
/// This serves as a namespace for memory storage types. A ``DiskStorage/Backend`` with a particular
/// ``DiskStorage/Config`` is used to define the storage.
///
/// Refer to these composite types for further details.
public enum DiskStorage {

    /// Represents a storage backend for the ``DiskStorage``.
    ///
    /// The value is serialized to binary data and stored as a file in the file system under a specified location.
    ///
    /// You can configure a ``DiskStorage/Backend`` in its ``DiskStorage/Backend/init(config:)`` by passing a
    /// ``DiskStorage/Config`` value or by modifying the ``DiskStorage/Backend/config`` property after it has been
    /// created. The ``DiskStorage/Backend`` will use the file's attributes to keep track of a file for its expiration
    /// or size limitation.
    public class Backend<T: DataTransformable> {
        
        /// The configuration used for this disk storage.
        ///
        /// It is a value you can set and use to configure the storage as needed.
        public var config: Config

        /// The final storage URL on disk of the disk storage ``DiskStorage/Backend``, considering the
        /// ``DiskStorage/Config/name`` and the  ``DiskStorage/Config/cachePathBlock``.
        public let directoryURL: URL

        let metaChangingQueue: DispatchQueue

        // A shortcut (which contains false-positive) to improve matching performance.
        var maybeCached : Set<String>?
        let maybeCachedCheckingQueue = DispatchQueue(label: "com.onevcat.Kingfisher.maybeCachedCheckingQueue")

        // `false` if the storage initialized with an error.
        // This prevents unexpected forcibly crash when creating storage in the default cache.
        private var storageReady: Bool = true

        /// Creates a disk storage with the given ``DiskStorage/Config``.
        ///
        /// - Parameter config: The configuration used for this disk storage.
        /// - Throws: An error if the folder for storage cannot be obtained or created.
        public convenience init(config: Config) throws {
            self.init(noThrowConfig: config, creatingDirectory: false)
            try prepareDirectory()
        }

        // If `creatingDirectory` is `false`, the directory preparation will be skipped.
        // We need to call `prepareDirectory` manually after this returns.
        init(noThrowConfig config: Config, creatingDirectory: Bool) {
            var config = config

            let creation = Creation(config)
            self.directoryURL = creation.directoryURL

            // Break any possible retain cycle set by outside.
            config.cachePathBlock = nil
            self.config = config

            metaChangingQueue = DispatchQueue(label: creation.cacheName)
            setupCacheChecking()

            if creatingDirectory {
                try? prepareDirectory()
            }
        }

        private func setupCacheChecking() {
            maybeCachedCheckingQueue.async {
                do {
                    self.maybeCached = Set()
                    try self.config.fileManager.contentsOfDirectory(atPath: self.directoryURL.path).forEach { 
                        fileName in
                        self.maybeCached?.insert(fileName)
                    }
                } catch {
                    // Just disable the functionality if we fail to initialize it properly. This will just revert to
                    // the behavior which is to check file existence on disk directly.
                    self.maybeCached = nil
                }
            }
        }

        // Creates the storage folder.
        private func prepareDirectory() throws {
            let fileManager = config.fileManager
            let path = directoryURL.path

            guard !fileManager.fileExists(atPath: path) else { return }

            do {
                try fileManager.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: nil)
            } catch {
                self.storageReady = false
                throw KingfisherError.cacheError(reason: .cannotCreateDirectory(path: path, error: error))
            }
        }

        /// Stores a value in the storage under the specified key and expiration policy.
        ///
        /// - Parameters:
        ///   - value: The value to be stored.
        ///   - key: The key to which the `value` will be stored. If there is already a value under the key,
        ///   the old value will be overwritten by the new `value`.
        ///   - expiration: The expiration policy used by this storage action.
        ///   - writeOptions: Data writing options used for the new files.
        /// - Throws: An error during converting the value to a data format or during writing it to disk.
        public func store(
            value: T,
            forKey key: String,
            expiration: StorageExpiration? = nil,
            writeOptions: Data.WritingOptions = []) throws
        {
            guard storageReady else {
                throw KingfisherError.cacheError(reason: .diskStorageIsNotReady(cacheURL: directoryURL))
            }

            let expiration = expiration ?? config.expiration
            // The expiration indicates that already expired, no need to store.
            guard !expiration.isExpired else { return }
            
            let data: Data
            do {
                data = try value.toData()
            } catch {
                throw KingfisherError.cacheError(reason: .cannotConvertToData(object: value, error: error))
            }

            let fileURL = cacheFileURL(forKey: key)
            do {
                try data.write(to: fileURL, options: writeOptions)
            } catch {
                if error.isFolderMissing {
                    // The whole cache folder is deleted. Try to recreate it and write file again.
                    do {
                        try prepareDirectory()
                        try data.write(to: fileURL, options: writeOptions)
                    } catch {
                        throw KingfisherError.cacheError(
                            reason: .cannotCreateCacheFile(fileURL: fileURL, key: key, data: data, error: error)
                        )
                    }
                } else {
                    throw KingfisherError.cacheError(
                        reason: .cannotCreateCacheFile(fileURL: fileURL, key: key, data: data, error: error)
                    )
                }
            }

            let now = Date()
            let attributes: [FileAttributeKey : Any] = [
                // The last access date.
                .creationDate: now.fileAttributeDate,
                // The estimated expiration date.
                .modificationDate: expiration.estimatedExpirationSinceNow.fileAttributeDate
            ]
            do {
                try config.fileManager.setAttributes(attributes, ofItemAtPath: fileURL.path)
            } catch {
                try? config.fileManager.removeItem(at: fileURL)
                throw KingfisherError.cacheError(
                    reason: .cannotSetCacheFileAttribute(
                        filePath: fileURL.path,
                        attributes: attributes,
                        error: error
                    )
                )
            }

            maybeCachedCheckingQueue.async {
                self.maybeCached?.insert(fileURL.lastPathComponent)
            }
        }

        /// Retrieves a value from the storage.
        /// - Parameters:
        ///   - key: The cache key of the value.
        ///   - extendingExpiration: The expiration policy used by this retrieval action.
        /// - Throws: An error during converting the data to a value or during the operation of disk files.
        /// - Returns: The value under `key` if it is valid and found in the storage; otherwise, `nil`.
        public func value(forKey key: String, extendingExpiration: ExpirationExtending = .cacheTime) throws -> T? {
            try value(forKey: key, referenceDate: Date(), actuallyLoad: true, extendingExpiration: extendingExpiration)
        }

        func value(
            forKey key: String,
            referenceDate: Date,
            actuallyLoad: Bool,
            extendingExpiration: ExpirationExtending) throws -> T?
        {
            guard storageReady else {
                throw KingfisherError.cacheError(reason: .diskStorageIsNotReady(cacheURL: directoryURL))
            }

            let fileManager = config.fileManager
            let fileURL = cacheFileURL(forKey: key)
            let filePath = fileURL.path

            let fileMaybeCached = maybeCachedCheckingQueue.sync {
                return maybeCached?.contains(fileURL.lastPathComponent) ?? true
            }
            guard fileMaybeCached else {
                return nil
            }
            guard fileManager.fileExists(atPath: filePath) else {
                return nil
            }

            let meta: FileMeta
            do {
                let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
                meta = try FileMeta(fileURL: fileURL, resourceKeys: resourceKeys)
            } catch {
                throw KingfisherError.cacheError(
                    reason: .invalidURLResource(error: error, key: key, url: fileURL))
            }

            if meta.expired(referenceDate: referenceDate) {
                return nil
            }
            if !actuallyLoad { return T.empty }

            do {
                let data = try Data(contentsOf: fileURL)
                let obj = try T.fromData(data)
                metaChangingQueue.async {
                    meta.extendExpiration(with: fileManager, extendingExpiration: extendingExpiration)
                }
                return obj
            } catch {
                throw KingfisherError.cacheError(reason: .cannotLoadDataFromDisk(url: fileURL, error: error))
            }
        }

        /// Determines whether there is valid cached data under a given key.
        ///
        /// - Parameter key: The cache key of the value.
        /// - Returns: `true` if there is valid data under the key; otherwise, `false`.
        ///
        /// > This method does not actually load the data from disk, so it is faster than directly loading the cached
        /// value by checking the nullability of the ``DiskStorage/Backend/value(forKey:extendingExpiration:)`` method.
        public func isCached(forKey key: String) -> Bool {
            return isCached(forKey: key, referenceDate: Date())
        }

        /// Determines whether there is valid cached data under a given key and a reference date.
        ///
        /// - Parameters:
        ///   - key: The cache key of the value.
        ///   - referenceDate: A reference date to check whether the cache is still valid.
        ///
        /// - Returns: `true` if there is valid data under the key; otherwise, `false`.
        ///
        /// If you pass `Date()` as the `referenceDate`, this method is identical to
        /// ``DiskStorage/Backend/isCached(forKey:)``. Use the `referenceDate` to determine whether the cache is still
        /// valid for a future date.
        public func isCached(forKey key: String, referenceDate: Date) -> Bool {
            do {
                let result = try value(
                    forKey: key,
                    referenceDate: referenceDate,
                    actuallyLoad: false,
                    extendingExpiration: .none
                )
                return result != nil
            } catch {
                return false
            }
        }

        /// Removes a value from a specified key.
        /// - Parameter key: The cache key of the value.
        /// - Throws: An error during the removal of the value.
        public func remove(forKey key: String) throws {
            let fileURL = cacheFileURL(forKey: key)
            try removeFile(at: fileURL)
        }

        func removeFile(at url: URL) throws {
            try config.fileManager.removeItem(at: url)
        }

        /// Removes all values in this storage.
        /// - Throws: An error during the removal of the values.
        public func removeAll() throws {
            try removeAll(skipCreatingDirectory: false)
        }

        func removeAll(skipCreatingDirectory: Bool) throws {
            try config.fileManager.removeItem(at: directoryURL)
            if !skipCreatingDirectory {
                try prepareDirectory()
            }
        }

        /// The URL of the cached file with a given computed `key`.
        ///
        /// - Parameter key: The final computed key used when caching the image. Please note that usually this is not
        /// the ``Source/cacheKey`` of an image ``Source``. It is the computed key with the processor identifier
        /// considered.
        ///
        /// This method does not guarantee that an image is already cached at the returned URL. It just provides the URL 
        /// where the image should be if it exists in the disk storage, with the given key.
        public func cacheFileURL(forKey key: String) -> URL {
            let fileName = cacheFileName(forKey: key)
            return directoryURL.appendingPathComponent(fileName, isDirectory: false)
        }

        func cacheFileName(forKey key: String) -> String {
            if config.usesHashedFileName {
                let hashedKey = key.kf.sha256
                if let ext = config.pathExtension {
                    return "\(hashedKey).\(ext)"
                } else if config.autoExtAfterHashedFileName,
                          let ext = key.kf.ext {
                    return "\(hashedKey).\(ext)"
                }
                return hashedKey
            } else {
                if let ext = config.pathExtension {
                    return "\(key).\(ext)"
                }
                return key
            }
        }

        func allFileURLs(for propertyKeys: [URLResourceKey]) throws -> [URL] {
            let fileManager = config.fileManager

            guard let directoryEnumerator = fileManager.enumerator(
                at: directoryURL, includingPropertiesForKeys: propertyKeys, options: .skipsHiddenFiles) else
            {
                throw KingfisherError.cacheError(reason: .fileEnumeratorCreationFailed(url: directoryURL))
            }

            guard let urls = directoryEnumerator.allObjects as? [URL] else {
                throw KingfisherError.cacheError(reason: .invalidFileEnumeratorContent(url: directoryURL))
            }
            return urls
        }

        /// Removes all expired values from this storage.
        /// - Throws: A file manager error during the removal of the file.
        /// - Returns: The URLs for the removed files.
        public func removeExpiredValues() throws -> [URL] {
            return try removeExpiredValues(referenceDate: Date())
        }

        func removeExpiredValues(referenceDate: Date) throws -> [URL] {
            let propertyKeys: [URLResourceKey] = [
                .isDirectoryKey,
                .contentModificationDateKey
            ]

            let urls = try allFileURLs(for: propertyKeys)
            let keys = Set(propertyKeys)
            let expiredFiles = urls.filter { fileURL in
                do {
                    let meta = try FileMeta(fileURL: fileURL, resourceKeys: keys)
                    if meta.isDirectory {
                        return false
                    }
                    return meta.expired(referenceDate: referenceDate)
                } catch {
                    return true
                }
            }
            try expiredFiles.forEach { url in
                try removeFile(at: url)
            }
            return expiredFiles
        }

        /// Removes all size-exceeded values from this storage.
        /// - Throws: A file manager error during the removal of the file.
        /// - Returns: The URLs for the removed files.
        ///
        /// This method checks ``DiskStorage/Config/sizeLimit`` and removes cached files in an LRU
        /// (Least Recently Used) way.
        public func removeSizeExceededValues() throws -> [URL] {

            if config.sizeLimit == 0 { return [] } // Back compatible. 0 means no limit.

            var size = try totalSize()
            if size < config.sizeLimit { return [] }

            let propertyKeys: [URLResourceKey] = [
                .isDirectoryKey,
                .creationDateKey,
                .fileSizeKey
            ]
            let keys = Set(propertyKeys)

            let urls = try allFileURLs(for: propertyKeys)
            var pendings: [FileMeta] = urls.compactMap { fileURL in
                guard let meta = try? FileMeta(fileURL: fileURL, resourceKeys: keys) else {
                    return nil
                }
                return meta
            }
            // Sort by last access date. Most recent file first.
            pendings.sort(by: FileMeta.lastAccessDate)

            var removed: [URL] = []
            let target = config.sizeLimit / 2
            while size > target, let meta = pendings.popLast() {
                size -= UInt(meta.fileSize)
                try removeFile(at: meta.url)
                removed.append(meta.url)
            }
            return removed
        }

        /// Gets the total file size of the cache folder in bytes.
        public func totalSize() throws -> UInt {
            let propertyKeys: [URLResourceKey] = [.fileSizeKey]
            let urls = try allFileURLs(for: propertyKeys)
            let keys = Set(propertyKeys)
            let totalSize: UInt = urls.reduce(0) { size, fileURL in
                do {
                    let meta = try FileMeta(fileURL: fileURL, resourceKeys: keys)
                    return size + UInt(meta.fileSize)
                } catch {
                    return size
                }
            }
            return totalSize
        }
    }
}

extension DiskStorage {
    
    /// Represents the configuration used in a ``DiskStorage/Backend``.
    public struct Config {

        /// The file size limit on disk of the storage in bytes. 
        ///
        /// `0` means no limit.
        public var sizeLimit: UInt

        /// The `StorageExpiration` used in this disk storage.
        ///
        /// The default is `.days(7)`, which means that the disk cache will expire in one week if not accessed anymore.
        public var expiration: StorageExpiration = .days(7)

        /// The preferred extension of the cache item. It will be appended to the file name as its extension.
        ///
        /// The default is `nil`, which means that the cache file does not contain a file extension.
        public var pathExtension: String? = nil

        /// Whether the cache file name will be hashed before storing.
        ///
        /// The default is `true`, which means that file name is hashed to protect user information (for example, the
        /// original download URL which is used as the cache key).
        public var usesHashedFileName = true

        
        /// Whether the image extension will be extracted from the original file name and appended to the hashed file
        /// name, which will be used as the cache key on disk.
        ///
        /// The default is `false`.
        public var autoExtAfterHashedFileName = false
        
        /// A closure that takes in the initial directory path and generates the final disk cache path.
        ///
        /// You can use it to fully customize your cache path.
        public var cachePathBlock: ((_ directory: URL, _ cacheName: String) -> URL)! = {
            (directory, cacheName) in
            return directory.appendingPathComponent(cacheName, isDirectory: true)
        }

        /// The desired name of the disk cache.
        ///
        /// This name will be used as a part of the cache folder name by default.
        public let name: String
        
        let fileManager: FileManager
        let directory: URL?

        /// Creates a config value based on the given parameters.
        ///
        /// - Parameters:
        ///   - name: The name of the cache. It is used as part of the storage folder and to identify the disk storage.
        ///   Two storages with the same `name` would share the same folder on the disk, and this should be prevented.
        ///   - sizeLimit: The size limit in bytes for all existing files in the disk storage.
        ///   - fileManager: The `FileManager` used to manipulate files on the disk. The default is `FileManager.default`.
        ///   - directory: The URL where the disk storage should reside. The storage will use this as the root folder,
        ///   and append a path that is constructed by the input `name`. The default is `nil`, indicating that
        ///   the cache directory under the user domain mask will be used.
        public init(
            name: String,
            sizeLimit: UInt,
            fileManager: FileManager = .default,
            directory: URL? = nil)
        {
            self.name = name
            self.fileManager = fileManager
            self.directory = directory
            self.sizeLimit = sizeLimit
        }
    }
}

extension DiskStorage {
    struct FileMeta {
    
        let url: URL
        
        let lastAccessDate: Date?
        let estimatedExpirationDate: Date?
        let isDirectory: Bool
        let fileSize: Int
        
        static func lastAccessDate(lhs: FileMeta, rhs: FileMeta) -> Bool {
            return lhs.lastAccessDate ?? .distantPast > rhs.lastAccessDate ?? .distantPast
        }
        
        init(fileURL: URL, resourceKeys: Set<URLResourceKey>) throws {
            let meta = try fileURL.resourceValues(forKeys: resourceKeys)
            self.init(
                fileURL: fileURL,
                lastAccessDate: meta.creationDate,
                estimatedExpirationDate: meta.contentModificationDate,
                isDirectory: meta.isDirectory ?? false,
                fileSize: meta.fileSize ?? 0)
        }
        
        init(
            fileURL: URL,
            lastAccessDate: Date?,
            estimatedExpirationDate: Date?,
            isDirectory: Bool,
            fileSize: Int)
        {
            self.url = fileURL
            self.lastAccessDate = lastAccessDate
            self.estimatedExpirationDate = estimatedExpirationDate
            self.isDirectory = isDirectory
            self.fileSize = fileSize
        }

        func expired(referenceDate: Date) -> Bool {
            return estimatedExpirationDate?.isPast(referenceDate: referenceDate) ?? true
        }
        
        func extendExpiration(with fileManager: FileManager, extendingExpiration: ExpirationExtending) {
            guard let lastAccessDate = lastAccessDate,
                  let lastEstimatedExpiration = estimatedExpirationDate else
            {
                return
            }

            let attributes: [FileAttributeKey : Any]

            switch extendingExpiration {
            case .none:
                // not extending expiration time here
                return
            case .cacheTime:
                let originalExpiration: StorageExpiration =
                    .seconds(lastEstimatedExpiration.timeIntervalSince(lastAccessDate))
                attributes = [
                    .creationDate: Date().fileAttributeDate,
                    .modificationDate: originalExpiration.estimatedExpirationSinceNow.fileAttributeDate
                ]
            case .expirationTime(let expirationTime):
                attributes = [
                    .creationDate: Date().fileAttributeDate,
                    .modificationDate: expirationTime.estimatedExpirationSinceNow.fileAttributeDate
                ]
            }

            try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}

extension DiskStorage {
    struct Creation {
        let directoryURL: URL
        let cacheName: String

        init(_ config: Config) {
            let url: URL
            if let directory = config.directory {
                url = directory
            } else {
                url = config.fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            }

            cacheName = "com.onevcat.Kingfisher.ImageCache.\(config.name)"
            directoryURL = config.cachePathBlock(url, cacheName)
        }
    }
}

fileprivate extension Error {
    var isFolderMissing: Bool {
        let nsError = self as NSError
        guard nsError.domain == NSCocoaErrorDomain, nsError.code == 4 else {
            return false
        }
        guard let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        guard underlyingError.domain == NSPOSIXErrorDomain, underlyingError.code == 2 else {
            return false
        }
        return true
    }
}

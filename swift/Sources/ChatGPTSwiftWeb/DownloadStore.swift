import ChatGPTSwiftWebCore
import Foundation

enum DownloadStore {
    static func downloadsDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
    }

    static func destinationURL(
        suggestedFilename: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let targetDirectory = directory ?? downloadsDirectory(fileManager: fileManager)
        return DownloadFilename.uniqueDownloadURL(
            suggestedFilename: suggestedFilename,
            in: targetDirectory,
            fileExists: { fileManager.fileExists(atPath: $0) }
        )
    }

    @discardableResult
    static func save(
        _ data: Data,
        suggestedFilename: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let targetDirectory = directory ?? downloadsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let destination = destinationURL(
            suggestedFilename: suggestedFilename,
            directory: targetDirectory,
            fileManager: fileManager
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    @discardableResult
    static func moveTemporaryFile(
        _ temporaryFileURL: URL,
        suggestedFilename: String,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let targetDirectory = directory ?? downloadsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let destination = destinationURL(
            suggestedFilename: suggestedFilename,
            directory: targetDirectory,
            fileManager: fileManager
        )
        try fileManager.moveItem(at: temporaryFileURL, to: destination)
        return destination
    }
}

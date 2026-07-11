import XCTest
@testable import ChatGPTSwiftWeb

final class DownloadIntegrationTests: XCTestCase {
    func testDownloadStoreWritesAtomicallyAndAvoidsOverwritingExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSwiftWebDownloadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstData = Data("first".utf8)
        let secondData = Data("second".utf8)
        let firstURL = try DownloadStore.save(firstData, suggestedFilename: "report.txt", directory: root)
        let secondURL = try DownloadStore.save(secondData, suggestedFilename: "report.txt", directory: root)

        XCTAssertEqual(firstURL.lastPathComponent, "report.txt")
        XCTAssertEqual(secondURL.lastPathComponent, "report-1.txt")
        XCTAssertEqual(try Data(contentsOf: firstURL), firstData)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondData)
        XCTAssertEqual(firstURL.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(secondURL.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
    }
}

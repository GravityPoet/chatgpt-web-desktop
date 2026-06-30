import Foundation
import XCTest
@testable import ChatGPTSwiftWebCore

final class DownloadFilenameTests: XCTestCase {
    func testSanitizeRemovesPathSeparatorsAndFallsBackForEmptyNames() {
        XCTAssertEqual(DownloadFilename.sanitize(" report/image:1.png "), "report-image-1.png")
        XCTAssertEqual(DownloadFilename.sanitize("\n\t"), "chatgpt-download")
    }

    func testUniqueDownloadURLAddsSuffixBeforeExtension() throws {
        let directory = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
        let occupied: Set<String> = [
            "/tmp/downloads/chatgpt-image.png",
            "/tmp/downloads/chatgpt-image-1.png",
        ]

        let url = DownloadFilename.uniqueDownloadURL(
            suggestedFilename: "chatgpt-image.png",
            in: directory,
            fileExists: { occupied.contains($0) }
        )

        XCTAssertEqual(url.path, "/tmp/downloads/chatgpt-image-2.png")
    }

    func testImageFilenameAddsExtensionFromMimeType() throws {
        XCTAssertEqual(
            DownloadFilename.imageFilename(suggestedFilename: nil, fallback: "chatgpt-image", mimeType: "image/png"),
            "chatgpt-image.png"
        )
        XCTAssertEqual(
            DownloadFilename.remoteImageFilename(
                suggestedFilename: "render",
                sourceURL: try XCTUnwrap(URL(string: "https://example.com/path/source")),
                mimeType: "image/webp"
            ),
            "render.webp"
        )
        XCTAssertEqual(
            DownloadFilename.imageFilename(suggestedFilename: "already.jpg", fallback: "unused", mimeType: "image/png"),
            "already.jpg"
        )
    }
}

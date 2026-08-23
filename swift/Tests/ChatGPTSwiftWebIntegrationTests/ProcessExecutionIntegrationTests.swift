import Foundation
import XCTest
@testable import ChatGPTSwiftWeb

final class ProcessExecutionIntegrationTests: XCTestCase {
    func testProcessRunnerDrainsLargeStandardOutputAndError() {
        let finished = expectation(description: "large child output drained")
        let resultLock = NSLock()
        var captured: ProcessRunResult?

        DispatchQueue.global(qos: .utility).async {
            let result = AppDelegate.runProcess(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "/usr/bin/yes O | /usr/bin/head -c 262144; /usr/bin/yes E | /usr/bin/head -c 262144 >&2"
                ],
                currentDirectory: nil
            )
            resultLock.lock()
            captured = result
            resultLock.unlock()
            finished.fulfill()
        }

        wait(for: [finished], timeout: 10)
        resultLock.lock()
        let result = captured
        resultLock.unlock()
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertEqual(result?.output.utf8.count, 262_144)
        XCTAssertEqual(result?.errorOutput.utf8.count, 262_144)
    }
}

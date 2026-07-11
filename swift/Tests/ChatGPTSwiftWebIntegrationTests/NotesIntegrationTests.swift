import XCTest
@testable import ChatGPTSwiftWeb

final class NotesIntegrationTests: XCTestCase {
    func testSelectedNoteFlowsFromScriptResultIntoPromptContext() {
        let executor = StubNotesScriptExecutor(
            result: .success("""
            Project note
            ----CHATGPT_SWIFT_NOTES_BODY----
            <div>First line</div><div>Second line</div>
            """)
        )
        let completed = expectation(description: "notes context")

        NotesContextReader.readSelectedNote(executor: executor, queue: DispatchQueue(label: "notes-test")) { result in
            switch result {
            case .success(let context):
                XCTAssertTrue(context.contains("Project note"))
                XCTAssertTrue(context.contains("First line"))
                XCTAssertTrue(context.contains("Second line"))
                XCTAssertTrue(executor.receivedSource.contains("set selectedNotes to selection"))
            case .failure(let error):
                XCTFail("unexpected error: \(error)")
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
    }

    func testAutomationDenialMapsToActionableNotesError() {
        let executor = StubNotesScriptExecutor(
            result: .failure(number: -1743, message: "Not authorized")
        )
        let completed = expectation(description: "notes denial")

        NotesContextReader.readSelectedNote(executor: executor, queue: DispatchQueue(label: "notes-denial-test")) { result in
            guard case .failure(let error) = result else {
                XCTFail("expected failure")
                completed.fulfill()
                return
            }
            XCTAssertEqual(error as? NotesContextError, .automationDenied)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
    }
}

private final class StubNotesScriptExecutor: NotesScriptExecuting {
    let result: NotesScriptExecutionResult
    private(set) var receivedSource = ""

    init(result: NotesScriptExecutionResult) {
        self.result = result
    }

    func execute(_ source: String) -> NotesScriptExecutionResult {
        receivedSource = source
        return result
    }
}

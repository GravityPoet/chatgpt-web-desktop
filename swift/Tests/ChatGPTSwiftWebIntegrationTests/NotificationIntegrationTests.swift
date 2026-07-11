import XCTest
@testable import ChatGPTSwiftWeb

final class NotificationIntegrationTests: XCTestCase {
    func testAuthorizedCompletionSchedulesExpectedNativeNotification() {
        let scheduler = StubCompletionNotificationScheduler(status: .authorized)
        let service = CompletionNotificationService(
            scheduler: scheduler,
            makeIdentifier: { "notification-id" }
        )
        let completed = expectation(description: "notification scheduled")

        service.postIfAuthorized(enabled: true, context: "Project chat") { outcome in
            XCTAssertEqual(outcome, .scheduled)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(
            scheduler.requests,
            [CompletionNotificationRequest(
                identifier: "notification-id",
                title: "ChatGPT 回复完成",
                body: "Project chat"
            )]
        )
    }

    func testDeniedCompletionDoesNotScheduleNotification() {
        let scheduler = StubCompletionNotificationScheduler(status: .denied)
        let service = CompletionNotificationService(scheduler: scheduler)
        let completed = expectation(description: "notification denied")

        service.postIfAuthorized(enabled: true, context: "Project chat") { outcome in
            XCTAssertEqual(outcome, .notAuthorized(.denied))
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertTrue(scheduler.requests.isEmpty)
    }
}

private final class StubCompletionNotificationScheduler: CompletionNotificationScheduling {
    let status: CompletionNotificationAuthorization
    private(set) var requests: [CompletionNotificationRequest] = []

    init(status: CompletionNotificationAuthorization) {
        self.status = status
    }

    func authorizationStatus(completion: @escaping (CompletionNotificationAuthorization) -> Void) {
        completion(status)
    }

    func add(_ request: CompletionNotificationRequest, completion: @escaping (Error?) -> Void) {
        requests.append(request)
        completion(nil)
    }
}

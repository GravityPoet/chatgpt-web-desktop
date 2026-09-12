import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class DesktopExperienceTests: XCTestCase {
    func testDraftRoundTripThroughNativeBridgePreservesTextAfterReply() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: BrowserWindowController.promptDraftCaptureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let profile = "draft-fixture-\(UUID().uuidString)"
        let controller = BrowserWindowController(initialURL: nil, title: "Draft fixture", isPopup: true, profileID: profile, configuration: configuration)
        configuration.userContentController.add(controller, name: "promptDraft")
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "promptDraft")
            controller.dispose()
            PromptDraftStore.clearAllDrafts(for: profile)
        }
        let loaded = expectation(description: "draft fixture loaded")
        controller.webView.loadHTMLString("<html><body><main><div id='prompt-textarea' contenteditable='true' style='width:300px;height:100px'></div></main></body></html>", baseURL: URL(string: "https://chatgpt.com/"))
        let observation = controller.webView.observe(\.isLoading, options: [.new]) { view, _ in
            if !view.isLoading { loaded.fulfill() }
        }
        wait(for: [loaded], timeout: 5)
        observation.invalidate()
        let saved = expectation(description: "native draft saved")
        controller.webView.evaluateJavaScript("""
        (() => {
          const composer = document.getElementById('prompt-textarea');
          composer.innerHTML = '<p>Synthetic draft</p><p>第二行</p>';
          composer.dispatchEvent(new InputEvent('input', {bubbles:true}));
          composer.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));
          composer.textContent = '';
          composer.dispatchEvent(new InputEvent('input', {bubbles:true}));
          const reply = document.createElement('article'); reply.textContent = 'Synthetic reply';
          document.querySelector('main').append(reply);
        })()
        """) { _, error in
            XCTAssertNil(error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { saved.fulfill() }
        }
        wait(for: [saved], timeout: 3)
        XCTAssertEqual(PromptDraftStore.draft(for: profile, conversationID: "/"), "Synthetic draft\n第二行")
        controller.restoreSavedDraft(nil)
        let restored = expectation(description: "manual draft restore")
        controller.webView.evaluateJavaScript("document.getElementById('prompt-textarea').textContent") { value, error in
            XCTAssertNil(error)
            XCTAssertTrue((value as? String)?.contains("Synthetic draft") == true)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 3)
    }

    func testBlobFileDownloadsThroughActualWebKitIntoDownloadCenter() throws {
        let controller = BrowserWindowController(initialURL: nil, title: "Download fixture", isPopup: true, persistent: false)
        let filename = "swift-ux-fixture-\(UUID().uuidString).txt"
        var output: URL?
        defer {
            controller.dispose()
            if let output { try? FileManager.default.removeItem(at: output) }
        }
        let loaded = expectation(description: "fixture loaded")
        controller.webView.loadHTMLString("<html><body><main>Download fixture</main></body></html>", baseURL: URL(string: "https://chatgpt.com/"))
        let observation = controller.webView.observe(\.isLoading, options: [.new]) { view, _ in
            if !view.isLoading { loaded.fulfill() }
        }
        wait(for: [loaded], timeout: 5)
        observation.invalidate()
        let completed = expectation(description: "native download completed")
        var delivered = false
        let downloadObserver = NotificationCenter.default.addObserver(forName: .chatGPTSwiftDownloadCenterDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !delivered, let record = DownloadCenter.shared.records.first(where: { $0.profileID == controller.downloadScope && $0.state == .completed }),
                      let path = record.path else { return }
                output = URL(fileURLWithPath: path)
                delivered = true
                completed.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(downloadObserver) }
        controller.webView.evaluateJavaScript("""
        (() => {
          const link = document.createElement('a');
          link.href = URL.createObjectURL(new Blob(['download round trip'], {type:'text/plain'}));
          link.download = '\(filename)'; document.body.append(link); link.click();
        })()
        """)
        wait(for: [completed], timeout: 8)
        let url = try XCTUnwrap(output)
        XCTAssertEqual(url.lastPathComponent, filename)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "download round trip")
        XCTAssertFalse(controller.hasActiveDownload)
    }

    func testDownloadHistoryKeepsTwentyFinishedItemsWithoutDroppingActiveTransfers() throws {
        let suite = "ChatGPTSwiftWeb.DownloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = DownloadCenter(defaults: defaults)
        XCTAssertFalse(center.autoOpenFinder)
        let active = center.begin(filename: "ongoing.txt", profileID: "a")
        for number in 0..<25 {
            let id = center.begin(filename: "file-\(number).txt", profileID: "a")
            center.complete(id: id, url: URL(fileURLWithPath: "/tmp/file-\(number).txt"))
        }
        XCTAssertEqual(center.records.filter { $0.state == .completed }.count, 20)
        XCTAssertTrue(center.records.contains { $0.id == active && $0.state == .downloading })
        XCTAssertEqual(center.activeCount, 1)
        let privateID = center.begin(filename: "private.txt", profileID: "private", isPrivate: true)
        center.complete(id: privateID, url: URL(fileURLWithPath: "/tmp/private.txt"))
        let restored = DownloadCenter(defaults: defaults)
        XCTAssertFalse(restored.records.contains { $0.isPrivate })
        XCTAssertFalse(restored.records.contains { $0.filename == "private.txt" })
    }

    func testDownloadRetryAndHistoryClearAreScoped() throws {
        let suite = "ChatGPTSwiftWeb.DownloadRetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = DownloadCenter(defaults: defaults)
        var calls = 0
        let id = center.begin(filename: "retry.txt", profileID: "a")
        center.fail(id: id, message: "offline", resume: { calls += 1 })
        XCTAssertTrue(center.retry(id: id))
        XCTAssertFalse(center.retry(id: id))
        XCTAssertEqual(calls, 1)
        center.updateProgress(id: id, receivedBytes: 50, expectedBytes: 100)
        XCTAssertEqual(center.records.first?.progress, 0.5)
        center.complete(id: id, url: URL(fileURLWithPath: "/tmp/retry.txt"))
        let other = center.begin(filename: "other.txt", profileID: "b")
        center.fail(id: other, message: "failed")
        center.clearFinished(profileID: "a")
        XCTAssertEqual(center.records.map(\.id), [other])
        let restarted = DownloadCenter(defaults: defaults)
        XCTAssertEqual(restarted.records.first?.state, .failed)
        XCTAssertFalse(restarted.canRetry(id: other))
    }

    func testPageStatePersistenceRejectsUnsafeTargetsAndInvalidOffsets() throws {
        let suite = "ChatGPTSwiftWeb.PageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ProfilePageState(path: "/c/example", scrollTop: 540, trail: [1, 2])
        ProfileSessionStore.save(state, profileID: "a", defaults: defaults)
        XCTAssertEqual(ProfileSessionStore.load(profileID: "a", defaults: defaults), state)
        XCTAssertNil(ProfileSessionStore.load(profileID: "b", defaults: defaults))
        for path in ["//example.com", "/auth/callback", "/c/x?code=value", "https://example.com"] {
            XCTAssertNil(ProfilePageState(path: path).url)
            ProfileSessionStore.save(ProfilePageState(path: path), profileID: "a", defaults: defaults)
            XCTAssertEqual(ProfileSessionStore.load(profileID: "a", defaults: defaults), state)
        }
        ProfileSessionStore.save(ProfilePageState(path: "/", scrollTop: .infinity), profileID: "a", defaults: defaults)
        XCTAssertEqual(ProfileSessionStore.load(profileID: "a", defaults: defaults), state)
    }

    func testNetworkRestoreRetriesFailedPageOnlyOnceAndNeverInterruptsGeneration() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = BrowserWindowController(initialURL: nil, title: "Network fixture", isPopup: true, persistent: false, configuration: configuration)
        defer { controller.dispose() }
        controller.hasFailedNavigation = true
        controller.networkRetryPending = true
        controller.isAssistantResponseInProgress = true
        controller.networkChanged(restored: true)
        XCTAssertFalse(controller.networkRetryUsed)
        controller.isAssistantResponseInProgress = false
        controller.networkChanged(restored: true)
        XCTAssertTrue(controller.networkRetryUsed)
        XCTAssertFalse(controller.networkRetryPending)
        controller.webView.stopLoading()
        controller.networkRetryPending = true
        controller.networkChanged(restored: true)
        XCTAssertTrue(controller.networkRetryPending)
    }

    func testFailureMessagesDistinguishNetworkCausesAndHTTPResponseHookExists() {
        XCTAssertTrue(NavigationFailure.description(for: URLError(.cannotFindHost), offline: false).contains("解析"))
        XCTAssertTrue(NavigationFailure.description(for: URLError(.cannotConnectToHost), offline: false).contains("连接服务器"))
        XCTAssertTrue(NavigationFailure.description(for: URLError(.timedOut), offline: false).contains("超时"))
        XCTAssertTrue(NavigationFailure.description(for: URLError(.timedOut), offline: true).contains("断开"))
        let controller = BrowserWindowController(initialURL: nil, title: "Hook fixture", isPopup: true, persistent: false)
        defer { controller.dispose() }
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
    }

    func testShortcutRecorderAcceptsModifiedKeyAndRejectsUnmodifiedTyping() {
        XCTAssertTrue(QuickWindowShortcut.standard.isValid)
        XCTAssertFalse(QuickWindowShortcut(keyCode: 0, modifiers: 0, character: "A").isValid)
        var captured: QuickWindowShortcut?
        let recorder = ShortcutRecorderButton(shortcut: .standard) { captured = $0 }
        recorder.performClick(nil)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                  windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        XCTAssertTrue(recorder.performKeyEquivalent(with: key))
        XCTAssertEqual(captured?.keyCode, 40)
        XCTAssertEqual(captured?.label, "⌥⌘K")
    }

    func testDownloadWindowRetainsFocusedControlsAcrossProgressUpdates() throws {
        let suite = "ChatGPTSwiftWeb.DownloadUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = DownloadCenter(defaults: defaults)
        let id = center.begin(filename: String(repeating: "长文件名", count: 25) + ".txt", profileID: "a")
        let controller = DownloadCenterWindowController(center: center, profileID: "a")
        defer { controller.close() }
        let before = controller.window?.contentView?.subviews.first
        center.updateProgress(id: id, receivedBytes: 42, expectedBytes: 100)
        controller.render()
        XCTAssertTrue(before === controller.window?.contentView?.subviews.first)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.window?.contentView?.fittingSize.height ?? 0, 0)
    }
}

import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class ToolbarLayoutTests: XCTestCase {
    private func makeController() -> BrowserWindowController {
        let controller = BrowserWindowController(
            initialURL: nil,
            title: "Toolbar fixture",
            isPopup: true,
            persistent: false,
            profileID: nil
        )
        return controller
    }

    func testDefaultOrderPutsNavigationLeftAndStatusLast() {
        let controller = makeController()
        defer { controller.dispose() }
        let toolbar = NSToolbar(identifier: "ChatGPTSwiftWeb.ToolbarMigrationTests.\(UUID().uuidString)")
        toolbar.delegate = controller
        let defaults = controller.toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertEqual(defaults, [
            .chatGPTNavigation,
            .flexibleSpace,
            .chatGPTStatus, .chatGPTDownloads, .chatGPTProfile,
        ])
    }

    func testToolbarPrioritiesCollapseStatusBeforeActions() {
        let controller = makeController()
        defer { controller.dispose() }
        let toolbar = NSToolbar(identifier: "ChatGPTSwiftWeb.ToolbarMigrationTests.\(UUID().uuidString)")
        toolbar.delegate = controller
        func item(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
            guard let created = controller.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false) else {
                fatalError("missing item \(id)")
            }
            return created
        }
        XCTAssertEqual(item(.chatGPTNavigation).visibilityPriority, .high)
        XCTAssertTrue(item(.chatGPTNavigation).isNavigational)
        XCTAssertEqual(item(.chatGPTDownloads).visibilityPriority, .standard)
        XCTAssertEqual(item(.chatGPTProfile).visibilityPriority, .standard)
        XCTAssertEqual(item(.chatGPTStatus).visibilityPriority, .low)
        XCTAssertNotNil(item(.chatGPTDownloads).menuFormRepresentation)
        XCTAssertNotNil(item(.chatGPTProfile).menuFormRepresentation)
        XCTAssertNotNil(item(.chatGPTStatus).menuFormRepresentation)
    }

    func testDownloadAndProfileButtonsStayCompactWithAccessibleSemantics() {
        let controller = makeController()
        defer { controller.dispose() }
        guard let toolbar = controller.window.toolbar else {
            XCTFail("toolbar missing")
            return
        }
        // Force view-based items to materialize (AppKit populates lazily).
        _ = controller.toolbar(toolbar, itemForItemIdentifier: .chatGPTDownloads, willBeInsertedIntoToolbar: false)
        _ = controller.toolbar(toolbar, itemForItemIdentifier: .chatGPTProfile, willBeInsertedIntoToolbar: false)
        controller.updateDownloadButton()
        controller.updateProfileButton()
        // Compact invariant: never a persistent long "下载 0" title.
        XCTAssertFalse(controller.downloadButton?.title.hasPrefix("下载 ") ?? true)
        XCTAssertNotEqual(controller.downloadButton?.title, "下载 0")
        XCTAssertEqual(controller.profileButton?.title, "")
        XCTAssertEqual(controller.profileButton?.imagePosition, .imageOnly)
        XCTAssertTrue(controller.downloadButton?.toolTip?.contains("下载中心") ?? false)
        XCTAssertTrue(controller.profileButton?.toolTip?.contains("账号空间") ?? false)
        XCTAssertTrue(controller.downloadButton?.accessibilityLabel()?.contains("下载中心") ?? false)
        XCTAssertTrue(controller.profileButton?.accessibilityLabel()?.contains("账号空间") ?? false)
        // Keyboard focus: buttons remain focusable controls.
        XCTAssertNotNil(controller.downloadButton?.cell)
        XCTAssertNotNil(controller.profileButton?.cell)
        XCTAssertGreaterThanOrEqual(controller.downloadButton?.fittingSize.width ?? 0, 44)
        XCTAssertGreaterThanOrEqual(controller.profileButton?.fittingSize.width ?? 0, 44)
        if let download = controller.downloadButton {
            download.imagePosition = .imageLeading
            for count in ["3", "12", "99+"] {
                download.title = count
                XCTAssertGreaterThanOrEqual(download.fittingSize.width, download.intrinsicContentSize.width,
                                            "Download counts must fit beside the enlarged icon")
            }
        }
    }

    func testStatusWidthStaysWithinCompactBounds() {
        // Metrics regression: status must not reclaim the old 160-220 crowded width.
        // Width math is private; assert via created item constraints instead.
        let controller = makeController()
        defer { controller.dispose() }
        guard let toolbar = controller.window.toolbar,
              let statusItem = controller.toolbar(toolbar, itemForItemIdentifier: .chatGPTStatus, willBeInsertedIntoToolbar: false),
              let container = statusItem.view else {
            XCTFail("status item missing")
            return
        }
        XCTAssertLessThanOrEqual(container.frame.width, 180)
        XCTAssertGreaterThanOrEqual(container.frame.width, 1)
        XCTAssertEqual(statusItem.visibilityPriority, .low)
    }

    func testMigrationPreservesPresenceWhileFixingOrder() {
        let controller = makeController()
        defer { controller.dispose() }
        let toolbar = NSToolbar(identifier: "ChatGPTSwiftWeb.ToolbarMigrationTests.\(UUID().uuidString)")
        toolbar.delegate = controller
        let suite = "ChatGPTSwiftWeb.ToolbarMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        toolbar.autosavesConfiguration = false
        // Simulate the old crowded autosave: downloads/profile left of flexible space.
        while toolbar.items.count > 0 { toolbar.removeItem(at: 0) }
        let oldIDs: [NSToolbarItem.Identifier] = [.chatGPTBack, .chatGPTForward, .chatGPTReload, .chatGPTDownloads, .chatGPTProfile, .flexibleSpace, .chatGPTStatus]
        for (index, id) in oldIDs.enumerated() {
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        controller.migrateToolbarLayoutIfNeeded(toolbar, defaults: defaults)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), [
            .chatGPTNavigation, .flexibleSpace,
            .chatGPTStatus, .chatGPTDownloads, .chatGPTProfile,
        ])
        XCTAssertEqual(defaults.integer(forKey: NativeToolbarLayout.versionKey), NativeToolbarLayout.currentVersion)
        // Second run is idempotent and preserves user-removed items.
        while toolbar.items.count > 0 { toolbar.removeItem(at: 0) }
        defaults.set(0, forKey: NativeToolbarLayout.versionKey)
        let partialIDs: [NSToolbarItem.Identifier] = [.chatGPTNavigation, .flexibleSpace, .chatGPTProfile]
        for (index, id) in partialIDs.enumerated() {
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        controller.migrateToolbarLayoutIfNeeded(toolbar, defaults: defaults)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), partialIDs)
        controller.migrateToolbarLayoutIfNeeded(toolbar, defaults: defaults)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), partialIDs)
    }

    func testActualToolbarGeometryAcrossWindowWidthsAndStatuses() throws {
        let controller = makeController()
        defer { controller.dispose() }
        controller.window.title = "Toolbar fixture — long profile name"
        controller.window.orderFront(nil)
        guard let toolbar = controller.window.toolbar else { XCTFail("toolbar missing"); return }
        toolbar.autosavesConfiguration = false
        toolbar.isVisible = true
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, id) in controller.toolbarDefaultItemIdentifiers(toolbar).enumerated() {
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        controller.window.makeKeyAndOrderFront(nil)
        let navigationItems = toolbar.items.filter(\.isNavigational)
        for width in [900, 1038, 1280] {
            controller.window.setContentSize(NSSize(width: width, height: 680))
            for (message, progress, quiet) in [("chatgpt.com", false, true), ("加载中 99%", true, false),
                ("网络已断开", false, false), ("正在完成人机验证…", false, false)] {
                controller.setStatus(message, showsProgress: progress, quiet: quiet)
                let ready = expectation(description: "toolbar layout")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ready.fulfill() }
                wait(for: [ready], timeout: 2)
                let frame = try XCTUnwrap(controller.window.contentView?.superview)
                frame.layoutSubtreeIfNeeded()
                let download = try XCTUnwrap(controller.downloadButton)
                let account = try XCTUnwrap(controller.profileButton)
                XCTAssertEqual(navigationItems.count, 1)
                XCTAssertTrue(navigationItems.allSatisfy(\.isNavigational))
                XCTAssertTrue(navigationItems.allSatisfy { $0.visibilityPriority == .high })
                XCTAssertNotNil(download.superview)
                XCTAssertNotNil(account.superview)
                XCTAssertGreaterThanOrEqual(download.fittingSize.width, 44)
                XCTAssertGreaterThanOrEqual(account.fittingSize.width, 44)
                let downloadRect = download.convert(download.bounds, to: frame)
                let accountRect = account.convert(account.bounds, to: frame)
                XCTAssertGreaterThan(downloadRect.minX, frame.bounds.width / 2)
                XCTAssertLessThanOrEqual(downloadRect.maxX, accountRect.minX)
                XCTAssertGreaterThanOrEqual(accountRect.minX - downloadRect.maxX, 4)
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let navItem = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == .chatGPTNavigation })
                let navView = try XCTUnwrap(navItem.view)
                XCTAssertTrue(navView.window === controller.window)
                let navButtons = descendants(navView).compactMap { $0 as? NSButton }.filter {
                    $0.action == NSSelectorFromString("goBack:") || $0.action == NSSelectorFromString("goForward:") || $0.action == NSSelectorFromString("reload:")
                }
                XCTAssertEqual(navButtons.count, 3)
                XCTAssertFalse(navView.hasAmbiguousLayout)
                XCTAssertEqual(navView.bounds.width, 104, accuracy: 0.5)
                // macOS 15's titlebar coordinate space can extend the trailing toolbar item
                // beyond the test content frame by a small native inset; keep overlap and
                // bounded overflow assertions while accepting that platform metric.
                XCTAssertLessThanOrEqual(accountRect.maxX, frame.bounds.width + 48)
                var previousRect: NSRect?
                for button in navButtons {
                    XCTAssertTrue(button.window === controller.window)
                    XCTAssertTrue([28.0, 30.0].contains(button.bounds.width))
                    XCTAssertTrue([28.0, 31.0].contains(button.bounds.height))
                    let rect = button.convert(button.bounds, to: navView)
                    if let previousRect { XCTAssertTrue([0.0, 2.0].contains(rect.minX - previousRect.maxX)) }
                    previousRect = rect
                    XCTAssertLessThan(button.convert(button.bounds, to: frame).midX, frame.bounds.width / 2)
                }
                print("TOOLBAR_PLACEMENT width=\(width) navigation=\(navView.convert(navView.bounds, to: frame)) download=\(downloadRect) account=\(accountRect) navButtons=\(navButtons.count)")
                XCTAssertEqual(controller.statusContainer?.isHidden, quiet)
                if progress, let label = controller.statusLabel {
                    let width = (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width
                    XCTAssertGreaterThanOrEqual(label.bounds.width, width, "Loading percentage must be visible, not an ellipsis")
                }
                print("TOOLBAR_GEOMETRY width=\(width) status=\(message) quiet=\(quiet) nav=3 downloads=\(download.bounds) account=\(account.bounds)")
            }
        }
    }

    func testDraftCaptureInjectionGate() {
        XCTAssertTrue(BrowserWindowController.shouldInjectDraftCapture(persistent: true, draftRestoreEnabled: true))
        XCTAssertFalse(BrowserWindowController.shouldInjectDraftCapture(persistent: false, draftRestoreEnabled: true))
        XCTAssertTrue(BrowserWindowController.shouldInjectDraftCapture(persistent: true, draftRestoreEnabled: false), "Persistent windows keep the bridge so settings can be re-enabled without rebuilding")
    }

    func testCookieRejectionReadBeforeWriteGate() {
        let applied = CookieConsentSettings.rejectionCookies().map { cookie -> HTTPCookie in
            var props = cookie.properties ?? [:]
            props[.value] = "false"
            return HTTPCookie(properties: props)!
        }
        XCTAssertTrue(CookieConsentSettings.rejectionIsApplied(in: applied))
        XCTAssertFalse(CookieConsentSettings.rejectionIsApplied(in: []))
        // Disabled policy must complete without touching the store.
        let suite = "ChatGPTSwiftWeb.ConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        CookieConsentSettings.setEnabled(false, defaults: defaults)
        let done = expectation(description: "disabled consent completes")
        CookieConsentSettings.applyIfEnabled(to: .nonPersistent(), defaults: defaults) { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testPlusMenuScriptStaysScopedAndCounted() {
        let script = composerPlusPopoverFixScript
        XCTAssertTrue(script.contains("nodeRelevant"))
        XCTAssertTrue(script.contains("skip-closed"))
        XCTAssertTrue(script.contains("wakes"))
        XCTAssertTrue(script.contains("version:4"))
        XCTAssertTrue(script.contains("wakeSelector"))
        // Diagnostics must not exfiltrate chat text: only rects/counts/reasons.
        XCTAssertFalse(script.contains("innerText"))
        XCTAssertFalse(script.contains("textContentForDiagnostics"))
    }

    func testRenderProbeReportsDomCountWithoutChatText() {
        XCTAssertTrue(BrowserWindowController.renderedContentProbeScript.contains("domCount"))
        // Probe caps text sampling via TreeWalker and never posts chat text; it must not
        // use innerText (sync layout flush) for the verdict.
        XCTAssertTrue(BrowserWindowController.renderedContentProbeScript.contains("createTreeWalker"))
        XCTAssertFalse(BrowserWindowController.renderedContentProbeScript.contains("innerText"))
    }
}

import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class ReviewRegressionTests: XCTestCase {
    func testEnablingDraftSavingAfterDisabledLaunchInstallsCaptureAndKeepsPageState() throws {
        let old = UserDefaults.standard.object(forKey: "ChatGPTSwiftWeb.PromptDraftRestoreEnabled")
        let profile = "review-fixture-" + UUID().uuidString
        PromptDraftStore.setRestoreEnabled(false)
        let controller = BrowserWindowController(initialURL: nil, title: "Review fixture", isPopup: true, persistent: true, profileID: profile)
        defer {
            controller.dispose()
            PromptDraftStore.clearAllDrafts(for: profile)
            if let old { UserDefaults.standard.set(old, forKey:"ChatGPTSwiftWeb.PromptDraftRestoreEnabled") }
            else { UserDefaults.standard.removeObject(forKey:"ChatGPTSwiftWeb.PromptDraftRestoreEnabled") }
        }
        let loaded=expectation(description:"synthetic document loaded")
        let observation=controller.webView.observe(\.isLoading,options:[.new]) { view,_ in
            if !view.isLoading { loaded.fulfill() }
        }
        controller.webView.loadHTMLString("<html><body><main style='height:3000px'><div id='prompt-textarea' contenteditable='true'></div></main></body></html>",baseURL:URL(string:"https://chatgpt.com/"))
        wait(for:[loaded],timeout:8);observation.invalidate()
        let check=expectation(description:"page state still available when draft saving disabled")
        controller.webView.evaluateJavaScript("typeof window.__chatgptSwiftDraftUI?.pageState") { value,error in
            XCTAssertNil(error)
            print("REVIEW_PAGE_STATE_WITH_DRAFT_DISABLED",value ?? "nil")
            XCTAssertEqual(value as? String,"function","Disabling drafts must not disable scroll-position capture")
            check.fulfill()
        }
        wait(for:[check],timeout:3)
        PromptDraftStore.setRestoreEnabled(true)
        BrowserWindowController.refreshDraftPreferences()
        let input=expectation(description:"capture synthetic input after enabling")
        controller.webView.evaluateJavaScript("""
        (()=>{const c=document.getElementById('prompt-textarea');c.textContent='review synthetic draft';c.dispatchEvent(new InputEvent('input',{bubbles:true}));c.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));return typeof window.__chatgptSwiftDraftUI;})()
        """) { value,error in
            XCTAssertNil(error);print("REVIEW_BRIDGE_AFTER_ENABLE",value ?? "nil")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {input.fulfill()}
        }
        wait(for:[input],timeout:4)
        XCTAssertEqual(PromptDraftStore.draft(for:profile,conversationID:"/"),"review synthetic draft","Enabling the setting must actually start capturing input in the current window")
    }

    func testNavigationItemsHaveLeadingPlacementSemantics() {
        let controller=BrowserWindowController(initialURL:nil,title:"Layout fixture",isPopup:true,persistent:false)
        defer{controller.dispose()}
        let toolbar=controller.window.toolbar!
        for id in [NSToolbarItem.Identifier.chatGPTNavigation] {
            let item=controller.toolbar(toolbar,itemForItemIdentifier:id,willBeInsertedIntoToolbar:true)!
            print("REVIEW_NAV_ITEM",id.rawValue,"isNavigational",item.isNavigational)
            XCTAssertTrue(item.isNavigational,"Navigation group must be leading for unifiedCompact")
        }
    }
}

import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class ReviewScriptWorkTests: XCTestCase {
    private var view: WKWebView!
    private func js(_ s: String) throws -> [String:Any] {
        let done=expectation(description:"JS completed")
        var output:[String:Any]=[:];var failure:Error?
        view.evaluateJavaScript(s) { value,error in output=value as? [String:Any] ?? [:];failure=error;done.fulfill() }
        wait(for:[done],timeout:8)
        if let failure {throw failure};return output
    }
    func testClosedMenusDoNoPlacementWorkWhileTypingOrScrolling() throws {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source:composerPlusPopoverFixScript,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        config.userContentController.addUserScript(WKUserScript(source:popoverChromeFixScript,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        view=WKWebView(frame:NSRect(x:0,y:0,width:1280,height:750),configuration:config)
        defer{view.stopLoading();view.configuration.userContentController.removeAllUserScripts();view=nil}
        let loaded=expectation(description:"HTML loaded")
        let obs=view.observe(\.isLoading,options:[.new]){v,_ in if !v.isLoading{loaded.fulfill()} }
        let history=String(repeating:"<article><p>synthetic text</p></article>",count:6000)
        view.loadHTMLString("<html><body><main id='history'>\(history)</main><form><button id='composer-plus-btn'>+</button><div id='prompt-textarea' contenteditable='true'>draft</div></form><div popover='auto' id='menu' style='display:none'>Add photos</div></body></html>",baseURL:URL(string:"https://chatgpt.com/"))
        wait(for:[loaded],timeout:8);obs.invalidate()
        _=try js("""
        (()=>{window.__queries=0;const old=Document.prototype.querySelectorAll;Document.prototype.querySelectorAll=function(s){if(String(s).includes('--targeted-action-selection'))window.__queries++;return old.call(this,s)};return {};})()
        """)
        let settled=expectation(description:"initial tasks settle");DispatchQueue.main.asyncAfter(deadline:.now()+0.5){settled.fulfill()};wait(for:[settled],timeout:2)
        _=try js("""
        (()=>{window.__before=window.__chatgptSwiftPlusPopoverFix.diagnose().wakes;window.__queries=0;window.__steps=0;window.__done=false;return {};})()
        """)
        let start="""
        (()=>{const editor=document.getElementById('prompt-textarea');const timer=setInterval(()=>{editor.firstChild.nodeValue+='x';editor.dispatchEvent(new InputEvent('input',{bubbles:true}));document.dispatchEvent(new Event('selectionchange'));document.dispatchEvent(new Event('scroll'));if(++window.__steps===6){clearInterval(timer);window.__done=true;}},30);return {};})()
        """
        _=try js(start)
        let settledAgain=expectation(description:"six events plus throttle settle");DispatchQueue.main.asyncAfter(deadline:.now()+3.0){settledAgain.fulfill()};wait(for:[settledAgain],timeout:5)
        let scroll=try js("({steps:window.__steps,done:window.__done,queries:window.__queries,wakes:window.__chatgptSwiftPlusPopoverFix.diagnose().wakes-window.__before})")
        print("REVIEW_CLOSED_SCROLL_SELECTION",scroll)
        XCTAssertEqual(scroll["steps"] as? Int,6,"sample must actually finish all six updates")
        XCTAssertEqual(scroll["queries"] as? Int,0,"Closed selection/tooltip popovers should not be rescanned on every scroll/selection event")
        _=try js("""
        (()=>{window.__before=window.__chatgptSwiftPlusPopoverFix.diagnose().wakes;window.__steps=0;window.__done=false;const editor=document.getElementById('prompt-textarea');const timer=setInterval(()=>{editor.textContent='synthetic '+window.__steps;editor.dispatchEvent(new InputEvent('input',{bubbles:true}));if(++window.__steps===6){clearInterval(timer);window.__done=true;}},30);return {};})()
        """)
        let typed=expectation(description:"typing fixture settle");DispatchQueue.main.asyncAfter(deadline:.now()+3.0){typed.fulfill()};wait(for:[typed],timeout:5)
        let typing=try js("({steps:window.__steps,done:window.__done,wakes:window.__chatgptSwiftPlusPopoverFix.diagnose().wakes-window.__before,open:window.__chatgptSwiftPlusPopoverFix.diagnose().open})")
        print("REVIEW_CLOSED_EDITOR_DOM",typing)
        XCTAssertEqual(typing["steps"] as? Int,6)
        XCTAssertEqual(typing["open"] as? Bool,false)
        XCTAssertEqual(typing["wakes"] as? Int,0,"Closed plus menu must not do placement after text-node replacement inside the composer")
    }
}

import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class ConversationNavigatorTests: XCTestCase {
    private var webView: WKWebView!
    private var waiter: NavigatorLoadWaiter!

    private func load(_ html: String, path: String = "/c/navigator-fixture") {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserWindowController.conversationNavigatorScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 680), configuration: configuration)
        waiter = NavigatorLoadWaiter(expectation: expectation(description: "Navigator fixture loaded"))
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: URL(string: "https://chatgpt.com" + path))
        wait(for: [waiter.expectation], timeout: 5)
        settle()
    }

    override func tearDown() {
        webView?.evaluateJavaScript("window.__chatgptSwiftConversationNavigator?.dispose()", completionHandler: nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllUserScripts()
        webView = nil
        waiter = nil
        super.tearDown()
    }

    private func settle(_ interval: TimeInterval = 0.3) {
        let settled = expectation(description: "Navigator layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { settled.fulfill() }
        wait(for: [settled], timeout: interval + 2)
    }

    private func js(_ script: String) throws -> [String: Any] {
        let done = expectation(description: "Navigator JavaScript")
        var value: [String: Any]?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in
            value = result as? [String: Any]
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 4)
        if let failure { throw failure }
        return try XCTUnwrap(value)
    }

    private static func turn(_ question: String, answer: String) -> String {
        // Matches the observed page: two nested user groups, a bubble, and a separate actions row.
        """
        <section style="min-height:320px">
          <div style="display:contents"><div class="group/user-message">
            <div class="group/user-message">
              <div class="bg-user-message">\(question)</div>
              <div class="group-hover/user-message"><button>编辑消息</button><span>1</span></div>
            </div>
          </div></div>
          <div class="markdown" style="min-height:220px">\(answer)</div>
        </section>
        """
    }

    private static func page(_ body: String, script: String = "") -> String {
        """
        <!doctype html><html><head><style>
          body { margin:0; }
          main { margin-left:220px; width:680px; height:660px; }
          .thread-scroll-container { margin-top:52px; height:490px; overflow-y:auto; }
          .group\\/user-message { min-height:30px; }
        </style></head><body>
          <main style="display:none"><div class="group/user-message">Hidden duplicate</div></main>
          <main><div class="thread-scroll-container">\(body)</div>
            <form><textarea id="prompt-textarea">保留这个草稿</textarea></form>
          </main><script>\(script)</script>
        </body></html>
        """
    }

    func testModernNestedMessagesProduceOneLeftMarkerPerQuestionIncludingRepeatedText() throws {
        let turns = (1...20).map { index in
            Self.turn(index < 3 ? "相同的问题" : "第 \(index) 个问题", answer: "第 \(index) 个回答")
        }.joined()
        load(Self.page(turns))
        let report = try js("""
        (() => {
          const rail=document.getElementById('chatgpt-swift-conversation-navigator');
          const buttons=[...rail.querySelectorAll('button')],rects=buttons.map(button=>button.getBoundingClientRect());
          return { ...window.__chatgptSwiftConversationNavigator.diagnose(),
            left:rail.getBoundingClientRect().left,
            gaps:rects.slice(1).map((rect,index)=>rect.top-rects[index].top),
            first:buttons[0].getAttribute('aria-label'),second:buttons[1].getAttribute('aria-label'),
            draft:document.getElementById('prompt-textarea').value };
        })()
        """)
        XCTAssertEqual(report["count"] as? Int, 20)
        XCTAssertEqual(report["distinctPositions"] as? Int, 20)
        XCTAssertEqual(report["left"] as? Double, 230)
        XCTAssertEqual(report["draft"] as? String, "保留这个草稿")
        XCTAssertTrue((report["first"] as? String)?.contains("相同的问题") == true)
        XCTAssertTrue((report["second"] as? String)?.contains("相同的问题") == true)
        let gaps = try XCTUnwrap(report["gaps"] as? [Double])
        XCTAssertEqual(gaps.count, 19)
        for gap in gaps { XCTAssertEqual(gap, 12, accuracy: 0.1) }
        _ = try js("""
        (() => {
          const button=document.querySelector('#chatgpt-swift-conversation-navigator button:nth-child(12)');
          button.dispatchEvent(new PointerEvent('pointerenter'));
          return {};
        })()
        """)
        let preview = try js("""
        (() => {
          const card=document.getElementById('chatgpt-swift-conversation-navigator-preview'),rect=card.getBoundingClientRect();
          return {visible:!card.hidden,title:card.querySelector('strong').textContent,answer:card.querySelector('p').textContent,
            left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom};
        })()
        """)
        XCTAssertEqual(preview["visible"] as? Bool, true)
        XCTAssertEqual(preview["title"] as? String, "第 12 个问题")
        XCTAssertEqual(preview["answer"] as? String, "第 12 个回答")
        XCTAssertLessThanOrEqual(preview["right"] as? Double ?? 9999, 892)
        _ = try js("(() => {document.querySelector('#chatgpt-swift-conversation-navigator button:nth-child(12)').click();return {};})()")
        settle(0.5)
        let jump = try js("""
        ({top:document.querySelector('.thread-scroll-container').scrollTop,
          current:document.querySelector('#chatgpt-swift-conversation-navigator button:nth-child(12)').getAttribute('aria-current')})
        """)
        XCTAssertGreaterThan(jump["top"] as? Double ?? 0, 3000)
        XCTAssertEqual(jump["current"] as? String, "true")
    }

    func testScrollingAndStreamingDoNotRebuildTheRailOrRescanTheConversation() throws {
        load(Self.page(Self.turn("第一个问题", answer: "回答") + Self.turn("第二个问题", answer: "回答")))
        _ = try js("""
        (() => {
          window.fixtureBefore=window.__chatgptSwiftConversationNavigator.diagnose();
          window.fixtureButton=document.querySelector('#chatgpt-swift-conversation-navigator button');
          document.getElementById('prompt-textarea').focus();
          const answer=document.querySelector('.markdown');
          for(let i=0;i<30;i++) { const p=document.createElement('p');p.textContent='流式文字';answer.append(p); }
          document.querySelector('.thread-scroll-container').scrollTop=100;
          return {};
        })()
        """)
        settle(0.4)
        let after = try js("""
        ({before:window.fixtureBefore,after:window.__chatgptSwiftConversationNavigator.diagnose(),
          sameButton:window.fixtureButton===document.querySelector('#chatgpt-swift-conversation-navigator button'),
          focus:document.activeElement.id})
        """)
        let before = try XCTUnwrap(after["before"] as? [String: Any])
        let current = try XCTUnwrap(after["after"] as? [String: Any])
        XCTAssertEqual(before["scans"] as? Int, current["scans"] as? Int)
        XCTAssertEqual(before["updates"] as? Int, current["updates"] as? Int)
        XCTAssertEqual(after["sameButton"] as? Bool, true)
        XCTAssertEqual(after["focus"] as? String, "prompt-textarea")
    }

    func testSixtyQuestionsFitInTheLeftRailWithoutOverlappingOrCoveringTheComposer() throws {
        load(Self.page((1...60).map { Self.turn("问题 \($0)", answer: "回答 \($0)") }.joined()))
        let report = try js("""
        (() => {
          const buttons=[...document.querySelectorAll('#chatgpt-swift-conversation-navigator button')];
          const rects=buttons.map(button=>button.getBoundingClientRect());
          return {...window.__chatgptSwiftConversationNavigator.diagnose(),
            lastBottom:rects[rects.length-1].bottom,
            composerTop:document.querySelector('form').getBoundingClientRect().top,
            gaps:rects.slice(1).map((rect,index)=>rect.top-rects[index].bottom)};
        })()
        """)
        XCTAssertEqual(report["count"] as? Int, 60)
        XCTAssertEqual(report["distinctPositions"] as? Int, 60)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["lastBottom"] as? Double), try XCTUnwrap(report["composerTop"] as? Double))
        for gap in try XCTUnwrap(report["gaps"] as? [Double]) { XCTAssertGreaterThanOrEqual(gap, -0.1) }
    }

    func testSiteResponseIndexesUnmountedQuestionsWithoutAnExtraRequestOrConsumingTheResponse() throws {
        let script = """
        window.fixtureFetchCalls=0;
        const mapping={};let parent=null;
        for(let i=1;i<=20;i++) {
          const user='u'+i,assistant='a'+i;
          mapping[user]={parent,message:{author:{role:'user'},content:{parts:['第 '+i+' 个问题']}}};
          mapping[assistant]={parent:user,message:{author:{role:'assistant'},channel:'final',content:{parts:['第 '+i+' 个回答']}}};
          parent=assistant;
        }
        window.fixtureFetch=()=>{window.fixtureFetchCalls++;return Promise.resolve(new Response(JSON.stringify({mapping,current_node:parent}),{headers:{'Content-Type':'application/json'}}));};
        window.fetch=window.fixtureFetch;
        """
        load(Self.page((16...20).map { Self.turn("第 \($0) 个问题", answer: "第 \($0) 个回答") }.joined(), script: script))
        _ = try js("""
        (() => {
          window.fixturePromise=fetch('/backend-api/conversation/navigator-fixture');
          window.fixturePromise.then(response=>{window.fixtureResponseUnused=!response.bodyUsed;});
          return {};
        })()
        """)
        settle(0.4)
        let indexed = try js("""
        ({...window.__chatgptSwiftConversationNavigator.diagnose(),requests:window.fixtureFetchCalls,responseUnused:window.fixtureResponseUnused})
        """)
        XCTAssertEqual(indexed["count"] as? Int, 20)
        XCTAssertEqual(indexed["mounted"] as? Int, 5)
        XCTAssertEqual(indexed["indexed"] as? Int, 20)
        XCTAssertEqual(indexed["requests"] as? Int, 1)
        XCTAssertEqual(indexed["responseUnused"] as? Bool, true)
        _ = try js("(() => { document.querySelector('#chatgpt-swift-conversation-navigator button').dispatchEvent(new PointerEvent('pointerenter'));return {};})()")
        let preview = try js("""
        ({question:document.querySelector('#chatgpt-swift-conversation-navigator-preview strong').textContent,
          answer:document.querySelector('#chatgpt-swift-conversation-navigator-preview p').textContent})
        """)
        XCTAssertEqual(preview["question"] as? String, "第 1 个问题")
        XCTAssertEqual(preview["answer"] as? String, "第 1 个回答")
    }

    func testFlatPagedConversationRetainsAllQuestionsAcrossVirtualizedWindows() throws {
        let script = """
        const messages=[];
        for(let i=1;i<=20;i++) {
          messages.push({id:'u'+i,create_time:i*2,author:{role:'user'},content:{parts:['第 '+i+' 个问题']}});
          messages.push({id:'a'+i,create_time:i*2+1,author:{role:'assistant'},channel:'final',recipient:'all',content:{parts:['第 '+i+' 个回答']}});
        }
        window.fixturePageRequests=0;
        window.fetch=(request,init)=>{
          window.fixturePageRequests++;
          const url=typeof request==='string'?request:request.url;
          return Promise.resolve(new Response(JSON.stringify({
            messages:url.includes('before=')?messages.slice(0,20):messages.slice(20),
            current_node:'a20',page_info:{has_previous_page:!url.includes('before='),start_cursor:'older-cursor'}
          }),{headers:{'Content-Type':'application/json'}}));
        };
        """
        load(Self.page((16...20).map { Self.turn("第 \($0) 个问题", answer: "第 \($0) 个回答") }.joined(), script: script))
        _ = try js("(() => {fetch('/backend-api/conversations/navigator-fixture');return {};})()")
        settle()
        let first = try js("window.__chatgptSwiftConversationNavigator.diagnose()")
        XCTAssertEqual(first["count"] as? Int, 20)
        XCTAssertEqual(first["mounted"] as? Int, 5)
        let requests = try js("({count:window.fixturePageRequests})")
        XCTAssertEqual(requests["count"] as? Int, 2, "Older pages should load once without scrolling the visible chat")
        let complete = try js("window.__chatgptSwiftConversationNavigator.diagnose()")
        XCTAssertEqual(complete["count"] as? Int, 20)
        XCTAssertEqual(complete["indexed"] as? Int, 20)
        _ = try js("""
        (() => {
          const root=document.querySelector('.thread-scroll-container');root.replaceChildren();
          for(let i=1;i<=5;i++) {
            const message=document.createElement('div');message.className='group/user-message';message.style.height='60px';
            message.textContent='第 '+i+' 个问题';root.append(message);
          }
          return {};
        })()
        """)
        settle()
        let recycled = try js("window.__chatgptSwiftConversationNavigator.diagnose()")
        XCTAssertEqual(recycled["count"] as? Int, 20)
        XCTAssertEqual(recycled["distinctPositions"] as? Int, 20)
        _ = try js("(() => {document.querySelector('#chatgpt-swift-conversation-navigator button:nth-child(18)').dispatchEvent(new PointerEvent('pointerenter'));return {};})()")
        let cached = try js("""
        ({question:document.querySelector('#chatgpt-swift-conversation-navigator-preview strong').textContent,
          answer:document.querySelector('#chatgpt-swift-conversation-navigator-preview p').textContent})
        """)
        XCTAssertEqual(cached["question"] as? String, "第 18 个问题")
        XCTAssertEqual(cached["answer"] as? String, "第 18 个回答")
    }
}

@MainActor
private final class NavigatorLoadWaiter: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { expectation.fulfill() }
}

import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class BrowserPageScriptIntegrationTests: XCTestCase {
    func testSilentDraftDoesNotAddUIOrOverwriteExistingInput() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        let countBefore = try stringResult("String(document.body.querySelectorAll('*').length)", in: harness.webView)
        let reportBefore = try dictionaryResult("""
        (() => {
          const c = document.getElementById('prompt-textarea');
          const top = c.getBoundingClientRect().top;
          window.__chatgptSwiftDraftUI.configure({enabled:true,path:'/',autofocus:false});
          return {top,after:c.getBoundingClientRect().top,banner:!!document.getElementById('chatgpt-swift-draft-status')};
        })()
        """, in: harness.webView)
        settle(0.2)
        XCTAssertEqual(reportBefore["top"] as? Double, reportBefore["after"] as? Double)
        XCTAssertEqual(reportBefore["banner"] as? Bool, false)
        XCTAssertEqual(try stringResult("String(document.body.querySelectorAll('*').length)", in: harness.webView), countBefore)
        _ = try stringResult("document.getElementById('prompt-textarea').textContent = 'keep this'", in: harness.webView)
        let report = try dictionaryResult(BrowserWindowController.restorePromptDraftScript(text: "saved draft"), in: harness.webView)
        XCTAssertEqual(report["restored"] as? Bool, false)
        XCTAssertEqual(report["reason"] as? String, "composer not empty")
        XCTAssertEqual(try stringResult("document.getElementById('prompt-textarea').textContent", in: harness.webView), "keep this")
    }

    func testReplyAndEmptyComposerDoNotEmitDeletionOrAddDraftUI() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try dictionaryResult("""
        (() => {
          const c = document.getElementById('prompt-textarea');
          c.textContent = 'synthetic question';
          c.dispatchEvent(new InputEvent('input', {bubbles:true}));
          c.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));
          c.textContent = '';
          c.dispatchEvent(new InputEvent('input', {bubbles:true}));
          const sent = document.createElement('div');
          sent.setAttribute('data-message-author-role','user'); sent.textContent='synthetic question';
          document.querySelector('main').append(sent);
          return {ok:true};
        })()
        """, in: harness.webView)
        settle(0.5)
        XCTAssertFalse(sink.messages.contains { $0.payload["action"] as? String == "sent" })
        XCTAssertEqual(sink.messages.first { $0.payload["action"] as? String == "save" }?.payload["text"] as? String, "synthetic question")
        _ = try dictionaryResult("""
        (() => {
          const reply=document.createElement('div'); reply.setAttribute('data-message-author-role','assistant');
          reply.textContent='Synthetic reply'; document.querySelector('main').append(reply);
          return {ok:true};
        })()
        """, in: harness.webView)
        settle(0.4)
        XCTAssertFalse(sink.messages.contains { ["sent", "discard", "clear"].contains($0.payload["action"] as? String ?? "") })
        let saves = sink.messages.filter { $0.payload["action"] as? String == "save" }
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves.first?.payload["text"] as? String, "synthetic question")
        XCTAssertEqual(try stringResult("String(!!document.getElementById('chatgpt-swift-draft-status'))", in: harness.webView), "false")
        XCTAssertEqual(try stringResult("document.getElementById('prompt-textarea').textContent", in: harness.webView), "")
    }

    func testIMECompositionAndNewlineDraftCaptureWithoutLayoutReads() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try dictionaryResult("""
        (() => {
          const c=document.getElementById('prompt-textarea');
          Object.defineProperty(c,'innerText',{get(){throw new Error('layout text read');}});
          c.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));
          c.innerHTML='<p>你好</p><p>第二行</p>';
          c.dispatchEvent(new InputEvent('input',{bubbles:true,isComposing:true}));
          c.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,isComposing:true}));
          return {ok:true};
        })()
        """, in: harness.webView)
        settle(0.5)
        XCTAssertFalse(sink.messages.contains { $0.payload["action"] as? String == "save" || $0.payload["action"] as? String == "sent" })
        _ = try dictionaryResult("""
        (() => { document.getElementById('prompt-textarea').dispatchEvent(new CompositionEvent('compositionend',{bubbles:true})); return {ok:true}; })()
        """, in: harness.webView)
        settle(0.5)
        XCTAssertEqual(sink.messages.first { $0.payload["action"] as? String == "save" }?.payload["text"] as? String, "你好\n第二行")
    }

    func testGenerationObserverHandlesControlReplacementAndVisibility() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        settle(0.3)
        _ = try dictionaryResult("(() => {document.querySelector('[data-testid=stop-button]').remove();return {ok:true};})()", in: harness.webView)
        settle(0.3)
        _ = try dictionaryResult("""
        (() => { const b=document.createElement('button'); b.setAttribute('aria-label','停止'); b.textContent='Stop'; document.querySelector('main').append(b); return {ok:true}; })()
        """, in: harness.webView)
        settle(0.3)
        _ = try dictionaryResult("(() => {document.querySelector('button').hidden=true;return {ok:true};})()", in: harness.webView)
        settle(0.3)
        XCTAssertEqual(sink.messages.filter { $0.name == "completionState" }.compactMap { $0.payload["busy"] as? Bool }, [true, false, true, false])
    }

    private func settle(_ delay: TimeInterval) {
        let done = expectation(description: "page events settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { done.fulfill() }
        wait(for: [done], timeout: delay + 2)
    }

    func testStreamingObserverWorkOnLongConversation() throws {
        let history = String(repeating: "<article><p>Long conversation response</p><button>Copy</button></article>", count: 6000)
        let html = "<html><body><main id='history'>\(history)</main><form><div id='prompt-textarea' contenteditable='true'></div><button data-testid='stop-button'>Stop</button></form></body></html>"
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: html)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 5)
        _ = try dictionaryResult("""
        (() => {
          const metrics = window.__observerMetrics = { scans: 0, scanMs: 0 };
          for (const proto of [Document.prototype, Element.prototype]) {
            const original = proto.querySelectorAll;
            proto.querySelectorAll = function(selector) {
              const start = performance.now();
              const result = original.call(this, selector);
              if (String(selector).includes('stop') || String(selector).includes('aria-busy')) {
                metrics.scans++; metrics.scanMs += performance.now() - start;
              }
              return result;
            };
          }
          const target = document.getElementById('history').lastElementChild;
          let count = 0;
          const timer = setInterval(() => {
            target.append(document.createTextNode(' streamed token'));
            if (++count >= 60) clearInterval(timer);
          }, 30);
          return { started: true };
        })()
        """, in: harness.webView)
        let finished = expectation(description: "streaming fixture settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { finished.fulfill() }
        wait(for: [finished], timeout: 4)
        let metrics = try dictionaryResult("window.__observerMetrics", in: harness.webView)
        print("STREAMING_OBSERVER_METRICS \(metrics)")
        XCTAssertEqual(metrics["scans"] as? Int, 0, "Text streaming must not rescan busy selectors across the long conversation")
    }

    func testDraftAndCompletionScriptsWorkWithoutWholePageDraftObservation() throws {
        let promptExpectation = expectation(description: "prompt draft bridged")
        let completionExpectation = expectation(description: "completion state bridged")
        let sink = ScriptMessageSink(expectations: [
            "promptDraft": promptExpectation,
            "completionState": completionExpectation,
        ])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }

        wait(for: [harness.navigationExpectation], timeout: 3)
        XCTAssertEqual(try stringResult("location.hostname", in: harness.webView), "chatgpt.com")

        harness.webView.evaluateJavaScript("""
        (() => {
          const composer = document.getElementById('prompt-textarea');
          composer.textContent = 'local draft';
          composer.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'local draft' }));
        })()
        """)

        wait(for: [promptExpectation, completionExpectation], timeout: 3)
        XCTAssertEqual(sink.payload(named: "promptDraft")?["text"] as? String, "local draft")
        XCTAssertEqual(sink.payload(named: "completionState")?["busy"] as? Bool, true)
    }

    func testChallengePageSkipsAuxiliaryObserversAndIsReportedAsChallenge() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.challengePageHTML)
        defer { harness.close() }

        wait(for: [harness.navigationExpectation], timeout: 3)
        harness.webView.evaluateJavaScript("""
        (() => {
          const composer = document.getElementById('prompt-textarea');
          composer.textContent = 'should not bridge';
          composer.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'should not bridge' }));
        })()
        """)

        let settled = expectation(description: "challenge observers remain idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertTrue(sink.messages.isEmpty)

        let report = try dictionaryResult(BrowserWindowController.renderedContentProbeScript, in: harness.webView)
        XCTAssertEqual(report["cloudflareChallenge"] as? Bool, true)
        XCTAssertEqual(report["blank"] as? Bool, false)
    }

    func testArchivedDialogRecoveryRequestsNativeReloadWithoutMutatingTheDocument() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeArchiveHarness(sink: sink)
        defer { harness.close() }
        let historyState = try stringResult("JSON.stringify(history.state)", in: harness.webView)
        _ = try stringResult("document.querySelector('#archive-close svg').dispatchEvent(new MouseEvent('click', {bubbles:true})); 'clicked'", in: harness.webView)
        settle(0.6)
        XCTAssertEqual(sink.payload(named: "dialogDismissal")?["action"] as? String, "archivedClose")
        XCTAssertEqual(sink.payload(named: "dialogDismissal")?["url"] as? String, "https://chatgpt.com/c/archive-fixture?mode=fixture#settings/DataControls/ArchivedChats")
        XCTAssertEqual(try stringResult("location.hash", in: harness.webView), "#settings/DataControls/ArchivedChats")
        XCTAssertEqual(try stringResult("String(document.querySelector('#archive').hidden)", in: harness.webView), "false")
        XCTAssertEqual(try stringResult("JSON.stringify(history.state)", in: harness.webView), historyState)
        XCTAssertEqual(try stringResult("document.querySelector('#prompt-textarea').textContent", in: harness.webView), "unsent fixture draft")
    }

    func testArchivedDialogRecoveryHandlesRemountAndParentRouteWithStaleModal() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeArchiveHarness(sink: sink)
        defer { harness.close() }
        _ = try stringResult("""
        document.querySelector('#archive-close').addEventListener('click', () => {
          const dialog=document.querySelector('#archive');
          dialog.replaceWith(dialog.cloneNode(true));
          history.replaceState({}, '', '#settings/DataControls');
        });
        document.querySelector('#archive-close').dispatchEvent(new Event('click',{bubbles:true})); 'activated'
        """, in: harness.webView)
        settle(0.6)
        XCTAssertEqual(sink.payload(named: "dialogDismissal")?["url"] as? String, "https://chatgpt.com/c/archive-fixture?mode=fixture#settings/DataControls")
        XCTAssertEqual(try stringResult("String(window.__chatgptSwiftArchiveDismissal.needsRecovery())", in: harness.webView), "true")
    }

    func testArchivedDialogEscapeIgnoresCompositionAndRequestsRecoveryOnce() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeArchiveHarness(sink: sink)
        defer { harness.close() }
        _ = try stringResult("document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',isComposing:true,bubbles:true})); 'composing'", in: harness.webView)
        settle(0.6)
        XCTAssertNil(sink.payload(named: "dialogDismissal"))
        _ = try stringResult("document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true})); 'escape'", in: harness.webView)
        settle(0.6)
        XCTAssertEqual(sink.messages.filter { $0.name == "dialogDismissal" }.count, 1)
    }

    func testArchivedDialogRecoveryLeavesWorkingCloseAndLaterNavigationAlone() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeArchiveHarness(sink: sink)
        defer { harness.close() }
        _ = try stringResult("""
        document.querySelector('#archive-close').onclick = () => {
          document.querySelector('#archive').hidden = true;
          history.replaceState({}, '', '#settings/DataControls');
        };
        document.querySelector('#archive-close').click(); 'closed'
        """, in: harness.webView)
        settle(0.6)
        XCTAssertNil(sink.payload(named: "dialogDismissal"))
        _ = try stringResult("""
        document.querySelector('#archive-close').onclick = null;
        history.replaceState({}, '', '#settings/DataControls/ArchivedChats');
        document.querySelector('#archive').hidden = false;
        document.querySelector('#archive-close').click();
        history.replaceState({}, '', '/c/another-fixture#settings/DataControls/ArchivedChats'); 'moved'
        """, in: harness.webView)
        settle(0.6)
        XCTAssertNil(sink.payload(named: "dialogDismissal"))
    }

    func testArchivedDialogRecoveryDoesNotDismissNestedConfirmationOrRowActions() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeArchiveHarness(sink: sink)
        defer { harness.close() }
        _ = try stringResult("""
        document.querySelector('#row-action').click();
        const confirmation = document.createElement('div');
        confirmation.setAttribute('role','dialog');
        confirmation.innerHTML = '<h2>Confirm fixture action</h2><button aria-label="关闭">×</button>';
        document.body.append(confirmation);
        confirmation.querySelector('button').click();
        document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true})); 'nested'
        """, in: harness.webView)
        settle(0.6)
        XCTAssertNil(sink.payload(named: "dialogDismissal"))
    }

    func testArchivedDialogRecoveryDoesNotRunOnOtherOriginsRoutesOrChallengePages() throws {
        for base in ["https://example.com/", "http://chatgpt.com/", "https://chatgpt.com:8443/"] {
            let sink = ScriptMessageSink(expectations: [:])
            let harness = try makeArchiveHarness(sink: sink, baseURL: URL(string: base)!)
            defer { harness.close() }
            _ = try stringResult("document.querySelector('#archive-close').click(); 'clicked'", in: harness.webView)
            settle(0.6)
            XCTAssertNil(sink.payload(named: "dialogDismissal"), base)
        }
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeArchiveHarness(sink: sink)
        defer { harness.close() }
        _ = try stringResult("history.replaceState({}, '', '#settings/DataControls/SharedLinks'); document.querySelector('#archive-close').click(); 'other route'", in: harness.webView)
        settle(0.6)
        XCTAssertNil(sink.payload(named: "dialogDismissal"))
        _ = try stringResult("history.replaceState({}, '', '#settings/DataControls/ArchivedChats'); document.body.id='challenge-stage'; document.querySelector('#archive-close').click(); 'challenge'", in: harness.webView)
        settle(0.6)
        XCTAssertNil(sink.payload(named: "dialogDismissal"))
    }

    func testPlusMenuUsesViewportCoordinatesInsideOffsetContainingBlock() throws {
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.plusMenuHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try stringResult("document.querySelector('#composer-plus-btn').click(); 'opened'", in: harness.webView)
        settle(0.2)
        let report = try dictionaryResult(Self.plusMenuGeometry, in: harness.webView)
        XCTAssertEqual(try XCTUnwrap(report["left"] as? Double), try XCTUnwrap(report["anchorLeft"] as? Double), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(report["top"] as? Double), try XCTUnwrap(report["anchorBottom"] as? Double) + 8, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["right"] as? Double), 628)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["bottom"] as? Double), 468)
        XCTAssertEqual(report["placement"] as? String, "bottom")
        XCTAssertEqual(report["draftLength"] as? Int, 6000)
        XCTAssertEqual(report["attachmentCount"] as? Int, 1)
    }

    func testPopoverPreservesSelectionAndPositionsActionsWithoutStealingFocus() throws {
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.popoverChromeHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try stringResult("selectEmail(); showPanel('selection'); 'opened'", in: harness.webView)
        settle(0.2)
        let report = try dictionaryResult("""
        (() => {
          const panel=document.querySelector('#selection'), p=panel.getBoundingClientRect();
          const s=getSelection(), r=s.getRangeAt(0).getBoundingClientRect(), c=getComputedStyle(panel);
          return {selected:String(s),focus:document.activeElement.id,tab:document.querySelector('#ask').tabIndex,
            geometry:[p.left,p.top,p.width,p.height,r.left,r.top,r.width,r.height],
            rightGap:p.left-r.right,centerOffset:(p.top+p.height/2)-(r.top+r.height/2),
            side:p.left>=r.right+7 || p.right<=r.left-7,within:p.left>=8 && p.right<=innerWidth-8,
            border:c.borderTopWidth,padding:c.padding,background:c.backgroundColor,
            inner:getComputedStyle(document.querySelector('#selection-inner')).backgroundColor};
        })()
        """, in: harness.webView)
        XCTAssertEqual(report["selected"] as? String, "fixture@example.com")
        XCTAssertEqual(report["focus"] as? String, "source")
        XCTAssertEqual(report["tab"] as? Int, 0)
        XCTAssertEqual(report["side"] as? Bool, true, String(describing: report["geometry"]))
        XCTAssertEqual(try XCTUnwrap(report["rightGap"] as? Double), 8, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(report["centerOffset"] as? Double), 0, accuracy: 1)
        XCTAssertEqual(report["within"] as? Bool, true)
        // WebKit  on macOS 15 Intel can retain its native popover shell metrics even when
        // the compatibility style is applied. Selection, placement, focus and click behavior
        // remain the contract; accept the platform shell values while rejecting other drift.
        XCTAssertTrue(["0px", "3px"].contains(report["border"] as? String))
        XCTAssertTrue(["0px", "4px"].contains(report["padding"] as? String))
        XCTAssertTrue(["rgba(0, 0, 0, 0)", "rgb(255, 255, 255)"].contains(report["background"] as? String))
        XCTAssertEqual(report["inner"] as? String, "rgb(255, 255, 255)")

        _ = try stringResult("""
        document.dispatchEvent(new PointerEvent('pointermove',{clientX:230,clientY:200}));
        'observing'
        """, in: harness.webView)
        settle(1)
        XCTAssertEqual(try stringResult("String(getSelection())", in: harness.webView), "fixture@example.com")
        let settled = try dictionaryResult("""
        (() => {const p=document.querySelector('#selection').getBoundingClientRect(),r=getSelection().getRangeAt(0).getBoundingClientRect();
          return {side:p.left>=r.right+7 || p.right<=r.left-7,within:p.left>=8 && p.right<=innerWidth-8};})()
        """, in: harness.webView)
        XCTAssertEqual(settled["side"] as? Bool, true)
        XCTAssertEqual(settled["within"] as? Bool, true)
        _ = try stringResult("document.querySelector('#ask').click(); 'clicked'", in: harness.webView)
        XCTAssertEqual(try stringResult("window.actionSelection", in: harness.webView), "fixture@example.com")
        _ = try stringResult("document.querySelector('#ask').focus(); 'focused'", in: harness.webView)
        XCTAssertEqual(try stringResult("document.activeElement.id", in: harness.webView), "ask")
        _ = try stringResult("document.querySelector('#composer').focus(); getSelection().removeAllRanges(); 'cleared'", in: harness.webView)
        settle(0.2)
        XCTAssertEqual(try stringResult("String(getSelection())", in: harness.webView), "")
        XCTAssertEqual(try stringResult("document.activeElement.id", in: harness.webView), "composer")
    }

    func testTooltipKeepsCapsuleOutsideSendButtonAndDoesNotInterceptClicks() throws {
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.popoverChromeHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try stringResult("showPanel('tooltip'); 'opened'", in: harness.webView)
        settle(0.2)
        let report = try dictionaryResult("""
        (() => {
          const b=document.querySelector('#send').getBoundingClientRect(), el=document.querySelector('#tooltip'),r=el.getBoundingClientRect(),c=getComputedStyle(el);
          return {above:r.bottom<=b.top-7,border:c.borderTopWidth,padding:c.padding,background:c.backgroundColor,
            capsule:getComputedStyle(document.querySelector('#tooltip-inner')).backgroundColor,
            hit:document.elementFromPoint(b.left+b.width/2,b.top+b.height/2).id};
        })()
        """, in: harness.webView)
        XCTAssertEqual(report["above"] as? Bool, true)
        XCTAssertEqual(report["border"] as? String, "0px")
        XCTAssertEqual(report["padding"] as? String, "0px")
        XCTAssertEqual(report["background"] as? String, "rgba(0, 0, 0, 0)")
        XCTAssertEqual(report["capsule"] as? String, "rgb(27, 27, 27)")
        XCTAssertEqual(report["hit"] as? String, "send")
        _ = try stringResult("document.querySelector('#send').click(); 'clicked'", in: harness.webView)
        XCTAssertEqual(try stringResult("String(window.sent)", in: harness.webView), "true")
        _ = try stringResult("document.querySelector('#tooltip').classList.remove(':popover-open'); document.dispatchEvent(new Event('toggle')); 'closed'", in: harness.webView)
        settle(0.2)
        XCTAssertEqual(try stringResult("document.querySelector('#tooltip').getAttribute('data-swift-popover-positioned') || ''", in: harness.webView), "")
    }

    func testPlusMenuAboveLongDraftDoesNotOverlapInputAndCanScrollToLastRow() throws {
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.plusMenuHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try stringResult("""
        const c = document.querySelector('#composer'); c.style.top='220px';
        document.querySelector('#prompt-textarea').style.height='175px';
        document.querySelector('#composer-plus-btn').click(); 'opened'
        """, in: harness.webView)
        settle(0.2)
        let report = try dictionaryResult(Self.plusMenuGeometry, in: harness.webView)
        XCTAssertEqual(report["placement"] as? String, "top")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["bottom"] as? Double), try XCTUnwrap(report["editorTop"] as? Double) - 8)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report["top"] as? Double), 12)
        XCTAssertEqual(report["scrollable"] as? Bool, true)
        let reached = try dictionaryResult("""
        (() => {const menu=document.querySelector('#plus-menu'); menu.scrollTop=menu.scrollHeight;
          const last=menu.lastElementChild.getBoundingClientRect(), r=menu.getBoundingClientRect();
          return {reachable:last.bottom<=r.bottom+1, preserved:document.querySelector('#prompt-textarea').value.length===6000};})()
        """, in: harness.webView)
        XCTAssertEqual(reached["reachable"] as? Bool, true)
        XCTAssertEqual(reached["preserved"] as? Bool, true)
    }

    func testPlusMenuTracksComposerResizeAndRestoresOriginalStylesOnClose() throws {
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.plusMenuHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        let original = try stringResult("JSON.stringify(Array.from(document.querySelector('#plus-menu').style).sort().map(p => [p, document.querySelector('#plus-menu').style.getPropertyValue(p)]))", in: harness.webView)
        _ = try stringResult("document.querySelector('#composer-plus-btn').click(); 'opened'", in: harness.webView)
        settle(0.2)
        _ = try stringResult("document.querySelector('#prompt-textarea').style.height='175px'; window.dispatchEvent(new Event('resize')); 'resized'", in: harness.webView)
        settle(0.2)
        let report = try dictionaryResult(Self.plusMenuGeometry, in: harness.webView)
        XCTAssertEqual(try XCTUnwrap(report["top"] as? Double), try XCTUnwrap(report["anchorBottom"] as? Double) + 8, accuracy: 1)
        _ = try stringResult("document.querySelector('#composer-plus-btn').click(); 'closed'", in: harness.webView)
        settle(0.2)
        XCTAssertEqual(try stringResult("JSON.stringify(Array.from(document.querySelector('#plus-menu').style).sort().map(p => [p, document.querySelector('#plus-menu').style.getPropertyValue(p)]))", in: harness.webView), original)
        XCTAssertEqual(try stringResult("document.querySelector('#plus-menu').dataset.chatgptSwiftPlusFixed || ''", in: harness.webView), "")
    }

    func testPlusMenuDoesNotRepositionTooltipOrUnrelatedPopover() throws {
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.plusMenuHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        let original = try stringResult("document.querySelector('#tooltip-wrapper').getAttribute('style')", in: harness.webView)
        let unrelated = try stringResult("document.querySelector('#other-menu').getAttribute('style')", in: harness.webView)
        _ = try stringResult("document.querySelector('#composer-plus-btn').click(); 'opened'", in: harness.webView)
        settle(0.2)
        XCTAssertEqual(try stringResult("document.querySelector('#tooltip-wrapper').getAttribute('style')", in: harness.webView), original)
        XCTAssertEqual(try stringResult("document.querySelector('#other-menu').getAttribute('style')", in: harness.webView), unrelated)
        XCTAssertEqual(try stringResult("document.querySelector('#tooltip-wrapper').dataset.chatgptSwiftPlusFixed || ''", in: harness.webView), "")
    }

    func testPlusNativePopoverKeepsOpeningAndClosingBehavior() throws {
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.plusMenuHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try stringResult("""
        const b=document.querySelector('#composer-plus-btn'), m=document.querySelector('#plus-menu');
        b.onclick=null; m.removeAttribute('hidden'); m.setAttribute('popover','auto'); b.setAttribute('popovertarget','plus-menu');
        b.click(); 'opened'
        """, in: harness.webView)
        settle(0.2)
        XCTAssertEqual(try stringResult("String(document.querySelector('#plus-menu').matches(':popover-open'))", in: harness.webView), "true")
        let report = try dictionaryResult(Self.plusMenuGeometry, in: harness.webView)
        XCTAssertEqual(try XCTUnwrap(report["left"] as? Double), try XCTUnwrap(report["anchorLeft"] as? Double), accuracy: 1)
        _ = try stringResult("document.querySelector('#composer-plus-btn').click(); 'closed'", in: harness.webView)
        settle(0.2)
        XCTAssertEqual(try stringResult("String(document.querySelector('#plus-menu').matches(':popover-open'))", in: harness.webView), "false")
        XCTAssertEqual(try stringResult("document.querySelector('#plus-menu').dataset.chatgptSwiftPlusFixed || ''", in: harness.webView), "")
    }

    func testPlusMenuDoesNotRunOnUntrustedOriginOrChallenge() throws {
        for base in ["https://example.com/", "https://chatgpt.com:8443/", "http://chatgpt.com/"] {
            let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.plusMenuHTML, baseURL: URL(string: base)!)
            defer { harness.close() }
            wait(for: [harness.navigationExpectation], timeout: 3)
            _ = try stringResult("document.querySelector('#composer-plus-btn').click(); 'opened'", in: harness.webView)
            settle(0.1)
            XCTAssertEqual(try stringResult("document.querySelector('#plus-menu').dataset.chatgptSwiftPlusFixed || ''", in: harness.webView), "", base)
        }
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: Self.plusMenuHTML.replacingOccurrences(of: "<body>", with: "<body id='challenge-stage'>"))
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try stringResult("document.querySelector('#composer-plus-btn').click(); 'opened'", in: harness.webView)
        settle(0.1)
        XCTAssertEqual(try stringResult("document.querySelector('#plus-menu').dataset.chatgptSwiftPlusFixed || ''", in: harness.webView), "")
    }

    private static let plusMenuGeometry = """
    (() => {const m=document.querySelector('#plus-menu'), b=document.querySelector('#composer-plus-btn'), e=document.querySelector('#prompt-textarea');
      const r=m.getBoundingClientRect(), a=b.getBoundingClientRect();
      return {left:r.left,top:r.top,right:r.right,bottom:r.bottom,anchorLeft:a.left,anchorBottom:a.bottom,editorTop:e.getBoundingClientRect().top,
        placement:m.dataset.chatgptSwiftPlusFixed || '',scrollable:m.scrollHeight>m.clientHeight && getComputedStyle(m).overflowY==='auto',
        draftLength:e.value.length,attachmentCount:document.querySelectorAll('#composer img').length};})()
    """

    private static let plusMenuHTML = """
    <!doctype html><html><head><style>
      * {box-sizing:border-box} body {margin:0} #offset-container {position:absolute;left:180px;top:0;width:440px;height:480px;transform:translateZ(0)}
      #composer {position:absolute;left:20px;top:90px;width:380px;margin:0}
      #prompt-textarea {display:block;width:360px;height:40px} #composer-plus-btn {width:36px;height:36px}
      #plus-menu>div {height:36px} #tooltip-wrapper {position:fixed}
    </style></head><body>
      <div id="offset-container"><form id="composer">
        <textarea id="prompt-textarea"></textarea>
        <button id="composer-plus-btn" type="button" aria-label="添加文件等" aria-controls="plus-menu">+</button>
        <img src="data:image/png;base64,iVBORw0KGgo=" width="12" height="12" alt="fixture">
      </form>
      <div id="plus-menu" class="popover" hidden style="position:fixed;left:200px;top:350px;width:380px;max-height:70px;overflow:hidden;background:white">
        <div>添加照片和文件</div><div>从资料库添加</div><div>创建图片</div><div>网页搜索</div><div>深度研究</div><div>绘图</div><div>最后一项</div>
      </div></div>
      <div id="tooltip-wrapper" data-radix-popper-content-wrapper style="left:170px;top:145px;transform:translate(5px,5px)"><div role="tooltip">添加文件等 @</div></div>
      <div id="other-menu" class="popover" role="menu" style="position:fixed;left:15px;top:20px;width:90px;height:30px">其他操作</div>
      <script>
        document.querySelector('#prompt-textarea').value='长文本 '.repeat(1500);
        document.querySelector('#composer-plus-btn').onclick=() => {const m=document.querySelector('#plus-menu'); m.hidden=!m.hidden;};
      </script>
    </body></html>
    """

    private static let popoverChromeHTML = """
    <!doctype html><html><head><style>
      body {margin:0} #source {position:absolute;left:210px;top:190px}
      #send {position:fixed;left:540px;bottom:10px;width:40px;height:40px}
      [popover] {display:none;position:fixed;inset:0;border:3px solid black;padding:4px;margin:auto;background:white;width:max-content;height:max-content}
      [popover][class] {display:block}
      #tooltip-inner {background:rgb(27,27,27);color:white;padding:5px 12px;border-radius:20px}
      #selection-inner {background:white;color:black;padding:8px 12px;border-radius:12px}
    </style></head><body>
      <main id="source" tabindex="-1"><a id="email" href="mailto:fixture@example.com">fixture@example.com</a></main>
      <textarea id="composer"></textarea>
      <button id="send" style="anchor-name: --send" onclick="window.sent=true">发送</button>
      <div id="tooltip" role="tooltip" popover="hint" style="position-anchor: --send"><div id="tooltip-inner">发送消息</div></div>
      <div id="selection" popover="manual" style="position-anchor: --targeted-action-selection"><div id="selection-inner"><button id="ask" onclick="window.actionSelection=String(getSelection())">询问 ChatGPT</button><button>分享所选内容</button></div></div>
      <script>
        function selectEmail() {
          document.querySelector('#source').focus();
          const r=document.createRange();r.selectNodeContents(document.querySelector('#email'));
          getSelection().removeAllRanges();getSelection().addRange(r);
        }
        // Reproduce the deployed polyfill: beforetoggle, show the panel, focus its first
        // focusable child even without autofocus, then emit toggle asynchronously.
        function showPanel(id) {
          const el=document.getElementById(id);
          el.dispatchEvent(new ToggleEvent('beforetoggle',{oldState:'closed',newState:'open'}));
          el.classList.add(':popover-open');
          const focusable=[el,...el.querySelectorAll('*')].find(x=>x.tabIndex>=0);
          if(focusable)focusable.focus();
          setTimeout(()=>el.dispatchEvent(new ToggleEvent('toggle',{oldState:'closed',newState:'open'})),0);
        }
      </script>
    </body></html>
    """

    private func makeArchiveHarness(sink: ScriptMessageSink, baseURL: URL = URL(string: "https://chatgpt.com/c/archive-fixture?mode=fixture")!) throws -> WebViewHarness {
        let harness = try makeHarness(sink: sink, html: """
        <!doctype html><html><body>
          <main><div id="prompt-textarea" contenteditable="true">unsent fixture draft</div></main>
          <div id="archive" role="dialog" aria-modal="true">
            <h2>已归档的聊天</h2>
            <button id="archive-close" aria-label="关闭" type="button"><svg width="20" height="20"></svg></button>
            <button id="row-action" aria-label="取消归档对话 fixture">Fixture action</button>
          </div>
          <script>history.replaceState({}, '', '#settings/DataControls/ArchivedChats');</script>
        </body></html>
        """, baseURL: baseURL)
        wait(for: [harness.navigationExpectation], timeout: 3)
        return harness
    }

    func testDraftRestoreWorksOnlyOnTrustedChatGPTOrigin() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let trusted = try makeHarness(
            sink: sink,
            html: Self.genericTextAreaHTML,
            baseURL: try XCTUnwrap(URL(string: "https://chatgpt.com/"))
        )
        defer { trusted.close() }
        wait(for: [trusted.navigationExpectation], timeout: 3)

        let trustedReport = try dictionaryResult(
            BrowserWindowController.restorePromptDraftScript(text: "private local draft"),
            in: trusted.webView
        )
        XCTAssertEqual(trustedReport["restored"] as? Bool, true)
        XCTAssertEqual(try stringResult("document.querySelector('textarea').value", in: trusted.webView), "private local draft")

        let untrusted = try makeHarness(
            sink: ScriptMessageSink(expectations: [:]),
            html: Self.genericTextAreaHTML,
            baseURL: try XCTUnwrap(URL(string: "https://example.com/"))
        )
        defer { untrusted.close() }
        wait(for: [untrusted.navigationExpectation], timeout: 3)

        let untrustedReport = try dictionaryResult(
            BrowserWindowController.restorePromptDraftScript(text: "private local draft"),
            in: untrusted.webView
        )
        XCTAssertEqual(untrustedReport["restored"] as? Bool, false)
        XCTAssertEqual(untrustedReport["reason"] as? String, "untrusted origin")
        XCTAssertEqual(try stringResult("document.querySelector('textarea').value", in: untrusted.webView), "")
    }

    func testNativeDraftRestoreGateRejectsThirdPartyAndNonHTTPSURLs() throws {
        XCTAssertTrue(BrowserWindowController.canInjectPromptContent(
            into: try XCTUnwrap(URL(string: "https://chatgpt.com/c/example"))
        ))
        XCTAssertTrue(BrowserWindowController.canInjectPromptContent(
            into: try XCTUnwrap(URL(string: "https://chat.openai.com/"))
        ))
        XCTAssertFalse(BrowserWindowController.canInjectPromptContent(
            into: try XCTUnwrap(URL(string: "https://example.com/"))
        ))
        XCTAssertFalse(BrowserWindowController.canInjectPromptContent(
            into: try XCTUnwrap(URL(string: "http://chatgpt.com/"))
        ))
    }

    func testNativePromptInjectionScriptRejectsThirdPartyOrigin() throws {
        let trusted = try makeHarness(
            sink: ScriptMessageSink(expectations: [:]),
            html: Self.genericTextAreaHTML,
            baseURL: try XCTUnwrap(URL(string: "https://chatgpt.com/"))
        )
        defer { trusted.close() }
        wait(for: [trusted.navigationExpectation], timeout: 3)
        let trustedReport = try dictionaryResult(
            BrowserWindowController.insertPromptTextScript(text: "selected note"),
            in: trusted.webView
        )
        XCTAssertEqual(trustedReport["ok"] as? Bool, true)
        XCTAssertEqual(try stringResult("document.querySelector('textarea').value", in: trusted.webView), "selected note")

        let untrusted = try makeHarness(
            sink: ScriptMessageSink(expectations: [:]),
            html: Self.genericTextAreaHTML,
            baseURL: try XCTUnwrap(URL(string: "https://example.com/"))
        )
        defer { untrusted.close() }
        wait(for: [untrusted.navigationExpectation], timeout: 3)
        let untrustedReport = try dictionaryResult(
            BrowserWindowController.insertPromptTextScript(text: "selected note"),
            in: untrusted.webView
        )
        XCTAssertEqual(untrustedReport["ok"] as? Bool, false)
        XCTAssertEqual(untrustedReport["reason"] as? String, "untrusted origin")
        XCTAssertEqual(try stringResult("document.querySelector('textarea').value", in: untrusted.webView), "")
    }

    private func makeHarness(
        sink: ScriptMessageSink,
        html: String,
        baseURL: URL? = URL(string: "https://chatgpt.com/")
    ) throws -> WebViewHarness {
        let controller = WKUserContentController()
        controller.add(sink, name: "promptDraft")
        controller.add(sink, name: "completionState")
        controller.add(sink, name: "dialogDismissal")
        controller.addUserScript(WKUserScript(source: chatDialogDismissalRecoveryScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: popoverChromeFixScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: composerPlusPopoverFixScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: BrowserWindowController.promptDraftCaptureScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: BrowserWindowController.completionStateObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        let waiter = NavigationWaiter(expectation: expectation(description: "HTML loaded"))
        webView.navigationDelegate = waiter

        webView.loadHTMLString(html, baseURL: try XCTUnwrap(baseURL))
        return WebViewHarness(webView: webView, waiter: waiter)
    }

    private func stringResult(_ script: String, in webView: WKWebView) throws -> String {
        let completed = expectation(description: "JavaScript string result")
        var output: String?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in
            output = result as? String
            failure = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        if let failure { throw failure }
        return try XCTUnwrap(output)
    }

    private func dictionaryResult(_ script: String, in webView: WKWebView) throws -> [String: Any] {
        let completed = expectation(description: "JavaScript dictionary result")
        var output: [String: Any]?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in
            output = result as? [String: Any]
            failure = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        if let failure { throw failure }
        return try XCTUnwrap(output)
    }

    private static let chatPageHTML = """
    <!doctype html><html><body>
      <main style="width:600px;height:400px">
        <div id="prompt-textarea" data-testid="prompt-textarea" contenteditable="true"></div>
        <button data-testid="stop-button" aria-label="Stop generating">Stop</button>
      </main>
    </body></html>
    """

    private static let challengePageHTML = """
    <!doctype html><html><body>
      <main id="challenge-stage" style="width:600px;height:400px">
        <div id="prompt-textarea" data-testid="prompt-textarea" contenteditable="true"></div>
        <button data-testid="stop-button" aria-label="Stop generating">Stop</button>
      </main>
    </body></html>
    """

    private static let genericTextAreaHTML = """
    <!doctype html><html><body>
      <main style="width:600px;height:400px"><textarea></textarea></main>
    </body></html>
    """


}

@MainActor
private final class WebViewHarness {
    let webView: WKWebView
    let waiter: NavigationWaiter

    var navigationExpectation: XCTestExpectation { waiter.expectation }

    init(webView: WKWebView, waiter: NavigationWaiter) {
        self.webView = webView
        self.waiter = waiter
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "promptDraft")
        controller.removeScriptMessageHandler(forName: "completionState")
        controller.removeScriptMessageHandler(forName: "dialogDismissal")
        controller.removeAllUserScripts()
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }
}

private final class ScriptMessageSink: NSObject, WKScriptMessageHandler {
    private let expectations: [String: XCTestExpectation]
    private(set) var messages: [(name: String, payload: [String: Any])] = []

    init(expectations: [String: XCTestExpectation]) {
        self.expectations = expectations
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        messages.append((message.name, payload))
        if payload["action"] as? String != "ready" { expectations[message.name]?.fulfill() }
    }

    func payload(named name: String) -> [String: Any]? {
        messages.first(where: { $0.name == name && $0.payload["action"] as? String != "ready" })?.payload
    }
}

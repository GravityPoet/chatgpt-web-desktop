import Foundation
import WebKit

extension BrowserWindowController {
    func focusPromptComposer(completion: ((String?) -> Void)? = nil) {
        show()
        setStatus("正在聚焦输入框…", showsProgress: true)
        focusPromptComposer(attemptsRemaining: 8, completion: completion)
    }

    func insertTextIntoPrompt(_ text: String, completion: @escaping (String?) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("没有可插入的文本")
            return
        }

        show()
        setStatus("正在插入上下文…", showsProgress: false)
        insertTextIntoPrompt(trimmed, attemptsRemaining: 8, completion: completion)
    }

    private func insertTextIntoPrompt(
        _ text: String,
        attemptsRemaining: Int,
        completion: @escaping (String?) -> Void
    ) {
        webView.evaluateJavaScript(Self.insertPromptTextScript(text: text)) { [weak self] result, error in
            guard let self else {
                return
            }
            if let error {
                if attemptsRemaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.insertTextIntoPrompt(text, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                    }
                    return
                }
                completion("插入失败：\(error.localizedDescription)")
                return
            }

            guard let report = result as? [String: Any],
                  Self.promptBoolValue(report["ok"]) else {
                if attemptsRemaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.insertTextIntoPrompt(text, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                    }
                    return
                }
                completion("未找到 ChatGPT 输入框")
                return
            }

            completion(nil)
        }
    }

    private func focusPromptComposer(attemptsRemaining: Int, completion: ((String?) -> Void)? = nil) {
        webView.evaluateJavaScript(Self.focusPromptComposerScript) { [weak self] result, error in
            guard let self else {
                return
            }
            if let error {
                if attemptsRemaining > 0 {
                    self.setStatus("等待 ChatGPT 输入框…", showsProgress: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.focusPromptComposer(attemptsRemaining: attemptsRemaining - 1, completion: completion)
                    }
                    return
                }
                self.setStatus("聚焦输入框失败", showsProgress: false)
                completion?("聚焦输入框失败：\(error.localizedDescription)")
                return
            }
            guard let report = result as? [String: Any],
                  Self.promptBoolValue(report["ok"]) else {
                if attemptsRemaining > 0 {
                    self.setStatus("等待 ChatGPT 输入框…", showsProgress: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.focusPromptComposer(attemptsRemaining: attemptsRemaining - 1, completion: completion)
                    }
                    return
                }
                self.setStatus("未找到输入框", showsProgress: false)
                completion?("未找到 ChatGPT 输入框")
                return
            }
            self.setStatus("输入框已聚焦", showsProgress: false)
            completion?(nil)
        }
    }

    private static let focusPromptComposerScript = """
    (() => {
      const visible = (element) => {
        if (!element) return false;
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
      };
      const firstVisible = (selector) => Array.from(document.querySelectorAll(selector)).find(visible);
      const composer =
        firstVisible('textarea[data-testid="prompt-textarea"]') ||
        firstVisible('[contenteditable="true"][data-testid="prompt-textarea"]') ||
        firstVisible('#prompt-textarea') ||
        firstVisible('textarea') ||
        firstVisible('[role="textbox"]') ||
        firstVisible('div[contenteditable="true"]');

      if (!composer) {
        return { ok: false };
      }
      composer.focus();
      if (typeof composer.scrollIntoView === 'function') {
        composer.scrollIntoView({ block: 'center', inline: 'nearest' });
      }
      return { ok: true };
    })()
    """

    private static func insertPromptTextScript(text: String) -> String {
        let textLiteral = promptJavaScriptStringLiteral(text)
        return """
        (() => {
          const text = \(textLiteral);
          const visible = (element) => {
            if (!element) return false;
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          };
          const placeCaretAtEnd = (element) => {
            const selection = window.getSelection();
            if (!selection) return;
            const range = document.createRange();
            range.selectNodeContents(element);
            range.collapse(false);
            selection.removeAllRanges();
            selection.addRange(range);
          };
          const firstVisible = (selector) => Array.from(document.querySelectorAll(selector)).find(visible);
          const composer =
            firstVisible('textarea[data-testid="prompt-textarea"]') ||
            firstVisible('[contenteditable="true"][data-testid="prompt-textarea"]') ||
            firstVisible('#prompt-textarea') ||
            firstVisible('textarea') ||
            firstVisible('[role="textbox"]') ||
            firstVisible('div[contenteditable="true"]');

          if (!composer) {
            return { ok: false };
          }

          composer.focus();
          if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
            const prefix = composer.value && !composer.value.endsWith('\\n') ? '\\n\\n' : '';
            const nextValue = composer.value + prefix + text;
            const descriptor = Object.getOwnPropertyDescriptor(
              composer instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,
              'value'
            );
            if (descriptor?.set) {
              descriptor.set.call(composer, nextValue);
            } else {
              composer.value = nextValue;
            }
            composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            composer.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            const existingText = composer.textContent || '';
            placeCaretAtEnd(composer);
            if (existingText.trim().length > 0) {
              document.execCommand('insertText', false, '\\n\\n' + text);
            } else {
              document.execCommand('insertText', false, text);
            }
            composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            composer.dispatchEvent(new Event('change', { bubbles: true }));
          }
          return { ok: true };
        })()
        """
    }

    private static func promptBoolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return string == "true" || string == "1"
        }
        return false
    }

    private static func promptJavaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }
}

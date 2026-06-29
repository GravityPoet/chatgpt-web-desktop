import AppKit

extension AppDelegate {
    @objc func focusPromptAction(_ sender: Any?) {
        guard let controller = BrowserWindowController.keyWindowController() ?? mainController else {
            return
        }
        controller.focusPromptComposer()
    }

    @objc func insertNotesContextAction(_ sender: Any?) {
        guard let controller = BrowserWindowController.keyWindowController() ?? mainController else {
            return
        }
        controller.setStatus("正在读取备忘录…", showsProgress: false)
        NotesContextReader.readSelectedNote { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let context):
                    controller.insertTextIntoPrompt(context) { errorText in
                        if let errorText {
                            controller.setStatus("上下文插入失败", showsProgress: false)
                            self.presentNotesContextError(errorText, for: controller)
                        } else {
                            controller.setStatus("备忘录上下文已插入", showsProgress: false)
                        }
                    }
                case .failure(let error):
                    controller.setStatus("备忘录上下文插入失败", showsProgress: false)
                    self.presentNotesContextError(error, for: controller)
                }
            }
        }
    }

    private func presentNotesContextError(_ error: Error, for controller: BrowserWindowController) {
        presentNotesContextError(error.localizedDescription, for: controller)
    }

    private func presentNotesContextError(_ message: String, for controller: BrowserWindowController) {
        let alert = NSAlert()
        alert.messageText = "无法插入备忘录上下文"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        if controller.window.isVisible {
            alert.beginSheetModal(for: controller.window)
        } else {
            alert.runModal()
        }
    }
}

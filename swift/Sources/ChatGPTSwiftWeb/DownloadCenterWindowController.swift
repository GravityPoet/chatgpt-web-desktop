import AppKit

@MainActor
final class DownloadCenterWindowController: NSWindowController {
    private let center: DownloadCenter
    private let profileID: String
    private let rows = NSStackView()
    private var observer: NSObjectProtocol?

    init(center: DownloadCenter, profileID: String) {
        self.center = center
        self.profileID = profileID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "下载中心"
        window.minSize = NSSize(width: 450, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = DownloadListDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        rows.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 18, right: 18)
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        let clear = NSButton(title: "清除已结束的记录", target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        clear.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(scroll)
        content.addSubview(clear)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: clear.topAnchor, constant: -10),
            clear.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), clear.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        observer = NotificationCenter.default.addObserver(forName: .chatGPTSwiftDownloadCenterDidChange, object: center, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func render() {
        let records = center.records.filter { $0.profileID == profileID }
        // Keep existing controls/focus while progress changes. Rebuild only when the row identities change.
        let existing = rows.arrangedSubviews.compactMap { $0 as? DownloadRow }
        if !records.isEmpty, existing.map(\.id) == records.map(\.id) {
            zip(existing, records).forEach { $0.0.update($0.1) }
            return
        }
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        if records.isEmpty {
            rows.addArrangedSubview(NSTextField(wrappingLabelWithString: "暂无下载。完成的文件保存在“下载”文件夹，最近 20 项记录会显示在这里。"))
        }
        for record in records {
            let row = DownloadRow(record: record, center: center)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -36).isActive = true
        }
    }

    @objc private func clearHistory() { center.clearFinished(profileID: profileID) }
}

private final class DownloadListDocument: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class DownloadRow: NSStackView {
    let id: UUID
    private var record: DownloadRecord
    private let center: DownloadCenter
    private let title = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let reveal = NSButton(title: "在 Finder 中显示", target: nil, action: nil)
    private let copy = NSButton(title: "复制路径", target: nil, action: nil)
    private let retry = NSButton(title: "重试", target: nil, action: nil)

    init(record: DownloadRecord, center: DownloadCenter) {
        id = record.id
        self.record = record
        self.center = center
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        addArrangedSubview(title)
        addArrangedSubview(status)
        addArrangedSubview(progress)
        let actions = NSStackView(views: [reveal, copy, retry])
        actions.spacing = 8
        addArrangedSubview(actions)
        for (button, selector) in [(reveal, #selector(revealFile)), (copy, #selector(copyPath)), (retry, #selector(retryDownload))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = selector
            button.setAccessibilityLabel("\(button.title)：\(record.filename)")
        }
        title.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        progress.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        update(record)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ record: DownloadRecord) {
        self.record = record
        title.stringValue = record.filename
        switch record.state {
        case .downloading:
            status.stringValue = record.progress.map { "正在下载 \(Int($0 * 100))%" } ?? "正在下载…"
        case .completed: status.stringValue = "已完成"
        case .failed: status.stringValue = record.errorMessage ?? "下载失败"
        case .canceled: status.stringValue = "下载已停止，请回原页面重新下载"
        }
        progress.isHidden = record.state != .downloading
        progress.isIndeterminate = record.progress == nil
        progress.doubleValue = record.progress ?? 0
        if record.state == .downloading && record.progress == nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        reveal.isHidden = record.path == nil
        copy.isHidden = record.path == nil
        retry.isHidden = record.state != .failed || !center.canRetry(id: record.id)
    }

    @objc private func revealFile() {
        guard let path = record.path else { return }
        guard FileManager.default.fileExists(atPath: path) else { status.stringValue = "文件已移动或删除"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    @objc private func copyPath() {
        guard let path = record.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        status.stringValue = "路径已复制"
    }
    @objc private func retryDownload() { _ = center.retry(id: id) }
}

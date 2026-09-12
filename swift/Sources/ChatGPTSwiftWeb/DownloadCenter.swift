import AppKit
import Foundation

struct DownloadRecord: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case downloading
        case completed
        case failed
        case canceled
    }

    let id: UUID
    var filename: String
    let profileID: String
    let isPrivate: Bool
    var path: String?
    var state: State
    var receivedBytes: Int64
    var expectedBytes: Int64?
    let createdAt: Date
    var completedAt: Date?
    var errorMessage: String?

    var progress: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

extension Notification.Name {
    static let chatGPTSwiftDownloadCenterDidChange = Notification.Name("ChatGPTSwift.DownloadCenterDidChange")
}

/// A small, process-local download ledger. WebKit owns the actual transfer; this object owns
/// user-visible state and history so completion never has to activate Finder.
@MainActor
final class DownloadCenter {
    static let shared = DownloadCenter()
    static let maximumHistoryCount = 20

    private static let recordsKey = "ChatGPTSwiftWeb.DownloadCenter.Records"
    private static let autoOpenFinderKey = "ChatGPTSwiftWeb.DownloadCenter.AutoOpenFinder"
    private let defaults: UserDefaults
    private(set) var records: [DownloadRecord]
    private var changeScheduled = false
    private var retryActions: [UUID: () -> Void] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recordsKey),
           let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = Array(decoded.filter { !$0.isPrivate }.prefix(Self.maximumHistoryCount)).map { record in
                var result = record
                if result.state == .downloading {
                    result.state = .failed
                    result.errorMessage = "上次下载已中断，请回原页面重新下载"
                }
                return result
            }
        } else {
            records = []
        }
    }

    var activeCount: Int {
        records.filter { $0.state == .downloading }.count
    }

    var autoOpenFinder: Bool {
        get { defaults.bool(forKey: Self.autoOpenFinderKey) }
        set { defaults.set(newValue, forKey: Self.autoOpenFinderKey) }
    }

    @discardableResult
    func begin(filename: String, profileID: String = "default", isPrivate: Bool = false, expectedBytes: Int64? = nil, retry: (() -> Void)? = nil) -> UUID {
        let id = UUID()
        let record = DownloadRecord(
            id: id,
            filename: filename,
            profileID: profileID,
            isPrivate: isPrivate,
            path: nil,
            state: .downloading,
            receivedBytes: 0,
            expectedBytes: expectedBytes,
            createdAt: Date(),
            completedAt: nil,
            errorMessage: nil
        )
        records.insert(record, at: 0)
        retryActions[id] = retry
        trimAndPersist()
        postChange()
        return id
    }

    func updateProgress(id: UUID, receivedBytes: Int64, expectedBytes: Int64? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .downloading else { return }
        records[index].receivedBytes = max(0, receivedBytes)
        if let expectedBytes { records[index].expectedBytes = max(0, expectedBytes) }
        postChange()
    }

    func complete(id: UUID, url: URL) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state != .canceled else { return }
        records[index].state = .completed
        records[index].path = url.path
        records[index].filename = url.lastPathComponent
        records[index].completedAt = Date()
        records[index].errorMessage = nil
        retryActions.removeValue(forKey: id)
        trimAndPersist()
        postChange()
        if autoOpenFinder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func fail(id: UUID, message: String, resume: (() -> Void)? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = .failed
        records[index].completedAt = Date()
        records[index].errorMessage = message
        retryActions[id] = resume
        trimAndPersist()
        postChange()
    }

    func cancel(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = .canceled
        records[index].completedAt = Date()
        retryActions.removeValue(forKey: id)
        trimAndPersist()
        postChange()
    }

    @discardableResult
    func retry(id: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].state == .failed,
              let action = retryActions[id] else { return false }
        records[index].state = .downloading
        records[index].completedAt = nil
        records[index].errorMessage = nil
        trimAndPersist()
        postChange()
        action()
        return true
    }

    func clearFinished(profileID: String) {
        records.removeAll { $0.profileID == profileID && $0.state != .downloading }
        trimAndPersist()
        postChange()
    }

    func canRetry(id: UUID) -> Bool { retryActions[id] != nil }

    func setRetry(id: UUID, action: @escaping () -> Void) { retryActions[id] = action }

    func forget(profileID: String) {
        records.removeAll { $0.profileID == profileID }
        trimAndPersist()
        postChange()
    }

    private func trimAndPersist() {
        let finished = Set(records.filter { $0.state != .downloading }.prefix(Self.maximumHistoryCount).map(\.id))
        records.removeAll { $0.state != .downloading && !finished.contains($0.id) }
        let remaining = Set(records.map(\.id))
        retryActions = retryActions.filter { remaining.contains($0.key) }
        if let data = try? JSONEncoder().encode(Array(records.filter { !$0.isPrivate }.prefix(Self.maximumHistoryCount))) {
            defaults.set(data, forKey: Self.recordsKey)
        }
    }

    func rename(id: UUID, filename: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].filename = filename
        trimAndPersist()
        postChange()
    }

    private func postChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.changeScheduled = false
            NotificationCenter.default.post(name: .chatGPTSwiftDownloadCenterDidChange, object: self)
        }
    }
}

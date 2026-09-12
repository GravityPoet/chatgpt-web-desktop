import Foundation
import Network

enum NetworkAvailability: Equatable {
    case unknown
    case online
    case constrained
    case offline

    var title: String {
        switch self {
        case .unknown: return "网络状态未知"
        case .online: return "本机网络已连接"
        case .constrained: return "网络受限"
        case .offline: return "网络已断开"
        }
    }
}

@MainActor
final class NetworkStatusMonitor {
    static let shared = NetworkStatusMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ChatGPTSwiftWeb.NetworkStatus", qos: .utility)
    private(set) var availability: NetworkAvailability = .unknown
    private(set) var interfaceDescription = "未检查"
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let next: NetworkAvailability
            if path.status != .satisfied {
                next = .offline
            } else if path.isConstrained {
                next = .constrained
            } else {
                next = .online
            }
            let interface = path.availableInterfaces.map { $0.type == .wifi ? "Wi-Fi" : $0.type == .wiredEthernet ? "有线" : $0.type == .cellular ? "蜂窝" : "其他" }.joined(separator: ", ")
            DispatchQueue.main.async {
                guard let self else { return }
                let old = self.availability
                self.availability = next
                self.interfaceDescription = interface.isEmpty ? "无可用接口" : interface
                NotificationCenter.default.post(name: .chatGPTSwiftNetworkDidChange, object: self,
                    userInfo: ["restored": old == .offline && next != .offline])
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        monitor.cancel()
        started = false
    }
}

extension Notification.Name {
    static let chatGPTSwiftNetworkDidChange = Notification.Name("ChatGPTSwift.NetworkDidChange")
}

enum NavigationFailure {
    static func description(for error: Error, offline: Bool) -> String {
        if offline { return "本机网络已断开；联网后将重试一次" }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return "页面加载失败，请重试" }
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "服务器域名解析失败，请检查 DNS 或代理"
        case NSURLErrorCannotConnectToHost:
            return "无法连接服务器，请检查网络或代理"
        case NSURLErrorTimedOut:
            return "连接超时，可以重试"
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
            return "网络连接中断；联网后将重试一次"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "安全连接失败，请检查系统时间或网络代理"
        default: return "页面加载失败，请重试"
        }
    }
}

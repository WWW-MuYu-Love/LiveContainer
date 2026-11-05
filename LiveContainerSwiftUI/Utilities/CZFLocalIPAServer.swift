import Foundation
import Network
import UIKit

// 本机 IPA 交接服务（Campbell 2026-11-06）：点「使用
// Sidekite 更新」时，LiveContainer 先把自己的更新包下载到
// 本地，再用 sidekite://install?url= 把包交给 Sidekite——
// url 给的是本机回环地址（http://127.0.0.1:<随机端口>/
// <随机令牌>/<文件名>），由本服务把文件喂给它。全程不弹
// 系统分享表（本地文件没有跨 App 直送通道，分享表是唯一
// 系统路；这里是让安装器自己按 url 来本机取，绕开分享）。
//
// 边界与兜底：
// - 只监听 127.0.0.1、随机端口 + 随机令牌路径，除了本机
//   的这次取包，谁也拿不到。
// - 启服务时领一个后台任务，跳到 Sidekite 后 LiveContainer
//   被挂起期间服务继续供包（回环传输很快，通常秒级完事）；
//   一次完整取包后留 60 秒宽限（防对方重试/续传），到点
//   自停；无论如何 240 秒绝对自停并删掉交接副本。
// - 对方若不支持 http 回环地址，调用方会退回原来的直链
//   交接（由 Sidekite 自己从 GitHub 下载），不会卡死。
final class CZFLocalIPAServer {
    static let shared = CZFLocalIPAServer()
    private init() {}

    private let queue = DispatchQueue(label: "czf.local-ipa-server")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var requestBuffers: [ObjectIdentifier: Data] = [:]
    private var fileURL: URL?
    private var token: String = ""
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var graceStopItem: DispatchWorkItem?
    private var absoluteStopItem: DispatchWorkItem?

    // 启动服务并返回取包 URL。重复启动会先停掉旧的一份。
    func start(fileURL: URL) async throws -> URL {
        queue.sync { self.stopLocked() }
        self.fileURL = fileURL
        self.token = UUID().uuidString

        // 后台任务保命：切到安装器后本进程被挂起，靠它把
        // 这次传输供完；系统给的时间用完会回调到停服。
        await MainActor.run {
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CZFUpdateHandoff") { [weak self] in
                self?.stop()
            }
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener = listener
        listener.start(queue: queue)

        // 等端口落位（ready 后 port 才有值），最多等 3 秒。
        var port: NWEndpoint.Port?
        for _ in 0..<30 {
            if let p = listener.port {
                port = p
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let port else {
            stop()
            throw NSError(domain: "CZFLocalIPAServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "本机服务启动失败"])
        }

        // 绝对上限：4 分钟后无论如何停服。
        let absolute = DispatchWorkItem { [weak self] in self?.stop() }
        absoluteStopItem = absolute
        queue.asyncAfter(deadline: .now() + 240, execute: absolute)

        let name = fileURL.lastPathComponent.isEmpty ? "LiveContainer.ipa" : fileURL.lastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "LiveContainer.ipa"
        return URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/\(encoded)")!
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    // 必须在 queue 上调用。
    private func stopLocked() {
        graceStopItem?.cancel()
        graceStopItem = nil
        absoluteStopItem?.cancel()
        absoluteStopItem = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        requestBuffers.removeAll()
        // 交接副本使命结束就删（Caches 里的下载件，占 ~17MB）
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        if backgroundTask != .invalid {
            let task = backgroundTask
            backgroundTask = .invalid
            DispatchQueue.main.async {
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.requestBuffers.removeValue(forKey: ObjectIdentifier(connection))
                self?.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection)
    }

    // 请求头可能分片到达，攒到 \r\n\r\n 再处理（上限 64KB）。
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            let key = ObjectIdentifier(connection)
            if let data, !data.isEmpty {
                var buffer = self.requestBuffers[key] ?? Data()
                buffer.append(data)
                self.requestBuffers[key] = buffer
                if buffer.range(of: Data([13, 10, 13, 10])) != nil || buffer.count > 65536 {
                    self.requestBuffers.removeValue(forKey: key)
                    self.respond(connection: connection, request: buffer)
                    return
                }
            }
            if error != nil {
                self.requestBuffers.removeValue(forKey: key)
                connection.cancel()
                return
            }
            self.receiveRequest(connection)
        }
    }

    private func respond(connection: NWConnection, request: Data) {
        guard let fileURL,
              let head = String(data: request, encoding: .utf8),
              let firstLine = head.components(separatedBy: "\r\n").first else {
            connection.cancel()
            return
        }
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.first ?? ""
        let path = parts.count > 1 ? parts[1] : ""
        guard path.hasPrefix("/\(token)/") else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(notFound.utf8), isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? nil
        guard let fileSize = size else {
            connection.cancel()
            return
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(fileSize)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { connection.cancel(); return }
            if method == "HEAD" {
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            self?.sendBody(connection: connection, fileURL: fileURL)
        })
    }

    // 文件分块流出，全发完才算一次完整取包：安排 60 秒
    // 宽限后自停（对方重试/续传在这窗口内还能再取）。
    private func sendBody(connection: NWConnection, fileURL: URL) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            connection.cancel()
            return
        }
        func sendNext() {
            let chunk = handle.readData(ofLength: 262144)
            if chunk.isEmpty {
                try? handle.close()
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    connection.cancel()
                    self?.scheduleGraceStop()
                })
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                sendNext()
            })
        }
        sendNext()
    }

    private func scheduleGraceStop() {
        guard graceStopItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        graceStopItem = item
        queue.asyncAfter(deadline: .now() + 60, execute: item)
    }
}

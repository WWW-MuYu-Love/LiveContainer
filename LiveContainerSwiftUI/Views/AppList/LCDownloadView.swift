//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import SwiftUI

public final class DownloadHelper : ObservableObject {
    @Published var downloadProgress : Float = 0.0
    @Published var downloadedSize : Int64 = 0
    @Published var totalSize : Int64 = 0
    @Published var isDownloading = false
    // 当前下载的文件名（取自下载地址的最后一段）：下载
    // 管理面板显示用。
    @Published var currentDownloadName: String = ""
    // 当前下载的地址：下载管理判重用（正在下的地址再来
    // 一次算重复任务）
    @Published var currentDownloadURL: URL? = nil
    // 更新包递交的下载正在进行（设置页置位）：已有更新
    // 包在下载任务里时，不允许再下第二个（Campbell 定）
    @Published var updatePackageDownloading = false
    @Published var cancelled = false
    // 进度发布节流用：上次发布进度的时间
    private var lastProgressPublish = Date.distantPast
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: UnsafeContinuation<(), Never>?
    // 断点续传：中断（取消/失败）时留下的续传数据和它对应的
    // 地址，下次下同一个地址时接着下，不用从 0 开始
    private var savedResumeData: Data?
    private var savedResumeURL: URL?
    private var currentURL: URL?

    func download(url: URL, to: URL) async throws {
        currentURL = url
        // 失败自动重试：最多 3 次（首次 + 2 次重试），网络抖
        // 一下不用用户再点一次。每次优先用上次留下的续传数
        // 据接着下（completeCallback 失败时已存好），不从 0
        // 开始；用户主动取消立即停、不重试
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            do {
                if let data = savedResumeData, savedResumeURL == url {
                    savedResumeData = nil
                    savedResumeURL = nil
                    try await downloadOnce(url: url, to: to, resumeData: data)
                } else {
                    try await downloadOnce(url: url, to: to, resumeData: nil)
                }
                return
            } catch {
                lastError = error
                if cancelled {
                    throw error
                }
            }
        }
        throw lastError ?? NSError(domain: "DownloadHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败"])
    }

    private func downloadOnce(url: URL, to: URL, resumeData: Data?) async throws {
        var ansError: Error? = nil
        // 本次下载建的会话，结束时要释放（见方法末尾）
        var createdSession: URLSession? = nil

        await MainActor.run {
            cancelled = false
            currentDownloadName = url.lastPathComponent
            currentDownloadURL = url

            downloadProgress = 0.0
            downloadedSize = 0
            totalSize = 0

            isDownloading = true
        }
        
        await withUnsafeContinuation { c in
            continuation = c
            
            let bgConfig = CZFVPNManager.hostDownloadConfiguration(identifier: "com.livecontainer.download.\(UUID().uuidString)")
            let session = URLSession(configuration: bgConfig, delegate: DownloadDelegate(progressCallback: { progress, downloaded, total in
                Task{ await MainActor.run {
                    // 节流：进度回调一秒能来几十次，每次都发布
                    // 会让监听这个对象的整个 App 列表跟着重绘，
                    // 下载中滑动就一卡一卡。进度变化不到 1% 且
                    // 离上次发布不到 0.25 秒的直接跳过，最后一
                    // 下（100%）照常发布
                    let now = Date()
                    if progress < 1,
                       abs(progress - self.downloadProgress) < 0.01,
                       now.timeIntervalSince(self.lastProgressPublish) < 0.25 {
                        return
                    }
                    self.lastProgressPublish = now
                    self.downloadProgress = progress
                    self.downloadedSize = downloaded
                    self.totalSize = total
                }}
            }, completeCallback: {tempFileURL, error in
                Task{ await MainActor.run {
                    self.isDownloading = false
                    self.currentDownloadURL = nil
                }}
                if let error {
                    print(error)
                    ansError = error
                    // 失败时系统给了续传数据就留着，下次接着下
                    if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        self.savedResumeData = data
                        self.savedResumeURL = url
                    }
                } else {
                    self.savedResumeData = nil
                    self.savedResumeURL = nil
                }
                if let tempFileURL {
                    do {
                        let fm = FileManager.default
                        print(to)
                        // 目标有同名残留时 moveItem 直接报"已存在
                        // 同名项目"、下载白下完（真机实测：上次
                        // 安装没清干净的 tmp 文件、或重试时上一
                        // 轮已搬到位的文件都会撞上）：搬之前先清
                        if tempFileURL.standardizedFileURL != to.standardizedFileURL,
                           fm.fileExists(atPath: to.path) {
                            try? fm.removeItem(at: to)
                        }
                        try fm.moveItem(at: tempFileURL, to: to)
                    } catch {
                        ansError = error
                    }
                }
                if self.continuation != nil {
                    c.resume()
                }

            }), delegateQueue: .main)
            createdSession = session

            if let resumeData {
                downloadTask = session.downloadTask(withResumeData: resumeData)
            } else {
                downloadTask = session.downloadTask(with: url)
            }
            downloadTask?.resume()
        }
        // 会话用完释放：以前每次下载（重试、预取都会叠加）都新
        // 建一个后台会话且从不 invalidate，只增不减地挂在系统
        // 里。任务已结束/失败/取消走到这里，收尾释放正合适
        createdSession?.finishTasksAndInvalidate()
        if let ansError {
            throw ansError
        }
    }
    
    func cancel() {
        if let continuation {
            continuation.resume()
        }
        cancelled = true
        continuation = nil
        // 带续传数据的取消：系统把下好的部分留成续传数据，
        // 下次下同一个地址接着下，不用从 0 开始
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data else {
                return
            }
            self.savedResumeData = data
            self.savedResumeURL = self.currentURL
        })
        isDownloading = false
    }
}

class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressCallback: (Float, Int64, Int64) -> Void
    let completeCallback: (URL?, Error?) -> Void

    init(progressCallback: @escaping (Float, Int64, Int64) -> Void,
         completeCallback: @escaping (URL?, Error?) -> Void) {
        self.progressCallback = progressCallback
        self.completeCallback = completeCallback
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // 服务器不发长度时 totalBytesExpectedToWrite 是 -1
        // （NSURLSessionTransferSizeUnknown），直接除会得到负
        // 进度，界面就显示负百分比和“-1”总大小；未知长度传
        // -1 作标记，界面按 totalSize <= 0 走未知长度分支。
        let progress: Float
        if totalBytesExpectedToWrite > 0 {
            progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        } else {
            progress = -1
        }
        progressCallback(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode

            // Check if the status code is in the 2xx range
            if (200...299).contains(statusCode) {
                completeCallback(location, nil)
            } else {
                // 报错说人话并分清原因：以前一律英文 "HTTP Error:
                // 404"，链接死了都看不出来
                let message: String
                switch statusCode {
                case 404:
                    message = "下载链接已失效（服务器返回 404）"
                case 403:
                    message = "服务器拒绝下载（403），链接可能已过期或需要登录"
                default:
                    message = "下载失败，服务器返回 \(statusCode)"
                }
                completeCallback(location, NSError(domain: "", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        } else {
            completeCallback(location, NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败：服务器没有返回有效文件"]))
        }
        

    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completeCallback(nil, error)
        } else {

        }
    }
}


// 「下载管理」里的一条已下载文件
struct CZFDownloadedFile: Identifiable {
    let url: URL
    let name: String
    let size: Int64
    let date: Date
    var id: String { url.path }
}

// 下载管理的文件仓库（Campbell 定）：浏览器下载、链接
// 下载的 IPA 不再直接安装，先存进 Documents/Downloads
// 保留着，用户在「下载管理」里点安装才装、点删除才删。
enum CZFDownloadStore {
    static func directory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // 同名文件已在时不覆盖：新文件依次叫「名字 2」「名字 3」
    static func uniqueDestination(filename: String) -> URL {
        let dir = directory()
        let name = filename.isEmpty ? "app.ipa" : filename
        var candidate = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(n)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }

    static func listFiles() -> [CZFDownloadedFile] {
        let dir = directory()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else {
            return []
        }
        return urls
            .filter { ["ipa", "tipa"].contains($0.pathExtension.lowercased()) }
            .map { u in
                let values = try? u.resourceValues(forKeys: Set(keys))
                return CZFDownloadedFile(url: u, name: u.lastPathComponent, size: Int64(values?.fileSize ?? 0), date: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }
}

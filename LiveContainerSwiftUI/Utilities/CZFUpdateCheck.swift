import Foundation

/// fork update 更新信息：只认 fork 自己的 update release，
/// 不认源里的 apps_nightly.json（它下载地址指向上游 nightly，
/// 装了会丢掉 fork 的功能和 🅥 改动），也不认 source.json 里
/// 上游 3.8.0 那条。查 GitHub 公开 API，不用任何 token，
/// 绝不能把 PAT 写进包里。
struct CZFUpdateInfo {
    /// 短提交号，如 25c5124
    let commit: String
    /// 该 update 包的版本号（发布脚本写在正文 **Version:** 行、
    /// 与 Info.plist 版本同步；旧正文没有这一行时为 nil，
    /// 展示时回落到只显提交号）
    let version: String?
    let publishedAt: Date?
    let downloadURL: URL
}

enum CZFUpdateCheck {
    private static let apiURL = URL(string: "https://api.github.com/repos/MuYu-Blog/LiveContainer-zh/releases/tags/update")!
    private static let fallbackIPAURL = URL(string: "https://github.com/MuYu-Blog/LiveContainer-zh/releases/download/update/LiveContainer.ipa")!
    // 二合一版的兜底直链：文件名按当前发布线（Codemagic 自动
    // 发布）的命名 LiveContainer.SideStore.ipa；资产列表拿得到
    // 时走下面的按名匹配，不依赖这个写死的名字。
    private static let fallbackSideStoreIPAURL = URL(string: "https://github.com/MuYu-Blog/LiveContainer-zh/releases/download/update/LiveContainer.SideStore.ipa")!

    /// 当前运行的是不是二合一版（包里带 SideStoreApp.framework）。
    private static var isCombinedBuild: Bool {
        UserDefaults.sideStoreExist()
    }

    /// 本机短提交号：包里 LCVersionInfo 是 "Release (main/25c5124)"
    /// 这种格式，构建时的 Run Script 写进去的；解析不到就返回 nil。
    static func currentCommit() -> String? {
        guard let info = Bundle.main.infoDictionary?["LCVersionInfo"] as? String,
              let slash = info.lastIndex(of: "/") else { return nil }
        let tail = info[info.index(after: slash)...]
        let commit = tail.prefix(while: { $0.isLetter || $0.isNumber })
        return commit.isEmpty ? nil : String(commit)
    }

    /// 查一次 fork update：正文第一行就是 "**Commit:** [完整 SHA](...)"。
    /// 资产按当前运行的版本挑：二合一版取带 SideStore 的包，
    /// 独立版取 LiveContainer.ipa。以前一律递独立版，二合一版
    /// 用户点更新装回来的是独立版、内置 SideStore 被覆盖没了
    /// （2026-11-05 实测后定的修法）。
    static func check(completion: @escaping (Result<CZFUpdateInfo, Error>) -> Void) {
        var request = URLRequest(url: apiURL)
        request.setValue("LiveContainer", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? String,
                  let fullSHA = updateCommitSHA(from: body) else {
                completion(.failure(NSError(domain: "CZFUpdateCheck", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "update 信息里没有提交号"])))
                return
            }
            var publishedAt: Date?
            if let publishedString = json["published_at"] as? String {
                publishedAt = ISO8601DateFormatter().date(from: publishedString)
            }
            let combined = isCombinedBuild
            var downloadURL = combined ? fallbackSideStoreIPAURL : fallbackIPAURL
            if let assets = json["assets"] as? [[String: Any]] {
                let ipas = assets.filter { (($0["name"] as? String) ?? "").hasSuffix(".ipa") }
                let picked: [String: Any]?
                if combined {
                    // 带 SideStore 的那个：两条构建线命名不同
                    // （LiveContainer+SideStore.ipa 与
                    // LiveContainer.SideStore.ipa），按含
                    // "SideStore" 匹配，两种都认。
                    picked = ipas.first(where: { (($0["name"] as? String) ?? "").contains("SideStore") })
                } else {
                    picked = ipas.first(where: { ($0["name"] as? String) == "LiveContainer.ipa" })
                        ?? ipas.first(where: { !(($0["name"] as? String) ?? "").contains("SideStore") })
                }
                if let picked,
                   let urlString = picked["browser_download_url"] as? String,
                   let url = URL(string: urlString) {
                    downloadURL = url
                }
            }
            completion(.success(CZFUpdateInfo(commit: String(fullSHA.prefix(7)),
                                               version: updateVersion(from: body),
                                               publishedAt: publishedAt,
                                               downloadURL: downloadURL)))
        }.resume()
    }

    /// 正文里的版本号：发布脚本在 Commit 行下一行写
    /// "**Version:** 3.8.3"，与该包 Info.plist 的版本同步。
    private static func updateVersion(from body: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "Version:\\*\\* ([0-9A-Za-z.\\-]+)"),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[range])
    }

    private static func updateCommitSHA(from body: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "Commit:\\*\\* \\[([0-9a-f]{40})\\]"),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[range])
    }
}

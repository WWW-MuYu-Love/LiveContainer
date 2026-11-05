//
//  CZFVPNManager.swift
//  单 App VPN（验证版，2026-10-21）
//
//  思路：sing-box 核心（Libbox）跑在宿主进程里，开一个
//  本地 SOCKS5 入口（127.0.0.1:10827）；被标记的 App 单独部署
//  CZFProxy.dylib，把它的 TCP 流量拐进这个入口经节点出网。
//  没标记的 App 完全不碰（不启核心、不装插件）。
//
//  节点链接由 CZFSingBoxConfig 生成 sing-box 出站配置（全量
//  sing-box，2026-11-05 定版，原 Xray 路径已删），本类负责
//  配置生成调度与启停。域名经 SOCKS 以域名形式交给节点远端
//  解析，本地不落 DNS。
//

import Foundation
import LiveContainerShared

public final class CZFVPNManager {
    public static let shared = CZFVPNManager()

    public static let socksPort = 10827
    private static let nodeLinkKey = "CZFVPNNodeLink"
    private static let nodeListKey = "CZFVPNNodeLinks"
    private static let activeNodeKey = "CZFVPNActiveNodeIndex"
    private static let enabledKeyPrefix = "CZFVPNEnabled-"
    private static let nodeOverrideKeyPrefix = "CZFVPNNodeOverride-"
    // 用户在 App 设置里亲手选过"跟随全局"时才为 true；缺省为 false，
    // 表示这个 App 还没选过，养号锁定逻辑可以替它钉死当前节点
    private static let followGlobalKeyPrefix = "CZFVPNFollowGlobal-"

    public private(set) var isRunning = false
    private var runningLink: String?
    // 当前在跑的是哪个核心（nil = 没在跑）：TUIC-only 单活切换
    // 的唯一事实来源——start 成功时记、stop 时清；测速分流
    // 与停核心都读它，绝不凭 isRunning 猜核心种类。
    private var runningCore: CZFCoreKind?
    // 核心当前归哪个 App 所有（ensureRunning 起核心时记下）：
    // 养号 App 在跑时，别的 App 自动启动不准抢核心换节点，
    // 手动在设置里切节点、停核心时会清掉这个归属
    private var coreOwnerBundleId: String?
    public private(set) var lastError: String?
    // 核心自动停：被标记 App 全部关掉后延迟停核心（见
    // noteRunningAppsChanged）；防抖靠"最近一次被标记 App
    // 启动时间"+ 30 分钟延迟双保险，避免 App 重启时反复启停
    private var pendingStopWork: DispatchWorkItem?
    private var lastFlaggedLaunchAt = Date.distantPast
    // 节点自动轮换：核心在跑时每 30 秒读归属 App 的插件统计，
    // 窗口内失败一直涨、成功代理一条不涨，就判定当前节点对该
    // App 已死，按列表顺序切下一个支持协议的节点并重启核心。
    // 归属 App 与 coreOwnerBundleId 同步记、同步清。
    private var coreOwnerAppInfo: LCAppInfo?
    private var pendingRotateWork: DispatchWorkItem?
    private var rotateLastFailed: Int64?
    private var rotateLastProxied: Int64?
    private var rotateBaselineLink: String?
    private var rotateCooldownUntil = Date.distantPast
    private var rotateTriedLinks = Set<String>()
    private static let autoRotateKey = "CZFVPNAutoRotate"
    // 轮换开关：键不存在 = 开（用户亲令要轮换，默认开着，随时可关）
    public static var isAutoRotateEnabled: Bool {
        guard let v = UserDefaults.standard.object(forKey: autoRotateKey) as? Bool else { return true }
        return v
    }
    public static func setAutoRotate(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoRotateKey)
        if enabled {
            shared.scheduleRotateCheck()
        } else {
            shared.cancelRotateCheck()
        }
    }
    // 核心状态串行化：start/stop/开 App 预热原来在
    // 主线程、detached Task、测速后台队列三处同时改
    // isRunning/runningLink/coreOwnerBundleId，测速中途开 App
    // 时 stop/start 互相插队，恢复完又被改回去。NSLock 在
    // start(withLink:) 内部调 stop() 时会同线程二次加锁死锁，
    // 故用 NSRecursiveLock（同仓 LCUtilsExtensions 的 lock/defer
    // 写法，见该文件 verifiedTweakFoldersLock 处）。
    // 锁只包状态切换（stop/start/抓状态/恢复），不包整段测速
    // （单探针有 5 秒超时、串行重试可达十几秒，包住会冻住主
    // 线程的预热）；测速窗口内别的触发靠下面的 isPinging 挡。
    private let vpnCoreLock = NSRecursiveLock()
    // 测速进行中标志：测速窗口内开 App、预热、切节点一律不
    // 直接动核心，改由测速收尾统一处理（见 pingAllNodes 末尾
    // 的 deferredEnsure / 切节点跟随），否则测速结果会被
    // 插队的核心启停打乱（探针被占用挡下）。
    private var isPinging = false
    // 测延迟自动停核心的恢复快照：startVPNPing 在核心在跑
    // 时先停、测完凭它重启原来那条（归属原样）；核心没在
    // 跑时不写，测完不启动。一次性的，restart 读完即清。
    private var pingStoppedLink: String?
    private var pingStoppedOwner: LCAppInfo?
    // 测速窗口内被挡下的开 App 请求：只记最后一个，测速完
    // 再给它 ensureRunning（游客启动时等核心，见 LCAppModel
    // 的 vpnCoreTask；挡下不等于丢掉）。
    private var deferredEnsureApp: LCAppInfo?
    // 旧测速收尾写过的延迟重试链接：只读版测速不再写它，
    // 仅 stop() 在非测速窗口内清掉它作兼容；用户亲手停核
    // 心时同样清掉，不留事后起回来的尾巴。
    private var pingRetryLink: String?
    // 用户/ App 动作计数：测速收尾要不要碰预热抑制，
    // 就看测速窗口内有没有这类动作。开 App（ensureRunning，
    // 含测速收尾补跑）、源下载开关（ensureRunningForHost）、
    // 设置页亲手起停核心（noteManualCoreToggle）都会 +1；
    // 预热、测速自身不 +1——它们是自动触发，不能反过来
    // 推翻用户/ App 在测速窗口内做的决定。
    private var coreActionEpoch = 0
    // 测速代次：每轮 pingAllNodes 开始时 +1，保留作代次
    // 区分；只读版已删收尾后校验，不再用它去翻状态。
    private var pingGeneration = 0
    // 测速结束时核心没在跑时对预热的持久抑制：v186 只压
    // 10 秒，超过窗口、切走再进 App，预热又把核心起回来，
    // 用户认定的就是“测速改了核心”。本标志只在测速收尾
    // 看到核心没在跑时置真，且落盘（UserDefaults），宿
    // 主进程重启也不丢；只由三类手动动作清掉：亲手起核心、
    // 打开标了 VPN 的 App、亲手拨一次预热开关。预热开关值
    // 本身不动，开关关着时 prewarmIfNeeded 本来就返回，
    // 本标志不影响它。测速结束时核心在跑就清掉，不留旧抑制。
    private var prewarmSuppressedAfterPing: Bool {
        get { UserDefaults.standard.bool(forKey: "CZFVPNPrewarmSuppressedAfterPing") }
        set { UserDefaults.standard.set(newValue, forKey: "CZFVPNPrewarmSuppressedAfterPing") }
    }
    // 设置页显示用：测速后预热是否被压着（开关开着也不预热时，
    // 界面要把这个状态说出来，不能让用户以为预热坏了）。
    public var isPrewarmSuppressedAfterPing: Bool {
        UserDefaults.standard.bool(forKey: "CZFVPNPrewarmSuppressedAfterPing")
    }
    // 测速窗口内被挡下的源下载开关起核心请求：与
    // deferredEnsureApp 同理，测速收尾再补跑一次。
    private var deferredHostEnsure = false
    // 核心关闭后自动停时长（CZF，可调）：设置页“单App VPN”里
    // 选 5 / 10 / 30 分钟，默认 10 分钟（以前写死 30 分钟）。
    // 注意定义：只在最后一个标 VPN 的 App 关窗后计时，
    // 最小化不算关、不计时——以前叫“闲置自动停”容易误读。
    // 已排队的停核心任务仍按排队时的时长触发，但触发时按
    // 当前档位重算闲置时长：档位改短不会提前停、改长不会
    // 误停，下次 App 变化重排时按新档位来，行为安全。
    private static let autoStopMinutesKey = "CZFVPNAutoStopMinutes"
    private static var autoStopDelay: TimeInterval {
        // integer(forKey:) 在键不存在时返回 0，正好落到默认 10，
        // 不用 object(as? Int) 的桥接不确定性（仓内 activeNodeIndex 同款读法）。
        let minutes = UserDefaults.standard.integer(forKey: autoStopMinutesKey)
        return TimeInterval([5, 10, 30].contains(minutes) ? minutes : 10) * 60
    }

    private init() {}

    // MARK: - 节点与标记（UserDefaults 存储）

    // 节点列表：老版本只存过单个链接，首次读时自动迁移成列表，
    // 用户原来填的节点不丢
    public var nodeLinks: [String] {
        if let saved = UserDefaults.standard.array(forKey: Self.nodeListKey) as? [String] {
            return saved
        }
        let legacy = UserDefaults.standard.string(forKey: Self.nodeLinkKey) ?? ""
        let migrated = legacy.isEmpty ? [] : [legacy]
        UserDefaults.standard.set(migrated, forKey: Self.nodeListKey)
        return migrated
    }

    public var activeNodeIndex: Int {
        let links = nodeLinks
        guard !links.isEmpty else { return 0 }
        let idx = UserDefaults.standard.integer(forKey: Self.activeNodeKey)
        return min(max(idx, 0), links.count - 1)
    }

    // 当前生效的节点链接（start/ensureRunning 都读它）
    public var nodeLink: String {
        let links = nodeLinks
        guard !links.isEmpty else { return "" }
        return links[activeNodeIndex]
    }

    // 节点变了就刷新设置备份：导入导出配置（CZFSettingsBackup.json）
    // 本来只在手动导出 / 备份 App 时写，节点增删改后不刷就过期，
    // 换机重装导入的还是旧节点；这里顺手刷一份，配置永远是最新节点。
    // 只调 DataManagement 现成的静态写函数，不改那份文件。
    private func refreshSettingsBackup() {
        _ = LCDataManagementView.writeCZFSettingsBackup()
    }

    // 返回 true 表示真的加进去了；空链接或已存在返回 false，
    // 界面据此提示“已存在”，不再静默失败（以前直接 return，
    // 界面还把输入框清空，看起来像加上了）。
    @discardableResult
    public func addNode(_ link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var links = nodeLinks
        if links.contains(trimmed) { return false }
        links.append(trimmed)
        UserDefaults.standard.set(links, forKey: Self.nodeListKey)
        refreshSettingsBackup()
        return true
    }

    // 清理专用：只换节点列表、不碰核心。清理只是删节点，
    // 核心在跑就继续用在用节点，停着就继续停着，绝不因清理
    // 启停核心；replaceAllNodes 会调 applyActiveNodeChange，
    // 清理不能走它。
    public func replaceNodesWithoutCoreChange(_ newLinks: [String]) {
        // 保序去重：订阅自带重复链接时不进两行（单测按 firstIndex
        // 写回会永远只写第一行），调用方（合并导入）已去重也无妨。
        var seen = Set<String>()
        let cleaned = newLinks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !cleaned.isEmpty else { return }
        let previousActive = nodeLink
        UserDefaults.standard.set(cleaned, forKey: Self.nodeListKey)
        if let idx = cleaned.firstIndex(of: previousActive) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        } else {
            UserDefaults.standard.set(0, forKey: Self.activeNodeKey)
        }
        refreshSettingsBackup()
    }

    // 用一批新链接整体替换节点列表（订阅刷新用）：尽量保留
    // 当前活动节点（按内容找回），找不到就落到第一个
    public func replaceAllNodes(_ newLinks: [String]) {
        var seen = Set<String>()
        let cleaned = newLinks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !cleaned.isEmpty else { return }
        let previousActive = nodeLink
        UserDefaults.standard.set(cleaned, forKey: Self.nodeListKey)
        if let idx = cleaned.firstIndex(of: previousActive) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        } else {
            UserDefaults.standard.set(0, forKey: Self.activeNodeKey)
        }
        applyActiveNodeChange()
        refreshSettingsBackup()
    }

    /// 订阅拉取结果：链接之外带回组名与流量/到期（响应头
    /// Subscription-Userinfo / Profile-Title；机场不给响应
    /// 头时正文里常有 STATUS= 行，同样解析），以及从 Clash
    /// 格式并行对回来的节点名（机场的小火箭格式里 vless
    /// 链接不带备注，名字只在 Clash 格式里有，按 协议+
    /// 服务器+端口 对回链接，见 matchClashNames）。
    public struct CZFVPNSubscriptionFetch {
        public var links: [String]
        public var title: String?
        public var upload: Int64?
        public var download: Int64?
        public var total: Int64?
        public var expire: TimeInterval?
        public var namesByLink: [String: String]
        public init(links: [String], title: String? = nil, upload: Int64? = nil, download: Int64? = nil, total: Int64? = nil, expire: TimeInterval? = nil, namesByLink: [String: String] = [:]) {
            self.links = links
            self.title = title
            self.upload = upload
            self.download = download
            self.total = total
            self.expire = expire
            self.namesByLink = namesByLink
        }
    }

    /// 拉订阅内容并解析出节点链接：机场订阅通常是整段 base64
    /// （解开后一行一条链接），也有直接一行一条的明文格式，
    /// 两种都认；只保留带 :// 的行（vless/vmess/trojan/ss 等）
    public static func fetchSubscriptionLinks(urlString: String, completion: @escaping (Result<[String], Error>) -> Void) {
        fetchSubscription(urlString: urlString) { result in
            completion(result.map { $0.links })
        }
    }

    public static func fetchSubscription(urlString: String, completion: @escaping (Result<CZFVPNSubscriptionFetch, Error>) -> Void) {
        var trimmedInput = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // sub:// 订阅链接：机场/客户端常发的格式，冒号后是真实订
        // 阅地址的 base64（URL 安全变体、可能缺 padding）。旧代码
        // 直接拿 sub:// 去拉，URLSession 不认这个 scheme，当场
        // 报「不支持的 URL」——正是用户 2026-10-26 截图里那条错。
        // 先解开：解出来是单条 http(s) 地址就按它拉；解出来已
        // 经是一批节点链接就直接返回，不用再发请求（这种没真
        // 地址可拉 Clash 格式对名字，namesByLink 留空）。
        if trimmedInput.lowercased().hasPrefix("sub://") {
            let payload = String(trimmedInput.dropFirst("sub://".count))
                .components(separatedBy: .whitespacesAndNewlines).joined()
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let decoded = Data(base64Encoded: padded),
               let decodedText = String(data: decoded, encoding: .utf8),
               !decodedText.isEmpty {
                let decodedTrimmed = decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
                let nodeLines = decodedTrimmed.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.contains("://") && !$0.lowercased().hasPrefix("http") }
                if !nodeLines.isEmpty {
                    completion(.success(CZFVPNSubscriptionFetch(links: nodeLines)))
                    return
                }
                trimmedInput = decodedTrimmed
            } else {
                completion(.failure(NSError(domain: "CZFVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "sub:// 订阅链接解不出来"])))
                return
            }
        }
        guard let url = URL(string: trimmedInput) else {
            completion(.failure(NSError(domain: "CZFVPN", code: -1, userInfo: [NSLocalizedDescriptionKey: "订阅地址不对"])))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // 不少机场按客户端 UA 返回不同格式，给个常见客户端的
        // UA 拿到原始分享链接列表
        request.setValue("Shadowrocket/2.2.50", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data, let raw = String(data: data, encoding: .utf8) else {
                completion(.failure(NSError(domain: "CZFVPN", code: -2, userInfo: [NSLocalizedDescriptionKey: "订阅内容读不出来"])))
                return
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = trimmed
            // 整体 base64 就先解开（去掉空白后能整段解码、且
            // 解出来含 :// 才算数，明文格式不会误伤）；有的
            // 机场用 URL 安全变体（- 和 _），一并兼容
            let compact = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            if !compact.isEmpty, compact.count % 4 == 0,
               let decoded = Data(base64Encoded: compact),
               let decodedText = String(data: decoded, encoding: .utf8),
               decodedText.contains("://") {
                text = decodedText
            }
            let links = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.contains("://") }
            if links.isEmpty {
                completion(.failure(NSError(domain: "CZFVPN", code: -3, userInfo: [NSLocalizedDescriptionKey: "订阅里没找到节点链接"])))
                return
            }
            var fetch = CZFVPNSubscriptionFetch(links: links)
            if let http = response as? HTTPURLResponse {
                applySubscriptionHeaders(from: http, to: &fetch)
            }
            parseStatusLine(in: text, to: &fetch)
            // 并行拉一份 Clash 格式对节点名：失败只当没名字，
            // 不影响导入本身。
            fetchClashNames(url: url) { proxies in
                var completed = fetch
                completed.namesByLink = matchClashNames(proxies, toLinks: links)
                completion(.success(completed))
            }
        }.resume()
    }

    private static func headerValue(_ response: HTTPURLResponse, _ name: String) -> String? {
        for (k, v) in response.allHeaderFields {
            if (k as? String)?.lowercased() == name, let s = v as? String {
                return s
            }
        }
        return nil
    }

    // 响应头里的订阅信息：Subscription-Userinfo 是精确字节
    // 数，优先用它；Profile-Title 可能是 base64: 前缀编码。
    private static func applySubscriptionHeaders(from response: HTTPURLResponse, to fetch: inout CZFVPNSubscriptionFetch) {
        if let ui = headerValue(response, "subscription-userinfo") {
            for part in ui.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                let val = kv[1].trimmingCharacters(in: .whitespaces)
                switch key {
                case "upload": fetch.upload = Int64(val) ?? Double(val).map { Int64($0) }
                case "download": fetch.download = Int64(val) ?? Double(val).map { Int64($0) }
                case "total": fetch.total = Int64(val) ?? Double(val).map { Int64($0) }
                case "expire": fetch.expire = TimeInterval(val) ?? Double(val)
                default: break
                }
            }
        }
        if let pt = headerValue(response, "profile-title") {
            if pt.lowercased().hasPrefix("base64:") {
                let b64 = String(pt.dropFirst("base64:".count))
                if let d = Data(base64Encoded: b64), let s = String(data: d, encoding: .utf8), !s.isEmpty {
                    fetch.title = s
                }
            } else if !pt.isEmpty {
                fetch.title = pt
            }
        } else if let cd = headerValue(response, "content-disposition"),
                  let m = cd.range(of: "filename=") {
            var fn = String(cd[m.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let semi = fn.firstIndex(of: ";") { fn = String(fn[..<semi]) }
            fn = fn.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !fn.isEmpty { fetch.title = fn }
        }
    }

    // 小火箭格式正文里的 STATUS= 行（🚀↑:0.26GB,↓:8.67GB,
    // TOT:170GB💡Expires:2026-12-03）：响应头缺字段时用它
    // 补，GB 按 GiB 换算（与机场响应头的字节数对得上）。
    private static func parseStatusLine(in text: String, to fetch: inout CZFVPNSubscriptionFetch) {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.contains("STATUS=") }) else { return }
        func gb(_ pattern: String) -> Int64? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line),
                  let v = Double(line[r]) else { return nil }
            return Int64(v * 1_073_741_824)
        }
        if fetch.upload == nil { fetch.upload = gb("↑[:：]?\\s*([0-9.]+)GB") }
        if fetch.download == nil { fetch.download = gb("↓[:：]?\\s*([0-9.]+)GB") }
        if fetch.total == nil { fetch.total = gb("TOT[:：]?\\s*([0-9.]+)GB") }
        if fetch.expire == nil,
           let re = try? NSRegularExpression(pattern: "Expires?[:：]?\\s*([0-9]{4}-[0-9]{2}-[0-9]{2})"),
           let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            if let date = df.date(from: String(line[r])) {
                fetch.expire = date.timeIntervalSince1970
            }
        }
    }

    // 用 Clash 客户端 UA 再拉一次同一地址：机场会回 YAML，
    // 里面每条代理都带真名。拉不到/不是 YAML 就返回空。
    private static func fetchClashNames(url: URL, completion: @escaping ([(type: String, server: String, port: Int, name: String)]) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("clash-verge/v2.0.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8), text.contains("proxies:") else {
                completion([])
                return
            }
            completion(parseClashProxyNames(text))
        }.resume()
    }

    /// 极简 Clash YAML 解析：只从 proxies: 段里抠每条的
    /// name/type/server/port。机场生成的条目不是单行 flow
    /// 映射就是块式缩进，两种都按「以 - 开头切条目、条目内
    /// 正则抠字段」处理；抠不全的条目跳过。
    private static func parseClashProxyNames(_ yaml: String) -> [(type: String, server: String, port: Int, name: String)] {
        var out: [(type: String, server: String, port: Int, name: String)] = []
        var inProxies = false
        var chunk = ""
        func flush() {
            defer { chunk = "" }
            guard !chunk.isEmpty else { return }
            func field(_ pattern: String) -> String? {
                guard let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)),
                      m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: chunk) else { return nil }
                return String(chunk[r])
            }
            guard let type = field(#"(?:^|[{\s,])type:\s*([a-z0-9-]+)"#),
                  let server = field(#"(?:^|[{\s,])server:\s*([^\s,}]+)"#),
                  let portStr = field(#"(?:^|[{\s,])port:\s*(\d+)"#),
                  let port = Int(portStr) else { return }
            let name = field(#"(?:^|[{\s,])name:\s*'([^']+)'"#)
                ?? field(#"(?:^|[{\s,])name:\s*"([^"]+)""#)
                ?? field(#"(?:^|[{\s,])name:\s*([^,}\n]+)"#)?.trimmingCharacters(in: .whitespaces)
            guard let name, !name.isEmpty else { return }
            out.append((type: type, server: server, port: port, name: name))
        }
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inProxies {
                if line.hasPrefix("proxies:") { inProxies = true }
                continue
            }
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            // proxies 段结束：顶格的新键（proxy-groups: 等）
            if !line.hasPrefix(" ") && !line.hasPrefix("-") { break }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                flush()
                chunk = String(trimmed.dropFirst(1))
            } else {
                chunk += "\n" + line
            }
        }
        flush()
        return out
    }

    // 把 Clash 名字对回分享链接：键 = 协议+服务器+端口（链
    // 接先经 normalizedShareLink 归一化，老格式也能抠出
    // 真实服务器与端口）。同键多条是机场的克隆条目（配置
    // 相同、只是名字不同），按出现顺序依次贴名，贴哪个
    // 都不影响使用。
    private static func matchClashNames(_ proxies: [(type: String, server: String, port: Int, name: String)], toLinks links: [String]) -> [String: String] {
        guard !proxies.isEmpty else { return [:] }
        var queues: [String: [String]] = [:]
        for p in proxies {
            queues["\(p.type)|\(p.server.lowercased())|\(p.port)", default: []].append(p.name)
        }
        var out: [String: String] = [:]
        for link in links {
            let std = normalizedShareLink(link)
            guard let comps = URLComponents(string: std), let host = comps.host, let port = comps.port else { continue }
            let scheme = nodeScheme(for: link)
            let clashType = scheme == "hy2" ? "hysteria2" : scheme
            let key = "\(clashType)|\(host.lowercased())|\(port)"
            if var q = queues[key], !q.isEmpty {
                out[link] = q.removeFirst()
                queues[key] = q
            }
        }
        return out
    }

    // 只换节点顺序（测速排序用）：活动节点按内容找回，不
    // 重启核心（顺序不影响在跑的核心用哪条节点）
    public func replaceNodeOrder(_ newLinks: [String]) {
        guard !newLinks.isEmpty else { return }
        let previousActive = nodeLink
        UserDefaults.standard.set(newLinks, forKey: Self.nodeListKey)
        if let idx = newLinks.firstIndex(of: previousActive) {
            UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
        }
        refreshSettingsBackup()
    }

    // MARK: - 节点分组（小火箭式：本地组 + 每订阅一组）

    /// 分组只是显示与归属层：核心、测速、轮换仍走上面的
    /// 扁平列表（nodeLinks / 活动下标），分组用链接内容与
    /// 扁平列表对齐——每个链接只属于一个组。nodeGroups()
    /// 每次读时按当前扁平列表校准（已删的链接不显示、没
    /// 归属的链接归本地组），所以旧路径（单删/清理/多选）
    /// 改完扁平列表，分组显示自动跟上，不用逐处同步。
    public struct CZFVPNNodeGroup: Codable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var sourceURL: String?
        public var links: [String]
        public var upload: Int64?
        public var download: Int64?
        public var total: Int64?
        public var expire: TimeInterval?
        public var collapsed: Bool
        // 用户改的组名：非空时订阅刷新不覆盖（见 upsert 与
        // renameGroup）；可选字段，旧存档解码自动为 nil。
        public var customName: String?
        public init(id: String, name: String, sourceURL: String?, links: [String], upload: Int64?, download: Int64?, total: Int64?, expire: TimeInterval?, collapsed: Bool, customName: String? = nil) {
            self.id = id
            self.name = name
            self.customName = customName
            self.sourceURL = sourceURL
            self.links = links
            self.upload = upload
            self.download = download
            self.total = total
            self.expire = expire
            self.collapsed = collapsed
        }
        public var isLocal: Bool { sourceURL == nil }
    }

    private static let nodeGroupsKey = "CZFVPNNodeGroups"
    public static let localGroupId = "local"

    private func loadStoredGroups() -> [CZFVPNNodeGroup] {
        guard let data = UserDefaults.standard.data(forKey: Self.nodeGroupsKey),
              let groups = try? JSONDecoder().decode([CZFVPNNodeGroup].self, from: data) else { return [] }
        return groups
    }

    private func storeGroups(_ groups: [CZFVPNNodeGroup]) {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: Self.nodeGroupsKey)
        }
    }

    /// 当前分组（已按扁平列表校准，本地组恒在第一位）。
    public func nodeGroups() -> [CZFVPNNodeGroup] {
        let flat = nodeLinks
        let flatSet = Set(flat)
        var groups = loadStoredGroups()
        if !groups.contains(where: { $0.sourceURL == nil }) {
            groups.insert(CZFVPNNodeGroup(id: Self.localGroupId, name: "本地节点", sourceURL: nil, links: [], upload: nil, download: nil, total: nil, expire: nil, collapsed: false), at: 0)
        }
        // 本地组挪到第一位（老数据里它可能不在首位）
        if let li = groups.firstIndex(where: { $0.sourceURL == nil }), li != 0 {
            let local = groups.remove(at: li)
            groups.insert(local, at: 0)
        }
        var seen = Set<String>()
        for i in groups.indices {
            groups[i].links = groups[i].links.filter { flatSet.contains($0) && seen.insert($0).inserted }
        }
        let leftovers = flat.filter { !seen.contains($0) }
        if !leftovers.isEmpty, let li = groups.firstIndex(where: { $0.sourceURL == nil }) {
            groups[li].links.append(contentsOf: leftovers)
        }
        return groups
    }

    /// 订阅导入/刷新落点：同地址已有组就刷新那个组（订阅
    /// 不再返回的旧节点从列表删掉，删在用节点走 removeNode
    /// 的既有语义——停核心不自动切），没有就新建一组；
    /// 订阅的链接从别的组认领过来，新链接追加进扁平列表。
    /// 不再有「整体替换」：别的组和手填节点一律不动。
    @discardableResult
    public func upsertSubscriptionGroup(url: String, fetch: CZFVPNSubscriptionFetch) -> (name: String, count: Int, isNew: Bool) {
        var seen = Set<String>()
        let cleaned = fetch.links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var groups = nodeGroups()
        if let idx = groups.firstIndex(where: { $0.sourceURL == url }) {
            let dropped = Set(groups[idx].links).subtracting(cleaned)
            if !dropped.isEmpty {
                removeNodeLinks(dropped)
                groups = nodeGroups()
            }
        }
        for link in cleaned where !nodeLinks.contains(link) {
            _ = addNode(link)
        }
        if !fetch.namesByLink.isEmpty {
            applyNameOverrides(fetch.namesByLink)
        }
        groups = nodeGroups()
        let cleanSet = Set(cleaned)
        for i in groups.indices {
            groups[i].links.removeAll { cleanSet.contains($0) }
        }
        let trimmedTitle = fetch.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = !trimmedTitle.isEmpty ? trimmedTitle : (URL(string: url)?.host ?? "订阅")
        let isNew: Bool
        if let idx = groups.firstIndex(where: { $0.sourceURL == url }) {
            groups[idx].links = cleaned
            groups[idx].name = groups[idx].customName ?? name
            groups[idx].upload = fetch.upload
            groups[idx].download = fetch.download
            groups[idx].total = fetch.total
            groups[idx].expire = fetch.expire
            isNew = false
        } else {
            groups.append(CZFVPNNodeGroup(id: UUID().uuidString, name: name, sourceURL: url, links: cleaned, upload: fetch.upload, download: fetch.download, total: fetch.total, expire: fetch.expire, collapsed: false))
            isNew = true
        }
        storeGroups(groups)
        refreshSettingsBackup()
        return (name, cleaned.count, isNew)
    }

    /// 删掉一整个订阅组及其节点（本地组不可删）。
    public func deleteSubscriptionGroup(id: String) {
        let groups = nodeGroups()
        guard let g = groups.first(where: { $0.id == id }), g.sourceURL != nil else { return }
        removeNodeLinks(Set(g.links))
        storeGroups(nodeGroups().filter { $0.id != id })
        refreshSettingsBackup()
    }

    public func setGroupCollapsed(id: String, collapsed: Bool) {
        var groups = nodeGroups()
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].collapsed = collapsed
        storeGroups(groups)
    }

    /// 改组名（订阅组）：记为自定义名并立即生效，之后订
    /// 阅刷新沿用这个名字、不再被订阅自带标题覆盖；传空
    /// 名 = 清掉自定义名，下次刷新回到订阅自带名。
    public func renameGroup(id: String, name: String) {
        var groups = nodeGroups()
        guard let idx = groups.firstIndex(where: { $0.id == id }), groups[idx].sourceURL != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            groups[idx].customName = nil
        } else {
            groups[idx].customName = trimmed
            groups[idx].name = trimmed
        }
        storeGroups(groups)
        refreshSettingsBackup()
    }

    /// 组内排序落盘（按延迟排序用）：只改各组 links 的顺序，
    /// 扁平列表与核心状态一律不碰。
    public func saveGroupOrder(_ ordered: [CZFVPNNodeGroup]) {
        storeGroups(ordered)
    }

    /// 按链接批量删节点：逐个走 removeNode(at:)，删在用
    /// 节点停核心等语义与单删完全一致；分组靠 nodeGroups()
    /// 读时校准自动跟上。
    public func removeNodeLinks(_ links: Set<String>) {
        guard !links.isEmpty else { return }
        let flat = nodeLinks
        for i in flat.indices.reversed() where links.contains(flat[i]) {
            removeNode(at: i)
        }
    }

    // MARK: - 节点行显示（国旗 / 协议行）

    /// 节点国旗：名字自带国旗 emoji 就用它；否则按名字里的
    /// 国家/城市关键词（中英）推；都推不出给地球。
    public static func nodeFlagEmoji(for link: String) -> String {
        let name = nodeDisplay(for: link).name
        let scalars = Array(name.unicodeScalars)
        if scalars.count >= 2,
           (0x1F1E6...0x1F1FF).contains(Int(scalars[0].value)),
           (0x1F1E6...0x1F1FF).contains(Int(scalars[1].value)) {
            return String(String.UnicodeScalarView([scalars[0], scalars[1]]))
        }
        for entry in flagKeywordsCN where entry.keywords.contains(where: { name.contains($0) }) {
            return entry.flag
        }
        let upper = name.uppercased()
        for entry in flagKeywordsEN where entry.keywords.contains(where: { upper.contains($0) }) {
            return entry.flag
        }
        return "🌐"
    }

    private static let flagKeywordsCN: [(keywords: [String], flag: String)] = [
        (["美国", "美國", "洛杉矶", "洛杉磯", "纽约", "紐約", "西雅图", "西雅圖", "芝加哥", "达拉斯", "達拉斯", "圣何塞", "聖何塞", "阿什本", "硅谷", "矽谷", "波特兰", "波特蘭", "迈阿密", "邁阿密", "凤凰城", "鳳凰城", "丹佛", "拉斯维加斯", "拉斯維加斯"], "🇺🇸"),
        (["日本", "东京", "東京", "大阪"], "🇯🇵"),
        (["香港"], "🇭🇰"),
        (["新加坡", "狮城", "獅城"], "🇸🇬"),
        (["台湾", "台灣", "台北"], "🇹🇼"),
        (["韩国", "韓國", "首尔", "首爾"], "🇰🇷"),
        (["英国", "英國", "伦敦", "倫敦"], "🇬🇧"),
        (["德国", "德國", "法兰克福", "法蘭克福"], "🇩🇪"),
        (["法国", "法國", "巴黎"], "🇫🇷"),
        (["加拿大", "多伦多", "溫哥華", "温哥华"], "🇨🇦"),
        (["澳大利亚", "澳大利亞", "澳洲", "悉尼", "墨尔本", "墨爾本"], "🇦🇺"),
        (["印度尼西亚", "印尼", "雅加达", "雅加達"], "🇮🇩"),
        (["印度", "孟买", "孟買"], "🇮🇳"),
        (["俄罗斯", "俄羅斯", "莫斯科"], "🇷🇺"),
        (["巴西", "圣保罗", "聖保羅"], "🇧🇷"),
        (["荷兰", "荷蘭", "阿姆斯特丹"], "🇳🇱"),
        (["土耳其", "伊斯坦布尔", "伊斯坦堡"], "🇹🇷"),
        (["泰国", "泰國", "曼谷"], "🇹🇭"),
        (["越南", "胡志明", "河内", "河內"], "🇻🇳"),
        (["马来西亚", "馬來西亞", "吉隆坡"], "🇲🇾"),
        (["菲律宾", "菲律賓", "马尼拉", "馬尼拉"], "🇵🇭"),
        (["阿根廷", "布宜诺斯艾利斯"], "🇦🇷"),
        (["西班牙", "马德里", "馬德里"], "🇪🇸"),
        (["意大利", "米兰", "米蘭", "罗马", "羅馬"], "🇮🇹"),
        (["瑞士", "苏黎世", "蘇黎世"], "🇨🇭"),
        (["瑞典", "斯德哥尔摩", "斯德哥爾摩"], "🇸🇪"),
        (["挪威", "奥斯陆", "奧斯陸"], "🇳🇴"),
        (["芬兰", "芬蘭", "赫尔辛基", "赫爾辛基"], "🇫🇮"),
        (["丹麦", "丹麥", "哥本哈根"], "🇩🇰"),
        (["波兰", "波蘭", "华沙", "華沙"], "🇵🇱"),
        (["乌克兰", "烏克蘭", "基辅", "基輔"], "🇺🇦"),
        (["以色列", "特拉维夫", "特拉維夫"], "🇮🇱"),
        (["阿联酋", "阿聯酋", "迪拜"], "🇦🇪"),
        (["南非", "约翰内斯堡", "約翰內斯堡"], "🇿🇦"),
        (["墨西哥", "墨西哥城"], "🇲🇽"),
        (["智利", "圣地亚哥", "聖地亞哥"], "🇨🇱"),
        (["新西兰", "新西蘭", "奥克兰", "奧克蘭"], "🇳🇿"),
        (["奥地利", "奧地利", "维也纳", "維也納"], "🇦🇹"),
        (["爱尔兰", "愛爾蘭", "都柏林"], "🇮🇪"),
        (["葡萄牙", "里斯本"], "🇵🇹"),
        (["中国", "中國"], "🇨🇳"),
    ]

    private static let flagKeywordsEN: [(keywords: [String], flag: String)] = [
        (["USA", "UNITED STATES", "AMERICA", "LOS ANGELES", "NEW YORK", "SEATTLE", "CHICAGO", "DALLAS", "SAN JOSE", "ASHBURN", "SILICON VALLEY", "PORTLAND", "MIAMI", "PHOENIX", "DENVER", "LAS VEGAS"], "🇺🇸"),
        (["JAPAN", "TOKYO", "OSAKA"], "🇯🇵"),
        (["HONG KONG"], "🇭🇰"),
        (["SINGAPORE"], "🇸🇬"),
        (["TAIWAN", "TAIPEI"], "🇹🇼"),
        (["KOREA", "SEOUL"], "🇰🇷"),
        (["UNITED KINGDOM", "LONDON", "BRITAIN", "ENGLAND"], "🇬🇧"),
        (["GERMANY", "FRANKFURT"], "🇩🇪"),
        (["FRANCE", "PARIS"], "🇫🇷"),
        (["CANADA", "TORONTO", "VANCOUVER"], "🇨🇦"),
        (["AUSTRALIA", "SYDNEY", "MELBOURNE"], "🇦🇺"),
        (["INDONESIA", "JAKARTA"], "🇮🇩"),
        (["INDIA", "MUMBAI"], "🇮🇳"),
        (["RUSSIA", "MOSCOW"], "🇷🇺"),
        (["BRAZIL"], "🇧🇷"),
        (["NETHERLANDS", "AMSTERDAM"], "🇳🇱"),
        (["TURKEY", "ISTANBUL"], "🇹🇷"),
        (["THAILAND", "BANGKOK"], "🇹🇭"),
        (["VIETNAM"], "🇻🇳"),
        (["MALAYSIA"], "🇲🇾"),
        (["PHILIPPINES", "MANILA"], "🇵🇭"),
        (["ARGENTINA"], "🇦🇷"),
        (["SPAIN", "MADRID"], "🇪🇸"),
        (["ITALY", "MILAN", "ROME"], "🇮🇹"),
        (["SWITZERLAND", "ZURICH"], "🇨🇭"),
        (["SWEDEN", "STOCKHOLM"], "🇸🇪"),
        (["NORWAY", "OSLO"], "🇳🇴"),
        (["FINLAND", "HELSINKI"], "🇫🇮"),
        (["DENMARK", "COPENHAGEN"], "🇩🇰"),
        (["POLAND", "WARSAW"], "🇵🇱"),
        (["UKRAINE", "KYIV"], "🇺🇦"),
        (["ISRAEL"], "🇮🇱"),
        (["DUBAI", "UAE"], "🇦🇪"),
        (["SOUTH AFRICA"], "🇿🇦"),
        (["MEXICO"], "🇲🇽"),
        (["CHILE"], "🇨🇱"),
        (["NEW ZEALAND", "AUCKLAND"], "🇳🇿"),
        (["AUSTRIA", "VIENNA"], "🇦🇹"),
        (["IRELAND", "DUBLIN"], "🇮🇪"),
        (["PORTUGAL", "LISBON"], "🇵🇹"),
        (["CHINA"], "🇨🇳"),
    ]

    /// 协议行（节点名下面那行小字）：协议 / 传输 / 安全，
    /// 如 "VLESS / WEBSOCKET / TLS"；解析不出就只给协议。
    public static func nodeProtocolLine(for link: String) -> String {
        let scheme = nodeScheme(for: link)
        switch scheme {
        case "ss": return "SHADOWSOCKS"
        case "hysteria2", "hy2": return "HYSTERIA2"
        case "tuic": return "TUIC"
        case "socks", "socks5": return "SOCKS5"
        case "anytls": return "ANYTLS"
        case "json": return "JSON 出站"
        case "vmess":
            if let json = vmessJSON(for: link) {
                var parts = ["VMESS"]
                if let net = json["net"] as? String, let t = transportDisplayName(net) { parts.append(t) }
                if (json["tls"] as? String) == "tls" { parts.append("TLS") }
                return parts.joined(separator: " / ")
            }
            return "VMESS"
        default:
            var parts = [scheme.uppercased()]
            let std = normalizedShareLink(link)
            var query: [String: String] = [:]
            if let comps = URLComponents(string: std), let items = comps.queryItems {
                for item in items where query[item.name] == nil {
                    query[item.name] = item.value ?? ""
                }
            }
            if let type = query["type"], let t = transportDisplayName(type) { parts.append(t) }
            if scheme == "trojan" {
                parts.append(query["security"] == "none" ? "无加密" : "TLS")
            } else if let sec = query["security"] {
                if sec == "tls" { parts.append("TLS") }
                else if sec == "reality" { parts.append("REALITY") }
            }
            return parts.joined(separator: " / ")
        }
    }

    private static func transportDisplayName(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "ws", "websocket": return "WEBSOCKET"
        case "grpc": return "GRPC"
        case "tcp", "raw": return "TCP"
        case "h2", "http": return "HTTP/2"
        case "quic": return "QUIC"
        case "kcp", "mkcp": return "KCP"
        case "xhttp": return "XHTTP"
        case "splithttp": return "SPLITHTTP"
        case "httpupgrade": return "HTTPUPGRADE"
        default: return nil
        }
    }

    /// 预热：有 App 标了 VPN 且预热开关没关时，提前把核心
    /// 拉起来（用全局当前节点），第一个 VPN App 点开就不
    /// 用等冷启动。核心已经在跑就直接返回，不打扰正在用
    /// 的连接；起了没人用时原有的 30 分钟自动停不覆盖这种
    /// 情况（没 App 启动过），核心随宿主进程被系统挂起，
    /// 不额外耗电
    public func prewarmIfNeeded() {
        // 测速窗口内不预热：预热起核心会让探针被占用挡下、
        // 测速结果不准；预热本就是 opportunistic，下次进前台还会再跑
        vpnCoreLock.lock()
        let pinging = isPinging
        // 测速结束时核心没在跑就一直不预热：见字段注释，
        // 与时间无关、切走再进、进程重启都不放行，直到
        // 亲手起核心、打开标了 VPN 的 App、亲手拨一次
        // 预热开关三者之一出现。恢复成“在跑”时下面
        // guard !isRunning 本来就返回，不需要这层。
        let suppressed = prewarmSuppressedAfterPing
        vpnCoreLock.unlock()
        if pinging { return }
        if suppressed { return }
        if UserDefaults.standard.object(forKey: "CZFVPNPrewarm") != nil, !UserDefaults.standard.bool(forKey: "CZFVPNPrewarm") {
            return
        }
        guard !isRunning, !nodeLinks.isEmpty else { return }
        let defaults = UserDefaults.standard
        let hasMarked = defaults.dictionaryRepresentation().keys.contains { key in
            key.hasPrefix("CZFVPNEnabled-") && defaults.bool(forKey: key)
        }
        guard hasMarked else { return }
        _ = start()
    }

    public func removeNode(at index: Int) {
        var links = nodeLinks
        guard links.indices.contains(index) else { return }
        // 删在用节点：以前 previousActive 找不回来就落到最后
        // 一个，applyActiveNodeChange 还会在核心在跑时直接按
        // 新节点重启——用户删在用节点本意是停掉，结果被静默
        // 切到别的节点继续跑。现在删在用节点就停核心，不自
        // 动切；选中项落到第一个（核心停着，不会立刻生效）。
        // 删非在用节点仍按内容找回，不动核心归属。
        let wasActive = index == activeNodeIndex
        let previousActive = nodeLink
        links.remove(at: index)
        UserDefaults.standard.set(links, forKey: Self.nodeListKey)
        if let newIdx = links.firstIndex(of: previousActive) {
            UserDefaults.standard.set(newIdx, forKey: Self.activeNodeKey)
        } else if wasActive {
            UserDefaults.standard.set(0, forKey: Self.activeNodeKey)
        } else {
            UserDefaults.standard.set(max(links.count - 1, 0), forKey: Self.activeNodeKey)
        }
        if wasActive {
            stop()
        } else {
            applyActiveNodeChange()
        }
        refreshSettingsBackup()
    }

    public func setActiveNode(at index: Int) {
        guard nodeLinks.indices.contains(index) else { return }
        UserDefaults.standard.set(index, forKey: Self.activeNodeKey)
        applyActiveNodeChange()
        refreshSettingsBackup()
    }

    // 活动节点变了而核心在跑：立刻按新节点重启（改完即生效）；
    // 没有可用节点了就停掉
    private func applyActiveNodeChange() {
        // 测速窗口内不切：切节点会重启核心、打断测速；
        // 节点选择已写进 UserDefaults，测速收尾
        // 会比对测速前后的活动链接、再跟随这次切换（见
        // pingAllNodes 末尾），用户的切换不会丢。
        vpnCoreLock.lock()
        let pinging = isPinging
        vpnCoreLock.unlock()
        if pinging { return }
        guard isRunning else { return }
        if nodeLink.isEmpty {
            stop()
        } else if runningLink != nodeLink {
            _ = start()
        }
    }

    // 节点显示名：优先链接里的备注（标准格式的 # 片段；老格式
    // 经 normalizedShareLink 后 remarks 也会落到片段里），其次
    // 是 地址:端口——列表里一眼能认出是哪个节点
    public static func nodeDisplay(for link: String) -> (name: String, detail: String) {
        let std = normalizedShareLink(link)
        var name = ""
        var detail = ""
        if let comps = URLComponents(string: std) {
            if let frag = comps.fragment, !frag.isEmpty {
                name = frag
            }
            if let host = comps.host, !host.isEmpty {
                detail = comps.port.map { "\(host):\($0)" } ?? host
            }
        }
        // 链接自带名字之外的两个来源（都没有才落到域名兜底）：
        // vmess 的名字在 base64 JSON 的 ps 字段里；机场小火箭
        // 格式的 vless 链接干脆不带备注，名字是导入订阅时从
        // Clash 格式对回来的覆盖名（见 applyNameOverrides）。
        if name.isEmpty, nodeScheme(for: link) == "vmess",
           let ps = vmessJSON(for: link)?["ps"] as? String, !ps.isEmpty {
            name = ps
        }
        if name.isEmpty, let override = nameOverride(for: link), !override.isEmpty {
            name = override
        }
        if name.isEmpty {
            name = detail.isEmpty ? "节点" : detail
        }
        // 行内显示 scheme：节点行一眼看出协议；支不支持由
        // isSupportedNodeScheme 按转换器清单再分级（未测到的
        // 不支持节点行内直接标“不支持”，不等人测完才知道）。
        let scheme = nodeScheme(for: link)
        if !scheme.isEmpty {
            detail = detail.isEmpty ? scheme : "\(scheme) · \(detail)"
        }
        // 不验证书标记：tuic 且含 allowInsecure 时标（判定在
        // CZFSingBoxRouting.showsInsecureMark：tuic 出站一定
        // 写 tls 块，insecure 参数真实生效才标）。
        if CZFSingBoxRouting.showsInsecureMark(for: link) {
            detail = detail.isEmpty ? "不验证书" : "\(detail) · 不验证书"
        }
        return (name, detail)
    }

    // MARK: - 节点名覆盖（订阅导入时从 Clash 格式对回）

    private static let nameOverrideKey = "CZFVPNNodeNameOverrides"

    public static func nameOverride(for link: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: nameOverrideKey) as? [String: String])?[link]
    }

    // 写入一批对回来的名字：合并进存量，并剪掉已不在节点
    // 列表里的链接，不让这份表无限长。
    public func applyNameOverrides(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        var stored = (UserDefaults.standard.dictionary(forKey: Self.nameOverrideKey) as? [String: String]) ?? [:]
        for (k, v) in map { stored[k] = v }
        let flat = Set(nodeLinks)
        stored = stored.filter { flat.contains($0.key) }
        UserDefaults.standard.set(stored, forKey: Self.nameOverrideKey)
    }

    // vmess 链接的 base64 JSON 全文（ps/add/port/net/tls 都在里面）
    private static func vmessJSON(for link: String) -> [String: Any]? {
        guard link.hasPrefix("vmess://") else { return nil }
        let rest = String(link.dropFirst("vmess://".count))
        let payload = rest.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? rest
        var b64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return obj as? [String: Any]
    }

    /// 节点链接的协议 scheme（小写；原始 Xray JSON 出站记
    /// 为 json；无 :// 的纯文本行记为空串）。取原文链接，
    /// 不取归一化后的（老格式 vless 归一化后 scheme 不变，
    /// 但原文才是用户贴进来的协议）。
    public static func nodeScheme(for link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return "json"
        }
        guard let range = trimmed.range(of: "://") else {
            return ""
        }
        return String(trimmed[..<range.lowerBound]).lowercased()
    }

    /// 协议清单分级：CZFSingBoxConfig 的 sing-box 出站构建
    /// 认这些协议族（VMess/VLESS/Hysteria2/SS/SOCKS/Trojan/
    /// TUIC/AnyTLS）+ 原始 sing-box JSON 出站；其余未列出
    /// 的 scheme、无 scheme 的纯文本一律不支持。注意这是
    /// 静态分级：清单内的节点仍可能因参数缺失/不合法被
    /// 配置生成拒收，那种以实测的 conversionFailed 为准。
    public static func isSupportedNodeScheme(_ scheme: String) -> Bool {
        // hy2 = Hysteria2 的标准别名，socks5 = SOCKS 的标准链接
        // scheme；静态分级宁可多认别名——真不认的节点实测时
        // conversionFailed 会纠回“不支持”，反过来漏标却要等
        // 实测才知道它是好的。
        ["vmess", "vless", "hysteria2", "hy2", "ss", "socks", "socks5", "trojan", "json", "tuic", "anytls"].contains(scheme)
    }

    public static func isEnabled(for appInfo: LCAppInfo) -> Bool {
        guard let bundleId = appInfo.bundleIdentifier() else { return false }
        return UserDefaults.standard.bool(forKey: enabledKeyPrefix + bundleId)
    }

    public static func setEnabled(_ enabled: Bool, for appInfo: LCAppInfo) {
        guard let bundleId = appInfo.bundleIdentifier() else { return }
        UserDefaults.standard.set(enabled, forKey: enabledKeyPrefix + bundleId)
        // 养号锁定（1）：刚打开 VPN 且还没钉过节点、也没亲手选
        // 过跟随全局时，立刻把当前全局节点钉成这个 App 的专属
        // 节点；以后全局怎么换都不动它。已经钉过的、亲手选过
        // 跟随全局的，都不动
        if enabled,
           nodeOverride(for: appInfo) == nil,
           !isFollowGlobalExplicit(for: appInfo) {
            let current = shared.nodeLink
            if !current.isEmpty {
                setNodeOverride(current, for: appInfo)
            }
        }
    }

    // 用户是否在 App 设置里亲手选过"跟随全局"（缺省 false）
    public static func isFollowGlobalExplicit(for appInfo: LCAppInfo) -> Bool {
        guard let bundleId = appInfo.bundleIdentifier() else { return false }
        return UserDefaults.standard.bool(forKey: followGlobalKeyPrefix + bundleId)
    }

    // 按 App 指定节点：存链接本身而不是下标，节点列表增删、
    // 排序、订阅替换都不会让指定关系错位。钉死后即使这条链
    // 接不在列表里了也照用——列表只是选节点的菜单，不是
    // App 的 IP 归属；删了菜单项就悄悄换 IP，正是养号最忌
    // 讳的。亲手选跟随全局时才回落全局
    public static func nodeOverride(for appInfo: LCAppInfo) -> String? {
        guard let bundleId = appInfo.bundleIdentifier() else { return nil }
        let saved = UserDefaults.standard.string(forKey: nodeOverrideKeyPrefix + bundleId)
        return (saved?.isEmpty == false) ? saved : nil
    }

    public static func setNodeOverride(_ link: String?, for appInfo: LCAppInfo) {
        guard let bundleId = appInfo.bundleIdentifier() else { return }
        if let link, !link.isEmpty {
            UserDefaults.standard.set(link, forKey: nodeOverrideKeyPrefix + bundleId)
            UserDefaults.standard.removeObject(forKey: followGlobalKeyPrefix + bundleId)
        } else {
            UserDefaults.standard.removeObject(forKey: nodeOverrideKeyPrefix + bundleId)
            UserDefaults.standard.set(true, forKey: followGlobalKeyPrefix + bundleId)
        }
    }

    // 这个 App 实际用的节点链接：钉死过就用钉死的，不管它还
    // 在不在列表里；没钉死才用全局活动节点
    public func effectiveLink(for appInfo: LCAppInfo?) -> String {
        if let appInfo,
           let override = Self.nodeOverride(for: appInfo) {
            return override
        }
        return nodeLink
    }

    // MARK: - 插件部署（signApp 签名前调用）

    // 按标记把 CZFProxy.dylib 同步进该 App 的专属插件目录：
    // 开着 → 内容不一致就拷入（随后 signTweaks 会签它）；
    // 关着 → 残留删掉。
    // 返回 true 表示这次换上了新插件文件——调用方要立刻给它
    // 单独补一签（见 signApp 里的说明）
    @discardableResult
    public static func syncProxyTweak(for appInfo: LCAppInfo, tweakFolderUrl: URL) -> Bool {
        let dest = tweakFolderUrl.appendingPathComponent("CZFProxy.dylib")
        let fm = FileManager.default
        // 目录可能还不存在（自动建的 CZFVPN 目录名只有名字、没落盘），
        // 先建出来——不建的话随后 signTweaks 枚举目录会直接报错，
        // 整个 App 都打不开（真机实测）
        try? fm.createDirectory(at: tweakFolderUrl, withIntermediateDirectories: true)
        // 养号严格模式标记（3）：钉死节点的 App 在插件目录里留
        // 一个 CZFProxyStrict 空文件，插件启动时读到它就改成
        // fail-closed（核心不在时断网不直连）；跟随全局的 App
        // 不留标记，维持原来的 fail-open。标记不是 dylib，
        // 不影响返回值（返回值只表示 dylib 有没有换上）
        let strictMarker = tweakFolderUrl.appendingPathComponent("CZFProxyStrict")
        // 节点端点豁免名单（经典启动核心与插件同进程用）：全部
        // 候选节点的 server+端口写成一个文本文件放插件同目录，
        // 插件启动时读它——核心自己连节点服务器的那几跳不许被
        // 钩子拦（解析给假 IP / TCP 又拐回核心自己 / 严格模式
        // 误杀核心的 UDP），否则经典模式核心起来了也出不了网。
        // 多任务下核心在宿主进程、插件在游客进程，名单用不上，
        // 写了也无害。内容与现文件一致就不重写。
        let endpointsFile = tweakFolderUrl.appendingPathComponent("CZFProxyCoreEndpoints")
        if isEnabled(for: appInfo) {
            if nodeOverride(for: appInfo) != nil {
                if !fm.fileExists(atPath: strictMarker.path) {
                    try? Data().write(to: strictMarker)
                }
            } else {
                try? fm.removeItem(at: strictMarker)
            }
            let endpointsText = Self.coreEndpointsText()
            if (try? String(contentsOf: endpointsFile, encoding: .utf8)) != endpointsText {
                try? endpointsText.write(to: endpointsFile, atomically: true, encoding: .utf8)
            }
            guard let src = Bundle.main.url(forResource: "CZFProxy", withExtension: "dylib") else { return false }
            let srcData = try? Data(contentsOf: src)
            let destData = try? Data(contentsOf: dest)
            var changed = false
            if destData != srcData {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: src, to: dest)
                changed = true
            }
            // 幻影依赖自愈：发布包里的 CZFProxy 只依赖系统
            // 库，但用户实测机上副本被重签/重打包环节加了一
            // 条 @loader_path/Frameworks/<哈希名>.dylib 的
            // 加载命令，指向的文件根本不存在，游客 dlopen
            // 插件直接报 Failed to load tweaks、代理不生效。
            // 同步时扫一遍目标文件：凡是 @loader_path 相对依
            // 赖在插件目录里找不到对应文件的，把那条加载命
            // 令按 LCMachOUtils 去重同款做法废掉（cmd 改成
            // 0x114515），随后照常单独补签。包内副本干净时
            // 扫不到任何东西，行为与旧版一致。
            // 3.8.12 只废加载命令还不够：那次修复后报错变成
            // Symbol not found: _NSClassFromString (Expected
            // in libobjc)——注入方加命令时把全部未定义符号
            // 的库序号整体 +1 了（已与发布包原文件逐项核对：
            // UUID 相同、原文件该符号序号 = 1 即 Foundation，
            // 机上副本 dyld 却按 2 去 libobjc 找）。废掉幻影
            // 命令后序号必须同步减回去，修法见下面函数的
            // chained fixups 导入表与符号表两处回退。
            if fm.fileExists(atPath: dest.path), Self.czfStripPhantomLoaderDeps(at: dest) {
                changed = true
            }
            return changed
        } else {
            try? fm.removeItem(at: dest)
            try? fm.removeItem(at: strictMarker)
            try? fm.removeItem(at: endpointsFile)
        }
        return false
    }

    // 扫一个 Mach-O（thin 64 位或 fat，逐 slice）里的 dylib
    // 加载命令：路径以 @loader_path/ 开头、且相对插件所在
    // 目录解析后文件不存在的，判定为幻影依赖，把该命令的
    // cmd 原地改成 0x114515（LCMachOUtils 去重重复依赖的
    // 同款废法，dyld 跳过不认的命令号）。改动落盘并返回
    // true；解析异常或没有幻影依赖返回 false、文件不动。
    // 只查 @loader_path 相对依赖一条：系统库是绝对路径，
    // 不在检查范围；自家插件除系统库外没有别的依赖，所
    // 以任何 @loader_path 依赖缺文件都是外来加的。
    // 同一轮里若废掉了 K 条幻影命令，再把被注入方整体
    // +K 的库序号回退 K：(1) LC_DYLD_CHAINED_FIXUPS 导
    // 入表每项的低字节 lib（dyld 实际绑定走的就是这张
    // 表）；(2) LC_SYMTAB 里未定义符号 n_desc 的高字节
    // 序号。序号大于 K 的才回退（≤K 的本就指向幻影库、
    // 原文件里不存在这种符号，不动）。整个回退只在本轮
    // 真废掉过幻影命令时才跑——干净文件一个字节都不动；
    // 而能跑到回退的文件本来就已经坏到加载不了，修错
    // 也不会让原本能用的配置变差。
    private static func czfStripPhantomLoaderDeps(at fileURL: URL) -> Bool {
        guard var bytes = try? [UInt8](Data(contentsOf: fileURL)), bytes.count >= 32 else { return false }
        func u32le(_ off: Int) -> UInt32 {
            UInt32(bytes[off]) | UInt32(bytes[off + 1]) << 8 | UInt32(bytes[off + 2]) << 16 | UInt32(bytes[off + 3]) << 24
        }
        func u32be(_ off: Int) -> UInt32 {
            UInt32(bytes[off]) << 24 | UInt32(bytes[off + 1]) << 16 | UInt32(bytes[off + 2]) << 8 | UInt32(bytes[off + 3])
        }
        let folderPath = fileURL.deletingLastPathComponent().path
        var patched = false
        // 单个 thin 64 位 slice：base 是 slice 在文件中的偏移
        func scanSlice(base: Int, size: Int) {
            guard base + 32 <= bytes.count, u32le(base) == 0xfeedfacf else { return }
            let ncmds = Int(u32le(base + 16))
            var off = base + 32
            let end = min(base + size, bytes.count)
            var slicePhantoms = 0
            var chainedFixups: (off: Int, size: Int)?
            var symtab: (off: Int, count: Int)?
            for _ in 0..<ncmds {
                guard off + 8 <= end else { break }
                let cmd = u32le(off)
                let cmdsize = Int(u32le(off + 4))
                guard cmdsize >= 8, off + cmdsize <= end else { break }
                if cmd == 0xc || cmd == 0x80000018 || cmd == 0x1f || cmd == 0x80000023 {
                    // dylib_command：name.offset 在命令头 +8 处
                    let nameOff = Int(u32le(off + 8))
                    if nameOff >= 24, off + nameOff < off + cmdsize {
                        var name = ""
                        var p = off + nameOff
                        while p < off + cmdsize, bytes[p] != 0 {
                            name.append(Character(UnicodeScalar(bytes[p])))
                            p += 1
                        }
                        if name.hasPrefix("@loader_path/") {
                            let rest = String(name.dropFirst("@loader_path/".count))
                            let target = (folderPath as NSString).appendingPathComponent(rest)
                            if !FileManager.default.fileExists(atPath: target) {
                                bytes[off] = 0x15
                                bytes[off + 1] = 0x45
                                bytes[off + 2] = 0x11
                                bytes[off + 3] = 0x00
                                patched = true
                                slicePhantoms += 1
                            }
                        }
                    }
                } else if cmd == 0x80000034 || cmd == 0x34, cmdsize >= 16 {
                    // LC_DYLD_CHAINED_FIXUPS：dataoff/datasize
                    // 是相对 slice 起点的文件偏移
                    chainedFixups = (Int(u32le(off + 8)), Int(u32le(off + 12)))
                } else if cmd == 0x2, cmdsize >= 24 {
                    // LC_SYMTAB：symoff/nsyms（字符串表用不上）
                    symtab = (Int(u32le(off + 8)), Int(u32le(off + 12)))
                }
                off += cmdsize
            }
            guard slicePhantoms > 0 else { return }
            let k = slicePhantoms
            // (1) chained fixups 导入表：头部 +8 是导入表
            // 相对偏移、+16 是导入项数；每项 4 字节，低字
            // 节是库序号（其余位是 weak 标记与符号名偏移，
            // 只改低字节就不碰它们）。发布包原文件已实测
            // 核对过这套布局（86 项、序号 1–4 对应四个系
            // 统库）。
            if let fx = chainedFixups, fx.off > 0, fx.size >= 24 {
                let blob = base + fx.off
                if blob + 24 <= end, blob + fx.size <= bytes.count {
                    let importsOff = Int(u32le(blob + 8))
                    let importsCount = Int(u32le(blob + 16))
                    let table = blob + importsOff
                    if importsCount > 0, importsCount < 100000, table + importsCount * 4 <= blob + fx.size {
                        for i in 0..<importsCount {
                            let eoff = table + i * 4
                            let lib = Int(bytes[eoff])
                            if lib > k {
                                bytes[eoff] = UInt8(lib - k)
                            }
                        }
                    }
                }
            }
            // (2) 符号表：nlist64 每项 16 字节，n_type 在
            // +4、n_desc（UInt16）在 +6，序号在 n_desc 高
            // 字节。只回退未定义且非调试项的符号，与原文
            // 件的序号编码一致（实测 0x0100–0x0400）。
            if let st = symtab, st.count > 0, st.count < 100000 {
                let table = base + st.off
                if table + st.count * 16 <= end {
                    for i in 0..<st.count {
                        let eoff = table + i * 16
                        let nType = bytes[eoff + 4]
                        guard nType & 0x0e == 0, nType & 0xe0 == 0 else { continue }
                        var desc = Int(bytes[eoff + 6]) | Int(bytes[eoff + 7]) << 8
                        let ordinal = desc >> 8
                        if ordinal > k {
                            desc -= k << 8
                            bytes[eoff + 6] = UInt8(desc & 0xff)
                            bytes[eoff + 7] = UInt8((desc >> 8) & 0xff)
                        }
                    }
                }
            }
        }
        if u32le(0) == 0xfeedfacf {
            scanSlice(base: 0, size: bytes.count)
        } else if u32be(0) == 0xcafebabe {
            let narch = Int(u32be(4))
            var aoff = 8
            for _ in 0..<narch {
                guard aoff + 20 <= bytes.count else { break }
                let sliceOff = Int(u32be(aoff + 8))
                let sliceSize = Int(u32be(aoff + 12))
                scanSlice(base: sliceOff, size: sliceSize)
                aoff += 20
            }
        } else {
            return false
        }
        guard patched else { return false }
        return (try? Data(bytes).write(to: fileURL)) != nil
    }

    // 豁免名单内容：节点列表里每条链接都按起核心的同一条路
    // 生成 sing-box 配置，再把出站里的 server / server_port
    // 摘出来——摘的就是核心实际要拨的端点，协议差异（vmess
    // 的 JSON、ss 的 authority、原始 JSON 节点）都由配置生成
    // 器兜住，这里不另写解析。全部候选都写：核心故障切换 /
    // 自动轮换换到哪个节点都在名单里。一行一个
    // 「server<TAB>port」，坏链接跳过。
    private static func coreEndpointsText() -> String {
        var lines = Set<String>()
        for link in shared.nodeLinks {
            guard let json = try? CZFSingBoxConfig.configJSON(for: Self.normalizedShareLink(link), socksPort: Self.socksPort, httpPort: 10828),
                  let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let outbounds = dict["outbounds"] as? [[String: Any]] else { continue }
            for outbound in outbounds {
                if let server = outbound["server"] as? String, !server.isEmpty,
                   let port = outbound["server_port"] as? Int, port > 0 {
                    lines.insert("\(server)\t\(port)")
                }
            }
        }
        return lines.sorted().joined(separator: "\n")
    }

    // MARK: - 核心启停

    // 被标记 App 启动前调用：核心已在跑且节点没换就直接返回；
    // 失败只记 lastError 不抛——游客侧插件有 fail-open，核心不
    // 在时 App 直连不断网（钉死节点 App 的插件读到严格标记
    // 后改成断网不直连，见 syncProxyTweak）。
    // 设置页亲手起停核心时调：把这次手动动作记进
    // coreActionEpoch，让测速收尾知道测速窗口内用户亲手
    // 动过核心——收尾就不再按测速前状态把用户的决定 undo
    // 回去（测速中亲手停核心，测完又被收尾起回来，正是
    // “测速把核心启动了”的一种真实路径）。
    public func noteManualCoreToggle(started: Bool) {
        vpnCoreLock.lock()
        coreActionEpoch += 1
        // 亲手起核心才清掉测速后的预热抑制：亲手停核心不
        // 清——停完切回前台又被预热起回来，和测速后翻盘是
        // 同一类毛病；想恢复预热，拨一次预热开关即可。
        if started { prewarmSuppressedAfterPing = false }
        vpnCoreLock.unlock()
    }

    // 设置页亲手拨预热开关时调：只清掉测速后的预热抑制，
    // 不记进 coreActionEpoch——拨开关本身不动核心状态，
    // 不应让测速收尾因此跳过恢复。
    public func notePrewarmSwitchToggled() {
        vpnCoreLock.lock()
        prewarmSuppressedAfterPing = false
        vpnCoreLock.unlock()
    }

    public func ensureRunning(for appInfo: LCAppInfo? = nil) {
        // 开 App 是用户/ App 动作：记进 epoch，测速收尾的
        // 校验不会把它当成自动触发 undo 掉。
        if appInfo != nil {
            vpnCoreLock.lock()
            coreActionEpoch += 1
            vpnCoreLock.unlock()
        }
        // 有被标记 App 在启动：取消待执行的自动停，并记下时间
        pendingStopWork?.cancel()
        pendingStopWork = nil
        lastFlaggedLaunchAt = Date()
        // 养号锁定（1）补钉：已经开了 VPN、还没钉过节点、也没
        // 亲手选过跟随全局的旧 App，第一次启动时就把当前全局
        // 节点钉死，之后不再跟全局走
        if let appInfo,
           Self.isEnabled(for: appInfo),
           Self.nodeOverride(for: appInfo) == nil,
           !Self.isFollowGlobalExplicit(for: appInfo) {
            let current = nodeLink
            if !current.isEmpty {
                Self.setNodeOverride(current, for: appInfo)
            }
        }
        // 测速窗口内不开核心：这时起核心会让探针被占用挡下、
        // 测速结果不准。只记下这次请求，测速收尾会补跑它；取消自动
        // 停、记启动时间、补钉节点这三件上面已经做了，不受
        // 挡下影响。
        vpnCoreLock.lock()
        let pinging = isPinging
        if pinging, let appInfo {
            deferredEnsureApp = appInfo
        }
        vpnCoreLock.unlock()
        if pinging { return }
        // 打开标了 VPN 的 App 是手动动作：清掉测速后的预热
        // 抑制，之后预热/自动启动照常工作。测速窗口内被挡
        // 下的请求走收尾补跑，补跑时 pinging 已是 false，
        // 同样在这里清掉；测速窗口内只记不启动，抑制不动。
        if appInfo != nil {
            vpnCoreLock.lock()
            prewarmSuppressedAfterPing = false
            vpnCoreLock.unlock()
        }
        // 用这个 App 自己的节点（钉死过就用钉死的，没钉死跟随
        // 全局）
        let link = effectiveLink(for: appInfo).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        if isRunning && runningLink == link {
            if let bid = appInfo?.bundleIdentifier() {
                coreOwnerBundleId = bid
            }
            coreOwnerAppInfo = appInfo
            scheduleRotateCheck()
            return
        }
        // 养号保护（2）：核心已经归另一个 App 所有（那个 App
        // 钉死了节点、核心正跑在它的节点上），这个 App 自动
        // 启动不准抢核心换节点——换 IP 正是养号最忌讳的。
        // 手动在设置里切节点（applyActiveNodeChange / start()）
        // 会清掉归属，那时才换；自动启动只保证核心在跑
        if isRunning,
           let owner = coreOwnerBundleId,
           let bid = appInfo?.bundleIdentifier(),
           owner != bid {
            lastError = "核心正被另一个已钉死节点的 App 占用，暂不切换（手动在设置里切节点可强制切换）"
            return
        }
        if start(withLink: link) {
            if let bid = appInfo?.bundleIdentifier() {
                coreOwnerBundleId = bid
            }
            coreOwnerAppInfo = appInfo
            scheduleRotateCheck()
        } else {
            // 启动时节点起不来就地往下一个切：之前是起不来
            // 就停在死节点上，App 一直不通；轮换要等 10 次
            // 失败才触发，根本等不到。排序与轮换同款（新鲜
            // 测速从快到慢，没测速排最后），钉死的改 override，
            // 跟随全局的改全局活动节点；一圈都不通就停。
            startFallback(from: link, for: appInfo)
        }
    }

    // 多任务列表变化后由 MultitaskDockManager 调用：还在跑的
    // App 里已经没有被标记的了，就按自动停档位排一个停核心；
    // 期间有被标记 App 起来（ensureRunning 会取消）就不停
    public func noteRunningAppsChanged(stillHasFlagged: Bool) {
        // 宿主自身走节点的开关开着时，核心同样算"还在被用"
        if stillHasFlagged || Self.isHostProxyEnabled {
            pendingStopWork?.cancel()
            pendingStopWork = nil
            return
        }
        guard isRunning else { return }
        pendingStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            if Self.isHostProxyEnabled { return }
            if Date().timeIntervalSince(self.lastFlaggedLaunchAt) < Self.autoStopDelay { return }
            // 测速窗口内不自动停：到点停核心、下一按钮刷新
            // 翻出已变状态，看起来就是“点测速/排序切了核心”；
            // 测速中到点就跳过这次自动停，下次 App 变化再排。
            self.vpnCoreLock.lock()
            let pinging = self.isPinging
            self.vpnCoreLock.unlock()
            if pinging { return }
            self.stop()
        }
        pendingStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoStopDelay, execute: work)
    }

    @discardableResult
    public func start() -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        // 手动 / 宿主 / 预热起核心：不归某个 App 所有，清掉
        // 养号归属，之后 App 自动启动才可以重新抢核心
        coreOwnerBundleId = nil
        coreOwnerAppInfo = nil
        return start(withLink: nodeLink)
    }

    // 用指定链接起核心：已在跑且正是这条链接就直接成功；
    // 在跑的是别的节点先停再按这条起
    private func start(withLink rawLink: String) -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else {
            lastError = "还没填节点链接"
            return false
        }
        if isRunning && runningLink == link { return true }
        if isRunning { stop() }

        // 临时探针在跑时拒绝起主核心：
        // 探针与主核心同进程只能活一个，探针起在前、主核心后起
        // 就是双运行时；探针几秒就完，拒绝后重试即可。stop()
        // 后 flag 仍为真只可能是探针（stop 成败都清 flag），
        // 所以这句报错只会在测速进行中出现。
        if CZFSingBoxCore.isServiceRunning {
            lastError = "测速进行中，稍后再试"
            return false
        }

        // 全量 sing-box（2026-11-05 用户定版）：所有协议统一
        // 由 CZFSingBoxConfig 生成配置、CZFSingBoxCore 启动，
        // 原 Xray 转换/启动路径已删。进来前已停掉旧核心
        // （先停后起，同一时刻只活一个核心，端口复用）。
        return startSingBox(withLink: link)
    }

    // sing-box 核心启动（调用方 start(withLink:) 已持锁且已
    // 停掉旧核心，这里不再重复加锁）。本地入口沿用同一对
    // 回环端口（SOCKS 10827 / HTTP 10828），插件侧的代理
    // 指向不用改。进配置生成前先把 vless/trojan 老格式归一
    // 化（normalizedShareLink 对其余协议原样返回）；归一化
    // 只影响生成的配置，runningLink 仍记原始链接（在跑检
    // 查、钉死节点都按原文比对）。启动失败时 isRunning 保持
    // false、runningCore 保持 nil，不碰严格标记：钉死节点
    // 的 App 插件读到 CZFProxyStrict 标记仍断网不直连
    // （fail-closed），跟随全局的 App 维持既有 fail-open——
    // 失败本身绝不偷偷改成直连或改标记。
    private func startSingBox(withLink link: String) -> Bool {
        let config: String
        do {
            config = try CZFSingBoxConfig.configJSON(for: Self.normalizedShareLink(link), socksPort: Self.socksPort, httpPort: 10828)
        } catch {
            lastError = "节点配置生成失败：\(error.localizedDescription)"
            return false
        }
        do {
            try CZFSingBoxCore.start(configJSON: config)
        } catch {
            lastError = "sing-box 启动失败：\(error.localizedDescription)"
            return false
        }
        isRunning = true
        runningLink = link
        runningCore = .singBox
        lastError = nil
        return true
    }

    public func stop() {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        // 旧测速延迟重试链接的清理：只读版测速不再写它，
        // 这里只在非测速窗口内清掉残留，免得事后起回来。
        if !isPinging { pingRetryLink = nil }
        // 全量 sing-box 后只有一个核心可停。stop 失败也吞掉
        // （CZFSingBoxCore 语义：失败也置 false），状态照常
        // 清干净，不留半吊子在跑态。
        try? CZFSingBoxCore.stop()
        isRunning = false
        runningLink = nil
        runningCore = nil
        coreOwnerBundleId = nil
        coreOwnerAppInfo = nil
        cancelRotateCheck()
        // 停核心后状态行不再显示上次启动失败的旧报错，
        // 改回“核心未启动”；启动失败时 start() 会重写它。
        lastError = nil
    }

    // MARK: - 节点自动轮换

    // 排一次 30 秒后的轮换检查：已排的先取消再重排，保证
    // 同一时刻只有一个巡检在跑；核心没在跑、开关关着、
    // 没有归属 App 时不排（下次起核心 / 开开关时再排）。
    private func scheduleRotateCheck() {
        pendingRotateWork?.cancel()
        pendingRotateWork = nil
        vpnCoreLock.lock()
        let running = isRunning
        let owner = coreOwnerAppInfo
        vpnCoreLock.unlock()
        guard running, Self.isAutoRotateEnabled, owner != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.rotateCheck()
        }
        pendingRotateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func cancelRotateCheck() {
        pendingRotateWork?.cancel()
        pendingRotateWork = nil
    }

    // 一轮检查：读归属 App 的插件统计，窗口内失败增量 ≥ 10
    // 且成功代理增量为 0，说明这 30 秒里被拦的连接全失败、
    // App 一条数据没拿到，当前节点对它已死 → 轮换。
    // 成功代理只要涨了，就说明节点通路还活着（个别域名失败
    // 是常态），不轮换，免得正常 App 被来回换 IP 折腾。
    private func rotateCheck() {
        pendingRotateWork = nil
        vpnCoreLock.lock()
        let running = isRunning
        let pinging = isPinging
        let link = runningLink
        let owner = coreOwnerAppInfo
        vpnCoreLock.unlock()
        guard running, Self.isAutoRotateEnabled, !pinging,
              let appInfo = owner,
              let dict = Self.proxyStatsDict(for: appInfo),
              let failed = Int64(dict["failed"] ?? ""),
              let proxied = Int64(dict["proxied"] ?? "") else {
            // 读不到统计（插件还没写文件等）：基线不动，下轮再看
            scheduleRotateCheck()
            return
        }
        // 核心换节点了（手动切或上次轮换）：基线重置，不拿旧数比
        if rotateBaselineLink != link {
            rotateBaselineLink = link
            rotateLastFailed = failed
            rotateLastProxied = proxied
            rotateTriedLinks = []
            scheduleRotateCheck()
            return
        }
        let failedDelta = failed - (rotateLastFailed ?? failed)
        let proxiedDelta = proxied - (rotateLastProxied ?? proxied)
        rotateLastFailed = failed
        rotateLastProxied = proxied
        if Date() < rotateCooldownUntil {
            scheduleRotateCheck()
            return
        }
        if failedDelta >= 10 && proxiedDelta == 0 {
            rotateToNextNode()
        }
        scheduleRotateCheck()
    }

    // 按列表顺序切下一个支持协议的节点并重启核心：归属 App
    // 钉死过就改它的 override（轮换后仍钉死在新节点，不回落
    // 全局），跟随全局就改全局活动节点。起不来的节点继续往
    // 下一个切，一圈都起不来就停轮换、写原因，不再无限重启。
    // 启动失败时的就地切节点（ensureRunning 专用）：候选按
    // 新鲜测速从快到慢（与轮换同款排序），跳过刚失败的那条；
    // 成功后按轮换同款改钉死/全局，并接管归属、排轮换检查；
    // 一圈都不通就停，lastError 留最后一次失败原因。
    private func startFallback(from failedLink: String, for appInfo: LCAppInfo?) {
        let links = nodeLinks
        guard links.count >= 2 else { return }
        let cands = Self.sortedSupportedCandidates(links: links, excluding: [failedLink])
        for cand in cands {
            if start(withLink: cand.link) {
                if let appInfo = appInfo, Self.nodeOverride(for: appInfo) != nil {
                    Self.setNodeOverride(cand.link, for: appInfo)
                } else {
                    UserDefaults.standard.set(cand.idx, forKey: Self.activeNodeKey)
                }
                if let bid = appInfo?.bundleIdentifier() {
                    coreOwnerBundleId = bid
                }
                coreOwnerAppInfo = appInfo
                scheduleRotateCheck()
                return
            }
        }
    }

    private func rotateToNextNode() {
        guard let appInfo = coreOwnerAppInfo else { return }
        let links = nodeLinks
        guard links.count >= 2 else { return }
        var current = effectiveLink(for: appInfo)
        for _ in 0..<links.count {
            guard let target = nextSupportedNode(after: current, links: links) else {
                cancelRotateCheck()
                lastError = "节点自动轮换一圈都不通，已停止轮换，手动换节点或检查订阅"
                return
            }
            rotateTriedLinks.insert(current)
            rotateTriedLinks.insert(target)
            if Self.nodeOverride(for: appInfo) != nil {
                Self.setNodeOverride(target, for: appInfo)
            } else if let idx = links.firstIndex(of: target) {
                UserDefaults.standard.set(idx, forKey: Self.activeNodeKey)
            }
            vpnCoreLock.lock()
            coreOwnerBundleId = nil
            vpnCoreLock.unlock()
            if start(withLink: target) {
                vpnCoreLock.lock()
                if let bid = appInfo.bundleIdentifier() {
                    coreOwnerBundleId = bid
                }
                coreOwnerAppInfo = appInfo
                vpnCoreLock.unlock()
                rotateCooldownUntil = Date().addingTimeInterval(60)
                rotateBaselineLink = target
                rotateLastFailed = nil
                rotateLastProxied = nil
                return
            }
            current = target
        }
        cancelRotateCheck()
        lastError = "节点自动轮换一圈都不通，已停止轮换，手动换节点或检查订阅"
    }

    // 测速缓存（与设置页同一份 UserDefaults，格式 link -> {v: code, t: time}；
    // code >= 0 为通的延迟 ms，-1/-2/-3 为不通/超时/不支持；24h 后算旧数不用）。
    private static let pingCacheKey = "CZFVPNPingCache"
    private static let pingCacheStaleAfter: TimeInterval = 86400

    private static func freshPingDelay(for link: String) -> Int? {
        guard let raw = UserDefaults.standard.dictionary(forKey: pingCacheKey),
              let value = raw[link] else { return nil }
        let code: Int
        let time: TimeInterval
        if let dict = value as? [String: Any] {
            code = (dict["v"] as? NSNumber)?.intValue ?? -1
            time = (dict["t"] as? NSNumber)?.doubleValue ?? 0
        } else if let num = value as? NSNumber {
            code = num.intValue
            time = 0
        } else {
            return nil
        }
        guard code >= 0, time != 0,
              Date().timeIntervalSince1970 - time <= pingCacheStaleAfter else { return nil }
        return code
    }

    // 轮换候选：按新鲜测速延迟从快到慢（没测过/旧数排最后，
    // 仍按列表顺序），而不是按列表顺序——轮换后落在最快的
    // 可用节点上，不会从 465ms 的 TUIC 切到 1791ms 的 VLESS。
    // 没测速数据时退化为原来的列表顺序，行为与之前一致。
    // 候选节点排序（轮换与启动 fallback 共用）：按新鲜测速从快
    // 到慢（没测速排最后，仍按列表顺序）；exclude 之外的才进
    // 候选。抽出来是去重——两边之前各写了一份同样的循环。
    private static func sortedSupportedCandidates(links: [String], excluding: Set<String>) -> [(link: String, idx: Int, delay: Int)] {
        var cands: [(link: String, idx: Int, delay: Int)] = []
        for (idx, cand) in links.enumerated() {
            if excluding.contains(cand) { continue }
            if !Self.isSupportedNodeScheme(Self.nodeScheme(for: cand)) { continue }
            cands.append((cand, idx, Self.freshPingDelay(for: cand) ?? Int.max))
        }
        cands.sort { ($0.delay, $0.idx) < ($1.delay, $1.idx) }
        return cands
    }

    private func nextSupportedNode(after current: String, links: [String]) -> String? {
        var excluding = rotateTriedLinks
        excluding.insert(current)
        return Self.sortedSupportedCandidates(links: links, excluding: excluding).first?.link
    }

    // MARK: - 节点延迟测试

    /// 一个节点的延迟测试结果：success 时 delay 是真实毫秒；
    /// 失败时 delay 是核心给的码（10000 出错 / 11000 超时），
    /// 界面别当毫秒显示。conversionFailed 区分两种失败：转换
    /// 器拒收（协议不在清单里）与网络不通——前者界面显示
    /// “不支持”而非“不通”，“清理不通”也不会误删它。
    public struct CZFNodePingResult {
        public let success: Bool
        public let delay: Int
        public let conversionFailed: Bool
        public init(success: Bool, delay: Int, conversionFailed: Bool = false) {
            self.success = success
            self.delay = delay
            self.conversionFailed = conversionFailed
        }
    }

    /// 测延迟前停核心（用户 2026-11-03 定的“停止测速启动”）：
    /// 核心在跑就先记下在跑的链接与归属 App 再停，返回 true；
    /// 核心没在跑就不动，返回 false（测完也不启动）。
    /// 快照与停核心同一把递归锁下做，免得抓到的在跑态
    /// 是另一路 stop/start 做到一半的中间态。stop() 会清
    /// 掉归属，所以快照必须在 stop() 之前抓。
    @discardableResult
    public func stopCoreForPing() -> Bool {
        vpnCoreLock.lock()
        defer { vpnCoreLock.unlock() }
        guard isRunning, let link = runningLink else {
            pingStoppedLink = nil
            pingStoppedOwner = nil
            return false
        }
        pingStoppedLink = link
        pingStoppedOwner = coreOwnerAppInfo
        stop()
        return true
    }

    /// 测延迟完重启原来那条（只在 stopCoreForPing 停过时
    /// 起作用）：归属 App 的有效链接没变才重启（测速中途
    /// 用户亲手换了节点就不抢，免得盖掉用户的新选择）；
    /// 重启走 ensureRunning，归属与轮换巡检原样恢复，起
    /// 不来走 250 的就地切下一个，不停在死节点上。快照
    /// 读完即清，重复调用不会二次启动。养号另有 ensureRunning
    /// 自己的占用守卫兜底（中途别的 App 起了核心就拒绝）。
    public func restartCoreAfterPing() {
        vpnCoreLock.lock()
        let link = pingStoppedLink
        let owner = pingStoppedOwner
        pingStoppedLink = nil
        pingStoppedOwner = nil
        vpnCoreLock.unlock()
        guard let link = link else { return }
        // 测速中途换了目标就不重启旧的：收尾已按用户的新
        // 选择处理过，旧快照作废。
        guard effectiveLink(for: owner).trimmingCharacters(in: .whitespacesAndNewlines) == link.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        ensureRunning(for: owner)
        // 重启成功后清掉测速收尾置的预热抑制：收尾时核心
        // 是停的（抑制置真），现在核心又在跑了，抑制前提
        // 已不存在；重启失败则留着，不让预热去起刚起不来
        // 的核心。归属 App 的重启已由 ensureRunning 清过，
        // 这里只补全局（owner 为 nil）那一路。isRunning 与
        // 清抑制同一把锁下读改，与测速收尾的读法一致。
        vpnCoreLock.lock()
        if isRunning {
            prewarmSuppressedAfterPing = false
        }
        vpnCoreLock.unlock()
    }

    /// 测全部节点的延迟（sing-box 临时实例串行探针：逐个
    /// 起临时实例、经节点向测速地址 host:80 发一次明文
    /// HTTP 量真实往返）。
    /// 测速只读：绝不 stop/start 核心、不改核心启停状态，
    /// 也不在测完事后起回或校验翻盘——测速前核心在跑就
    /// 保持在跑、没在跑就保持没在跑。代价要明说：核心
    /// 在跑时临时实例起不来（同进程单服务），整批结果
    /// 会是失败，此时 completion 的 rejected 为真，界面
    /// 要提示“核心在跑、测速被占用”而不是把节点标不通、
    /// 更不能用这批结果去清理节点。onPartial 在第一轮
    /// 测完就回主线程，只含当轮结果，界面只合并其中通
    /// 的节点先显示，不通的继续重试、等最终 completion。
    /// completion 回主线程，结果与 nodeLinks 同序。
    public func pingAllNodes(onPartial: (([CZFNodePingResult]) -> Void)? = nil, onProgress: ((Int, Int, String) -> Void)? = nil, completion: @escaping ([CZFNodePingResult], Bool) -> Void) {
        let links = nodeLinks
        guard !links.isEmpty else { completion([], false); return }
        // 先在调用线程把测速标志立起来再派后台队列：原来标
        // 志只在后台块里立，调用与后台执行之间的窗口里预
        // 热可能抢跑起核心，测速中就先变在跑；立标志本身
        // 不抓状态，状态快照仍在后台块里同一把锁下抓。
        vpnCoreLock.lock()
        isPinging = true
        vpnCoreLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            // 抓状态必须和 start/stop 同一把锁：否则抓到的
            // 核心在跑/活动链接可能是另一路 stop/start
            // 做到一半的中间态，收尾判断就按错状态走。
            // 抓完立刻放锁——锁不包整段测速（见字段注释）。
            self.vpnCoreLock.lock()
            self.isPinging = true
            self.pingRetryLink = nil
            self.pingGeneration += 1
            let epochAtPingStart = self.coreActionEpoch
            let coreRunningAtStart = self.isRunning
            let prePingActiveLink = self.nodeLink
            self.vpnCoreLock.unlock()
            var outcome = self.runPingBatches(links: links, url: "https://cp.cloudflare.com/", phase: "测速", onProgress: onProgress)
            // 核心在跑且整批被拒 = 核心占用测速，不是节点不通：
            // 测速只读，不停车重测、不重试（重试同样会被拒，
            // 只会白白拖时间），直接把被拒结果交给界面提示。
            let pingRejected = coreRunningAtStart && outcome.batchRejected
            // 轮末复核（TUIC 探针竞态）：测速中途刚起的核心
            // 也会让探针记被拒，completion 用起止任一时刻在跑
            // 且被拒才算占用，见末尾 finalRejected；重试门只
            // 看起时状态（重试失败不覆写成功项，无害）。
            if let onPartial {
                let firstItems = outcome.items
                DispatchQueue.main.async { onPartial(firstItems) }
            }
            if !pingRejected {
                // 假不通修法：第一地址（Cloudflare）个别失败时，
                // 按顺序用另外两个地址单独重测，只认重测通的——
                // 有些 REALITY 节点对 Cloudflare 那一路不通，但
                // 实际经节点上网是通的（小火箭同节点 183ms），
                // 一次失败就永久标不通、逼用户换 IP 是错的。
                // 只用一个重试地址还不够：测速库对 204 空回应
                // 的判定未必算成功，所以第二重试用返回 200 的
                // 苹果连通性检测页兜底；三个地址都失败才标不通。
                var failedIndices = outcome.items.enumerated().filter { !$0.element.success }.map { $0.offset }
                for retryURL in ["https://www.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"] {
                    if failedIndices.isEmpty { break }
                    let failedLinks = failedIndices.map { links[$0] }
                    let retry = self.runPingBatches(links: failedLinks, url: retryURL, phase: "重试", onProgress: onProgress)
                    var stillFailed: [Int] = []
                    for (j, idx) in failedIndices.enumerated() {
                        if retry.items[j].success {
                            outcome.items[idx] = retry.items[j]
                        } else {
                            stillFailed.append(idx)
                        }
                    }
                    failedIndices = stillFailed
                }
            }
            // 测速收尾（只读版）：测速本身绝不动核心启停，
            // 没有恢复、没有事后重试、没有校验翻盘。收尾只做
            // 三件与核心启停无关的事：
            // 1) 没用户动作时，把测速结束时的核心状态记成
            //    预热抑制（在跑就清、没在跑就置），这样测速
            //    后切回前台，预热不会把停着的核心悄悄起回来；
            //    有用户动作时不碰抑制，亲手起停/开 App 的路
            //    径自己会清或保留；
            // 2) 测速窗口内被挡下的开 App / 源下载请求、以及
            //    用户换过的活动节点，在测速结束后补跑一次——
            //    这些是用户/App 自己的动作，不是测速在动核心；
            // 3) 把结果和被拒标志交给 completion，界面据此
            //    决定要不要提示“核心占用”以及要不要禁清理。
            var deferredApp: LCAppInfo?
            var deferredHost = false
            var postPingActiveLink = prePingActiveLink
            self.vpnCoreLock.lock()
            let epochChanged = self.coreActionEpoch != epochAtPingStart
            if !epochChanged {
                self.prewarmSuppressedAfterPing = !self.isRunning
            } else {
                self.pingRetryLink = nil
            }
            postPingActiveLink = self.nodeLink
            deferredApp = self.deferredEnsureApp
            self.deferredEnsureApp = nil
            deferredHost = self.deferredHostEnsure
            self.deferredHostEnsure = false
            self.isPinging = false
            self.vpnCoreLock.unlock()
            if let deferredApp {
                self.ensureRunning(for: deferredApp)
            } else if postPingActiveLink != prePingActiveLink {
                self.applyActiveNodeChange()
            }
            if deferredHost {
                self.ensureRunningForHost()
            }
            self.vpnCoreLock.lock()
            let coreRunningAtEnd = self.isRunning
            self.vpnCoreLock.unlock()
            let finalRejected = (coreRunningAtStart || coreRunningAtEnd) && outcome.batchRejected
            let items = outcome.items
            DispatchQueue.main.async { completion(items, finalRejected) }
        }
    }

    /// 只测一个节点：复用 runPingBatches 的单链接子集与三地址
    /// 重试（Cloudflare → gstatic → Apple），不测整表。测速只读
    /// 规则与全量测速一致：立 isPinging 挡预热/切节点/开 App，
    /// 收尾只做预热抑制与被挡请求的补跑，绝不动核心启停；
    /// 核心在跑且整批被拒时 rejected 为真，界面不覆写旧结果。
    /// completion 回主线程，result 为 nil 表示下标已失效。
    public func pingSingleNode(at index: Int, completion: @escaping (CZFNodePingResult?, Bool) -> Void) {
        let links = nodeLinks
        guard links.indices.contains(index) else { completion(nil, false); return }
        let link = links[index]
        vpnCoreLock.lock()
        isPinging = true
        vpnCoreLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.vpnCoreLock.lock()
            self.isPinging = true
            self.pingRetryLink = nil
            self.pingGeneration += 1
            let epochAtPingStart = self.coreActionEpoch
            let coreRunningAtStart = self.isRunning
            let prePingActiveLink = self.nodeLink
            self.vpnCoreLock.unlock()
            var outcome = self.runPingBatches(links: [link], url: "https://cp.cloudflare.com/", phase: "测速", onProgress: nil)
            let pingRejected = coreRunningAtStart && outcome.batchRejected
            if !pingRejected {
                var failed = outcome.items.first?.success == true ? [] : [0]
                for retryURL in ["https://www.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"] {
                    if failed.isEmpty { break }
                    let retry = self.runPingBatches(links: [link], url: retryURL, phase: "重试", onProgress: nil)
                    if retry.items.first?.success == true {
                        outcome.items[0] = retry.items[0]
                        failed = []
                    }
                }
            }
            var deferredApp: LCAppInfo?
            var deferredHost = false
            var postPingActiveLink = prePingActiveLink
            self.vpnCoreLock.lock()
            let epochChanged = self.coreActionEpoch != epochAtPingStart
            if !epochChanged {
                self.prewarmSuppressedAfterPing = !self.isRunning
            } else {
                self.pingRetryLink = nil
            }
            postPingActiveLink = self.nodeLink
            deferredApp = self.deferredEnsureApp
            self.deferredEnsureApp = nil
            deferredHost = self.deferredHostEnsure
            self.deferredHostEnsure = false
            self.isPinging = false
            self.vpnCoreLock.unlock()
            if let deferredApp {
                self.ensureRunning(for: deferredApp)
            } else if postPingActiveLink != prePingActiveLink {
                self.applyActiveNodeChange()
            }
            if deferredHost {
                self.ensureRunningForHost()
            }
            self.vpnCoreLock.lock()
            let coreRunningAtEnd = self.isRunning
            self.vpnCoreLock.unlock()
            // 轮末复核：与 pingAllNodes 同理，中途起的核心也算占用。
            let finalRejected = (coreRunningAtStart || coreRunningAtEnd) && outcome.batchRejected
            let item = outcome.items.first
            DispatchQueue.main.async { completion(item, finalRejected) }
        }
    }

    /// 只测指定下标的一组节点（组头右滑「测试」用）：与
    /// pingSingleNode 同一套只读语义（立 isPinging、绝不
    /// 动核心启停、被拒不覆写）与三地址重试，只是子集从
    /// 一条变多条；completion 回主线程，带 (扁平下标, 结
    /// 果) 对，界面按下标合并进结果表、逐条落缓存。
    public func pingNodes(atIndices indices: [Int], onProgress: ((Int, Int, String) -> Void)? = nil, completion: @escaping ([(Int, CZFNodePingResult)], Bool) -> Void) {
        let all = nodeLinks
        let valid = indices.filter { all.indices.contains($0) }
        guard !valid.isEmpty else { completion([], false); return }
        let links = valid.map { all[$0] }
        vpnCoreLock.lock()
        isPinging = true
        vpnCoreLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.vpnCoreLock.lock()
            self.isPinging = true
            self.pingRetryLink = nil
            self.pingGeneration += 1
            let epochAtPingStart = self.coreActionEpoch
            let coreRunningAtStart = self.isRunning
            let prePingActiveLink = self.nodeLink
            self.vpnCoreLock.unlock()
            var outcome = self.runPingBatches(links: links, url: "https://cp.cloudflare.com/", phase: "测速", onProgress: onProgress)
            let pingRejected = coreRunningAtStart && outcome.batchRejected
            if !pingRejected {
                var failedPositions = outcome.items.enumerated().filter { !$0.element.success }.map { $0.offset }
                for retryURL in ["https://www.gstatic.com/generate_204", "https://captive.apple.com/hotspot-detect.html"] {
                    if failedPositions.isEmpty { break }
                    let failedLinks = failedPositions.map { links[$0] }
                    let retry = self.runPingBatches(links: failedLinks, url: retryURL, phase: "重试", onProgress: onProgress)
                    var stillFailed: [Int] = []
                    for (j, pos) in failedPositions.enumerated() {
                        if retry.items[j].success {
                            outcome.items[pos] = retry.items[j]
                        } else {
                            stillFailed.append(pos)
                        }
                    }
                    failedPositions = stillFailed
                }
            }
            var deferredApp: LCAppInfo?
            var deferredHost = false
            var postPingActiveLink = prePingActiveLink
            self.vpnCoreLock.lock()
            let epochChanged = self.coreActionEpoch != epochAtPingStart
            if !epochChanged {
                self.prewarmSuppressedAfterPing = !self.isRunning
            } else {
                self.pingRetryLink = nil
            }
            postPingActiveLink = self.nodeLink
            deferredApp = self.deferredEnsureApp
            self.deferredEnsureApp = nil
            deferredHost = self.deferredHostEnsure
            self.deferredHostEnsure = false
            self.isPinging = false
            self.vpnCoreLock.unlock()
            if let deferredApp {
                self.ensureRunning(for: deferredApp)
            } else if postPingActiveLink != prePingActiveLink {
                self.applyActiveNodeChange()
            }
            if deferredHost {
                self.ensureRunningForHost()
            }
            self.vpnCoreLock.lock()
            let coreRunningAtEnd = self.isRunning
            self.vpnCoreLock.unlock()
            let finalRejected = (coreRunningAtStart || coreRunningAtEnd) && outcome.batchRejected
            let pairs = zip(valid, outcome.items).map { ($0.0, $0.1) }
            DispatchQueue.main.async { completion(pairs, finalRejected) }
        }
    }

    /// 逐个节点测延迟（同步阻塞，必须在后台线程调）。
    /// 全量 sing-box 测速（测速只读，不动主核心）：
    /// - 每个链接先过 CZFSingBoxConfig 配置生成校验（批量
    ///   构建时顺带完成），生成失败记 conversionFailed
    ///   （界面“不支持”，清理不删）；
    /// - 生成成功的走批量临时实例：一台实例装下一片节点
    ///   （每节点一个入站端口），只起停一次，片内 8 路并
    ///   发用 CZFSingBoxProbe 对本轮测速 URL 的 host:80
    ///   做真实往返。旧做法逐节点起停实例，起停开销占大
    ///   半时间（用户报太慢）；批量配置被核心拒时整片回
    ///   退旧串行逐节点探针兜底，结果语义不变；
    /// - 主核心在跑时临时实例不起（sing-box 同进程单服
    ///   务），整轮记被拒，调用方按“核心占用”保留旧结
    ///   果——界面层的测速流程本来就先停核心再测（用户
    ///   定版规则）。
    /// 探针目标 host 取本轮测速 URL 的 host（Cloudflare /
    /// gstatic / Apple 三轮各不相同）；失败节点随重试轮次
    /// 重探（每轮最坏 5 秒超时，并发下不再串行叠加）。
    private func runPingBatches(links: [String], url: String, phase: String = "", onProgress: ((Int, Int, String) -> Void)? = nil) -> (items: [CZFNodePingResult], batchRejected: Bool) {
        var items = [CZFNodePingResult?](repeating: nil, count: links.count)
        var batchRejected = false
        // 占用判定在函数入口抓一次（不包整段测速，见字段注释）。
        vpnCoreLock.lock()
        let mainRunning = isRunning
        vpnCoreLock.unlock()
        let normalizedLinks = links.map { Self.normalizedShareLink($0) }
        let probeHost = URLComponents(string: url)?.host ?? ""
        let total = links.count
        // 进度计数单独加锁数：并发探针回填时不能读 items
        // 数组本身数（与写回填竞态），每个下标恰好回填一
        // 次，计数与回填一一对应。
        var progressDone = 0
        let progressLock = NSLock()
        func noteProgress() {
            guard let onProgress else { return }
            progressLock.lock()
            progressDone += 1
            let done = progressDone
            progressLock.unlock()
            DispatchQueue.main.async { onProgress(done, total, phase) }
        }
        enum BatchStart { case started, occupied, failed }
        // 分片：一台实例最多装 64 个节点（端口 10927 起连
        // 续分配），片内并发、片间串行（同进程单服务）。
        let sliceSize = 64
        var sliceStart = 0
        while sliceStart < total {
            let sliceEnd = min(sliceStart + sliceSize, total)
            let sliceLinks = Array(normalizedLinks[sliceStart..<sliceEnd])
            let (batchJSON, ports) = CZFSingBoxConfig.batchProbeConfigJSON(for: sliceLinks, basePort: 10927)
            // 批量配置里缺席的链接 = 转换失败（与旧校验同义）。
            for local in 0..<sliceLinks.count where ports[local] == nil {
                items[sliceStart + local] = CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
                noteProgress()
            }
            let validLocals = ports.keys.sorted()
            if validLocals.isEmpty {
                sliceStart = sliceEnd
                continue
            }
            if mainRunning {
                batchRejected = true
                for local in validLocals {
                    items[sliceStart + local] = CZFNodePingResult(success: false, delay: 10000)
                    noteProgress()
                }
                sliceStart = sliceEnd
                continue
            }
            // 起批量实例：与 probeSingBoxNode 同款占用复核 +
            // 持锁起实例，防主核心插进检查与启动之间的窗口。
            var batchStart: BatchStart = .failed
            if let batchJSON {
                vpnCoreLock.lock()
                if isRunning || CZFSingBoxCore.isServiceRunning {
                    batchStart = .occupied
                } else {
                    do {
                        try CZFSingBoxCore.start(configJSON: batchJSON)
                        batchStart = .started
                    } catch {
                        batchStart = .failed
                    }
                }
                vpnCoreLock.unlock()
            }
            switch batchStart {
            case .occupied:
                // 起探针时核心刚被别路起起来：记被拒，调用方
                // 按“核心占用”保留旧结果（与旧单探针 nil 同义）。
                batchRejected = true
                for local in validLocals {
                    items[sliceStart + local] = CZFNodePingResult(success: false, delay: 10000)
                    noteProgress()
                }
            case .failed:
                // 批量配置被核心拒：回退旧串行逐节点探针兜底。
                for local in validLocals {
                    if let result = probeSingBoxNode(link: sliceLinks[local], host: probeHost) {
                        items[sliceStart + local] = result
                    } else {
                        batchRejected = true
                        items[sliceStart + local] = CZFNodePingResult(success: false, delay: 10000)
                    }
                    noteProgress()
                }
            case .started:
                // 8 路并发探针：探针是纯函数（端口+host 进、
                // 结果出），并发安全；结果回填加锁串行化。
                let group = DispatchGroup()
                let sem = DispatchSemaphore(value: 8)
                let fillLock = NSLock()
                for local in validLocals {
                    let port = ports[local]!
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        sem.wait()
                        let r = CZFSingBoxProbe.probe(port: port, host: probeHost, timeout: 5)
                        sem.signal()
                        let mapped: CZFNodePingResult
                        if r.success {
                            mapped = CZFNodePingResult(success: true, delay: r.delayMs)
                        } else if r.rejected {
                            mapped = CZFNodePingResult(success: false, delay: 10000)
                        } else {
                            mapped = CZFNodePingResult(success: false, delay: 11000)
                        }
                        fillLock.lock()
                        items[sliceStart + local] = mapped
                        fillLock.unlock()
                        noteProgress()
                        group.leave()
                    }
                }
                group.wait()
                try? CZFSingBoxCore.stop()
            }
            sliceStart = sliceEnd
        }
        return (items.map { $0 ?? CZFNodePingResult(success: false, delay: 10000) }, batchRejected)
    }

    /// sing-box 节点临时探针（只在无主核心时调用；起实例前
    /// 再复核一次占用，占用竞态时返回 nil，由调用方记被拒）。
    /// 生成临时配置（端口 10927，不建 http 入站）→ 起临时
    /// 实例 → 探针（host 取本轮测速 URL 的 host，端口 80，
    /// 超时 5 秒）→ defer 里停实例。start 成功才注册 defer；
    /// start 失败直接记失败，不留实例。绝不碰主核心状态
    /// （isRunning/runningLink 不动，只动
    /// CZFSingBoxCore.isServiceRunning）。延迟码约定：被拒
    /// 记 10000（界面“不通”，清理可删），超时或失败记
    /// 11000（界面“超时”，实际含义是超时或失败，不是已
    /// 证实的超时——探针不区分两者的已知局限）。
    private func probeSingBoxNode(link: String, host: String) -> CZFNodePingResult? {
        vpnCoreLock.lock()
        // 主核心在跑，或上个临时实例泄漏未停（崩溃才可能），
        // 都算占用：不与任何已跑实例同进程起第二个。
        let occupied = isRunning || CZFSingBoxCore.isServiceRunning
        vpnCoreLock.unlock()
        if occupied { return nil }
        let config: String
        do {
            config = try CZFSingBoxConfig.configJSON(for: link, socksPort: 10927, httpPort: nil)
        } catch {
            return CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
        }
        // 拿着锁起临时实例：起完（flag 已置 true）再放锁，
        // 主核心的 start 拿不到锁就进不来，不可能插进
        // “检查完还没起”的窗口。只锁起实例这一下，不锁
        // 整个探针（探针要几秒，锁全程会冻住起核心）。
        vpnCoreLock.lock()
        if isRunning || CZFSingBoxCore.isServiceRunning {
            vpnCoreLock.unlock()
            return nil
        }
        do {
            try CZFSingBoxCore.start(configJSON: config)
        } catch {
            vpnCoreLock.unlock()
            return CZFNodePingResult(success: false, delay: 11000)
        }
        vpnCoreLock.unlock()
        defer { try? CZFSingBoxCore.stop() }
        let probe = CZFSingBoxProbe.probe(port: 10927, host: host, timeout: 5)
        if probe.success {
            return CZFNodePingResult(success: true, delay: probe.delayMs)
        }
        if probe.rejected {
            return CZFNodePingResult(success: false, delay: 10000)
        }
        return CZFNodePingResult(success: false, delay: 11000)
    }

    // MARK: - 老格式链接翻译

    // 有些面板发的 vless 链接是老格式：vless://<base64>?参数，
    // base64 解开是「加密:uuid@地址:端口」。官方解析器只认标准
    // 格式（uuid@地址:端口 写在明处），先把老格式翻译成标准
    // 格式再交给它；认不出的一律原样返回。
    private static func normalizedShareLink(_ link: String) -> String {
        let scheme: String
        if link.hasPrefix("vless://") {
            scheme = "vless://"
        } else if link.hasPrefix("trojan://") {
            scheme = "trojan://"
        } else {
            return link
        }
        let rest = String(link.dropFirst(scheme.count))
        let authEnd = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = String(rest[..<authEnd])
        if authority.contains("@") {
            // 标准格式：只翻译小火箭参数，其余原样。
            return rewriteShadowrocketParams(link)
        }
        guard scheme == "vless://" else { return link } // trojan 老格式不动

        var b64 = authority
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let decodedData = Data(base64Encoded: b64),
              let decoded = String(data: decodedData, encoding: .utf8) else { return link }

        let pattern = #"^([^:]+):([^@]+)@([^:]+):([0-9]+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
              m.numberOfRanges == 5 else { return link }
        func group(_ i: Int) -> String {
            let r = Range(m.range(at: i), in: decoded)!
            return String(decoded[r])
        }
        let encryption = group(1), uuid = group(2), host = group(3), port = group(4)

        // 查询参数手动切分（不走 URLComponents：它对这种 base64
        // 当主机名的怪链接有整串拒绝的先例，参数会丢）
        var query: [String: String] = [:]
        if let qStart = link.firstIndex(of: "?") {
            var qStr = link[link.index(after: qStart)...]
            if let hashIdx = qStr.firstIndex(of: "#") {
                qStr = qStr[..<hashIdx]
            }
            for pair in qStr.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    query[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                }
            }
        }

        var out: [(String, String)] = [("encryption", encryption)]
        if let pbk = query["pbk"], !pbk.isEmpty {
            out.append(("security", "reality"))
            out.append(("pbk", pbk))
            if let sid = query["sid"], !sid.isEmpty { out.append(("sid", sid)) }
        } else if query["tls"] == "1" {
            out.append(("security", "tls"))
        } else {
            out.append(("security", "none"))
        }
        if let sni = query["peer"] ?? query["sni"], !sni.isEmpty {
            out.append(("sni", sni))
        }
        if let flow = query["flow"], !flow.isEmpty {
            out.append(("flow", flow))
        } else if query["xtls"] == "2" {
            out.append(("flow", "xtls-rprx-vision"))
        } else if query["xtls"] == "1" {
            out.append(("flow", "xtls-rprx-origin"))
        }
        if let fp = query["fingerprint"] ?? query["fp"], !fp.isEmpty {
            out.append(("fp", fp))
        }
        // 小火箭写法：obfs=websocket 即 ws，obfsParam 即 WS host；标准参数优先。
        let type = query["type"] ?? query["net"] ?? (query["obfs"] == "websocket" ? "ws" : nil) ?? "tcp"
        out.append(("type", type))
        if type == "ws" {
            if let h = query["host"] ?? query["obfsParam"], !h.isEmpty { out.append(("host", h)) }
            if let p = query["path"], !p.isEmpty { out.append(("path", p)) }
        }

        var result = "vless://\(uuid)@\(host):\(port)?"
        result += out.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.1)" }
            .joined(separator: "&")
        if let name = query["remarks"], !name.isEmpty {
            result += "#" + (name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name)
        }
        return result
    }

    // 标准格式链接里的小火箭参数翻译：只在查询串后追加标准参数，
    // authority 与片段、原有参数串一律原样不动。
    // obfs=websocket → type=ws（仅当没写 type/net 时）；
    // obfsParam → host（仅当没写 host 且最终是 ws 时）；
    // peer → sni（仅当没写 sni 时）。三个参数一个都没有时原样返回。
    private static func rewriteShadowrocketParams(_ link: String) -> String {
        guard let qStart = link.firstIndex(of: "?") else { return link }
        let afterQ = link[link.index(after: qStart)...]
        let hashIdx = afterQ.firstIndex(of: "#")
        let qStr = hashIdx.map { String(afterQ[..<$0]) } ?? String(afterQ)
        let fragment = hashIdx.map { String(afterQ[$0...]) } ?? ""
        // 只读键与解码后的值做判断，原有参数串不重编码。
        var keys = Set<String>()
        var values: [String: String] = [:]
        for pair in qStr.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                keys.insert(String(parts[0]))
                values[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        var add: [String] = []
        if !keys.contains("type"), !keys.contains("net"), values["obfs"] == "websocket" {
            add.append("type=ws")
        }
        let finalIsWS = values["type"] == "ws" || values["net"] == "ws" || add.contains("type=ws")
        if finalIsWS, !keys.contains("host"), let h = values["obfsParam"], !h.isEmpty {
            add.append("host=" + (h.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? h))
        }
        if !keys.contains("sni"), let s = values["peer"], !s.isEmpty {
            add.append("sni=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s))
        }
        guard !add.isEmpty else { return link }
        let base = String(link[..<qStart])
        let sep = qStr.isEmpty ? "" : "&"
        return base + "?" + qStr + sep + add.joined(separator: "&") + fragment
    }

    // 读游客插件写的运行统计（插件同目录的 CZFProxyStats.txt），
    // 供 App 设置页显示：插件到底干了多少活、哪类连接没被拦到
    // MARK: 宿主自身走节点（源刷新 / 从源下载 IPA）

    /// 开关：LiveContainer 自己的源请求与下载也经内置节点出网
    /// （境外源才需要；JIT 的局域网服务器调用不走这里、不受影响）
    public static var isHostProxyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "CZFVPNHostProxyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "CZFVPNHostProxyEnabled") }
    }

    public static func proxyDictionary() -> [String: Any] {
        [
            "HTTPEnable": true, "HTTPProxy": "127.0.0.1", "HTTPPort": 10828,
            "HTTPSEnable": true, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 10828,
            "SOCKSEnable": true, "SOCKSProxy": "127.0.0.1", "SOCKSPort": socksPort,
        ]
    }

    private static let proxiedHostSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = proxyDictionary()
        return URLSession(configuration: config)
    }()

    /// 宿主自己的网络会话：开关开且核心在跑时经核心出网，
    /// 否则系统共享会话（fail-open，不断网）
    public static func hostSession() -> URLSession {
        guard isHostProxyEnabled, shared.isRunning else { return .shared }
        return proxiedHostSession
    }

    /// 下载用配置：走节点时改用前台配置——后台配置的下载任务由
    /// 系统进程执行、代理字典不生效；不开节点时维持后台配置原样
    public static func hostDownloadConfiguration(identifier: String) -> URLSessionConfiguration {
        if isHostProxyEnabled && shared.isRunning {
            let config = URLSessionConfiguration.default
            config.connectionProxyDictionary = proxyDictionary()
            return config
        }
        return URLSessionConfiguration.background(withIdentifier: identifier)
    }

    /// 宿主开关打开时把核心拉起来（源/下载要用），顺带取消待执行的自动停
    public func ensureRunningForHost() {
        guard Self.isHostProxyEnabled else { return }
        // 源下载开关在测速窗口内打开时也不直接起核心：它
        // 和开 App 一样是用户动作，测速收尾再补跑，免得测
        // 速窗口内起核心让探针被占用挡下、测速结果不准。
        vpnCoreLock.lock()
        let pinging = isPinging
        if pinging {
            deferredHostEnsure = true
            coreActionEpoch += 1
        }
        vpnCoreLock.unlock()
        if pinging { return }
        // 源下载开关是手动动作：和开 App 一样清掉测速后的
        // 预热抑制；测速窗口内被挡下的请求走收尾补跑，补
        // 跑时 pinging 已是 false，同样在这里清掉。
        vpnCoreLock.lock()
        prewarmSuppressedAfterPing = false
        vpnCoreLock.unlock()
        pendingStopWork?.cancel()
        pendingStopWork = nil
        if !isRunning {
            vpnCoreLock.lock()
            coreActionEpoch += 1
            vpnCoreLock.unlock()
            _ = start()
        }
    }

    /// 读按包名统计文件并解析成 k=v 表；文件没有/读不出返回 nil。
    /// 统计文件在插件自己的目录（CZFVPN）里：多选时先找它，
    /// 没有再退第一个文件夹（旧单选行为），都没有才看开关默认
    private static func proxyStatsDict(for appInfo: LCAppInfo) -> [String: String]? {
        let czfFolders = LCAppModel.czfSplitTweakFolders(appInfo.tweakFolder)
        guard let folderName = czfFolders.first(where: { $0 == "CZFVPN" }) ?? czfFolders.first ?? (isEnabled(for: appInfo) ? "CZFVPN" : nil) else { return nil }
        let base = appInfo.isShared ? LCPath.lcGroupTweakPath : LCPath.tweakPath
        let folder = base.appendingPathComponent(folderName)
        // 统计按 App 分文件（插件按包名命名）；按包名文件没有就不显示，
        // 不再退读老版共用文件——那是各 App 混在一起的老数，显示成当前
        // App 的就是错数
        let bid = appInfo.bundleIdentifier() ?? ""
        let url = folder.appendingPathComponent("CZFProxyStats-\(bid).txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var dict: [String: String] = [:]
        for part in raw.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        return dict
    }

    /// 自检 0 = 钩子没装上、代理没生效；只有统计文件里明确写 0 才报，
    /// 没文件时不报（那时统计行本身也不显示）
    public static func proxySelfTestFailed(for appInfo: LCAppInfo) -> Bool {
        proxyStatsDict(for: appInfo)?["selftest"] == "0"
    }

    public static func proxyStatsText(for appInfo: LCAppInfo) -> String? {
        guard let dict = proxyStatsDict(for: appInfo) else { return nil }
        guard let load = dict["load"] else { return nil }
        return "插件统计（加载 \(load) · 自检 \(dict["selftest"] ?? "?")）：解析共 \(dict["gaiPass"] ?? "0") 次（假IP \(dict["gaiFake"] ?? "0")）· 代理连接 \(dict["proxied"] ?? "0") · 失败 \(dict["failed"] ?? "0") · 直连 \(dict["direct"] ?? "0") · 放行 \(dict["pass"] ?? "0") · connectx \(dict["connectx"] ?? "0")（代理 \(dict["connectxProxied"] ?? "0")）· 会话改写 \(dict["swizzled"] ?? "0") · 配置改写 \(dict["cfg"] ?? "0") · 拦QUIC \(dict["quic"] ?? "0") · QUIC代理 \(dict["quicProxied"] ?? "0")"
    }

}

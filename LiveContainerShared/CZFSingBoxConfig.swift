import Foundation

// CZFSingBoxConfig.swift
//
// 职责：sing-box 分流判定 + 全部协议的配置 JSON 生成。
// 2026-11-05 用户定版全量 sing-box：原 TUIC-only 分流取消，
// vless/vmess/trojan/ss/hysteria2/socks/tuic/anytls 与原始
// sing-box JSON 出站都由本文件生成出站，原 Xray 路径已删。
// 只含纯函数与静态方法：不调用任何 Libbox/CGo 函数，不碰 UserDefaults，
// 不读写文件、不联网。配置一律用 JSONSerialization 拼（不许字符串插值），
// 密码/密钥里含引号、反斜杠也不会打断 JSON。
//
// 与 CZFVPNManager 的衔接：
// CZFVPNManager.nodeScheme / isSupportedNodeScheme 是协议清单，
// 本文件的 coreKind 恒为 singBox（保留接口是给旧调用点兼容）。
// 调用方（CZFVPNManager）在调 configJSON 前先对 vless/trojan
// 做 normalizedShareLink 归一化（老格式/小火箭参数翻译），
// 本文件只认标准格式链接。
// 本地无 Swift 工具链：括号平衡 ≠ 编译通过，需 CI 验证。

/// 核心分流结果。xray = 走 Xray（含“不走 sing-box”的一切情况）。
public enum CZFCoreKind {
    case xray
    case singBox
}

/// 配置生成错误。所有 case 只带字段名或 scheme 名，绝不带密码、
// 密钥、uuid、私钥等任何凭证值（调用方打印错误也不会泄漏）。
public enum CZFSingBoxConfigError: Error {
    case missingField(String)
    case invalidValue(String)
    case unsupportedScheme(String)
    case notSingBoxNode
    case encodingFailed
}

extension CZFSingBoxConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingField(let field): return "缺少 \(field)"
        case .invalidValue(let field): return "\(field) 不合法"
        case .unsupportedScheme(let scheme): return "不支持的协议：\(scheme)"
        case .notSingBoxNode: return "该节点不走 sing-box，不由本文件生成配置"
        case .encodingFailed: return "配置 JSON 编码失败"
        }
    }
}

// MARK: - 分流判定

public enum CZFSingBoxRouting {

    /// 节点出站的统一 tag。
    static let nodeTag = "node-out"

    // MARK: scheme 与 query 解析（与 CZFVPNManager.nodeScheme 同语义）

    /// scheme（小写；原始 JSON 出站记为 json；无 :// 的纯文本记为空串）。
    static func scheme(of link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return "json" }
        guard let range = trimmed.range(of: "://") else { return "" }
        return String(trimmed[..<range.lowerBound]).lowercased()
    }

    /// query 参数表（同一参数多次出现时保留全部值）。
    /// URLComponents 已经做过一次 percent-decode，这里绝不再
    /// removingPercentEncoding：密码里若含 %XX 字样，二次解码会
    /// 把它改写成别的字符，等于改了密码（TUICLink 的教训，照抄）。
    static func queryMap(of link: String) -> [String: [String]] {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return [:]
        }
        var map: [String: [String]] = [:]
        for item in comps.queryItems ?? [] {
            guard let value = item.value else { continue }
            map[item.name, default: []].append(value)
        }
        return map
    }

    /// 按顺序取第一个非空 query 值。
    static func firstQuery(_ map: [String: [String]], _ names: String...) -> String? {
        for name in names {
            if let value = map[name]?.first, !value.isEmpty { return value }
        }
        return nil
    }

    /// 布尔型 query 参数：1 / true / yes（不区分大小写）即真。
    /// 同 splitList 的原因，不能把 [String] 转发给 variadic，
    /// 这里自己循环取首个非空值。
    static func boolQuery(_ map: [String: [String]], _ names: String...) -> Bool {
        var raw: String?
        for name in names {
            if let value = map[name]?.first, !value.isEmpty { raw = value; break }
        }
        guard let raw = raw else { return false }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "1" || v == "true" || v == "yes"
    }

    /// 是否含“跳过证书验证”参数（allow_insecure / insecure /
    /// skip-cert-verify 任一为 1/true/yes）。无 :// 的纯文本与
    /// JSON 出站返回 false。
    public static func isInsecureNode(_ link: String) -> Bool {
        let scheme = scheme(of: link)
        if scheme.isEmpty || scheme == "json" { return false }
        let map = queryMap(of: link)
        return boolQuery(map, "allow_insecure", "insecure", "skip-cert-verify")
    }

    // MARK: 对外接口

    /// 分流主入口：全量 sing-box 后恒为 singBox（Xray 路径
    /// 已删）。保留这个接口是给旧调用点兼容，新代码直接
    /// 按 sing-box 处理即可。
    public static func coreKind(for link: String) -> CZFCoreKind {
        return .singBox
    }

    /// 行内“不验证书”标记判定：链接带 allowInsecure 类参数
    /// 且该协议的出站真的会写 tls.insecure 时才标（tuic /
    /// anytls / trojan / hysteria2 恒有 tls；vless 只在
    /// security=tls 时；vmess 的 insecure 在 JSON 里、不走
    /// query，保守不标）。调用方是 CZFVPNManager.nodeDisplay。
    public static func showsInsecureMark(for link: String) -> Bool {
        guard isInsecureNode(link) else { return false }
        switch scheme(of: link) {
        case "tuic", "anytls", "trojan", "hysteria2", "hy2":
            return true
        case "vless":
            let security = (firstQuery(queryMap(of: link), "security") ?? "").lowercased()
            return security == "tls"
        default:
            return false
        }
    }
}

// MARK: - 配置生成

public enum CZFSingBoxConfig {

    // MARK: 通用解析工具（全部只抛“缺什么/哪项不合法”，绝不带凭证值）

    /// URLComponents（trim 后解析；解析失败返回 nil，调用方按缺字段抛错）。
    static func components(of link: String) -> URLComponents? {
        return URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// host 非空校验（空 host 一律 throw，不区分协议）。
    static func requireHost(_ comps: URLComponents?) throws -> String {
        guard let host = comps?.host, !host.isEmpty else {
            throw CZFSingBoxConfigError.missingField("server")
        }
        return host
    }

    /// 端口校验：缺端口 throw，超出 1...65535 throw。
    static func requirePort(_ comps: URLComponents?) throws -> Int {
        guard let port = comps?.port else {
            throw CZFSingBoxConfigError.missingField("server_port")
        }
        guard (1...65535).contains(port) else {
            throw CZFSingBoxConfigError.invalidValue("server_port")
        }
        return port
    }

    /// alpn：逗号分隔或重复 query 项都认（照抄 TUICLink 的 alpn 处理）。
    static func alpnList(_ map: [String: [String]]) -> [String] {
        return (map["alpn"] ?? [])
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }

    /// 出站 tls 块（官方 shared/tls 出站字段：enabled / server_name /
    /// insecure / alpn）。server_name 与 alpn 为空时省略，不写空值。
    /// 注意：uTLS 指纹（fp / fingerprint 参数）本期一律丢弃不传——
    /// 因为不构建 with_utls 的 sing-box，传了 utls 块也跑不起来；
    /// 这是有意取舍，不是漏传（见交付汇报）。
    static func tlsBlock(serverName: String?, alpn: [String], insecure: Bool, enabled: Bool = true) -> [String: Any] {
        var tls: [String: Any] = ["enabled": enabled, "insecure": insecure]
        if let name = serverName, !name.isEmpty { tls["server_name"] = name }
        if !alpn.isEmpty { tls["alpn"] = alpn }
        return tls
    }

    /// sni/server_name + allowInsecure/insecure/skip-cert-verify 的统一取法。
    static func tlsParams(_ map: [String: [String]]) -> (serverName: String?, alpn: [String], insecure: Bool) {
        let serverName = CZFSingBoxRouting.firstQuery(map, "sni", "server_name")
        let insecure = CZFSingBoxRouting.boolQuery(map, "allow_insecure", "insecure", "skip-cert-verify")
        return (serverName, alpnList(map), insecure)
    }

    // MARK: TUIC 出站（字段名后都注了文档依据）

    /// tuic：照抄 TUICLink 语义（官方 outbound/tuic：server /
    /// server_port 必填，uuid 必填，password，congestion_control
    /// ∈ cubic/new_reno/bbr，udp_relay_mode ∈ native/quic，tls 必填）。
    static func tuicOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "tuic" else {
            throw CZFSingBoxConfigError.unsupportedScheme("tuic")
        }
        // user/password 是 URLComponents 一次解码后的值，不二次解码。
        guard let uuid = comps.user, !uuid.isEmpty else {
            throw CZFSingBoxConfigError.missingField("uuid")
        }
        guard UUID(uuidString: uuid) != nil else {
            throw CZFSingBoxConfigError.invalidValue("uuid")
        }
        guard let password = comps.password else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        let tlsP = tlsParams(map)
        var out: [String: Any] = [
            "type": "tuic",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "password": password,
        ]
        if let cc = CZFSingBoxRouting.firstQuery(map, "congestion_control"), !cc.isEmpty {
            out["congestion_control"] = cc
        }
        if let mode = CZFSingBoxRouting.firstQuery(map, "udp_relay_mode"), !mode.isEmpty {
            out["udp_relay_mode"] = mode
        }
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    // MARK: TLS / 传输层（多协议共用）

    /// security 参数 → tls 块：reality（utls + reality 一起写，
    /// 指纹缺省 chrome——Reality 没有 utls 握手根本不成立，
    /// 构建侧已带 with_utls 标签）/ tls / 其余返回 nil 不写 tls。
    static func securityTlsBlock(_ map: [String: [String]]) -> [String: Any]? {
        let security = (CZFSingBoxRouting.firstQuery(map, "security") ?? "").lowercased()
        let tlsP = tlsParams(map)
        if security == "reality" {
            var tls = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: false)
            let fp = CZFSingBoxRouting.firstQuery(map, "fp", "fingerprint") ?? "chrome"
            tls["utls"] = ["enabled": true, "fingerprint": fp]
            var reality: [String: Any] = ["enabled": true]
            if let pbk = CZFSingBoxRouting.firstQuery(map, "pbk", "publicKey") {
                reality["public_key"] = pbk
            }
            if let sid = CZFSingBoxRouting.firstQuery(map, "sid", "shortId") {
                reality["short_id"] = sid
            }
            tls["reality"] = reality
            return tls
        }
        if security == "tls" {
            return tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        }
        return nil
    }

    /// 传输层块：ws / grpc / http(h2) / splithttp / httpupgrade；
    /// tcp 或不认识的值返回 nil（不写 transport，走默认 TCP）。
    static func transportBlock(_ map: [String: [String]]) -> [String: Any]? {
        let type = (CZFSingBoxRouting.firstQuery(map, "type", "net") ?? "tcp").lowercased()
        switch type {
        case "ws", "websocket":
            var t: [String: Any] = ["type": "ws"]
            if let path = CZFSingBoxRouting.firstQuery(map, "path") { t["path"] = path }
            if let host = CZFSingBoxRouting.firstQuery(map, "host") { t["headers"] = ["Host": host] }
            return t
        case "grpc":
            var t: [String: Any] = ["type": "grpc"]
            if let sn = CZFSingBoxRouting.firstQuery(map, "serviceName", "service_name") { t["service_name"] = sn }
            return t
        case "http", "h2":
            var t: [String: Any] = ["type": "http"]
            if let host = CZFSingBoxRouting.firstQuery(map, "host") { t["host"] = [host] }
            if let path = CZFSingBoxRouting.firstQuery(map, "path") { t["path"] = path }
            return t
        case "splithttp", "xhttp":
            var t: [String: Any] = ["type": "splithttp"]
            if let host = CZFSingBoxRouting.firstQuery(map, "host") { t["host"] = host }
            if let path = CZFSingBoxRouting.firstQuery(map, "path") { t["path"] = path }
            return t
        case "httpupgrade":
            var t: [String: Any] = ["type": "httpupgrade"]
            if let host = CZFSingBoxRouting.firstQuery(map, "host") { t["host"] = host }
            if let path = CZFSingBoxRouting.firstQuery(map, "path") { t["path"] = path }
            return t
        default:
            return nil
        }
    }

    /// 宽容 base64 解码（标准/URL 安全变体、缺 padding 都认），失败返回 nil。
    static func base64DecodeString(_ s: String) -> String? {
        var b64 = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// JSON 字段的整数读法（NSNumber 与字符串数字都认）。
    static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    // MARK: VLESS 出站

    /// vless：uuid@服务器:端口；flow（vision）只在 TCP 直连
    /// 时写（带传输层写上核心会拒）；tls/reality 走 security。
    static func vlessOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "vless" else {
            throw CZFSingBoxConfigError.unsupportedScheme("vless")
        }
        guard let uuid = comps.user, !uuid.isEmpty else {
            throw CZFSingBoxConfigError.missingField("uuid")
        }
        guard UUID(uuidString: uuid) != nil else {
            throw CZFSingBoxConfigError.invalidValue("uuid")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        var out: [String: Any] = [
            "type": "vless",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "uuid": uuid,
        ]
        let network = (CZFSingBoxRouting.firstQuery(map, "type", "net") ?? "tcp").lowercased()
        if network == "tcp", let flow = CZFSingBoxRouting.firstQuery(map, "flow"), !flow.isEmpty {
            out["flow"] = flow
        }
        if let transport = transportBlock(map) { out["transport"] = transport }
        if let tls = securityTlsBlock(map) { out["tls"] = tls }
        return out
    }

    // MARK: VMess 出站

    /// vmess 链接的 base64 JSON 全文，解析失败返回 nil。
    static func vmessPayload(_ link: String) -> [String: Any]? {
        let rest = String(link.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("vmess://".count))
        let payload = rest.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? rest
        guard let text = base64DecodeString(payload),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return obj as? [String: Any]
    }

    /// vmess：参数都在 JSON 里（add/port/id/aid/scy/net/host/
    /// path/tls/sni/alpn）；传输层借 transportBlock 的 query
    /// 语义，把 JSON 字段折成同名 map 再用。
    static func vmessOutbound(link: String) throws -> [String: Any] {
        guard let json = vmessPayload(link) else {
            throw CZFSingBoxConfigError.invalidValue("vmess")
        }
        guard let server = json["add"] as? String, !server.isEmpty else {
            throw CZFSingBoxConfigError.missingField("server")
        }
        guard let port = intValue(json["port"]), (1...65535).contains(port) else {
            throw CZFSingBoxConfigError.missingField("server_port")
        }
        guard let uuid = json["id"] as? String, !uuid.isEmpty else {
            throw CZFSingBoxConfigError.missingField("uuid")
        }
        var out: [String: Any] = [
            "type": "vmess",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "alter_id": intValue(json["aid"]) ?? 0,
            "security": (json["scy"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "auto",
        ]
        let net = (json["net"] as? String) ?? "tcp"
        var map: [String: [String]] = ["type": [net]]
        if let host = json["host"] as? String, !host.isEmpty { map["host"] = [host] }
        if let path = json["path"] as? String, !path.isEmpty {
            map["path"] = [path]
            map["serviceName"] = [path]
        }
        if net.lowercased() != "tcp", let t = transportBlock(map) { out["transport"] = t }
        if (json["tls"] as? String) == "tls" {
            let alpn = (json["alpn"] as? String)?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            let insecure = (json["allowInsecure"] as? String) == "1" || (json["allowInsecure"] as? Bool) == true
            out["tls"] = tlsBlock(serverName: json["sni"] as? String, alpn: alpn, insecure: insecure)
        }
        return out
    }

    // MARK: Trojan 出站

    /// trojan：密码在 userinfo；默认带 TLS（security=none 才
    /// 不带）；security=reality 时与 vless 同路。
    static func trojanOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "trojan" else {
            throw CZFSingBoxConfigError.unsupportedScheme("trojan")
        }
        guard let password = comps.user, !password.isEmpty else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        var out: [String: Any] = [
            "type": "trojan",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "password": password,
        ]
        if let transport = transportBlock(map) { out["transport"] = transport }
        let security = (CZFSingBoxRouting.firstQuery(map, "security") ?? "").lowercased()
        if security != "none" {
            if let tls = securityTlsBlock(map) {
                out["tls"] = tls
            } else {
                let tlsP = tlsParams(map)
                out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
            }
        }
        return out
    }

    // MARK: Shadowsocks 出站

    /// ss：三种写法都认——SIP002（userinfo 是 base64 的
    /// method:password 或明文 method:password）、老格式
    /// （整段 authority 是 base64 的 method:password@host:port）。
    /// plugin 参数（obfs-local / v2ray-plugin）原样折成
    /// plugin + plugin_opts。
    static func shadowsocksOutbound(link: String) throws -> [String: Any] {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var method: String?
        var password: String?
        var server: String?
        var port: Int?
        if let comps = components(of: link), let host = comps.host, let p = comps.port {
            server = host
            port = p
            if let pw = comps.password, let user = comps.user {
                method = user
                password = pw
            } else if let user = comps.user, let decoded = base64DecodeString(user),
                      let colon = decoded.firstIndex(of: ":") {
                method = String(decoded[..<colon])
                password = String(decoded[decoded.index(after: colon)...])
            }
        } else {
            // 老格式：ss:// 后到 # 或 ? 为止整段是 base64
            var authority = String(trimmed.dropFirst("ss://".count))
            if let cut = authority.firstIndex(where: { $0 == "#" || $0 == "?" }) {
                authority = String(authority[..<cut])
            }
            if let decoded = base64DecodeString(authority), let at = decoded.lastIndex(of: "@") {
                let cred = decoded[..<at]
                let hp = decoded[decoded.index(after: at)...]
                if let colon = cred.firstIndex(of: ":") {
                    method = String(cred[..<colon])
                    password = String(cred[cred.index(after: colon)...])
                }
                if let colon = hp.lastIndex(of: ":"), let p = Int(hp[hp.index(after: colon)...]) {
                    server = String(hp[..<colon])
                    port = p
                }
            }
        }
        guard let method, !method.isEmpty else { throw CZFSingBoxConfigError.missingField("method") }
        guard let password else { throw CZFSingBoxConfigError.missingField("password") }
        guard let server, !server.isEmpty else { throw CZFSingBoxConfigError.missingField("server") }
        guard let port, (1...65535).contains(port) else { throw CZFSingBoxConfigError.missingField("server_port") }
        var out: [String: Any] = [
            "type": "shadowsocks",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "method": method,
            "password": password,
        ]
        let map = CZFSingBoxRouting.queryMap(of: link)
        if let plugin = CZFSingBoxRouting.firstQuery(map, "plugin") {
            let parts = plugin.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            out["plugin"] = String(parts[0])
            if parts.count > 1 { out["plugin_opts"] = String(parts[1]) }
        }
        return out
    }

    // MARK: Hysteria2 出站

    /// hysteria2 / hy2：userinfo 整段是密码（含冒号时按原文
    /// 拼回）；obfs-password → salamander 混淆；TLS 必带，
    /// insecure 是机场节点的常态参数，如实透传。
    static func hysteria2Outbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link) else {
            throw CZFSingBoxConfigError.unsupportedScheme("hysteria2")
        }
        let password: String
        if let user = comps.user, !user.isEmpty {
            password = comps.password.map { "\(user):\($0)" } ?? user
        } else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        var out: [String: Any] = [
            "type": "hysteria2",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "password": password,
        ]
        if let obfs = CZFSingBoxRouting.firstQuery(map, "obfs-password", "obfs_password"), !obfs.isEmpty {
            out["obfs"] = ["type": "salamander", "password": obfs]
        }
        let tlsP = tlsParams(map)
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    // MARK: SOCKS 出站

    /// socks / socks5：userinfo 可缺（无认证）。
    static func socksOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link) else {
            throw CZFSingBoxConfigError.unsupportedScheme("socks")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        var out: [String: Any] = [
            "type": "socks",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "version": "5",
        ]
        if let user = comps.user, !user.isEmpty {
            out["username"] = user
            out["password"] = comps.password ?? ""
        }
        return out
    }

    // MARK: AnyTLS 出站

    /// anytls：userinfo 整段是密码；TLS 必带（sni/insecure
    /// 如实透传）。sing-box 1.12+ 原生协议，钉版 1.14.4 支持。
    static func anytlsOutbound(link: String) throws -> [String: Any] {
        guard let comps = components(of: link), comps.scheme?.lowercased() == "anytls" else {
            throw CZFSingBoxConfigError.unsupportedScheme("anytls")
        }
        let password: String
        if let user = comps.user, !user.isEmpty {
            password = comps.password.map { "\(user):\($0)" } ?? user
        } else {
            throw CZFSingBoxConfigError.missingField("password")
        }
        let server = try requireHost(comps)
        let port = try requirePort(comps)
        let map = CZFSingBoxRouting.queryMap(of: link)
        var out: [String: Any] = [
            "type": "anytls",
            "tag": CZFSingBoxRouting.nodeTag,
            "server": server,
            "server_port": port,
            "password": password,
        ]
        let tlsP = tlsParams(map)
        out["tls"] = tlsBlock(serverName: tlsP.serverName, alpn: tlsP.alpn, insecure: tlsP.insecure)
        return out
    }

    // MARK: 原始 JSON 出站

    /// json：整条链接就是一份 sing-box 出站 JSON（对象带
    /// type 就直接用；带 outbounds 数组就取第一个出站），
    /// tag 强制改成统一的 node-out。全量 sing-box 后这里认
    /// 的是 sing-box 格式，老 Xray 格式 JSON 不再适用。
    static func jsonOutbound(link: String) throws -> [String: Any] {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw CZFSingBoxConfigError.invalidValue("json")
        }
        if let type = dict["type"] as? String, !type.isEmpty {
            var out = dict
            out["tag"] = CZFSingBoxRouting.nodeTag
            return out
        }
        if let arr = dict["outbounds"] as? [[String: Any]], let first = arr.first,
           let type = first["type"] as? String, !type.isEmpty {
            var out = first
            out["tag"] = CZFSingBoxRouting.nodeTag
            return out
        }
        throw CZFSingBoxConfigError.invalidValue("json")
    }

    // MARK: 对外接口

    /// 生成完整 sing-box 配置 JSON（JSONSerialization，sortedKeys）。
    /// 固定骨架：log.level=warning（不写 log.output 文件）；
    /// dns.servers=[{tag:local,type:local}] + final=local；
    /// inbounds：mixed（listen 127.0.0.1，listen_port=socksPort），
    /// httpPort 非 nil 时再加一个 http 入站（listen_port=httpPort）；
    /// route.final=node-out；outbounds=[该节点的 sing-box 出站]。
    /// 协议分发：vless/vmess/trojan/shadowsocks/hysteria2/
    /// socks/tuic/anytls 各有构建函数，json 走原始出站透传，
    /// 其余 scheme throw unsupportedScheme（调用方据此判
    /// “转换失败”，与旧 Xray 转换器的失败语义一致）。
    /// 主用例：socksPort=10827、httpPort=10828；测速临时实例：
    /// socksPort=10927、httpPort=nil（不建 http 入站）。
    public static func configJSON(for link: String, socksPort: Int, httpPort: Int?) throws -> String {
        guard (1...65535).contains(socksPort) else {
            throw CZFSingBoxConfigError.invalidValue("socksPort")
        }
        if let httpPort = httpPort {
            guard (1...65535).contains(httpPort) else {
                throw CZFSingBoxConfigError.invalidValue("httpPort")
            }
        }
        let scheme = CZFSingBoxRouting.scheme(of: link)
        let outbound: [String: Any]
        switch scheme {
        case "tuic":
            outbound = try tuicOutbound(link: link)
        case "vless":
            outbound = try vlessOutbound(link: link)
        case "vmess":
            outbound = try vmessOutbound(link: link)
        case "trojan":
            outbound = try trojanOutbound(link: link)
        case "ss", "shadowsocks":
            outbound = try shadowsocksOutbound(link: link)
        case "hysteria2", "hy2":
            outbound = try hysteria2Outbound(link: link)
        case "socks", "socks5":
            outbound = try socksOutbound(link: link)
        case "anytls":
            outbound = try anytlsOutbound(link: link)
        case "json":
            outbound = try jsonOutbound(link: link)
        default:
            throw CZFSingBoxConfigError.unsupportedScheme(scheme)
        }

        var inbounds: [[String: Any]] = [[
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": socksPort,
        ]]
        if let httpPort = httpPort {
            inbounds.append([
                "type": "http",
                "tag": "http-in",
                "listen": "127.0.0.1",
                "listen_port": httpPort,
            ])
        }

        var root: [String: Any] = [
            "log": ["level": "warning"],
            "dns": [
                "servers": [["tag": "local", "type": "local"]],
                "final": "local",
            ],
            "inbounds": inbounds,
            "route": ["final": CZFSingBoxRouting.nodeTag],
        ]
        // 注意：不能把 Optional 直接塞进 JSON（JSONSerialization
        // 不认 Optional，必抛错），这里先解包再放进数组。
        root["outbounds"] = [outbound]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CZFSingBoxConfigError.encodingFailed
        }
        return json
    }
}

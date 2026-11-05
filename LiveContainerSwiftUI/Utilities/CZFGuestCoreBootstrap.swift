import Foundation
import Darwin

// 经典（全屏）启动专用：游客进程里自己把 VPN 核心拉起来。
//
// 病根：sing-box 核心跑在宿主 UI 进程里，而经典启动的交接
// （launchToGuestApp）会让宿主进程自杀、另起一个新进程当
// 游客——核心随宿主一起死，游客里的 CZFProxy 探不到核心，
// 按 fail-open 直连，表现为「点启动的窗口 VPN 不生效」。
// 小窗口（多任务 LiveProcess）宿主不退出、核心活着，所以
// 那条路一直正常，本文件不碰它。
//
// 时机：LCBootstrap 在 invokeAppMain 里读完 guestAppInfo、
// 且还没覆盖 NSUserDefaults / 主目录之前按类名调用这里——
// 管理器的标记与节点都存在 LiveContainer 自己的偏好里，
// 覆盖之后读到的就是游客自己的偏好，起不了核心。ObjC 侧
// 用 NSClassFromString + performSelector 调用，不加编译期
// 依赖；类名经 @objc 固定，改名时两边要一起改。
@objc(CZFGuestCoreBootstrap)
public final class CZFGuestCoreBootstrap: NSObject {

    @objc public static func startCoreIfNeeded(bundlePath: String) {
        // 已有核心在监听 10827 就不重复起：同设备另一实例的
        // 核心一样能给本游客的插件供流量（插件只认回环口）。
        if socksPortAlive() { return }
        guard let appInfo = LCAppInfo(bundlePath: bundlePath) else { return }
        guard CZFVPNManager.isEnabled(for: appInfo) else { return }
        CZFVPNManager.shared.ensureRunning(for: appInfo)
    }

    // 探 127.0.0.1:10827 能不能连上。回环的成功与拒绝都是
    // 毫秒级，0.3 秒超时只是兜底（与插件侧探活同值）。
    private static func socksPortAlive() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(10827).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

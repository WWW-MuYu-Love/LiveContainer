//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import ObjectiveC

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for Dock
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    // C4：条目创建时间（=窗口创建时间）——客进程已死的 stale
    // 窗只清 30 秒以上的，刚建窗、pid 还没落位时不误清。
    let czfAppearedAt = Date()
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// C6：多任务窗口出现信号——dock 条目追加时发，smallWindow
// 的建窗回调与串行门都认它（与 smallWindow 旧轮询同一信号）。
extension Notification.Name {
    static let czfMultitaskWindowAppeared = Notification.Name("CZFMultitaskWindowAppeared")
}

// MARK: - MultitaskDockView Manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = []
    @Published var isVisible: Bool = false
    @Published @objc var isCollapsed: Bool = false
    @Published var isDockHidden: Bool = false
    @Published var settingsChanged: Bool = false
    // 源面板每次调出时 +1，面板视图据此刷新源数据（覆盖层常驻，onAppear 只来一次）
    @Published var czfSourcesPanelOpenCounter: Int = 0
    // App 面板每次调出时 +1，面板视图据此滚回顶部（每次调出都是初始状态，用户定）
    @Published var czfAppPanelOpenCounter: Int = 0
    // 手势面板覆盖层（背景遮罩 + 面板宿主）：只建一次常驻窗口待命，
    // 开/关只切可见性和位置；开没开以面板视图的 isHidden 为准，不以引用为准
    // 定时最小化打开的轮询定时器（30 秒一轮，只在宿主活着时跑）
    private var czfSchedMinTimer: Timer?
    // 定时打开当天豁免名单：定时拉起的窗口当天不算自动关、
    // 也不触发上限弹框，否则定时打开一最小化就进自动关
    // 计时、满 3 个时还弹框等人点，定时执行就卡住。
    // 只记当天（yyyyMMdd），次日检查时清掉重算：当天叫回
    // 再最小化仍豁免，次日恢复正常，不用在每个恢复入口
    // 逐个清标记；关窗后 uuid 不在运行列表，豁免自然失效。
    private var czfSchedMinOpenedDay: String?
    private var czfSchedMinOpenedUUIDs: Set<String> = []
    // 最小化超 30 分钟自动关（CZF）：60 秒一轮，只在宿主活着时跑；
    // 宿主被彻底关掉时不跑，下次打开时运行中列表是空的，无需补查。
    // 键为 appUUID（多开同 App 不同容器各算各的），值是首次看到
    // 它已最小化的时间；恢复可见、关窗、画中画、开关关时清掉。
    private var czfMinAutoCloseTimer: Timer?
    private var czfMinimizedSince: [String: Date] = [:]
    // 同时运行上限（CZF）：3 个，第 4 个窗口注册时弹确认，
    // 防连续注册时弹框叠加，只弹一个。
    private var czfCapAlertShowing = false
    private var czfPanelOverlayBackdrop: UIView?
    private var czfPanelOverlayHost: UIHostingController<AnyView>?
    // App 面板卡片式（主窗悬浮卡）用的抓手条与底部留白：
    // 呈现时按目标窗口写入，下滑关闭/互切动画据此算静止位。
    private var czfPanelGrabber: UIView?
    private var czfAppPanelBottomInset: CGFloat = 0
    // 源面板覆盖层：与 App 面板同构，各自一套遮罩+宿主，互开时先关对方
    private var czfSourcesOverlayBackdrop: UIView?
    private var czfSourcesOverlayHost: UIHostingController<AnyView>?
    // 源面板卡片式的抓手条与底部留白（与 App 面板那套同义，
    // 2026-11-06 样式同步后源面板在主窗同为悬浮卡片）
    private var czfSourcesPanelGrabber: UIView?
    private var czfSourcesPanelBottomInset: CGFloat = 0

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var hostingController: UIHostingController<AnyView>?

    public struct Constants {
        // MARK: - Layout & Sizing
        // 默认快捷栏宽度 25（Campbell 2026-11-06 定；键
        // LCDockWidth 没设过时 originalDockWidth 与隐藏偏
        // 移都按这个值走，设置页 @AppStorage 默认同为 25）
        static let defaultDockWidth: CGFloat = 25.0
        // 顶部条额外内边距的历史参照（见面板条构造处）：
        // 以 90 为零点按比例加减，与默认宽度无关，勿动。
        static let dockWidthPaddingReference: CGFloat = 90.0
        static let minAdaptiveDockWidth: CGFloat = 50.0
        static let minAdaptiveIconSize: CGFloat = 10.0
        static let maxIconSize: CGFloat = 100.0
        static let minCollapsedHeight: CGFloat = 60.0
        static let minCollapsedButtonSize: CGFloat = 44.0
        static let maxCollapsedButtonSize: CGFloat = 80.0
        static let initialDockShowHeight: CGFloat = 120.0

        // MARK: - Margins & Padding
        static let adaptiveWidthVerticalMargin: CGFloat = 20.0
        static let dockVerticalMargin: CGFloat = 30.0
        static let dockContentSpacing: CGFloat = 8.0
        static let dockVerticalPadding: CGFloat = 30.0
        // Extra padding is derived from dockVerticalPadding to match the SwiftUI layout exactly
        
        // MARK: - Ratios & Factors
        static let iconToWidthRatio: CGFloat = 0.75
        static let collapsedButtonToWidthRatio: CGFloat = 0.7
        static let maxHeightRatioOfAvailableArea: CGFloat = 0.85
        
        // MARK: - Animation & Interaction
        // 完全隐藏：偏移量 = 整条栏宽度 + 4，整条滑出屏幕不留边
        static var dockHiddenOffset: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans + 4
                } else {
                    return defaultDockWidth + 4
                }
            }
        }
        static var hideGestureThreshold: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans / 5
                } else {
                    return 16
                }
            }
        }
        static let edgeSwipeThreshold: CGFloat = 30.0
        
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
    }
    
    // Original dock width from user settings (without auto-adjustment)
    private var originalDockWidth: CGFloat {
        let storedValue = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
        return storedValue > 0 ? CGFloat(storedValue) : Constants.defaultDockWidth
    }
    
    // Calculate adaptive dock width (auto-adjust when exceeding safe area)
    public var dockWidth: CGFloat {
        guard !apps.isEmpty else { return originalDockWidth }
        
        let totalVerticalMargin = Constants.adaptiveWidthVerticalMargin * 2
        let availableHeight = self.safeAreaHeight - totalVerticalMargin
        
        let maxSafeHeight = availableHeight * Constants.maxHeightRatioOfAvailableArea
        
        let userWidth = originalDockWidth
        let iconSize = calculateIconSize(for: userWidth)
        let requiredHeight = expandedDockHeight(for: userWidth, iconSize: iconSize)
        
        if requiredHeight > maxSafeHeight && !apps.isEmpty {
            let buttonSize = calculateButtonSize(for: userWidth)
            let baseHeight = expandedDockBaseHeight(for: userWidth, buttonSize: buttonSize)
            let availableForIcons = maxSafeHeight - baseHeight
            let maxAllowedIconSize = availableForIcons / CGFloat(apps.count)
            
            let targetIconSize = max(Constants.minAdaptiveIconSize, maxAllowedIconSize)
            
            let targetWidth = targetIconSize / Constants.iconToWidthRatio
            
            return max(Constants.minAdaptiveDockWidth, targetWidth)
        }
        
        return userWidth
    }
    
    // Calculate icon size based on dock width
    private func calculateIconSize(for width: CGFloat) -> CGFloat {
        let iconSize = width * Constants.iconToWidthRatio
        return max(Constants.minAdaptiveIconSize, min(Constants.maxIconSize, iconSize))
    }

    private func calculateButtonSize(for width: CGFloat) -> CGFloat {
        let targetSize = width * Constants.collapsedButtonToWidthRatio
        return max(Constants.minCollapsedButtonSize, min(Constants.maxCollapsedButtonSize, targetSize))
    }

    private func expandedDockBaseHeight(for width: CGFloat, buttonSize: CGFloat) -> CGFloat {
        let spacingCount = max(self.apps.count + 1, 0)
        let totalSpacingHeight = CGFloat(spacingCount) * Constants.dockContentSpacing
        return Constants.dockVerticalPadding + buttonSize * 2 + totalSpacingHeight
    }

    private func expandedDockHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        let baseHeight = expandedDockBaseHeight(for: width, buttonSize: buttonSize)
        let iconHeight = CGFloat(self.apps.count) * iconSize
        return baseHeight + iconHeight
    }

    private func collapsedDockHeight(for width: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        return Constants.dockVerticalPadding + buttonSize
    }
    

    // Calculate adaptive icon size
    public var adaptiveIconSize: CGFloat {
        return calculateIconSize(for: dockWidth)
    }

    public var keyWindow: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }

    public var safeAreaInsets: UIEdgeInsets {
        if #available(iOS 11.0, *) {
            return keyWindow?.safeAreaInsets ?? .zero
        }
        return .zero
    }

    private var safeAreaHeight: CGFloat {
        keyWindow!.bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
    }
    
    /// 窗口宿主视图的挂载重试计数（见 attachWindowHostingViewWhenReady）
    private var windowAttachRetries = 0

    override init() {
        super.init()
        Self.deployDockGestureTweak()
        registerDockEdgeDarwinObservers()
        startScheduledMinimizeOpenTimer()
        startMinAutoCloseTimer()
        attachWindowHostingViewWhenReady()
        setupDockView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: LCUtils.appGroupUserDefault
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        // 宿主主界面（App 页）手势不灵的根因：全局滑动识别器只在
        // updateDockFrame 里装，而宿主主界面从不显示快捷栏，那条
        // 路一次都不跑，识别器从没装上（LCTabView 注释称 init 里
        // 装配是错的，init 里只有 Darwin 监听）。init 里直接装：
        // 当前窗口立刻装上，窗口/场景监听也随之建立，后来的窗口
        // 自动补装；游客进程里 updateDockFrame 本来就会装，本处
        // 按窗口去重，不会重复装。
        setupGlobalSwipeRecognizer()
    }
    
    /// 把窗口宿主视图挂到根视图的第一个子视图上（挂载目标与
    /// 原实现一致）。原实现是同步三重强解包
    /// keyWindow!.rootViewController!.view.subviews.first!：
    /// 管理器以前只在打开第一个游客 App 时才建、那时窗口层级
    /// 早已齐全；改为 LiveContainer 主界面出现时提前建后
    /// （任意位置调面板），init 发生在首帧渲染求值中，层级
    /// 还没建好，强解包当场陷阱闪退（2026-10-23 21:16 日志
    /// 符号化实证：LCTabView.body → shared 初始化 → 本 init）。
    /// 改成就绪才挂、没就绪 0.1 秒重试（上限 50 次约 5 秒），
    /// 齐了仍挂同一位置，行为与原来一致
    private func attachWindowHostingViewWhenReady() {
        if let hostView = keyWindow?.rootViewController?.view.subviews.first {
            hostView.addSubview(self.windowHostingView)
            return
        }
        windowAttachRetries += 1
        guard windowAttachRetries <= 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.attachWindowHostingViewWhenReady()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async {
            self.settingsChanged.toggle()
            // 刚打开隐藏快捷栏：正在显示的栏立刻收掉（不是只拦下次弹出）；
            // 再关掉开关：有在跑的 App 就立刻把栏请回来（不然开关看着像坏了）
            if LCUtils.appGroupUserDefault.bool(forKey: "LCHideDock") {
                if self.isVisible {
                    self.hideDock()
                }
            } else if !self.apps.isEmpty && !self.isVisible {
                self.showDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            let dockView = AnyView(MultitaskDockSwiftView()
                .environmentObject(self))
            
            self.hostingController = UIHostingController(rootView: dockView)
            self.hostingController?.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
            self.hostingController?.view.backgroundColor = .clear
            // 预建手势面板覆盖层：常驻窗口待命，左滑时不再现建视图树
            if let window = self.keyWindow {
                self.ensurePanelOverlay(in: window)
            }
        }
    }

    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController else { return }
        setupGlobalSwipeRecognizer()

        let screenBounds = keyWindow!.bounds
        let currentDockWidth = self.dockWidth
        
        let dockHeight = calculateTargetDockHeight(forWidth: currentDockWidth)

        let currentFrame = hostingController.view.frame
        let isOnRightSide = (currentFrame.midX > screenBounds.width / 2) || (currentFrame.isEmpty)
        let targetX = calculateTargetX(isDockHidden: self.isDockHidden, 
                                    isOnRightSide: isOnRightSide, 
                                    dockWidth: currentDockWidth, 
                                    screenWidth: screenBounds.width)

        let targetY = calculateTargetY(for: currentFrame, 
                                    dockHeight: dockHeight, 
                                    screenHeight: screenBounds.height)
        
        let newFrame = CGRect(x: targetX, y: targetY, width: currentDockWidth, height: dockHeight)
        
        applyNewFrame(newFrame, for: hostingController, animated: animated)
        // 隐藏折叠 Dock 开着且栏已折叠：整个宿主视图藏掉
        // （isHidden 才真不挡边缘手势，光透明还占着触摸区）
        hostingController.view.isHidden = LCUtils.appGroupUserDefault.bool(forKey: "LCHideCollapsedDock") && isCollapsed
    }

    // MARK: - Frame Calculation Helpers

    private func calculateTargetDockHeight(forWidth width: CGFloat) -> CGFloat {
        if isCollapsed {
            let collapsedHeight = collapsedDockHeight(for: width)
            return max(Constants.minCollapsedHeight, collapsedHeight)
        } else {
            let currentIconSize = calculateIconSize(for: width)
            return expandedDockHeight(for: width, iconSize: currentIconSize)
        }
    }

    func calculateTargetX(isDockHidden: Bool, isOnRightSide: Bool, dockWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {

        let safeInsets = self.safeAreaInsets
        var ans : CGFloat
        if isOnRightSide {
            ans = screenWidth - dockWidth
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeLeft {
                ans -= safeInsets.right
            }
            
            if isDockHidden {
                ans += Constants.dockHiddenOffset
            }
        } else {
            ans = 0
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeRight {
                ans += safeInsets.left
            }
            if isDockHidden {
                ans -= Constants.dockHiddenOffset
            }
        }
        
        return ans;

    }

    private func calculateTargetY(for currentFrame: CGRect, dockHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let safeAreaMinY = self.safeAreaInsets.top + Constants.dockVerticalMargin
        let safeAreaMaxY = screenHeight - self.safeAreaInsets.bottom - dockHeight - Constants.dockVerticalMargin
        
        if currentFrame.height > 0 {
            let desiredY = currentFrame.midY - dockHeight / 2
            return max(safeAreaMinY, min(safeAreaMaxY, desiredY))
        } else {
            let safeAreaCenterY = safeAreaMinY + (safeAreaMaxY - safeAreaMinY) / 2
            return max(safeAreaMinY, min(safeAreaMaxY, safeAreaCenterY - dockHeight / 2))
        }
    }

    private func applyNewFrame(_ newFrame: CGRect, for hostingController: UIHostingController<AnyView>, animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.frame = newFrame
            }
        } else {
            hostingController.view.frame = newFrame
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        DispatchQueue.main.async {
            if let bid = self.apps.first(where: { $0.appUUID == appUUID })?.appInfo?.bundleIdentifier() {
                self.czfUnregisterTouchRaiseObserver(bundleId: bid)
            }
            self.apps.removeAll { $0.appUUID == appUUID }

            if self.apps.isEmpty {
                self.hideDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }

            // 单 App VPN 核心自动停：还在跑的 App 里没有被标记
            // 的了，通知管理器排队停核心（它内部有防抖）
            let stillHasFlagged = self.apps.contains { app in
                guard let info = app.appInfo else { return false }
                return CZFVPNManager.isEnabled(for: info)
            }
            CZFVPNManager.shared.noteRunningAppsChanged(stillHasFlagged: stillHasFlagged)
            CZFHostKeepAlive.shared.refresh()
        }
    }
    
    @objc public func showDock() {
        guard isDockEnabled() else { return }
        // 隐藏快捷栏开着：栏不弹出（只拦显形，不拦 App 追踪，
        // 面板里的条子还要读运行中列表）
        guard !LCUtils.appGroupUserDefault.bool(forKey: "LCHideDock") else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        
        guard let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            self.isVisible = true
            
            let screenBounds = keyWindow.bounds
            let currentDockWidth = self.dockWidth
            let initialHeight = Constants.initialDockShowHeight
            
            // If not already in view hierarchy, add it
            if hostingController.view.superview == nil {
                keyWindow.addSubview(hostingController.view)
                hostingController.view.frame = CGRect(
                    x: screenBounds.width - currentDockWidth,
                    y: (screenBounds.height - initialHeight) / 2,
                    width: currentDockWidth,
                    height: initialHeight
                )
            }
            
            self.updateDockFrame(animated: false) 
            
            self.setupEdgeGestureRecognizers()
            
            hostingController.view.alpha = 0
            let initialScale = Constants.initialScale
            hostingController.view.transform = CGAffineTransform(scaleX: initialScale, y: initialScale)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 1
                hostingController.view.transform = .identity
            }
        }
    }
    
    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 0
                let finalScale = Constants.initialScale
                hostingController.view.transform = CGAffineTransform(scaleX: finalScale, y: finalScale)
                // Move off-screen to hide, but keep in view hierarchy
                let screenBounds = self.keyWindow!.bounds
                let currentDockWidth = self.dockWidth
                let targetX = self.calculateTargetX(isDockHidden: true, isOnRightSide: hostingController.view.frame.midX > screenBounds.width / 2, dockWidth: currentDockWidth, screenWidth: screenBounds.width)
                let targetY = hostingController.view.frame.origin.y // Keep current Y
                hostingController.view.frame.origin = CGPoint(x: targetX, y: targetY)
            } completion: { _ in
                self.isVisible = false
                hostingController.view.transform = .identity
            }
        }
    }

    @objc public func animateFrame(to finalFrame: CGRect) {
        guard let hostingController = self.hostingController else { return }
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.standardSpringDamping,
            initialSpringVelocity: Constants.standardSpringVelocity,
            options: .curveEaseOut
        ) {
            hostingController.view.frame = finalFrame
        }
    }

    @objc public func updateFrameAfterAnimation(finalOffset: CGSize) {
        guard let hostingController = self.hostingController else { return }
        
        let newFrame = hostingController.view.frame.offsetBy(dx: finalOffset.width, dy: finalOffset.height)
        
        hostingController.view.frame = newFrame
    }

    func handleSwipeToHideOrShowGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        let isSwipingAway = (isOnRightSide && translation.width > 0) || (!isOnRightSide && translation.width < 0)
        
        if isSwipingAway {
            guard !self.isDockHidden else { return false }
            self.hideDockToSide()
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            return true
        } else {
            guard self.isDockHidden else { return false }
            self.showDockFromHidden()
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            return true
        }
    }
    
    // Check if gesture is for cross-screen movement (left to right or vice versa)
    func isPositionChangeGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)
        
        guard !self.isDockHidden, horizontalDistance > verticalDistance else {
            return false
        }
        
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        
        guard !self.isDockHidden else { return false }
        
        let isMovingToOtherSide = (isOnRightSide && translation.width < 0) || (!isOnRightSide && translation.width > 0)
        guard isMovingToOtherSide else { return false }
        
        let draggedX = originalFrame.origin.x + translation.width
        let screenCenter = screenWidth / 2
        
        if isOnRightSide {
            return draggedX < screenCenter
        } else {
            return (draggedX + originalFrame.width) > screenCenter
        }
    }
    
    // 清掉无窗口的残留 dock 条目：容器已不在任何已装 App 名下，
    // 或对应 App 已不在（被删/被覆盖替换）。正在运行的窗口
    // （view 非空）一律不动；本函数不关任何窗口，只删条目记录。
    // 调用点：App 删除/覆盖安装/恢复完成，以及 bring-to-front 前
    // 的安全网。必须在主线程调（apps 是 @Published）。
    func pruneStaleDockEntries() {
        let allModels = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        var ownedContainers = Set<String>()
        for model in allModels {
            for container in model.uiContainers {
                ownedContainers.insert(container.folderName)
            }
            for container in model.appInfo.containers {
                ownedContainers.insert(container.folderName)
            }
        }
        let ownedBundlePaths = Set(allModels.compactMap { $0.appInfo.relativeBundlePath })
        apps.removeAll { entry in
            // 正在运行的窗口：view 是窗口存在的硬证据，一律不动。
            guard entry.view == nil else { return false }
            // 容器已无任何已装 App 认领 → 残留条目，剪掉。
            if !ownedContainers.contains(entry.appUUID) {
                return true
            }
            // 容器还在，但条目对应的 App 已不在（被覆盖替换后旧
            // 条目指着旧包路径）→ 剪掉；appInfo 缺失时无法证明
            // App 已走，留给带回守卫处理，不在这里剪。
            if let entryPath = entry.appInfo?.relativeBundlePath, !ownedBundlePaths.contains(entryPath) {
                return true
            }
            return false
        }
    }

    /// App 删除/覆盖安装/恢复完成 后调用：AppInfo 缓存与 dock
    /// 残留条目一起清掉，否则删掉/换掉的 App 还会按旧 LCAppInfo
    /// 被解析、旧 dock 条目还会被顶回前台。正在运行的窗口不动
    /// （见 pruneStaleDockEntries）。必须在主线程调。
    /// 注意：本类是 iOS 16+ 类，调用方须用 #available 包住。
    static func refreshAfterAppChanged() {
        AppInfoProvider.shared.clearCache()
        MultitaskDockManager.shared.pruneStaleDockEntries()
    }

    // C4 信号：最近一次 bring 调用是否清掉了死窗（见
    // bringMultitaskViewToFront；removeRunningApp 是异步的，
    // 调用方不能靠事后查 apps 来判断）。
    var czfLastBringCleanedDeadWindowUUID: String?

    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        // C4 信号：本次调用是否清掉了死窗——removeRunningApp
        // 是异步的，调用方不能靠事后查 apps 是否还在来判断，
        // 必须认这个同步置位的旗（每次调用入口先清零）。
        czfLastBringCleanedDeadWindowUUID = nil
        // 带回前先清残留条目：无窗口的过期条目若留着，find 会
        // 按 uuid 命中它（即使 view 为空也会走一圈）；清掉后带回
        // 失败即回 false，调用方自然走正常启动。正在运行的窗口
        // 不受影响（prune 从不剪 view 非空的条目）。
        pruneStaleDockEntries()
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                // C4：客进程已死的 stale 窗兜底——视图还在、pid 已无
                // （jetsam 后清理链丢了），带回只会顶回一帧死画面：
                // 拆条目 + 摘视图 + 清场景，返回 false 让调用方走
                // 正常启动（即重启入口）。进程活着一律不动；30 秒
                // 内的新窗不动（刚建窗时 pid 可能还没落位，误清
                // 正在启动的窗口比留一个死窗更糟）；条目对不上
                // （年龄未知）时保守不动。
                if let decoratedVC = targetView._viewDelegate() as? DecoratedAppSceneViewController,
                   let appSceneVC = decoratedVC.appSceneVC,
                   !appSceneVC.isAppRunning,
                   let entry = apps.first(where: { $0.appUUID == uuid }),
                   Date().timeIntervalSince(entry.czfAppearedAt) > 30 {
                    czfLastBringCleanedDeadWindowUUID = uuid
                    removeRunningApp(uuid)
                    targetView.removeFromSuperview()
                    appSceneVC.appTerminationCleanUp()
                    return false
                }
                passURLSchemeToView(targetView)
                // 用视图实际所在的窗口做置顶：findMultitaskView 不看 window 参数，
                // 循环第一个窗口未必是视图的窗口，窗口级置顶会抬错窗口。
                animateViewAppearance(targetView, from: center, in: targetView.window ?? window)
                return true
            }
        }
        
        return false
    }

    // 游客点按信号到达：按 bundleId 找到窗口，只调层级、不做脉冲动画。
    // 游客里每次点按都会发信号，带动画会点一下闪一下，故必须静默。
    @objc public func czfRaiseWindowForTouch(bundleId: String) {
        DispatchQueue.main.async {
            guard let app = self.apps.first(where: { $0.appInfo?.bundleIdentifier() == bundleId }),
                  let view = app.view,
                  let window = view.window ?? view.superview?.window else { return }
            self.bringViewToFront(view, in: window)
        }
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false

        // C2：带回前台时 PiP 未激活却残留 shouldIgnoreSceneUpdates
        // （WillStop 回调漏掉）→ 先清掉，否则此后场景更新全被丢、
        // 窗口只剩最后一帧；PiP 正激活时不动，stopPiP 也已同步清。
        if let decoratedVC, let appSceneVC = decoratedVC.appSceneVC,
           PiPManager.shared?.isPiP(withDecoratedVC: decoratedVC) != true,
           appSceneVC.shouldIgnoreSceneUpdates {
            appSceneVC.shouldIgnoreSceneUpdates = false
        }

        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }
        
        if isHidden {
            // 最小化省电恢复：藏着的窗口被叫回台前时清最小化标记、
            // 恢复前台。只走这条带取消隐藏的路，不走单纯调层级的
            // bringViewToFront（后者不取消隐藏，恢复了会藏着也变前台）。
            decoratedVC?.czfRestoreFromMinimize()
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                }
            )
        } else {
            bringViewToFront(view, in: window)
            // C3：可见分支以前只走脉冲动画、不写前台——客经不藏
            // 视图路径被后台化后，窗口看着回了前台、客仍后台；
            // 这里补一次前台写（PiP 激活时 czfSetSceneForeground
            // 自己跳过，残留标志已由上面 C2 清掉）。单次慢点
            // 的脉冲动画本身不动。
            decoratedVC?.appSceneVC?.czfSetSceneForeground(true)

            UIView.animate(withDuration: Constants.shortAnimationDuration1, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let windowSuperview = window.superview {
            windowSuperview.bringSubviewToFront(window)
        }
    }
    
    // Recursively find multitask view
    private func findMultitaskView(in view: UIView, withUUID uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }
    
    // Get view's dataUUID property through reflection
    private func getDataUUID(from view: UIView) -> String? {
        let mirror = Mirror(reflecting: view)
        
        if let child = (mirror.children.first { $0.label == "dataUUID" })?.value as? String {
            return child
        }
        
        if view.responds(to: NSSelectorFromString("dataUUID")) {
            return view.value(forKey: "dataUUID") as? String
        }
        
        return nil
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        
        if apps.contains(where: { $0.appUUID == appUUID }) {
            return
        }
        
        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)

        DispatchQueue.main.async {
            self.apps.append(appModel)
            // C6：窗口出现信号（条目真正追加时才发，调用方凭
            // appUUID 过滤；串行门轮询的也是这个 apps 信号）。
            NotificationCenter.default.post(name: .czfMultitaskWindowAppeared, object: nil, userInfo: ["appUUID": appUUID])
            if let bid = appInfo?.bundleIdentifier() {
                self.czfRegisterTouchRaiseObserver(bundleId: bid)
            }

            if self.apps.count == 1 {
                self.showDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
            CZFHostKeepAlive.shared.refresh()
            self.czfEnforceRunningCap(newUUID: appUUID)
        }
    }

    /// C6 回调：等指定 dataUUID 的窗口出现（dock 条目追加）再
    /// 调 handler；超时（默认 30 秒）未出现则放弃等、不留野
    /// 观察者。调用方须在启动前注册——窗口出现先于注册的竞
    /// 态由开头的已存在检查兜底（已在就地调 handler）。
    func czfOnWindowAppeared(uuid: String, timeout: TimeInterval = 30, handler: @escaping () -> Void) {
        if apps.contains(where: { $0.appUUID == uuid }) {
            handler()
            return
        }
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: .czfMultitaskWindowAppeared, object: nil, queue: .main) { note in
            guard (note.userInfo?["appUUID"] as? String) == uuid else { return }
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            handler()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    // 同时运行上限（CZF）：最多 3 个窗口。第 4 个窗口注册时
    // 才触发（App 页点开、快捷栏点开都走 addRunningAppWithInfo
    // 注册，所以两条路都拦得到；已在运行的点回来不算新注册）。
    // 候选只认已最小化的窗口：可见的不动、画中画豁免、没有
    // 最小化候选时不强制关可见窗口（上限此时是软上限，允许
    // 第 4 个留着）。弹确认，点了“关闭并继续”才关最久最小
    // 化的那个，点了“不开了”就关掉刚开的这个新窗口。
    private func czfEnforceRunningCap(newUUID: String) {
        guard apps.count > 3, !czfCapAlertShowing else { return }
        // 定时打开不弹框：定时执行时人可能不在手机前，弹框
        // 没人点就卡住；当天定时拉起的直接按软上限放行（第 4 个
        // 先留着，与无最小化候选时一致），不关可见窗口。
        if czfIsSchedMinOpened(uuid: newUUID) { return }
        let candidates = apps.filter { app in
            guard app.appUUID != newUUID,
                  let view = app.view,
                  view.isHidden,
                  let vc = view._viewDelegate() as? DecoratedAppSceneViewController,
                  PiPManager.shared?.isPiP(withDecoratedVC: vc) != true else {
                return false
            }
            return true
        }
        guard let oldest = candidates.sorted(by: {
            // 没计时条目的窗口是 60 秒轮询还没扫到的新最小化，
            // 按现在算（最新），不能按 distantPast 算最久，否则
            // 刚最小化的反而会被先关掉。
            (czfMinimizedSince[$0.appUUID] ?? Date()) < (czfMinimizedSince[$1.appUUID] ?? Date())
        }).first else { return }
        guard let keyWindow = self.keyWindow else { return }
        var top = keyWindow.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        guard let presenter = top else { return }
        czfCapAlertShowing = true
        let alert = UIAlertController(
            title: "同时运行已满 3 个",
            message: "关闭最久最小化的「\(oldest.appName)」并继续打开新 App？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "关闭并继续", style: .default) { [weak self] _ in
            self?.czfCapAlertShowing = false
            self?.closeAppWindow(uuid: oldest.appUUID)
        })
        alert.addAction(UIAlertAction(title: "不开了，关新 App", style: .destructive) { [weak self] _ in
            self?.czfCapAlertShowing = false
            self?.closeAppWindow(uuid: newUUID)
        })
        presenter.present(alert, animated: true)
    }

    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
        }
    }
    
    @objc public func minimizeWindow(uuid: String) {
        DispatchQueue.main.async {
            if let app = self.apps.first(where: { $0.appUUID == uuid }),
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                app.view?.layer.removeAllAnimations()
                vc.minimizeWindow()
            }
        }
    }

    // 关闭单个运行中 App（面板顶部状态栏的图标右上角 ✕ 用）
    @objc public func closeAppWindow(uuid: String) {
        DispatchQueue.main.async {
            if let app = self.apps.first(where: { $0.appUUID == uuid }),
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                vc.closeWindow()
            }
        }
    }

    // 一键重启运行中的 App（卡死时用）：关掉窗口，等它退
    // 干净再按平时的启动路线重新拉起
    @objc public func restartApp(uuid: String) {
        guard let app = self.apps.first(where: { $0.appUUID == uuid }) else { return }
        let bundlePath = app.appInfo?.relativeBundlePath ?? ""
        closeAppWindow(uuid: uuid)
        guard !bundlePath.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // 跳错修复：重启不再走只带包名的 URL（那边按包名
            // 取首个模型，重启第 2 个实例会拉起第 1 个）；但
            // restartApp 手里只有 DockAppModel（无 runApp），
            // 直启走不通，改走 URL 但补 container-folder-name
            //（launchAppWithBundleId 已支持，直达被关实例的容器）。
            // bundlePath 是 .app 文件夹名，可能含空格；直接拼 URL(string:)
            // 会返回 nil，重启就变成只关不开。先 percent-encoding 再拼。
            let encodedBundlePath = bundlePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundlePath
            if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(encodedBundlePath)&container-folder-name=\(uuid)") {
                #if !os(visionOS)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                #endif
            }
        }
    }

    // MARK: - 定时最小化打开（CZF）
    // 每个 App 在其设置页单独开关+定时间（UserDefaults 键 CZFSchedMin*，
    // 按 bundleIdentifier 存）。宿主活着时每 30 秒查一轮：到点且今天
    // 还没开过 → 拉起并最小化，一轮最多开一个（避免同时拉起多个）。
    // 宿主被彻底关掉时 iOS 不会唤醒它，到点没开成的会在下次打开
    // LiveContainer 时由同一轮检查补开。
    private func startScheduledMinimizeOpenTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.czfSchedMinTimer?.invalidate()
            self.czfSchedMinTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.checkScheduledMinimizeOpen()
            }
            self.checkScheduledMinimizeOpen()
        }
    }

    /// 供设置页定时开关写盘时调用（见 LCAppSettingsView
    /// .saveSchedMinSettings）：确保定时器在跑，重复调无害；
    /// 关掉唯一一个定时后，下一轮检查发现无定时会自己停表。
    @objc public func czfKickSchedMinTimer() {
        startScheduledMinimizeOpenTimer()
    }

    // 定时器不再常驻：check 里没有任何 App 开着定时就停表，
    // 下次开定时时由设置页 kick 重起；已开但今天已开过的
    // 不算“没有”，明天还得靠它触发，所以只认开关，不认
    // 今日已开标记。日期格式器只建一次，不再每 30 秒新建。
    private static let schedMinDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private func checkScheduledMinimizeOpen() {
        let defaults = UserDefaults.standard
        let today = Self.schedMinDayFormatter.string(from: Date())
        let cal = Calendar.current
        let now = Date()
        let nowTotal = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        var hasEnabled = false
        for app in allApps {
            guard let bundleId = app.appInfo.bundleIdentifier() else { continue }
            guard defaults.bool(forKey: "CZFSchedMinEnabled-\(bundleId)") else { continue }
            hasEnabled = true
            if defaults.string(forKey: "CZFSchedMinLastDate-\(bundleId)") == today { continue }
            let target = defaults.integer(forKey: "CZFSchedMinMinutes-\(bundleId)")
            if nowTotal < target { continue }
            guard app.appInfo.dataUUID != nil,
                  app.appInfo.relativeBundlePath != nil else { continue }
            // 先记账再打开，防同一天重复触发
            defaults.set(today, forKey: "CZFSchedMinLastDate-\(bundleId)")
            czfMinimizeOpenApp(app: app)
            break
        }
        // 一个定时都没开：停掉定时器，不再每 30 秒空扫；
        // 下次开定时时由设置页 kick 重起。
        if !hasEnabled {
            czfSchedMinTimer?.invalidate()
            czfSchedMinTimer = nil
        }
    }

    /// 定时打开当天标记：拉起前就记，注册时上限检查、
    /// 最小化后自动关检查都认这张名单。
    private func czfMarkSchedMinOpened(uuid: String) {
        let today = Self.schedMinDayFormatter.string(from: Date())
        if czfSchedMinOpenedDay != today {
            czfSchedMinOpenedDay = today
            czfSchedMinOpenedUUIDs.removeAll()
        }
        czfSchedMinOpenedUUIDs.insert(uuid)
    }

    private func czfIsSchedMinOpened(uuid: String) -> Bool {
        let today = Self.schedMinDayFormatter.string(from: Date())
        if czfSchedMinOpenedDay != today {
            czfSchedMinOpenedDay = today
            czfSchedMinOpenedUUIDs.removeAll()
            return false
        }
        return czfSchedMinOpenedUUIDs.contains(uuid)
    }

    // 与面板/卡片的最小化完全同款（用户令对齐）：UUID 取
    // 选中容器 folderName（dataUUID 回落）——旧路只认
    // dataUUID，多开实例的 dock 条目键是 folderName，查不
    // 到运行中的窗口；未运行还走不带 multitask 的全屏直
    // 启 + 轮询等条目，全屏条目键对不上、轮询等不到，定
    // 时打开就成了全屏启动。当天豁免标记也按这个 uuid 记
    //（上限检查与自动关豁免都是按条目 appUUID 查的，旧路
    // 按 dataUUID 记，多开实例同样对不上）。
    private func czfMinimizeOpenApp(app: LCAppModel) {
        guard let uuid = app.uiSelectedContainer?.folderName ?? app.appInfo.dataUUID else { return }
        czfMarkSchedMinOpened(uuid: uuid)
        // 已在运行：归属对不上（共用容器的别的条目）不碰
        // 它，落到下面启动分支起自己的窗口。归属先验相对
        // 路径；路径缺失时用 bundleId 兜底验（同款）。
        if let runningApp = apps.first(where: { $0.appUUID == uuid }) {
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != app.appInfo.relativeBundlePath
            } else if let runningInfo = runningApp.appInfo {
                belongsToOther = runningInfo.bundleIdentifier() != app.appInfo.bundleIdentifier()
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                minimizeWindow(uuid: uuid)
                return
            }
        }
        // 未运行：先注册窗口出现回调，再以多任务方式启
        // 动；窗口一出现（0.35 秒后）复验归属再最小化。
        // 回调 30 秒超时兜底，不留野观察者。
        let expectedPath = app.appInfo.relativeBundlePath
        let expectedBundleId = app.appInfo.bundleIdentifier()
        czfOnWindowAppeared(uuid: uuid, timeout: 30) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, let entry = self.apps.first(where: { $0.appUUID == uuid }) else { return }
                let owned: Bool
                if let entryPath = entry.appInfo?.relativeBundlePath, !entryPath.isEmpty {
                    owned = entryPath == expectedPath
                } else if let entryInfo = entry.appInfo {
                    owned = entryInfo.bundleIdentifier() == expectedBundleId
                } else {
                    owned = false
                }
                if owned {
                    self.minimizeWindow(uuid: uuid)
                }
            }
        }
        Task {
            try? await app.runApp(multitask: true, containerFolderName: uuid)
        }
    }

    // MARK: - 最小化自动关（CZF）
    // 开关在多任务设置页，键 CZFMinAutoCloseEnabled，键不存在 = 开；
    // 时长键 CZFMinAutoCloseMinutes，10 / 30 / 60 分钟，默认 30。
    // 只关“已最小化满设定时长”的窗口：可见的、画中画的、已关的都不动；
    // 恢复可见后计时清零，重最小化重新计时间。60 秒一轮，误差
    // 不超过一轮；宿主被彻底关掉时定时器不跑，不存在补关误伤。
    // 定时器不再常驻：checkMinAutoClose 发现没有最小化窗口
    // 计时（或开关已关）就停掉；窗口最小化时由 czfKickMinAutoCloseTimer
    // 重新起——最小化必经 DecoratedAppSceneViewController.minimizeWindow
    //（标题栏按钮、快捷栏最小化全部、Swift 侧 minimizeWindow 都走它），
    // 该方法完成隐藏后调这个 kick，start 本身幂等、重复调只会
    // 重建同一个定时器，不会叠加。
    private func startMinAutoCloseTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.czfMinAutoCloseTimer?.invalidate()
            self.czfMinAutoCloseTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.checkMinAutoClose()
            }
            self.checkMinAutoClose()
        }
    }

    /// 供 ObjC 侧最小化完成时调用（见 DecoratedAppSceneViewController
    /// .minimizeWindow）：确保自动关定时器在跑，重复调无害。
    @objc public func czfKickMinAutoCloseTimer() {
        startMinAutoCloseTimer()
    }

    private func checkMinAutoClose() {
        let defaults = LCUtils.appGroupUserDefault
        let enabled = defaults.object(forKey: "CZFMinAutoCloseEnabled") == nil || defaults.bool(forKey: "CZFMinAutoCloseEnabled")
        guard enabled else {
            czfMinimizedSince.removeAll()
            czfMinAutoCloseTimer?.invalidate()
            czfMinAutoCloseTimer = nil
            return
        }
        // 自动关时长（CZF，可调）：设置页“最小化省电”里选
        // 10 / 30 / 60 分钟，默认 30 分钟（以前写死 1800 秒）。
        // integer(forKey:) 键不存在时返回 0，正好落到默认 30。
        let closeMinutes = defaults.integer(forKey: "CZFMinAutoCloseMinutes")
        let closeDelay = TimeInterval([10, 30, 60].contains(closeMinutes) ? closeMinutes : 30) * 60
        let now = Date()
        var toClose: [String] = []
        for app in apps {
            guard let view = app.view,
                  let vc = view._viewDelegate() as? DecoratedAppSceneViewController else {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
                continue
            }
            // 画中画在播视频：豁免，不计也不关。
            if PiPManager.shared?.isPiP(withDecoratedVC: vc) == true {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
                continue
            }
            // 保活白名单：豁免，不计也不关。以前白名单只管宿主
            // 音频保不保，自动关照样关，同一个“保活”两个意思
            // 打架；现在名单里的最小化窗口自动关直接跳过。
            // 文件不存在时 isInKeepAliveWhitelist 返回 false，
            // 自动关照常跑，不会把默认自动关废掉。
            if let bid = app.appInfo?.bundleIdentifier(), !bid.isEmpty,
               CZFHostKeepAlive.isInKeepAliveWhitelist(for: bid) {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
                continue
            }
            // 定时打开当天：豁免，不计也不关。定时拉起就是要
            // 它在后台待命，最小化满 30 分钟就关等于白开；
            // 只豁免当天，次日恢复正常（见 czfIsSchedMinOpened）。
            if czfIsSchedMinOpened(uuid: app.appUUID) {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
                continue
            }
            // 只认真正藏起来的：动画中途 alpha 为 0 但 hidden 还没置位
            // 时不算，避免 0.3 秒动画就开始计时。
            if view.isHidden {
                if let since = czfMinimizedSince[app.appUUID] {
                    if now.timeIntervalSince(since) >= closeDelay {
                        toClose.append(app.appUUID)
                    }
                } else {
                    czfMinimizedSince[app.appUUID] = now
                }
            } else {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
            }
        }
        // 已不在运行列表里的计时一并清掉，防 uuid 复用后误关新窗。
        let liveUUIDs = Set(apps.map { $0.appUUID })
        czfMinimizedSince = czfMinimizedSince.filter { liveUUIDs.contains($0.key) }
        for uuid in toClose {
            czfMinimizedSince.removeValue(forKey: uuid)
            closeAppWindow(uuid: uuid)
        }
        // 没有最小化窗口在计时了：停掉定时器，不再每 60 秒
        // 空扫 apps；下次窗口最小化时由 kick 重新起。
        if czfMinimizedSince.isEmpty {
            czfMinAutoCloseTimer?.invalidate()
            czfMinAutoCloseTimer = nil
        }
    }

    // 最大化指定 App（状态栏点按用）：vc 的 maximizeWindow() 是
    // 切换式的（已最大化时调它反而还原小窗口），只在没最大化
    // 时调一次。
    @objc public func maximizeWindow(uuid: String) {
        DispatchQueue.main.async {
            if let app = self.apps.first(where: { $0.appUUID == uuid }),
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
               !vc.isMaximized {
                vc.maximizeWindow()
            }
        }
    }

    // 收起专用：台前 App 未最大化就最大化，已最大化或没前台
    // App 时空操作；与折叠栏、关面板一起达成图一全屏效果。
    @objc public func maximizeFrontmostWindow() {
        guard let front = czfFrontmostApp() else { return }
        maximizeWindow(uuid: front.appUUID)
    }

    // 小窗口打开指定 App（状态栏长按用，用户定：长按是小窗口
    // 不是最小化）：同样借切换式的 maximizeWindow()——已最大化
    // 时调一次正好还原成小窗口；本来就是小窗口的不动。
    @objc public func restoreSmallWindow(uuid: String) {
        DispatchQueue.main.async {
            if let app = self.apps.first(where: { $0.appUUID == uuid }),
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
               vc.isMaximized {
                vc.maximizeWindow()
                // 小窗口打开默认不收快捷栏（见 czfExpandDockIfCollapsed）
                self.czfExpandDockIfCollapsed()
            }
        }
    }
    
    @objc public func closeAllWindows() {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                    vc.closeWindow()
                }
            }
        }
    }
    
    @objc public func toggleDockCollapse() {
        DispatchQueue.main.async {
            self.isCollapsed.toggle()
            self.updateDockFrame()
            self.notifyDockCollapseChanged()
        }
    }

    // 小窗口打开专用：把快捷栏展开（Campbell 2026-11-06）。
    // 与窗口侧 czfAutoCollapseDockIfNeeded 成对：全屏（最大
    // 化）打开默认收起走那边；小窗口打开默认不收——新窗口
    // 按默认最大化落地时先被自动收起，随后小窗口路把它还
    // 原成小窗，若不展开，结束状态是「小窗口 + 快捷栏收
    // 着」。只在确实收着时拨一次展开；全屏打开不经小窗
    // 口路，不受影响；标题栏按钮手动最大化/还原也不经
    // 这里，行为不变。
    @objc public func czfExpandDockIfCollapsed() {
        if isCollapsed {
            toggleDockCollapse()
        }
    }
    
    @objc public func notifyDockCollapseChanged() {
        self.updateDockFrame()
        // find fullscreen apps and hide its UINavigationBar
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc.isMaximized {
                vc.updateVerticalConstraints()
            }
        }
    }
    
    // Toggle dock hide/show state
    @objc public func toggleDockVisibility() {
        DispatchQueue.main.async {
            self.isDockHidden.toggle()
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    @objc public func showDockFromHidden() {
        // 隐藏快捷栏开着：右缘划出也不唤回栏（左缘开面板不受影响）
        guard !LCUtils.appGroupUserDefault.bool(forKey: "LCHideDock") else { return }
        DispatchQueue.main.async {
            self.isDockHidden = false
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    @objc public func hideDockToSide() {
        DispatchQueue.main.async {
            self.isDockHidden = true
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    // MARK: - 边缘拖动手势（边缘起手横拖 隐藏/显示 快捷栏）
    // 只认从屏幕边缘一条（44pt）起手的横拖：栏在右时，边缘往右拖隐藏、
    // 往左拖显示；其他区域完全不碰，不干扰 App 内容。
    // 注意：游客 App 的内容是独立场景窗口，触摸不经过宿主窗口，
    // 所以必须给每个场景的每个窗口都挂上，宿主窗口一个不够。
    private var globalSwipeRecognizers: [UIPanGestureRecognizer] = []
    // 全窗口手势的起手位置：0=不在边缘 1=左边缘 2=右边缘
    private var globalSwipeStartEdge: Int = 0
    // 起手 x：终结位移跟起手位置挂钩用（与客侧 gCZFStartX 同款，
    // 用户 2026-11-04 令，2 号机制修）
    private var globalSwipeStartX: CGFloat = 0
    // 边缘手势启用带：边缘起手的触摸只有落在屏幕高度的一段
    // 内才算数，上下不调（防误触）。2026-10-24 用户红圈定：
    // 调用带移到屏幕底部 10%–30% 一段（从顶算 70%–90%，
    // 别再放中间）；三档同中心 80%，低=带更窄、高=带更宽。
    // TweakLoader 内手势用中档值，宿主这边按档位做
    // 最终判定，两边中档必须同值。
    private static var czfEdgeBandTop: CGFloat { czfEdgeBandValues.top }
    private static var czfEdgeBandBottom: CGFloat { czfEdgeBandValues.bottom }
    private static var czfEdgeBandValues: (top: CGFloat, bottom: CGFloat) {
        switch czfEdgeSensitivity {
        case 0: return (0.75, 0.85)
        case 2: return (0.65, 0.95)
        default: return (0.70, 0.90)
        }
    }
    // 灵敏度档位：0 低 1 中（默认）2 高（设置页可调）
    private static var czfEdgeSensitivity: Int {
        UserDefaults.standard.object(forKey: "CZFEdgeSensitivity") as? Int ?? 1
    }
    // 往外弹启用带：用户 2026-11-04 令左往左滑根本不好用、检查
    // 好修复——11-03 把往外弹带收窄到跟 App 面板一致（0.70–0.90）
    // 后，左滑大半高度都认不出；恢复收窄前的好用值（中档
    // 0.55–0.93，低 0.65–0.90、高 0.50–0.95），左滑带宽回
    // 来才灵敏。App 面板往里拖仍用普通带，不动。
    private static var czfEdgeOutwardBandValues: (top: CGFloat, bottom: CGFloat) {
        switch czfEdgeSensitivity {
        case 0: return (0.65, 0.90)
        case 2: return (0.50, 0.95)
        default: return (0.55, 0.93)
        }
    }
    private static var czfEdgeOutwardBandTop: CGFloat { czfEdgeOutwardBandValues.top }
    private static var czfEdgeOutwardBandBottom: CGFloat { czfEdgeOutwardBandValues.bottom }
    // 触发距离系数：低档要拖得更远才认、高档拖一点就认
    private static var czfThresholdScale: CGFloat {
        switch czfEdgeSensitivity {
        case 0: return 1.4
        case 2: return 0.6
        default: return 1.0
        }
    }
    // 边缘手势总开关（设置页控制，键不存在 = 开；
    // Campbell 2026-11-06 先令改默认关、同日又令改回
    // 默认开：没存过值按开算，手动关掉存下的关值保留）
    static var czfEdgeGesturesEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: "CZFEdgeGesturesEnabled") == nil { return true }
        return d.bool(forKey: "CZFEdgeGesturesEnabled")
    }
    private var globalSwipeStartInBand: Bool = true
    // 起手是否落在往外弹专用带内（比普通带宽，只给往外弹用；
    // 往里拖与右边缘一律不认它，见下方两个判定函数）。
    private var globalSwipeStartInOutwardBand: Bool = true
    private var globalSwipeObserversInstalled = false
    // 边缘手势一次性闩锁：一次拖动只触发一次动作（源面板入口带震动，
    // 不闩住会在 .changed 里连震好几下）
    private var czfEdgeSwipeLatched = false

    private func setupGlobalSwipeRecognizer() {
        // 宿主 sendEvent 直读只装一次（左滑出源面板专用，见下）。
        _ = Self.czfHostSendEventInstalled
        // 游客 App 的窗口出现得晚：监听新窗口/新场景，一出现就补装
        if !globalSwipeObserversInstalled {
            globalSwipeObserversInstalled = true
            NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setupGlobalSwipeRecognizer()
            }
            NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setupGlobalSwipeRecognizer()
            }
        }
        globalSwipeRecognizers.removeAll { $0.view == nil }
        var windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        // 兜底：全进程窗口（含非 UIWindowScene 托管的游客窗口）
        for window in UIApplication.shared.windows where !windows.contains(where: { $0 === window }) {
            windows.append(window)
        }
        for window in windows {
            if globalSwipeRecognizers.contains(where: { $0.view === window }) {
                continue
            }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGlobalSwipe(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = self
            window.addGestureRecognizer(pan)
            globalSwipeRecognizers.append(pan)
        }
    }

    // MARK: - 宿主 sendEvent 直读（左滑出源面板专用，2026-11-04）
    // 宿主窗口 pan 在代码上全对、但真机左滑（往外弹）仍不可靠：
    // 手指几毫米就出屏，识别器那步可能直接丢触摸。客侧漏斗
    // 用 sendEvent 直读原始触摸才灵敏，宿主照抄同款机制：
    // 只接左滑（往外弹）一路，右滑（往里拖）仍走原来好用的
    // pan，一律不动；pan 的往外弹分支同步停用，避免两路重复。
    // 钩子名用 czf_host_ 前缀，与客侧 czf_ 区分开，万一同进程
    // 也不撞；只观察、绝不拦截/改事件，原实现先转发。
    // 注意：extension 里的钩子方法必须加 dynamic，否则 Swift
    // 静态分发会自递归（交换后调自己、栈溢出），切勿去掉。
    private static let czfHostSendEventInstalled: Void = {
        guard let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let swizzled = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.czf_host_sendEvent(_:))) else { return }
        method_exchangeImplementations(original, swizzled)
    }()
    private static var czfHostOutwardTouches = [UITouch: CGPoint]()

    static func czfHostOutwardObserve(window: UIWindow, event: UIEvent) {
        guard let touches = event.allTouches, !touches.isEmpty else { return }
        let height = window.bounds.height
        guard height > 0 else { return }
        let top = Self.czfEdgeOutwardBandTop
        let bottom = Self.czfEdgeOutwardBandBottom
        let s = Self.czfThresholdScale
        for touch in touches {
            let loc = touch.location(in: window)
            switch touch.phase {
            case .began:
                if loc.x <= 44, loc.y >= height * top, loc.y <= height * bottom {
                    czfHostOutwardTouches[touch] = loc
                }
            case .moved:
                guard let start = czfHostOutwardTouches[touch] else { continue }
                let dx = loc.x - start.x
                let dy = loc.y - start.y
                if dx <= -6 * s, abs(dx) > 0.9 * abs(dy) {
                    czfHostOutwardTouches.removeValue(forKey: touch)
                    Self.shared.czfOpenSourcesPanelFromFunnel()
                }
            case .ended, .cancelled:
                if let start = czfHostOutwardTouches[touch] {
                    let dx = loc.x - start.x
                    let dy = loc.y - start.y
                    let need: CGFloat = start.x <= 20 ? 3 : 8 * s
                    if dx <= -need, abs(dx) > 0.4 * abs(dy) {
                        Self.shared.czfOpenSourcesPanelFromFunnel()
                    }
                    czfHostOutwardTouches.removeValue(forKey: touch)
                }
            default:
                break
            }
        }
    }

    @objc private func handleGlobalSwipe(_ gesture: UIPanGestureRecognizer) {
        // 不再要求 isVisible：源面板和 App 面板都要在"没打开任何
        // App"时也能从主界面调出（用户定：任意位置可调出面板）。
        // 其余动作入口（显隐快捷栏/全屏切换）自带场景守卫，在主
        // 界面裸跑时各自落空，不会误触发。
        //
        // 判定模型与 TweakLoader 内手势对齐：滑动中过门槛即
        // 触发（不等抬指），终结/被取消时再走一遍宽松兜底（只看物理
        // 结果：净位移方向 + 落点贴边，方向比只留底线）。原来只在
        // .ended 拿全程位移卡 1.5 倍方向比——手指在屏幕上/下部天然
        // 走弧线、纵向位移大，整段被判掉，真机表现就是"只有中间
        // 一段灵、上下无效"，且被列表滚动取消（.cancelled）时直接
        // 不判；插件侧有 sendEvent 漏斗直读原始触摸才显得灵敏。
        let translation = gesture.translation(in: gesture.view)
        let endX = gesture.location(in: gesture.view).x
        let width = gesture.view?.bounds.width ?? 0
        switch gesture.state {
        case .began:
            czfEdgeSwipeLatched = false
        case .changed:
            guard globalSwipeStartEdge == 0 || globalSwipeStartInBand || globalSwipeStartInOutwardBand, !czfEdgeSwipeLatched else { return }
            if processGlobalSwipe(startEdge: globalSwipeStartEdge, startInBand: globalSwipeStartInBand, startInOutwardBand: globalSwipeStartInOutwardBand, translation: translation, endX: endX, width: width) {
                czfEdgeSwipeLatched = true
            }
        case .ended, .cancelled:
            defer { czfEdgeSwipeLatched = false }
            guard globalSwipeStartEdge == 0 || globalSwipeStartInBand || globalSwipeStartInOutwardBand, !czfEdgeSwipeLatched else { return }
            processGlobalSwipeFallback(startEdge: globalSwipeStartEdge, startInBand: globalSwipeStartInBand, startInOutwardBand: globalSwipeStartInOutwardBand, translation: translation, endX: endX, width: width, startX: globalSwipeStartX)
        default:
            break
        }
    }

    // 终结兜底判定：与 TweakLoader 内手势触摸漏斗的终结规则同参。
    // 只认边缘起手；任意位置起手不兜底（防误触设计不变）。
    private func processGlobalSwipeFallback(startEdge: Int, startInBand: Bool, startInOutwardBand: Bool, translation: CGPoint, endX: CGFloat, width: CGFloat, startX: CGFloat) {
        let dx = translation.x
        let dy = translation.y
        let s = Self.czfThresholdScale
        if startEdge == 1 {
            // 2026-10-23 真机纠正后对调：左边缘往里拖（手指右移）
            // = App 面板，往外弹（手指左移）= 源面板。门槛跟着动作
            // 的物理方向走，不跟面板走（往里拖与 App 内横滑同轨，
            // 门槛保持严；往外弹空间小，门槛保持松）
            // 往外弹带已恢复 0.55–0.93（2026-11-04 左滑修复），
            // 往里拖仍只认普通带。
            // 2026-11-04 2 号机制修：位移门槛跟起手位置挂钩——
            // 贴边起手（≤20pt，与客侧 kCZFEdgeTouchMax 同值）
            // 只认 3pt，离边维持 8×s（灵敏度档照旧）。
            // 256修：往外弹不再验落点贴边（同客侧理由）。
            // 2026-11-04 sendEvent 直读接管往外弹后，兜底不再
            // 触发源面板，避免两路重复；往里拖（App 面板）不变。
            if dx >= 44 * s, abs(dx) > 0.8 * abs(dy), startInBand {
                fireDockAction { self.czfOpenAppPanel() }
            }
        } else if startEdge == 2 {
            // 右边缘不放宽：两个方向都只认普通带。
            if dx >= 8 * s, endX >= width - 12, abs(dx) > 0.4 * abs(dy), startInBand {
                fireDockAction { self.czfEdgeRightOutward() }
            } else if dx <= -44 * s, abs(dx) > 0.8 * abs(dy), startInBand {
                fireDockAction { self.czfEdgeRightInward() }
            }
        }
    }

    // 手势判定核心：宿主窗口手势与悬浮边条窗共用。
    // startEdge：0=任意位置 1=左边缘 2=右边缘；往外滑门槛低（手指很快滑出屏幕）。
    // startInBand：起手是否落在启用带内；任意位置起手拖到右边缘切 App 也要带内
    // 才触发（2026-11-01 用户定：右边跟左边一样，只认带内）。
    // 返回 true 表示本次判定触发了动作（边条 handler 据此做一次性触发）
    @discardableResult
    private func processGlobalSwipe(startEdge: Int, startInBand: Bool, startInOutwardBand: Bool, translation: CGPoint, endX: CGFloat, width: CGFloat) -> Bool {
        let draggingRight = translation.x > 0
        // 往外弹（左缘左移/右缘右移）物理行程就只有起手那几十
        // 点：手指几毫米就出屏，拇指走的还是弧线、纵向分量大，
        // 方向比按 1.5 卡会把大半次弹滑判掉（用户真机反馈左缘
        // 往左弹很不灵敏）。往外方向方向比放宽到 0.9、距离门槛
        // 降到 6：贴边往外滑没有任何 App 手势同轨，放宽不抢
        // 东西；往里拖和任意位置维持原判定不变
        let isOutward = (startEdge == 1 && !draggingRight) || (startEdge == 2 && draggingRight)
        guard abs(translation.x) > (isOutward ? 0.9 : 1.5) * abs(translation.y) else { return false }
        let s = Self.czfThresholdScale
        if startEdge == 2 {
            // 右边缘不放宽：两个方向都只认普通带（调用点门槛
            // 放宽后，往外弹带起手的右边缘滑动到这里照样不触发）。
            guard startInBand else { return false }
            // 右边缘改派：往左/往右的动作在入口判定（切换已打开
            // App：往左上一个、往右下一个）；门槛乘灵敏度系数（设置页三档）
            if draggingRight {
                guard translation.x > 6 * s else { return false }
                fireDockAction { self.czfEdgeRightOutward() }
            } else {
                guard abs(translation.x) > 24 * s else { return false }
                fireDockAction { self.czfEdgeRightInward() }
            }
            return true
        } else if startEdge == 1 {
            // 左边缘（2026-10-23 真机纠正后对调）：往里拖（手指
            // 右移，门槛30）= App 面板；往外弹（手指左移，门槛10）
            // = 源面板。与插件侧判定保持一致；门槛跟着物理方向
            // 走：往里拖与 App 内横滑同轨，30 的门槛只认边缘起手
            // 的决断横拖，不抢 App 自己的滑动。
            // 往外弹带已恢复 0.55–0.93（2026-11-04 左滑修复），
            // 往里拖仍只认普通带——带外起手的往里拖到这里返回
            // false 不闩锁，之后改往外弹仍能触发。
            if draggingRight {
                guard startInBand else { return false }
                guard translation.x > 30 * s else { return false }
                fireDockAction { self.czfOpenAppPanel() }
            } else {
                // 往外弹已由宿主 sendEvent 直读接管（2026-11-04），
                // pan 不再触发源面板，避免两路重复；返回 false
                // 不闩锁，之后改往里拖仍能触发。
                return false
            }
            return true
        } else {
            // 任意位置起手：拖到屏幕边缘、位移 >50 才算隐藏；
            // 拖到右边缘切 App 也要起手在带内（跟左边一样），
            // 带外起手往右拖到边不切；往左拖到边藏栏维持原样
            guard abs(translation.x) > 50 else { return false }
            if draggingRight && startInBand && endX >= width - 30 {
                fireDockAction { self.czfEdgeRightOutward() }
                return true
            } else if !draggingRight && endX <= 30 {
                fireDockAction { self.czfEdgeLeftOutward() }
                return true
            }
            return false
        }
    }

    // 手势动作统一入口：只执行，不在这里震——震动由各动作在真正
    // 生效的点自己给一次（原来这里一下+入口一下+插件一下，一滑
    // 震两三下，用户反馈像滑了两次）。
    private func fireDockAction(_ action: () -> Void) {
        action()
    }

    // 起手点落在控件/滑块类视图上时，全局手势不接：视频
    // 进度条一般在底部横跨全屏，从边缘 44pt 附近起手横拖
    // 本来正落在边缘区 + 启用带双命中区，位移一过门槛就
    // 触发面板/切 App，还跟 App 手势同时识别两边同动。
    // 顺着触摸视图往上查祖先：UIControl（UISlider、按钮等）
    // 全算，类名含 slider/scrub/seek/progress 的自定义
    // 进度条（非 UIControl、自带 pan 的那种）也算；只拦
    // 全局 pan 这一路，不动面板自身的边缘识别器。
    private func czfTouchOnControlOrSlider(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view {
            if v is UIControl { return true }
            let name = String(describing: type(of: v)).lowercased()
            if name.contains("slider") || name.contains("scrub") || name.contains("seek") || name.contains("progress") {
                return true
            }
            view = v.superview
        }
        return false
    }

    // 只认滑块/进度条类（拖动会跟 pan 冲突的那种），普通按钮
    // 不算——边缘按钮上的滑动要放行给全局手势。
    private func czfTouchOnSliderOrProgress(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view {
            if v is UISlider { return true }
            let name = String(describing: type(of: v)).lowercased()
            if name.contains("slider") || name.contains("scrub") || name.contains("seek") || name.contains("progress") {
                return true
            }
            view = v.superview
        }
        return false
    }

    // 全部接收、只记录起手位置；触发判定在 handler 里按起手+落点做
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 屏幕边缘识别器（栏隐藏时的 UIScreenEdgePan）：按启用带
        // 放行，带外的触摸直接不让它识别。
        if gestureRecognizer is UIScreenEdgePanGestureRecognizer,
           let window = gestureRecognizer.view as? UIWindow {
            let y = touch.location(in: window).y
            let height = window.bounds.height
            return y >= height * Self.czfEdgeBandTop && y <= height * Self.czfEdgeBandBottom
        }
        guard globalSwipeRecognizers.contains(where: { $0 === gestureRecognizer }),
              let window = gestureRecognizer.view as? UIWindow else { return true }
        // 用户 2026-11-04 令：左往左滑根本不好用——折叠滑块
        // 也不拦：收起后栏收成滑块贴在左缘，拦滑块就等于左
        // 缘手势全死（左滑出源面板失灵的根因之一）；栏上滑
        // 动一律进全局手势。
        // 边缘起手且落在普通控件（App 行按钮、导航按钮等）上时
        // 不拦：点按无位移不会触发 pan，不影响点按；滑动则进
        // 全局手势——否则左缘被按钮盖住时左滑全死（根本不好
        // 用的另一根因）。滑块/进度条仍拦（拖动会跟 pan 同时动）。
        if czfTouchOnControlOrSlider(touch) {
            let edgeLoc = touch.location(in: window)
            let atEdge = edgeLoc.x <= 44 || edgeLoc.x >= window.bounds.width - 44
            if !(atEdge && !czfTouchOnSliderOrProgress(touch)) {
                globalSwipeStartEdge = 0
                return false
            }
        }
        let loc = touch.location(in: window)
        let height = window.bounds.height
        globalSwipeStartInBand = loc.y >= height * Self.czfEdgeBandTop && loc.y <= height * Self.czfEdgeBandBottom
        globalSwipeStartInOutwardBand = loc.y >= height * Self.czfEdgeOutwardBandTop && loc.y <= height * Self.czfEdgeOutwardBandBottom
        if loc.x >= window.bounds.width - 44 {
            globalSwipeStartEdge = 2
        } else if loc.x <= 44 {
            globalSwipeStartEdge = 1
        } else {
            globalSwipeStartEdge = 0
        }
        globalSwipeStartX = loc.x
        return true
    }

    // 全局甩动手势只观察、不同步拦截：与 App 自己的手势同时识别
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return globalSwipeRecognizers.contains { $0 === gestureRecognizer }
    }

    // MARK: - 边缘手势入口（悬浮边条窗 / 宿主窗口手势共用）
    private var dockIsOnRightSide: Bool {
        let screenWidth = keyWindow?.bounds.width ?? 0
        return (hostingController?.view.frame.midX ?? 0) > screenWidth / 2
    }

    // 动作确认震动：只在动作真正生效的点调用（守卫之后），
    // 一次手势最多一下，没生效不震。
    private func edgeCallbackBuzz() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // 右边缘手势改派（用户定 2026-10-25）：不再是小窗口/最大化，
    // 改成切换已打开的 App——往左滑=上一个，往右滑=下一个，按
    // 运行中列表（启动顺序）循环；只切前台，不改窗口状态（不强
    // 制最大化也不强制小窗口）。面板开着时不抢：面板自己的边缘
    // 互切（App↔源）处理。左边缘手势（App 面板/源面板开关）不
    // 动。宿主窗口手势与游客插件的 Darwin 通知都汇到这两个入
    // 口，动作在此判定。
    @objc public func czfEdgeRightInward() {
        guard Self.czfEdgeGesturesEnabled else { return }
        czfSwitchRunningApp(step: -1)
    }

    @objc public func czfEdgeRightOutward() {
        guard Self.czfEdgeGesturesEnabled else { return }
        czfSwitchRunningApp(step: +1)
    }

    // 已打开 App 循环切换：以台前 App 为基准（czfFrontmostApp），
    // 上一个/下一个按运行中列表顺序、首尾相接；主界面（没有台
    // 前 App）时往右=列表第一个、往左=列表最后一个。没运行 App
    // 或面板开着时不动。
    private func czfSwitchRunningApp(step: Int) {
        guard !apps.isEmpty, !isAppPanelOpen, !isSourcesPanelOpen else { return }
        // 单个 App：右缘轮换改成隐藏/显示切换（用户定 2026-10-25）。
        // 只有一个在跑时轮换目标永远是自己、看着像没反应；改成：
        // 可见时滑一下最小化（回宿主），已最小化时滑一下叫回来。
        // 多个 App 仍按原路循环切换。
        if apps.count == 1 {
            let only = apps[0]
            if czfFrontmostApp()?.appUUID == only.appUUID {
                minimizeWindow(uuid: only.appUUID)
            } else {
                guard bringMultitaskViewToFront(uuid: only.appUUID, from: nil) else { return }
            }
            edgeCallbackBuzz()
            return
        }
        let currentIndex = czfFrontmostApp().flatMap { front in
            apps.firstIndex(where: { $0.appUUID == front.appUUID })
        }
        let targetIndex: Int
        if let i = currentIndex {
            targetIndex = (i + step + apps.count) % apps.count
        } else {
            targetIndex = step > 0 ? 0 : apps.count - 1
        }
        let target = apps[targetIndex]
        // 切到大窗口：直接全屏调出来（用户定 2026-10-25）。
        // 通用带脉冲动画的路径在 1 大 1 小时盖不住小窗口（实测）；
        // 大窗口不走缩放脉冲（全屏窗脉冲多余），改走静默直提 + 重申最大化状态，
        // 并保留 LCMaxOneAppOnStage 的最小化他人行为；切到小窗口走原路径不变。
        // 但已最小化的大窗口不走静默直提：静默分支只调 z 序、不取消
        // 隐藏，滑了也出不来（最小化过的 App 右缘叫不回来的根因）；
        // 隐藏的目标改走带取消隐藏的通用路径（面板「打开」同款）。
        if let targetView = target.view,
           let targetVC = targetView._viewDelegate() as? DecoratedAppSceneViewController,
           targetVC.isMaximized,
           !targetView.isHidden, targetView.alpha >= 0.1,
           let targetWindow = targetView.window ?? targetView.superview?.window {
            passURLSchemeToView(targetView)
            if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") {
                minimizeAllWindows(except: targetVC)
            }
            bringViewToFront(targetView, in: targetWindow)
            maximizeWindow(uuid: target.appUUID)
            edgeCallbackBuzz()
        } else {
            guard bringMultitaskViewToFront(uuid: target.appUUID, from: nil) else { return }
            edgeCallbackBuzz()
        }
    }

    // 当前 App：层级最靠前、可见的运行中 App，纯按 z 序算，不以
    // “已最大化”优先——最大化不等于在最上：小窗口切到前台后会
    // 盖在最大化 App 上面。原来“见最大化就返回”会让台前判定卡
    // 在先启动的那个最大化 App 上，轮流切换时每次都算出同一个
    // 目标、看着像没切（v164 上报的 bug）。最小化中的（视图已
    // 隐藏）不算。
    private func czfFrontmostApp() -> DockAppModel? {
        var frontmost: DockAppModel?
        var frontmostZ = -1
        for app in apps {
            guard let view = app.view, !view.isHidden, view.alpha >= 0.1,
                  view._viewDelegate() is DecoratedAppSceneViewController else { continue }
            let z = view.superview?.subviews.firstIndex(where: { $0 === view }) ?? 0
            if z > frontmostZ {
                frontmostZ = z
                frontmost = app
            }
        }
        return frontmost
    }

    @objc public func czfEdgeLeftOutward() {
        guard Self.czfEdgeGesturesEnabled else { return }
        guard isVisible || !apps.isEmpty, !isDockHidden, !dockIsOnRightSide else { return }
        edgeCallbackBuzz()
        hideDockToSide()
    }

    // App 面板入口：左边缘往里拖（手指右移）调出（2026-10-23
    // 真机纠正对调：此前按"手指往左移"实现，与用户实际动作
    // 正好相反）。面板独立呈现，不联动快捷栏——栏藏着就保持
    // 藏着（用户定：调面板时不许把栏也带出来）。全屏同理，不
    // 用小窗口绕路（#91 的先还原小窗口已删）。触发收不到的
    // 根因在插件侧（系统左边缘手势截走触摸），已由插件的
    // sendEvent 触摸漏斗修复。
    // 两个面板当前是否打开（以面板视图 isHidden 为准，与呈现层同源）
    private var isAppPanelOpen: Bool {
        guard let host = czfPanelOverlayHost else { return false }
        return !host.view.isHidden
    }
    private var isSourcesPanelOpen: Bool {
        guard let host = czfSourcesOverlayHost else { return false }
        return !host.view.isHidden
    }

    // 面板动作防重复：同一次滑动可能被插件（Darwin）和宿主窗口
    // 识别器两条路各报一次（小窗口模式两边都收得到触摸），切换式
    // 开关下第二下会把刚打开的面板又关掉，还多震一下。
    // 分来源去重（行为底线不动：启用带、控件排除、切换式全不变）：
    // 同来源 0.4 秒内重复吞掉（各来源各算各的，不再互相吞掉对方
    // 的第二次滑动）；跨来源回声另防——任一面板刚由另一来源打开
    // （1.0 秒内），本次就是同一物理滑动的第二路信号，直接吞掉，
    // 不开了又关、不多震。面板内互切（switchPanels）仍用下面
    // 共用的 czfLastPanelActionAt，不走这两路。
    private var czfLastPanelActionAt = Date.distantPast
    private enum CZFPanelSignalSource { case host, funnel }
    // 节流按面板分开记（2026-11-04 左滑确定性修复）：两面板
    // 共用一个节流时，右滑刚开完 App 面板、马上左滑会被吞掉，
    // 看着像左滑失灵；分开后互不影响，关着时一次左滑必定开。
    // 几何（带宽、边缘宽、门槛）一律不动。
    private var czfLastHostAppPanelActionAt = Date.distantPast
    private var czfLastFunnelAppPanelActionAt = Date.distantPast
    private var czfLastAppPanelOpenedAt = Date.distantPast
    private var czfLastAppPanelOpenedSource: CZFPanelSignalSource?
    private var czfLastHostSourcesPanelActionAt = Date.distantPast
    private var czfLastFunnelSourcesPanelActionAt = Date.distantPast
    private var czfLastSourcesPanelOpenedAt = Date.distantPast
    private var czfLastSourcesPanelOpenedSource: CZFPanelSignalSource?

    @objc public func czfOpenAppPanel() {
        czfToggleAppPanel(source: .host)
    }

    @objc public func czfOpenAppPanelFromFunnel() {
        czfToggleAppPanel(source: .funnel)
    }

    // 快捷栏按钮直调（Campbell 2026-11-06：App 面板呈现统
    // 一，手势路与快捷栏按钮共用同一个面板）：走同一套覆
    // 盖层呈现，不再另开系统 sheet。与 czfToggleAppPanel
    // 的区别只有两点：不吃边缘手势总开关（手势关掉时按钮
    // 照样要能开面板）、不走手势的跨源节流（按钮点按是单
    // 一干净信号）。开关式与手势路一致：开着再点就关。
    @objc public func czfOpenAppPanelFromDock() {
        if isAppPanelOpen {
            dismissPanelOverlay()
        } else {
            presentAllAppsPanel()
        }
    }

    private func czfToggleAppPanel(source: CZFPanelSignalSource) {
        guard Self.czfEdgeGesturesEnabled else { return }
        // 不再要求已打开 App/快捷栏可见：用户定任意位置（包括刚
        // 进 LiveContainer 的主界面）都要能调出面板，与源面板同
        // 待遇。呈现走 keyWindow 兜底（presentAllAppsPanel 内）。
        let now = Date()
        switch source {
        case .host:
            guard now.timeIntervalSince(czfLastHostAppPanelActionAt) > 0.4 else { return }
            czfLastHostAppPanelActionAt = now
        case .funnel:
            guard now.timeIntervalSince(czfLastFunnelAppPanelActionAt) > 0.4 else { return }
            czfLastFunnelAppPanelActionAt = now
        }
        if now.timeIntervalSince(czfLastAppPanelOpenedAt) < 1.0, czfLastAppPanelOpenedSource != source { return }
        edgeCallbackBuzz()
        // 切换式（用户要求）：面板已打开再滑一次就关掉，
        // 不再是只能滑开、关还得点按钮/点遮罩。
        if isAppPanelOpen {
            dismissPanelOverlay()
            return
        }
        czfLastAppPanelOpenedAt = now
        czfLastAppPanelOpenedSource = source
        presentAllAppsPanel()
    }

    // 源面板入口：左边缘往外弹（手指左移）调出（2026-10-23
    // 对调后，与往里拖的 App 面板对称）。故意不加 isVisible/
    // !apps 守卫：没打开任何 App、在主界面时也要能调出（用户
    // 明确要求）；呈现走 keyWindow 兜底。同样是切换式：已打开
    // 再滑一次关掉。
    @objc public func czfOpenSourcesPanel() {
        czfToggleSourcesPanel(source: .host)
    }

    @objc public func czfOpenSourcesPanelFromFunnel() {
        czfToggleSourcesPanel(source: .funnel)
    }

    private func czfToggleSourcesPanel(source: CZFPanelSignalSource) {
        guard Self.czfEdgeGesturesEnabled else { return }
        let now = Date()
        switch source {
        case .host:
            guard now.timeIntervalSince(czfLastHostSourcesPanelActionAt) > 0.4 else { return }
            czfLastHostSourcesPanelActionAt = now
        case .funnel:
            guard now.timeIntervalSince(czfLastFunnelSourcesPanelActionAt) > 0.4 else { return }
            czfLastFunnelSourcesPanelActionAt = now
        }
        if now.timeIntervalSince(czfLastSourcesPanelOpenedAt) < 1.0, czfLastSourcesPanelOpenedSource != source { return }
        edgeCallbackBuzz()
        if isSourcesPanelOpen {
            dismissSourcesOverlay()
            return
        }
        czfLastSourcesPanelOpenedAt = now
        czfLastSourcesPanelOpenedSource = source
        presentSourcesPanel()
    }


    // 建好手势面板覆盖层（只建一次，常驻窗口待命，和快捷栏同一个生命周期）。
    // #89 是每次左滑现建 SwiftUI 视图树：首帧渲染慢，滑完要等一下才动，
    // 体感像失灵；且开/关状态只认存着的引用，视图一旦被外部摘掉引用还
    // 非空，之后永远弹不出（小窗口"有时行有时不行"）。常驻后开/关只改
    // 可见性和位置，状态以视图 isHidden 为准，不再被旧引用毒化。
    private func ensurePanelOverlay(in window: UIWindow) {
        if let host = czfPanelOverlayHost, let backdrop = czfPanelOverlayBackdrop {
            // 已建过：若被挪出当前窗口（窗口/场景切换），搬回当前窗口
            if host.view.superview !== window {
                window.addSubview(backdrop)
                window.addSubview(host.view)
            }
            return
        }
        // 状态不完整（只剩一半）：清掉重建，避免留孤儿视图
        czfPanelOverlayHost?.view.removeFromSuperview()
        czfPanelOverlayBackdrop?.removeFromSuperview()
        czfPanelOverlayHost = nil
        czfPanelOverlayBackdrop = nil
        // 背景遮罩：点任意空白处关闭
        let backdrop = UIView(frame: window.bounds)
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        backdrop.alpha = 0
        backdrop.isHidden = true
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.czfPanelBackdropTapped)))
        window.addSubview(backdrop)
        // 面板本体：底部 60% 高，上圆角（75% 版 2026-10-23 当晚被
        // 用户真机否决：又高又肿，且整条盖死源面板手势起手带）
        let rootView = AnyView(
            AllAppsListView()
                .environmentObject(self)
                .environment(\.czfPanelClose) { [weak self] in self?.dismissPanelOverlay() }
        )
        let host = UIHostingController(rootView: rootView)
        let b = window.bounds
        host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: b.height * 0.6)
        host.view.layer.cornerRadius = 20
        host.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        host.view.clipsToBounds = true
        host.view.isHidden = true
        window.addSubview(host.view)
        // 卡片式抓手条（顶中，与 sheet 的拖动指示器同位）：
        // 默认藏，呈现时按形态点亮（czfApplyAppPanelStyle）。
        let grabber = UIView()
        grabber.backgroundColor = UIColor.label.withAlphaComponent(0.25)
        grabber.layer.cornerRadius = 2.5
        grabber.frame = CGRect(x: (b.width - 38) / 2, y: 8, width: 38, height: 5)
        grabber.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        grabber.isHidden = true
        host.view.addSubview(grabber)
        czfPanelGrabber = grabber
        // 下滑关闭：面板宿主挂拖动手势（只认顶部标题区起手，不抢
        // 列表滚动，起手判定在 gestureRecognizerShouldBegin）
        let drag = UIPanGestureRecognizer(target: self, action: #selector(self.czfPanelDragged(_:)))
        drag.delegate = self
        host.view.addGestureRecognizer(drag)
        // 边缘横滑切源面板（用户定）：面板打开时遮罩盖全屏、原来的
        // 边缘手势被挡，只能靠面板自己身上的手势切；UIScreenEdgePan
        // 只认贴边起手，不抢面板里横滑条的滚动；遮罩和面板本体各
        // 挂一个（一个手势只能挂一个视图）
        let edgeToSources = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.czfAppPanelEdgeSwitched(_:)))
        edgeToSources.edges = .left
        backdrop.addGestureRecognizer(edgeToSources)
        let edgeToSourcesOnPanel = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.czfAppPanelEdgeSwitched(_:)))
        edgeToSourcesOnPanel.edges = .left
        host.view.addGestureRecognizer(edgeToSourcesOnPanel)
        czfPanelOverlayBackdrop = backdrop
        czfPanelOverlayHost = host
    }

    // 面板要进的窗口：台前 App 最大化时必须用它的窗口——
    // 宿主窗（栏所在窗）会被全屏游客窗口盖住，面板在里面
    // 开了也看不见（最大化根本用不了手势面板、没法调 App）。
    // 非最大化时沿用宿主窗，不动原有行为。
    private var czfPanelTargetWindow: UIWindow? {
        if let front = czfFrontmostApp(),
           let view = front.view,
           let vc = view._viewDelegate() as? DecoratedAppSceneViewController,
           vc.isMaximized,
           let w = view.window {
            return w
        }
        return hostingController?.view.window ?? keyWindow
    }

    // 目标窗口是不是台前最大化游客的窗口（与 czfPanelTargetWindow
    // 的游客分支同判据）：是就不套卡片式，保持旧抽屉，免得
    // 卡片套进游客窗里缩成一团。
    private func czfPanelIsGuestWindow(_ window: UIWindow) -> Bool {
        guard let front = czfFrontmostApp(),
              let view = front.view,
              let vc = view._viewDelegate() as? DecoratedAppSceneViewController,
              vc.isMaximized else { return false }
        return view.window === window
    }

    // App 面板在目标窗口里的静止位/离屏位（用户定版：主窗里
    // 是悬浮卡片——左右各留 10、底留 10、四角全圆 30、高
    // 55%，顶部带抓手条；游客窗里保持旧的贴底抽屉：满宽、
    // 只圆上两角、高 60%）。所有入口（边缘手势/快捷栏按钮）
    // 都走这一套呈现，没有第二种样式。
    private func czfAppPanelFrames(in window: UIWindow) -> (open: CGRect, offscreen: CGRect, card: Bool) {
        let b = window.bounds
        let card = !czfPanelIsGuestWindow(window)
        let h = b.height * (card ? 0.55 : 0.6)
        let side: CGFloat = card ? 10 : 0
        let bottom: CGFloat = card ? 10 : 0
        let width = b.width - side * 2
        return (CGRect(x: side, y: b.height - bottom - h, width: width, height: h),
                CGRect(x: side, y: b.height, width: width, height: h),
                card)
    }

    // 按卡片/抽屉形态对齐 App 面板宿主的圆角与抓手条显隐，
    // 并记下底部留白供下滑关闭与互切动画算静止位。
    private func czfApplyAppPanelStyle(in window: UIWindow) {
        guard let host = czfPanelOverlayHost else { return }
        let frames = czfAppPanelFrames(in: window)
        host.view.layer.cornerRadius = frames.card ? 30 : 20
        host.view.layer.maskedCorners = frames.card
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        czfPanelGrabber?.isHidden = !frames.card
        czfAppPanelBottomInset = frames.card ? 10 : 0
    }

    // 源面板的静止位/离屏位：与 App 面板共用同一套帧规则
    // （Campbell 2026-11-06 令：两个面板样式同步、以快捷
    // 栏打开的 App 面板为准）。czfAppPanelFrames 只按目标
    // 窗口算（主窗卡片/游客窗抽屉）、与面板种类无关，
    // 直接转调，两边永远一致。
    private func czfSourcesPanelFrames(in window: UIWindow) -> (open: CGRect, offscreen: CGRect, card: Bool) {
        return czfAppPanelFrames(in: window)
    }

    // 按卡片/抽屉形态对齐源面板宿主的圆角与抓手条显隐
    // （czfApplyAppPanelStyle 的源面板对应版）。
    private func czfApplySourcesPanelStyle(in window: UIWindow) {
        guard let host = czfSourcesOverlayHost else { return }
        let frames = czfSourcesPanelFrames(in: window)
        host.view.layer.cornerRadius = frames.card ? 30 : 20
        host.view.layer.maskedCorners = frames.card
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        czfSourcesPanelGrabber?.isHidden = !frames.card
        czfSourcesPanelBottomInset = frames.card ? 10 : 0
    }

    private func presentAllAppsPanel() {
        DispatchQueue.main.async {
            guard let window = self.czfPanelTargetWindow else { return }
            // 两个面板互斥：开这个先关那个
            self.dismissSourcesOverlay()
            self.ensurePanelOverlay(in: window)
            guard let host = self.czfPanelOverlayHost, let backdrop = self.czfPanelOverlayBackdrop else { return }
            // 每次调用都强制对齐到打开状态，不看旧状态早退：旧状态可能
            // 与真实显示脱节（isHidden 为 false 但 frame 停在屏外/被盖住，
            // 表现为"滑一次没出来、再滑一次才出来"）。搬顶层、摆正、
            // 切可见、动画到目标位，一次调用即恢复；已打开时动画终点
            // 与当前位相同，无可见副作用。
            // 计数 +1：面板视图据此滚回顶部（每次调出都是初始状态）
            self.czfAppPanelOpenCounter += 1
            window.bringSubviewToFront(backdrop)
            window.bringSubviewToFront(host.view)
            let b = window.bounds
            // 形态按目标窗口定（主窗卡片式/游客窗抽屉式），
            // 静止位与离屏位都走 czfAppPanelFrames 一处计算。
            let frames = self.czfAppPanelFrames(in: window)
            self.czfApplyAppPanelStyle(in: window)
            backdrop.frame = b
            backdrop.isHidden = false
            host.view.isHidden = false
            if host.view.frame.height != frames.open.height || host.view.frame.width != frames.open.width {
                host.view.frame = frames.offscreen
            }
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.6, options: [.curveEaseOut]) {
                backdrop.alpha = 1
                host.view.frame = frames.open
            }
        }
    }

    @objc private func czfPanelBackdropTapped() {
        dismissPanelOverlay()
    }

    // 面板下滑关闭的起手限制：App 面板认固定栏整条（标题行
    // 已去掉后约 58pt，取 64：顶边 16 + 图标 40 + 底边 2；
    // 再往下是运行条（约 66 起），不扩到它），用户 2026-11-03
    // 定固定栏往下滑动隐藏面板；源面板没有固定栏，仍只认
    // 顶部 52pt 标题区。面板内的列表滚动一点不受影响；其余
    // 手势一律放行。
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let hostView = gestureRecognizer.view,
           hostView === czfPanelOverlayHost?.view || hostView === czfSourcesOverlayHost?.view {
            let topLimit: CGFloat = hostView === czfPanelOverlayHost?.view ? 64 : 52
            guard gestureRecognizer.location(in: hostView).y < topLimit else { return false }
            // 下滑关闭只认向下为主的初动：原来顶部区内任何方向
            // 的移动都让下滑手势先认——横滑被它认走后全局手势
            // 失效（面板上左滑有时不出），点按被它取消（收起
            // 点着没反应）。横滑交给全局手势，点按不受影响。
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let t = pan.translation(in: hostView)
                return t.y > abs(t.x) && t.y > 0
            }
            return true
        }
        return true
    }

    // 面板下滑关闭（两个面板共用，按手势挂的宿主区分）：拖动跟随
    // 手指，松手时位移过 90 或下滑速度过 500 就关，否则弹回。
    @objc private func czfPanelDragged(_ gesture: UIPanGestureRecognizer) {
        guard let hostView = gesture.view, let container = hostView.superview else { return }
        let isSources = hostView === czfSourcesOverlayHost?.view
        let backdrop = isSources ? czfSourcesOverlayBackdrop : czfPanelOverlayBackdrop
        let panelHeight = hostView.frame.height
        // 卡片式时静止位还要扣掉底部留白（呈现时按面板记的）
        let openY = container.bounds.height - panelHeight - (isSources ? czfSourcesPanelBottomInset : czfAppPanelBottomInset)
        switch gesture.state {
        case .changed:
            let dy = max(0, gesture.translation(in: container).y)
            hostView.frame.origin.y = openY + dy
            backdrop?.alpha = max(0, 1 - dy / panelHeight)
        case .ended, .cancelled:
            let dy = max(0, gesture.translation(in: container).y)
            let velocityY = gesture.velocity(in: container).y
            if dy > 90 || velocityY > 500 {
                if isSources {
                    dismissSourcesOverlay()
                } else {
                    dismissPanelOverlay()
                }
            } else {
                UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
                    hostView.frame.origin.y = openY
                    backdrop?.alpha = 1
                }
            }
        default:
            break
        }
    }

    // 关闭手势面板覆盖层：滑出后切回隐藏待命（不摘除、不销毁）。
    // 背景点击、面板内关闭/启动/最小化/小窗口按钮（经 czfPanelClose 注入）
    // 都会走到这里。
    private func dismissPanelOverlay() {
        guard let host = czfPanelOverlayHost, let backdrop = czfPanelOverlayBackdrop, !host.view.isHidden else { return }
        // 滑到容器底边之外：卡片式静止位离底边还差一个留白，
        // 只按高度偏移会露出一条边，必须滑到 superview 底。
        let targetY = host.view.superview?.bounds.height ?? host.view.frame.origin.y + host.view.frame.height + 16
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn], animations: {
            backdrop.alpha = 0
            host.view.frame.origin.y = targetY
        }, completion: { _ in
            backdrop.isHidden = true
            host.view.isHidden = true
        })
    }

    // MARK: - 源面板覆盖层（与 App 面板同构：常驻待命、强制对齐呈现）

    private func ensureSourcesOverlay(in window: UIWindow) {
        if let host = czfSourcesOverlayHost, let backdrop = czfSourcesOverlayBackdrop {
            if host.view.superview !== window {
                window.addSubview(backdrop)
                window.addSubview(host.view)
            }
            return
        }
        czfSourcesOverlayHost?.view.removeFromSuperview()
        czfSourcesOverlayBackdrop?.removeFromSuperview()
        czfSourcesOverlayHost = nil
        czfSourcesOverlayBackdrop = nil
        let backdrop = UIView(frame: window.bounds)
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        backdrop.alpha = 0
        backdrop.isHidden = true
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.czfSourcesBackdropTapped)))
        window.addSubview(backdrop)
        let rootView = AnyView(
            SourcesPanelView()
                .environmentObject(self)
                // app 卡复用源页面的 LCSourceAppBanner，它读
                // SharedModel 环境对象：覆盖层不在主 App 的环
                // 境链里，必须在这里补注入（与主入口同一个
                // DataManager.shared.model 实例）。
                .environmentObject(DataManager.shared.model)
                .environment(\.czfPanelClose) { [weak self] in self?.dismissSourcesOverlay() }
        )
        let host = UIHostingController(rootView: rootView)
        let b = window.bounds
        host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: b.height * 0.6)
        host.view.layer.cornerRadius = 20
        host.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        host.view.clipsToBounds = true
        host.view.isHidden = true
        window.addSubview(host.view)
        // 卡片式抓手条：与 App 面板同款（顶中 38×5），呈现时
        // 按形态点亮（czfApplySourcesPanelStyle）。
        let grabber = UIView()
        grabber.backgroundColor = UIColor.label.withAlphaComponent(0.25)
        grabber.layer.cornerRadius = 2.5
        grabber.frame = CGRect(x: (b.width - 38) / 2, y: 8, width: 38, height: 5)
        grabber.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        grabber.isHidden = true
        host.view.addSubview(grabber)
        czfSourcesPanelGrabber = grabber
        // 下滑关闭：与 App 面板共用同一个拖动处理器
        let drag = UIPanGestureRecognizer(target: self, action: #selector(self.czfPanelDragged(_:)))
        drag.delegate = self
        host.view.addGestureRecognizer(drag)
        // 边缘横滑切 App 面板（用户定，与 App 面板那侧镜像）：右缘
        // 往左滑切回 App 面板，同样只认贴边起手、不抢横滑条滚动
        let edgeToApps = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.czfSourcesPanelEdgeSwitched(_:)))
        edgeToApps.edges = .right
        backdrop.addGestureRecognizer(edgeToApps)
        let edgeToAppsOnPanel = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.czfSourcesPanelEdgeSwitched(_:)))
        edgeToAppsOnPanel.edges = .right
        host.view.addGestureRecognizer(edgeToAppsOnPanel)
        czfSourcesOverlayBackdrop = backdrop
        czfSourcesOverlayHost = host
    }

    private func presentSourcesPanel() {
        DispatchQueue.main.async {
            guard let window = self.czfPanelTargetWindow else { return }
            // 两个面板互斥：开这个先关那个
            self.dismissPanelOverlay()
            self.ensureSourcesOverlay(in: window)
            guard let host = self.czfSourcesOverlayHost, let backdrop = self.czfSourcesOverlayBackdrop else { return }
            // 计数 +1：面板视图据此刷新源数据（覆盖层常驻，onAppear 不重来）
            self.czfSourcesPanelOpenCounter += 1
            window.bringSubviewToFront(backdrop)
            window.bringSubviewToFront(host.view)
            let b = window.bounds
            // 形态与 App 面板同步（czfSourcesPanelFrames）：
            // 主窗悬浮卡片、游客窗贴底抽屉，静止位/离屏位
            // 都走同一处计算（与 presentAllAppsPanel 同构）。
            let frames = self.czfSourcesPanelFrames(in: window)
            self.czfApplySourcesPanelStyle(in: window)
            backdrop.frame = b
            backdrop.isHidden = false
            host.view.isHidden = false
            if host.view.frame.height != frames.open.height || host.view.frame.width != frames.open.width {
                host.view.frame = frames.offscreen
            }
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.6, options: [.curveEaseOut]) {
                backdrop.alpha = 1
                host.view.frame = frames.open
            }
        }
    }

    // 面板互切（用户定）：App 面板左缘往右滑切源面板、源面板右缘
    // 往左滑切 App 面板。面板打开时遮罩盖全屏、原来的边缘手势被
    // 挡，只能靠面板自己身上的边缘手势切；切换时遮罩不闪（新遮
    // 罩直接显到 1、旧遮罩动画完再藏），两面板同时上下滑（旧的
    // 下去、新的上来），看着像翻页，不是一关一开；0.4 秒节流和
    // 开面板同款，防连滑叠动画。
    private func switchPanels(toSources: Bool) {
        DispatchQueue.main.async {
            guard Self.czfEdgeGesturesEnabled else { return }
            let now = Date()
            guard now.timeIntervalSince(self.czfLastPanelActionAt) > 0.4 else { return }
            guard toSources ? self.isAppPanelOpen : self.isSourcesPanelOpen else { return }
            guard let window = self.czfPanelTargetWindow else { return }
            self.czfLastPanelActionAt = now
            self.edgeCallbackBuzz()
            if toSources {
                self.ensureSourcesOverlay(in: window)
            } else {
                self.ensurePanelOverlay(in: window)
            }
            guard let oldHost = toSources ? self.czfPanelOverlayHost : self.czfSourcesOverlayHost,
                  let oldBackdrop = toSources ? self.czfPanelOverlayBackdrop : self.czfSourcesOverlayBackdrop,
                  let newHost = toSources ? self.czfSourcesOverlayHost : self.czfPanelOverlayHost,
                  let newBackdrop = toSources ? self.czfSourcesOverlayBackdrop : self.czfPanelOverlayBackdrop else { return }
            let b = window.bounds
            if toSources {
                self.czfSourcesPanelOpenCounter += 1
                self.czfApplySourcesPanelStyle(in: window)
            } else {
                self.czfAppPanelOpenCounter += 1
                self.czfApplyAppPanelStyle(in: window)
            }
            window.bringSubviewToFront(newBackdrop)
            window.bringSubviewToFront(newHost.view)
            newBackdrop.frame = b
            newBackdrop.isHidden = false
            newBackdrop.alpha = 1
            newHost.view.isHidden = false
            // 新面板的静止位：两个面板共用同一套帧规则
            // （czfAppPanelFrames / czfSourcesPanelFrames，
            // 主窗卡片式/游客窗抽屉式）。
            let newOpenFrame = toSources
                ? self.czfSourcesPanelFrames(in: window).open
                : self.czfAppPanelFrames(in: window).open
            if newHost.view.frame.height != newOpenFrame.height || newHost.view.frame.width != newOpenFrame.width {
                newHost.view.frame = CGRect(x: newOpenFrame.origin.x, y: b.height, width: newOpenFrame.width, height: newOpenFrame.height)
            }
            let oldHeight = oldHost.view.frame.height
            // 旧面板滑出：卡片式时多滑一个底部留白，不然动
            // 画途中会露出一条边（终点在屏外即可）；旧面板
            // 是谁就用谁的留白（样式同步后两边同为 10）。
            let oldOffset = oldHeight + (toSources ? self.czfAppPanelBottomInset : self.czfSourcesPanelBottomInset)
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.6, options: [.curveEaseOut]) {
                oldHost.view.frame = oldHost.view.frame.offsetBy(dx: 0, dy: oldOffset)
                newHost.view.frame = newOpenFrame
            } completion: { _ in
                oldBackdrop.isHidden = true
                oldHost.view.isHidden = true
            }
        }
    }

    @objc private func czfAppPanelEdgeSwitched(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        // 左缘互切只认往右（向里）：注释定的方向，代码原来不验，
        // 往外方向的滑动也会切到源面板。
        guard gesture.translation(in: gesture.view).x > 0 else { return }
        switchPanels(toSources: true)
    }

    @objc private func czfSourcesPanelEdgeSwitched(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        // 右缘互切只认往左（向里）
        guard gesture.translation(in: gesture.view).x < 0 else { return }
        switchPanels(toSources: false)
    }

    @objc private func czfSourcesBackdropTapped() {
        dismissSourcesOverlay()
    }

    private func dismissSourcesOverlay() {
        guard let host = czfSourcesOverlayHost, let backdrop = czfSourcesOverlayBackdrop, !host.view.isHidden else { return }
        // 与 App 面板关闭同款：卡片式静止位离底边还差一个
        // 留白，只按高度偏移会露出一条边，必须滑到
        // superview 底边之外。
        let targetY = host.view.superview?.bounds.height ?? host.view.frame.origin.y + host.view.frame.height + 16
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn], animations: {
            backdrop.alpha = 0
            host.view.frame.origin.y = targetY
        }, completion: { _ in
            backdrop.isHidden = true
            host.view.isHidden = true
        })
    }

    // 手势已改走宿主悬浮边条窗，不再用插件：清掉旧版本部署到两个全局
    // Tweaks 根目录的手势插件文件，避免它继续随游客 App 加载。
    // 静态方法：宿主一启动（AppDelegate）就调，赶在任何游客 App 启动之前。
    // 管理器初始化时也会再调一次（幂等）。
    // 游客 App 是独立进程，插件的手势信号通过 Darwin 跨进程通知送达这里
    // 游客点按置顶的宿主侧观察者：游客每次触摸按下发 czf.window.touch.<bid>，
    // 宿主按名找到窗口静默置顶。注册记账防重复（同 bid 重装不重复注册；
    // 残留观察者也无害：触发时按 bid 现查，找不到就空操作）。
    private var czfTouchRaiseRegisteredBids: Set<String> = []
    private func czfRegisterTouchRaiseObserver(bundleId: String) {
        guard !czfTouchRaiseRegisteredBids.contains(bundleId) else { return }
        czfTouchRaiseRegisteredBids.insert(bundleId)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let name = "czf.window.touch.\(bundleId)"
        CFNotificationCenterAddObserver(center, observer, { _, observerPtr, cfName, _, _ in
            guard let observerPtr = observerPtr, let cfName = cfName else { return }
            let manager = Unmanaged<MultitaskDockManager>.fromOpaque(observerPtr).takeUnretainedValue()
            let notificationName = cfName.rawValue as String
            guard notificationName.hasPrefix("czf.window.touch.") else { return }
            let bid = String(notificationName.dropFirst("czf.window.touch.".count))
            DispatchQueue.main.async {
                manager.czfRaiseWindowForTouch(bundleId: bid)
            }
        }, name as CFString, nil, .deliverImmediately)
    }
    private func czfUnregisterTouchRaiseObserver(bundleId: String) {
        guard czfTouchRaiseRegisteredBids.remove(bundleId) != nil else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(rawValue: "czf.window.touch.\(bundleId)" as CFString), nil)
    }

    // 边缘手势信号观察者：游客边缘手势的 Darwin 信号（czf.dock.*）送达这里
    private func registerDockEdgeDarwinObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let names = ["czf.dock.rightInward", "czf.dock.rightOutward", "czf.dock.leftOutward", "czf.dock.openPanel", "czf.dock.openSources"]
        for name in names {
            CFNotificationCenterAddObserver(center, observer, { _, observerPtr, cfName, _, _ in
                guard let observerPtr = observerPtr, let cfName = cfName else { return }
                let manager = Unmanaged<MultitaskDockManager>.fromOpaque(observerPtr).takeUnretainedValue()
                let notificationName = cfName.rawValue as String
                DispatchQueue.main.async {
                    switch notificationName {
                    case "czf.dock.rightInward": manager.czfEdgeRightInward()
                    case "czf.dock.rightOutward": manager.czfEdgeRightOutward()
                    case "czf.dock.leftOutward": manager.czfEdgeLeftOutward()
                    case "czf.dock.openPanel": manager.czfOpenAppPanelFromFunnel()
                    case "czf.dock.openSources": manager.czfOpenSourcesPanelFromFunnel()
                    default: break
                    }
                }
            }, name as CFString, nil, .deliverImmediately)
        }
    }

    // 把手势插件拷到两个全局 Tweaks 根目录（随所有游客 App 加载），并强制签名。
    // 静态方法：宿主一启动（AppDelegate）就调，赶在任何游客 App 启动之前，
    // 避开签名缓存与启动抢跑。管理器初始化时也会再调一次（幂等）。
    static func deployDockGestureTweak() {
        // 手势不再作为独立插件下发（2026-10-24 用户亲定：别再注入）：
        // 手势代码已随 TweakLoader 编译进启动器，这里只清掉全局插件
        // 目录里残留的旧独立文件——不清的话 TweakLoader 还会把它
        // 当插件 dlopen，双份挂钩、手势触发两次。
        let fm = FileManager.default
        for folder in [LCPath.tweakPath, LCPath.lcGroupTweakPath] {
            try? fm.removeItem(at: folder.appendingPathComponent("CZFDockGesture.dylib"))
        }
    }

    // Add edge gesture recognition areas when dock is hidden
    private func setupEdgeGestureRecognizers() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = windowScene.windows.first else { return }
        
        keyWindow.gestureRecognizers?.removeAll { gesture in
            return gesture is UITapGestureRecognizer || gesture is UIScreenEdgePanGestureRecognizer
        }
        
        if isDockHidden {
            let leftEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            leftEdgeGesture.edges = .left
            leftEdgeGesture.delegate = self
            keyWindow.addGestureRecognizer(leftEdgeGesture)
            
            let rightEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            rightEdgeGesture.edges = .right
            rightEdgeGesture.delegate = self
            keyWindow.addGestureRecognizer(rightEdgeGesture)
        }
    }
    
    @objc private func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard isDockHidden, gesture.state == .began || gesture.state == .changed else {
            return
        }
        if gesture.state == .began {
            czfEdgeSwipeLatched = false
        }

        let translation = gesture.translation(in: gesture.view)
        let swipeDistance = abs(translation.x)

        if swipeDistance > Constants.edgeSwipeThreshold, !czfEdgeSwipeLatched {
            czfEdgeSwipeLatched = true
            // 左边缘（屏幕边缘手势只能往里拖）= App 面板
            // （2026-10-23 对调后，与全局甩手判定一致）；
            // 右边缘：App 页（没有台前 App）且有运行中 App
            // 时切到 App（最近一个）；否则照旧唤出快捷栏。
            // 游客里台前有 App 时不动，免得和游客侧切换
            // 重复触发。
            if gesture.edges == .left {
                czfOpenAppPanel()
            } else if czfFrontmostApp() == nil, !apps.isEmpty {
                czfEdgeRightInward()
            } else {
                showDockFromHidden()
            }
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}



// MARK: - SwiftUI Dock View
@available(iOS 16.0, *)
public struct MultitaskDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var dragOffset = CGSize.zero
    @State private var isMoving: Bool = false
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    
    // Calculate dynamic padding based on user settings
    private var dynamicPadding: CGFloat {
        let basePadding: CGFloat = 4
        let extraPadding = (dockManager.dockWidth - MultitaskDockManager.Constants.dockWidthPaddingReference) * 0.2
        return max(basePadding, basePadding + extraPadding)
    }
    
    public var body: some View {
        GeometryReader { g in
            VStack(spacing: 8) {
                if dockManager.isCollapsed {
                    CollapsedDockView(isHidden: dockManager.isDockHidden)
                        .onTapGesture {
                            dockManager.toggleDockCollapse()
                        }
                } else {
                    VStack(spacing: 8) {
                        AllAppsButtonView()
                            .onTapGesture {
                                // 与手势路共用同一个 App 面板（覆盖
                                // 层呈现），不再另开系统 sheet
                                dockManager.czfOpenAppPanelFromDock()
                            }
                        
                        CollapseButtonView()
                            .onTapGesture {
                                dockManager.toggleDockCollapse()
                            }
                        
                        MinimizeAllButtonView()
                            .onTapGesture {
                                dockManager.minimizeAllWindows()
                            }
                        
                        ForEach(dockManager.apps) { app in
                            AppIconView(app: app)
                        }
                        
                        CloseAllButtonView()
                            .onTapGesture {
                                dockManager.closeAllWindows()
                            }
                    }
                }
            }
            .padding(dynamicPadding)
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .rect(cornerRadius: 15))
                } else {
                    content.background(
                        RoundedRectangle(cornerRadius: 15)
                            .fill(Color.black.opacity(dockManager.isDockHidden ? 0.3 : 0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.white.opacity(dockManager.isDockHidden ? 0.1 : 0.3), lineWidth: 1)
                            )
                    )
                }
            }
            .scaleEffect(dockManager.isVisible ? 1.0 : 0.8)
            .opacity(dockManager.isDockHidden ? 0.0 : 1.0)
            .offset(dragOffset)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }



        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 5)
            .onChanged { value in
                self.isMoving = true
                self.dragOffset = value.translation
            }
            .onEnded { value in
                self.isMoving = true

                let hcFrame = dockManager.hostingController?.view.frame ?? .zero
                
                let currentPhysicalFrame = hcFrame.offsetBy(dx: self.dragOffset.width, dy: self.dragOffset.height)
                
                if dockManager.isPositionChangeGesture(for: hcFrame, translation: value.translation) {
                    let screenBounds = dockManager.keyWindow!.bounds
                    let targetX = dockManager.calculateTargetX(isDockHidden: false, isOnRightSide: currentPhysicalFrame.midX > screenBounds.width / 2, dockWidth: dockManager.dockWidth, screenWidth: screenBounds.width)
                    
                    let safeAreaInsets = dockManager.safeAreaInsets
                    let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                    let minY = safeAreaInsets.top + dockVerticalMargin
                    let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                    let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                    
                    let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                    
                    let newOffset = CGSize(
                        width: finalPhysicalPosition.x - hcFrame.origin.x,
                        height: finalPhysicalPosition.y - hcFrame.origin.y
                    )
                    
                    let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                    
                    withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = newOffset
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                        dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                        
                        self.dragOffset = .zero
                        
                        self.isMoving = false
                    }
                    return
                }
                
                if dockManager.handleSwipeToHideOrShowGesture(for: hcFrame, translation: value.translation) {
                    withAnimation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = .zero
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + MultitaskDockManager.Constants.longAnimationDuration) {
                        self.isMoving = false
                    }
                    return
                }
                
                let screenBounds = dockManager.keyWindow!.bounds
                let safeAreaInsets = dockManager.safeAreaInsets
                let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                let minY = safeAreaInsets.top + dockVerticalMargin
                let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                
                let targetX: CGFloat

                let isOnRightSide = hcFrame.origin.x > screenBounds.width / 2
                targetX = dockManager.calculateTargetX(isDockHidden: dockManager.isDockHidden, isOnRightSide: isOnRightSide, dockWidth: currentPhysicalFrame.width, screenWidth: screenBounds.width)
                
                let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                
                let newOffset = CGSize(
                    width: finalPhysicalPosition.x - hcFrame.origin.x,
                    height: finalPhysicalPosition.y - hcFrame.origin.y
                )
                
                let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                
                withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                    self.dragOffset = newOffset
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                    dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                    
                    self.dragOffset = .zero
                    
                    self.isMoving = false
                }
            }
        )
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isCollapsed)
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isDockHidden)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.dockWidth)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.settingsChanged)
    }
    
    public init() {}
}

// MARK: - Collapsed Dock View
@available(iOS 16.0, *)
struct CollapsedDockView: View {
    let isHidden: Bool
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            // 蓝色渐变改平实心蓝：与面板主按钮同语言（渐变是旧
            // 糖果皮的一部分）；隐藏态靠透明度压暗的语义不变
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(isHidden ? 0.5 : 0.9))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Group {
                if isHidden {
                    Image(systemName: "eye.slash")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.system(size: dockManager.adaptiveIconSize * 0.35, weight: .bold))
                } else {
                    Image(systemName: "chevron.up")
                        .foregroundColor(.white)
                        .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .bold))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isHidden ? 0.2 : 0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .scaleEffect(isHidden ? 0.9 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// dock 小按钮底色/图标色：必须跟底板实际渲染走——v149 回归
// 教训：白底白字只在深色底板上可见；iOS 26 液态玻璃底板是
// 浅色磨砂，白按钮直接隐身（位置还在、能点但看不见）。玻璃
// 下用状态栏条同款浅灰底 + 深色图标，深色底板下用半透明
// 浅底 + 白图标，跟底板取同一个判断条件
private enum CZFDockButtonStyle {
    static var tile: Color {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            return Color(.systemGray5)
        }
        return Color.white.opacity(0.15)
    }
    static var glyph: Color {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            return .primary
        }
        return .white
    }
}

// MARK: - Collapse Button View
@available(iOS 16.0, *)
struct CollapseButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        // #12/#14：跟底板走（见 CZFDockButtonStyle，玻璃下浅灰
        // 底 + 深色图标，深色底板下半透明浅底 + 白图标）
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(CZFDockButtonStyle.tile)
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)

            Image(systemName: "chevron.down")
                .foregroundColor(CZFDockButtonStyle.glyph)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Minimize All Button View
@available(iOS 16.0, *)
struct MinimizeAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        // #12/#14：同收起钮，跟底板走（见 CZFDockButtonStyle）
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(CZFDockButtonStyle.tile)
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)

            Image(systemName: "rectangle.stack.badge.minus")
                .foregroundColor(CZFDockButtonStyle.glyph)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
    }
}

// MARK: - All Apps Button View
@available(iOS 16.0, *)
struct AllAppsButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    private let appIcon = UIImage(named: "DockAppIcon")
    
    var body: some View {
        ZStack {
            if let icon = appIcon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.8))
                    .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)

                Image(systemName: "apps.iphone")
                    .foregroundColor(.white)
                    .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Close All Button (red X)
@available(iOS 16.0, *)
struct CloseAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        // 与面板「关闭全部」同款：浅红底 + 红图标（原实心红块
        // 太重）；dock 底板是深色，红色透明度比面板略提一档保识别
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.25))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)

            Image(systemName: "xmark")
                .foregroundColor(.red)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
    }
}

// 手势面板（窗口覆盖层方式）专用的关闭通道：覆盖层不是模态呈现，
// SwiftUI 的 dismiss 在那里无效。覆盖层注入关闭动作，面板内按钮统一走
// closePanel()：有注入走注入（覆盖层），没注入走 dismiss 兜底。
private struct CZFPanelCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var czfPanelClose: (() -> Void)? {
        get { self[CZFPanelCloseKey.self] }
        set { self[CZFPanelCloseKey.self] = newValue }
    }
}

// MARK: - All Apps List View
// 面板顶部固定 App 的存储（用户定）：长按列表行固定/取消固定，
// 按实例记：键是“包名_数据文件夹名（dataUUID）”，与图标缓存
// 同款写法。只按包名记会把同 App 多开的全部实例一起固定
// （用户实证：固定一个 Muse，固定区出现两个 Muse）。
// 注意：删 App 重装会换数据文件夹，固定不跟过去（只丢固定，
// 不丢数据）；平时更新不换文件夹，固定不受影响。
final class CZFPinnedAppsStore: ObservableObject {
    static let shared = CZFPinnedAppsStore()
    @Published private(set) var pinnedIds: [String] = []
    private let defaultsKey = "CZFPinnedPanelApps"
    private let migratedKey = "CZFPinnedPanelAppsMigratedV2"
    init() {
        pinnedIds = LCUtils.appGroupUserDefault.stringArray(forKey: defaultsKey) ?? []
    }
    /// 固定键：实例粒度。dataUUID 是数据文件夹名，多开各实例不同；
    /// 为空时退到“包名_”（该模型无容器、跑不起来，撞键也无实际影响）。
    static func pinKey(for app: LCAppModel) -> String {
        "\(app.appInfo.bundleIdentifier() ?? "")_\(app.appInfo.dataUUID ?? "")"
    }
    /// 入参直接是模型对象，不再传裸字符串——传错键（比如包名）
    /// 就是这次 bug 的根源，API 上直接堵死。
    func isPinned(_ app: LCAppModel) -> Bool { pinnedIds.contains(Self.pinKey(for: app)) }
    func toggle(_ app: LCAppModel) {
        let key = Self.pinKey(for: app)
        if let idx = pinnedIds.firstIndex(of: key) {
            pinnedIds.remove(at: idx)
        } else {
            pinnedIds.append(key)
        }
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
    }
    /// 固定区拖动换位（用户 2026-11-03 定：按住图标拖到目标
    /// 位置松手）：to 是换位后该项应占的下标（先删后插，
    /// 与 SwiftUI List 的 move 语义一致）；顺序即时落盘。
    func movePinned(from source: Int, to destination: Int) {
        guard source != destination,
              pinnedIds.indices.contains(source),
              destination >= 0, destination < pinnedIds.count else { return }
        let key = pinnedIds.remove(at: source)
        pinnedIds.insert(key, at: destination)
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
    }
    /// 旧版按包名存的固定项迁移（只跑一次）：单实例的包名直转
    /// 成该实例的键（用户的固定保留）；多实例的包名无法断定
    /// 当初固定的是哪一个，丢弃（用户重固定一次即可，点一下），
    /// 绝不猜一个实例替用户固定；已删 App 的残留一并清掉。
    /// 模型表为空时不跑、不记迁移完成（等面板下次打开模型到了再跑）。
    func migrateLegacyPins(models: [LCAppModel]) {
        guard !LCUtils.appGroupUserDefault.bool(forKey: migratedKey) else { return }
        guard !models.isEmpty else { return }
        var migrated: [String] = []
        for entry in pinnedIds {
            if models.contains(where: { Self.pinKey(for: $0) == entry }) {
                if !migrated.contains(entry) { migrated.append(entry) }
                continue
            }
            let sameBundle = models.filter { ($0.appInfo.bundleIdentifier() ?? "") == entry }
            if sameBundle.count == 1, let only = sameBundle.first {
                let key = Self.pinKey(for: only)
                if !migrated.contains(key) { migrated.append(key) }
            }
            // 多实例（sameBundle.count > 1）或查无此 App：一律丢弃。
        }
        pinnedIds = migrated
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
        LCUtils.appGroupUserDefault.set(true, forKey: migratedKey)
    }
}

// 面板顶部固定区：直接贴面板底色排版，不套灰卡；图标
// 横排，点按打开；没固定过时给一行提示怎么固定。
// 视觉对齐（2026-10-24）：面板三段统一外边距 16、内容列
// 对齐到 26（外 16 + 内 10，与运行条、列表行图标列同线）、
// 段间距统一 10；固定区图标行单独内缩 10，标题行不动
// （标题对齐卡片背景边，图标对齐图标列）。
// 固定区拖动换位的 DropDelegate：拖过目标图标即换位（松手
// 即定，不用等放下才动）；拖的键用 @State 传，不读 provider
// 的异步加载——dropEntered 是同步回调，读 provider 来不及。
// 拖出目标外取消时不调 performDrop，键残留无害：下一次拖
// 动起拖即覆盖，dropEntered 只在拖动进行中才触发。
@available(iOS 16.0, *)
private struct CZFPinnedReorderDelegate: DropDelegate {
    let targetIndex: Int
    let store: CZFPinnedAppsStore
    @Binding var draggedKey: String?

    func dropEntered(info: DropInfo) {
        guard let draggedKey = draggedKey,
              store.pinnedIds.indices.contains(targetIndex),
              store.pinnedIds[targetIndex] != draggedKey,
              let from = store.pinnedIds.firstIndex(of: draggedKey) else { return }
        store.movePinned(from: from, to: targetIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedKey = nil
        return true
    }
}

@available(iOS 16.0, *)
struct PinnedAppsStripView: View {
    @ObservedObject var sortManager = LCAppSortManager.shared
    @ObservedObject var pinnedStore = CZFPinnedAppsStore.shared
    let onLaunch: (LCAppModel) -> Void

    // 固定区顺序跟固定顺序走（不再跟列表排序走）：按住拖动
    // 换位改的就是这个顺序；已删 App 的残留键自然掉。
    private var pinnedApps: [LCAppModel] {
        pinnedStore.pinnedIds.compactMap { id in
            sortManager.sortedApps.first { CZFPinnedAppsStore.pinKey(for: $0) == id }
        }
    }
    @State private var draggedPinKey: String?

    var body: some View {
        // 直接贴面板底色排版，不再套一层灰卡（卡里套卡是用户
        // 点名"太丑"的主因）；图标 40pt / 圆角 12（用户定小点），
        // 运行区 46pt、列表行 52pt，左边缘对齐即可
        // 标题行已去掉（用户 2026-11-03 令去最顶部图钉与 ✕）：
        // 面板改由固定栏往下滑动隐藏，关面板走遮罩点按与下滑。
        VStack(alignment: .leading, spacing: 8) {
            if pinnedApps.isEmpty {
                Text("长按下面的 App 可以固定到这里")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        // id 跟 App 走（不用下标）：换位时 SwiftUI 按
                        // App 身份做移动画，不会把图标内容错位互换。
                        ForEach(Array(pinnedApps.enumerated()), id: \.element) { pair in
                            let index = pair.offset
                            let app = pair.element
                            // 固定区只留图标、不要名字（用户定）：名字
                            // 字号小又挤，图标本身已够认；点按仍打开。
                            // 按住拖动换位（用户 2026-11-03 定）：iOS
                            // 的 onDrag 本来就要按住才起拖，与点按不
                            // 冲突；拖过目标即换位，松手即定。
                            RunningAppIcon(appInfo: app.appInfo)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
                                .contentShape(Rectangle())
                                .onTapGesture { onLaunch(app) }
                                .onDrag {
                                    let key = CZFPinnedAppsStore.pinKey(for: app)
                                    draggedPinKey = key
                                    return NSItemProvider(object: key as NSString)
                                }
                                .onDrop(of: [.text], delegate: CZFPinnedReorderDelegate(targetIndex: index, store: pinnedStore, draggedKey: $draggedPinKey))
                        }
                    }
                    // 图标列对齐：固定区图标左边缘与运行条、列表行
                    // 图标列同线（外 16 + 内 10 = 26），标题行不动
                    .padding(.leading, 10)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 2)
        // 旧版按包名存的固定项迁移：面板打开时跑一次（模型到了
        // 才跑，模型没到不记完成、下次打开再跑；跑过一次就不再跑）。
        // 任务绑模型数：模型表从空变有也触发，不会卡在空表上。
        .task(id: sortManager.sortedApps.count) {
            pinnedStore.migrateLegacyPins(models: sortManager.sortedApps)
        }
    }
}

// List 背景透明化（iOS 16+）：scrollContentBackground 是
// 16 起的 API，部署目标 15 起，低版本保持列表自带底色
// （面板本身是 16+ 多任务特性，15 上差异仅底色一项）。
// 注意：@available 必须紧贴它修饰的声明——2026-11-06
// 构建 #16 失败就是它被插在 AllAppsListView 的注解与
// 声明之间，把注解“偷”走了（见 AllAppsListView 处）。
@available(iOS 16.0, *)
private struct CZFListBackdropHidden: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

// 分组列表段间距压到 0（iOS 17+）：insetGrouped 的 Section
// 即使没有段头，系统也留一截段头间距，面板里第一张卡上方
// 就空出一条大空白（Campbell 2026-11-06 真机点名）。struct
// 本身只标 16（与 CZFListBackdropHidden 同款），17 的 API
// 在 body 内再判一次，16 上保持系统间距。
@available(iOS 16.0, *)
private struct CZFListSectionSpacingZero: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.listSectionSpacing(0)
        } else {
            content
        }
    }
}

// 列表滚动内容顶部边距压到 0（iOS 17+）：insetGrouped 列表
// 自带一截顶部内容边距，与段间距是两笔账，分开压。
@available(iOS 16.0, *)
private struct CZFListTopMarginZero: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentMargins(.top, 0, for: .scrollContent)
        } else {
            content
        }
    }
}

@available(iOS 16.0, *)
struct AllAppsListView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.czfPanelClose) private var czfPanelClose
    @EnvironmentObject var dockManager: MultitaskDockManager

    // 关闭面板：覆盖层呈现走注入的关闭动作（面板呈现已统一
    // 为覆盖层一路，旧 sheet 路 2026-11-06 删除）；无注入时
    // 退回 dismiss 兜底。
    private func closePanel() {
        if let czfPanelClose = czfPanelClose {
            czfPanelClose()
        } else {
            dismiss()
        }
    }
    @ObservedObject var sortManager = LCAppSortManager.shared

    // 面板启动失败提示：原来三条启动路全是 try? 吞错，面板又
    // 已关掉，失败时只剩“点了没反应”。覆盖层常驻窗口（只改
    // 可见性不销毁），这个 @State alert 能正常弹出。JIT 取消
    // 不抛错，不会误弹。（旧 sheet 路的 onLaunchError 回传通
    // 道已随 sheet 删除，2026-11-06 面板呈现统一为覆盖层。）
    @State private var launchError: String?

    private func reportLaunchError(_ message: String) {
        launchError = message
    }

    // 面板动作防双发（Campbell 2026-11-06 真机点名）：卡面
    // 按钮点一次，List 行的按钮投递会连带把另一条启动路也
    // 触发，同一个 App 亚秒内被起两次，窗口直接「App 已被
    // 终止」；滑动触发则正常。卡面按钮已改点按手势（见
    // AppCardRow），这里再加一道闸：同一 App 0.5 秒内只认
    // 第一个动作（启动/最小化/小窗口共用一把闸），双发的
    // 第二个直接丢弃。面板在第一个动作后就关闭，正常连点
    // 本就到不了第二下，不误伤。
    @State private var lastPanelActionKey: String?
    @State private var lastPanelActionAt = Date.distantPast

    private func claimPanelAction(_ app: LCAppModel) -> Bool {
        let key = app.appInfo.dataUUID ?? app.appInfo.bundleIdentifier() ?? ""
        let now = Date()
        if key == lastPanelActionKey, now.timeIntervalSince(lastPanelActionAt) < 0.5 {
            return false
        }
        lastPanelActionKey = key
        lastPanelActionAt = now
        return true
    }

    // 面板搜索：不用 .searchable（原来绑常量空串根本不筛选，
    // iOS 26 还把它渲染成悬浮条压住最后一行才被拆掉），改用
    // 普通 TextField 按名字/Bundle ID 过滤。
    @State private var searchText = ""

    private var filteredPanelApps: [LCAppModel] {
        if searchText.isEmpty { return sortManager.sortedApps }
        return sortManager.sortedApps.filter { app in
            app.appInfo.displayName().localizedCaseInsensitiveContains(searchText) ||
            (app.appInfo.bundleIdentifier() ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        // 不用 NavigationView：空标题的导航栏白占一条高度，面板
        // 本来就只有半屏多；原来挂的 .searchable 绑的是常量空串
        // （根本不筛选），iOS 26 还把它渲染成悬浮条压在面板底部，
        // 遮住最后一行（用户真机点名"一拉出来都遮挡住了"）。改成
        // 关闭钮并进固定区标题行：独立顶栏又是一层，顶部
        // 顶栏+固定+运行三层叠着（用户点名），省下的高度
        // 全留给列表
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // 顶部固定区（用户定）：不要"App"标题，换成可固定
                // 的 App 小图标横排（长按下面列表行固定/取消），
                // 固定区不随列表滚动
                PinnedAppsStripView(onLaunch: { app in launchApp(app) })
                // 状态栏条固定在顶部，不随列表滚动（原来在
                // ScrollView 里，往下翻卡片后收起/最小化/
                // 关闭全部就没了，得翻回顶部）
                RunningAppsStripView { closePanel() }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                // 搜索框：固定在运行条下方，不随列表滚动。
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索", text: $searchText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            // 列表改 List（2026-11-06）：卡片的滑动动作只认
            // List 行（与源面板同款转换）。卡片自带底色/圆
            // 角，行底透明、无分隔线；行距上下各 5 凑出原
            // 卡片间 10 的间距，左右 16 与固定区、运行条同
            // 线；顶部留一个 0 高锚点行供调出时滚回最顶部。
            // 锚点行真 0 高要靠下面 List 上的
            // defaultMinListRowHeight=0：List 行有系统默认
            // 最小行高（44），不压掉它，锚点行就占 44 高，
            // 第一张卡上方空出一大条（Campbell 2026-11-06
            // 真机点名）。卡片行内容本身远高于 44，不受影响。
            List {
                Color.clear
                    .frame(height: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id("czfAppPanelTop")
                ForEach(filteredPanelApps, id: \.self) { app in
                    AppCardRow(app: app, dockManager: dockManager, onLaunch: {
                        if claimPanelAction(app) { launchApp(app) }
                    }, onMinimizeOpen: {
                        if claimPanelAction(app) { minimizeOpenApp(app) }
                    }, onSmallWindowOpen: {
                        if claimPanelAction(app) { smallWindowOpenApp(app) }
                    })
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .modifier(CZFListBackdropHidden())
            .onChange(of: dockManager.czfAppPanelOpenCounter) { _ in
                // 每次调出回到初始状态：滚回最顶部（用户定，
                // 不留上次滑动的位置），搜索也一并清空。
                proxy.scrollTo("czfAppPanelTop", anchor: .top)
                searchText = ""
            }
            }
        }
        // 启动失败提示（源面板同款写法）：面板已关、启动在后台
        // Task 里抛错时，把原因弹出来，不再“点了没反应”。
        .alert("提示", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("好") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }
    
    private func launchApp(_ app: LCAppModel) {
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == app.appInfo.dataUUID }) {
            // 窗口必须属于本条目：同包名别的条目若共用容器，
            // 按 dataUUID 找会把别人的窗口顶回来；归属对不上
            // 就不顶，走下面 URL 启动，runApp 里会拆共享容器。
            // runningApp 存在却无法证明归属（appInfo 缺失或路径
            // 为空）时同样视为未知，一律不顶；宁可多起一个窗口，
            // 不顶错别人的。
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != app.appInfo.relativeBundlePath
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                let brought = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
                // 面板带回也拉满（卡片 3.8.238 同款语义，启动=
                // 大窗口）：带回成功且窗口未最大化时拉满；带回
                // 失败照原样关面板返回，不改落空路径；新开路
                // 在 3.8.240 已拉满，这里不动。
                if brought, let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController, !vc.isMaximized {
                    vc.maximizeWindow()
                }
                closePanel()
                return
            }
        }
        // 跳错修复：非运行实例不再走只带包名的 URL（那边按包名
        // 取首个模型，点第 2 个实例必开第 1 个），改走模型直启，
        // 与 smallWindowOpenApp 同款；上面运行中实例的顶回
        // 前台路径一字不动。
        closePanel()
        Task {
            do {
                try await app.runApp(containerFolderName: app.appInfo.dataUUID)
                // 新开路拉满（3.8.240）：面板启动同款，起完等窗进
                // dock 再拉满一次，不管上次关时大小；在跑的顶回
                // 前台那条路（上面）不动，不改面板点按聚焦行为。
                await MainActor.run {
                    self.pollAndMaximizeFreshWindow(app: app)
                }
            } catch {
                await MainActor.run { reportLaunchError(error.localizedDescription) }
            }
        }
    }

    // 启动新开路拉满（3.8.240，面板版）：与卡片同款逻辑，
    // 0.3 秒×20 次轮询等新窗进 dock，归属按路径验。
    private func pollAndMaximizeFreshWindow(app: LCAppModel) {
        let expectedPath = app.appInfo.relativeBundlePath
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            attempts += 1
            let uuid = app.uiSelectedContainer?.folderName ?? app.appInfo.dataUUID
            guard let uuid = uuid,
                  let entry = self.dockManager.apps.first(where: { $0.appUUID == uuid }) else {
                if attempts >= 20 {
                    timer.invalidate()
                }
                return
            }
            let owned: Bool
            if let runningPath = entry.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                owned = runningPath == expectedPath
            } else {
                owned = false
            }
            if !owned {
                timer.invalidate()
                return
            }
            guard let vc = entry.view?._viewDelegate() as? DecoratedAppSceneViewController else {
                if attempts >= 20 {
                    timer.invalidate()
                }
                return
            }
            if !vc.isMaximized {
                vc.maximizeWindow()
            }
            if vc.isMaximized || attempts >= 20 {
                timer.invalidate()
            }
        }
    }
    
    private func minimizeOpenApp(_ app: LCAppModel) {
        // 与主列表卡片的最小化完全同款（用户令：快捷栏面板
        // 这颗必须和卡片那颗一样）。以前这份是旧路：实例
        // UUID 只取 dataUUID、未运行走 runApp 不带
        // multitask 全屏直启、再按 dataUUID 轮询等条目——
        // 多开实例的 dock 条目键是容器 folderName，只认
        // dataUUID 查不到运行中的窗口；全屏直启的条目键也
        // 对不上，轮询等不到，窗口就挂在全屏——点了等于
        // 点启动（录屏实测：对未运行的 App 点最小化直接全
        // 屏打开，还会弹“启动会终止多任务 App”的警告）。
        // 改为照抄卡片 minimizeButtonTapped 的三段：UUID
        // 取选中容器 folderName（dataUUID 回落）；已运行验
        // 归属后直接最小化；未运行先注册窗口出现回调、再
        // 以多任务方式启动，窗口一出现复验归属再最小化。
        guard let uuid = app.uiSelectedContainer?.folderName ?? app.appInfo.dataUUID else {
            // 容器删光：先启动（runApp 会重建容器），容器一
            // 出现就重走正常路；20 次内没出现就停（启动失
            // 败已由 runApp 侧报 reportLaunchError，不重复）。
            Task {
                do {
                    try await app.runApp(multitask: true, containerFolderName: nil)
                } catch {
                    await MainActor.run { reportLaunchError(error.localizedDescription) }
                }
            }
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
                attempts += 1
                if (app.uiSelectedContainer?.folderName ?? app.appInfo.dataUUID) != nil {
                    timer.invalidate()
                    self.minimizeOpenApp(app)
                } else if attempts >= 20 {
                    timer.invalidate()
                }
            }
            return
        }
        // 已在运行：归属对不上（共用容器的别的条目）不碰
        // 它，落到下面启动分支起自己的窗口。归属先验相对
        // 路径；路径缺失（条目按存盘 bundlePath 重建）时
        // 用 bundleId 兜底验（与卡片同款）。
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }) {
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != app.appInfo.relativeBundlePath
            } else if let runningInfo = runningApp.appInfo {
                belongsToOther = runningInfo.bundleIdentifier() != app.appInfo.bundleIdentifier()
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                dockManager.minimizeWindow(uuid: uuid)
                closePanel()
                return
            }
        }
        // 未运行：照卡片/小窗口同款——先注册窗口出现回
        // 调，再以多任务方式启动；窗口一出现（0.35 秒
        // 后）复验归属再最小化。效果与手动「点小窗口 →
        // 点黄色减号」一致：窗口以小窗出现、随即收进右侧
        // dock。回调由 czfOnWindowAppeared 的 30 秒超时
        // 兜底，窗口不出现就自动放弃，不留野观察者。
        let expectedPath = app.appInfo.relativeBundlePath
        let expectedBundleId = app.appInfo.bundleIdentifier()
        dockManager.czfOnWindowAppeared(uuid: uuid, timeout: 30) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let entry = self.dockManager.apps.first(where: { $0.appUUID == uuid }) else { return }
                let owned: Bool
                if let entryPath = entry.appInfo?.relativeBundlePath, !entryPath.isEmpty {
                    owned = entryPath == expectedPath
                } else if let entryInfo = entry.appInfo {
                    owned = entryInfo.bundleIdentifier() == expectedBundleId
                } else {
                    owned = false
                }
                if owned {
                    self.dockManager.minimizeWindow(uuid: uuid)
                }
            }
        }
        closePanel()
        Task {
            do {
                try await app.runApp(multitask: true, containerFolderName: uuid)
            } catch {
                await MainActor.run { reportLaunchError(error.localizedDescription) }
            }
        }
    }

    // 直接以小窗口（多任务）打开：窗口若被设置成最大化打开，还原成小窗口尺寸
    private func smallWindowOpenApp(_ app: LCAppModel) {
        guard let dataUUID = app.appInfo.dataUUID else { return }
        // 已在运行：把它的窗口带到前面，并还原为小窗口
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == dataUUID }) {
            // runningApp 存在却无法证明归属（appInfo 缺失或路径
            // 为空）时视为未知，一律不顶窗口，交给 runApp 起新
            // 窗口；宁可多起一个窗口，不顶错别人的。
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != app.appInfo.relativeBundlePath
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                let brought = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
                if brought {
                    unmaximizeWindow(uuid: dataUUID)
                    closePanel()
                    return
                }
                // 带回失败：条目还在且不是本次 C4 清掉的（窗口
                // 不在任何窗口里等）→ 保持旧行为，不重复起新窗；
                // 本次 C4 清掉了死窗，或 prune 同步剪掉了无窗残
                // 留（条目已不在）→ 落到下面 runApp 起新窗（即
                // 重启入口）。注意不能只查条目在不在：C4 的
                // removeRunningApp 是异步的，刚调完时条目还在。
                let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == dataUUID
                let entryGone = !dockManager.apps.contains(where: { $0.appUUID == dataUUID })
                if !cleanedByC4 && !entryGone {
                    unmaximizeWindow(uuid: dataUUID)
                    closePanel()
                    return
                }
            }
        }
        closePanel()
        // C6 回调驱动：先注册、再启动——窗口出现（dock 条目
        // 追加）才还原为小窗，不再 0.3 秒×30 次轮询、9 秒过期；
        // 启动慢（签名/VPN/JIT）时窗出来仍能还原。30 秒未出现
        // 则放弃等，不留野观察者；还原前仍留 0.35 秒让窗落稳。
        // 还原前按路径复验归属（L5）：同 uuid 条目已存在时回调
        // 立即触发、不验归属——占着 uuid 的若是别人的窗口，复验
        // 拦住，别把别人的窗口还原成小窗。
        let expectedPath = app.appInfo.relativeBundlePath
        dockManager.czfOnWindowAppeared(uuid: dataUUID, timeout: 30) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.unmaximizeWindowIfOwned(uuid: dataUUID, expectedPath: expectedPath)
            }
        }
        Task {
            do {
                try await app.runApp(multitask: true, containerFolderName: dataUUID)
            } catch {
                await MainActor.run { reportLaunchError(error.localizedDescription) }
            }
        }
    }

    private func unmaximizeWindow(uuid: String) {
        guard let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }),
              let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
              vc.isMaximized else { return }
        vc.maximizeWindow()
        // 小窗口打开默认不收快捷栏（Campbell 2026-11-06）：
        // 窗口落地最大化时被自动收起的那次，在这里还原成
        // 小窗后展开回来；全屏打开不经此路，仍默认收起。
        dockManager.czfExpandDockIfCollapsed()
    }

    // 小窗口回落路专用（3.8.239）：见卡片同款 helper 注释。
    private func unmaximizeWindowIfOwned(uuid: String, expectedPath: String?) {
        guard let expectedPath,
              let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }),
              let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty,
              runningPath == expectedPath else { return }
        unmaximizeWindow(uuid: uuid)
    }
}

// MARK: - Sources Panel View（左边缘往外弹调出，与 App 面板对称；2026-10-23 对调）
// 数据复用源页面的 AltStoreSourcesViewModel（进面板自动加载+刷新，
// 每次调出计数变化再刷一次）；行卡片按源页 LCSourceAppBanner 的状态
// 逻辑简化（复制/下载/安装/打开/更新/已安装），安装走与源页完全相同
// 的通道：IPA 发 InstallAppNotification 给 App 列表执行，dylib 直装
// 插件目录并签名。
@available(iOS 16.0, *)
struct SourcesPanelView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.czfPanelClose) private var czfPanelClose
    @EnvironmentObject var dockManager: MultitaskDockManager
    @StateObject private var viewModel = AltStoreSourcesViewModel()
    @State private var errorMessage: String?

    // 面板搜索：与 App 面板同款固定搜索框（不用 .searchable，
    // 理由见 AllAppsListView 那边的注释）。过滤规则与源页面
    // 一致（用户定的搜索口径）：源名命中整源全列；否则按
    // app 名/包名/开发者/副标题逐个匹配，无命中的源整段
    // 隐藏；加载中/失败的源按显示名匹配。
    @State private var searchText = ""

    private var panelQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func panelFilteredApps(for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        guard let source = item.source else { return [] }
        let query = panelQuery
        guard !query.isEmpty else { return source.apps }
        if item.displayName.lowercased().contains(query.lowercased()) {
            return source.apps
        }
        let lower = query.lowercased()
        return source.apps.filter { app in
            app.name.lowercased().contains(lower) ||
            app.bundleIdentifier.lowercased().contains(lower) ||
            (app.developerName?.lowercased().contains(lower) ?? false) ||
            (app.subtitle?.lowercased().contains(lower) ?? false)
        }
    }

    private func panelItemVisible(_ item: AltStoreSourcesViewModel.SourceItem) -> Bool {
        let query = panelQuery
        guard !query.isEmpty else { return true }
        guard item.source != nil else {
            return item.displayName.lowercased().contains(query.lowercased())
        }
        return item.displayName.lowercased().contains(query.lowercased()) || !panelFilteredApps(for: item).isEmpty
    }

    private func closePanel() {
        if let czfPanelClose = czfPanelClose {
            czfPanelClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // 标题行手写（原来是 NavigationView 的导航栏）：
                // 导航栏会给 VStack 里的 List 强加一个导航栏高
                // 度的顶部内边距，第一张卡上方空出约 64pt
                // （Campbell 2026-11-06 装 3.8.15 后仍点名）；
                // App 面板一直没有导航栏、从来没这毛病，源
                // 面板照改：去掉 NavigationView，标题/关闭/
                // 刷新用 ZStack 手写一行（标题绝对居中）。
                ZStack {
                    Text("源")
                        .font(.headline)
                    HStack {
                        Button { closePanel() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await viewModel.refreshAllSources() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 2)
                // 状态栏条固定在顶部，不随列表滚动（与 App 面板一致）
                RunningAppsStripView { closePanel() }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                // 搜索框：与 App 面板同款，固定在运行条下方，
                // 不随列表滚动。
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索", text: $searchText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            if viewModel.sources.isEmpty {
                VStack(alignment: .leading) {
                    Text("还没有添加源")
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 12)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
            // 列表与源页面同构（Campbell 2026-11-06：面板的
            // app 卡片与源页面一样）：List + insetGrouped +
            // 一源一段卡，app 行直接复用源页面的
            // LCSourceAppBanner（滑动动作/长按菜单/状态判定
            // 全是同一份）。回顶锚点挂在第一个可见段的第一
            // 行上（调出面板滚回最顶部，用户定）。
            List {
                let firstVisibleID = viewModel.sources.first(where: { panelItemVisible($0) })?.id
                if firstVisibleID == nil {
                    Section {
                        Text("lc.sources.section.noApps".loc)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .id("czfSourcesPanelTop")
                    }
                }
                ForEach(viewModel.sources) { item in
                    if panelItemVisible(item) {
                        Section {
                            if let source = item.source {
                                Text(source.name)
                                    .font(.headline)
                                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 2, trailing: 16))
                                    .id(item.id == firstVisibleID ? "czfSourcesPanelTop" : item.id.absoluteString + "-name")
                                ForEach(panelFilteredApps(for: item)) { app in
                                    LCSourceAppBanner(app: app, source: source, installAction: { installFromPanel(app: $0) }, installAsNewAction: { installFromPanel(app: $0) }, downloadAction: { downloadFromPanel(app: $0) }, isBatchMode: false, isSelected: false, onToggleSelect: {})
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                }
                            } else if item.isLoading {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(item.displayName)
                                        .foregroundColor(.secondary)
                                }
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .id(item.id == firstVisibleID ? "czfSourcesPanelTop" : item.id.absoluteString + "-loading")
                            } else if let err = item.error {
                                Text("\(item.displayName) 加载失败：\(err)")
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                    .id(item.id == firstVisibleID ? "czfSourcesPanelTop" : item.id.absoluteString + "-error")
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // 与 App 面板同款磨砂玻璃质感（Campbell 2026-11-06
            // 令）：列表底色透明化，透出下方被遮罩压暗的界
            // 面，卡片浮在半透明底上（App 面板一直如此，源
            // 面板此前是整块实色分组底，没有玻璃感）。
            .modifier(CZFListBackdropHidden())
            // 段间距压 0：无段头的 Section 系统也留段头间距，
            // 第一张卡上方空出一大条（Campbell 2026-11-06
            // 真机点名，与 App 面板的锚点行最小行高同批修）。
            .modifier(CZFListSectionSpacingZero())
            // 顶部内容边距也压 0、行最小高也归 0：与段间距
            // 是两笔账，三笔一起清（3.8.15 只压段间距没压
            // 干净，装机后仍剩约 64pt，主因是导航栏内边距，
            // 已随标题行手写一并去掉，这里补齐列表自身这笔）
            .modifier(CZFListTopMarginZero())
            .environment(\.defaultMinListRowHeight, 0)
            }
            }
            // 回顶/提示等修饰挂在 VStack 上：挂在 if/else 语
            // 句后面构建 #16 报过找不到（if/else 的结果不是
            // 可修饰的具体视图）。标题行已手写（见 VStack
            // 第一行），这里不再有 navigationTitle/toolbar。
            .onChange(of: dockManager.czfSourcesPanelOpenCounter) { _ in
                // 每次调出回到初始状态：滚回最顶部（用户定，
                // 不留上次滑动的位置）+ 刷新源数据 + 清空搜索
                // （与 App 面板同款）
                proxy.scrollTo("czfSourcesPanelTop", anchor: .top)
                searchText = ""
                Task { await viewModel.refreshAllSources() }
            }
            .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            }
    }

    // 与源页 LCSourcesView.install 一致，额外关掉面板让用户看安装进度
    @MainActor
    private func installFromPanel(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        if downloadURL.pathExtension.lowercased() == "dylib" {
            Task { await installTweakFromPanel(from: downloadURL, name: app.name) }
            return
        }
        DataManager.shared.model.selectedTab = .apps
        closePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": downloadURL])
        }
    }

    // 与源页 LCSourcesView.installTweak 一致
    @MainActor
    private func installTweakFromPanel(from url: URL, name: String) async {
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let fm = FileManager.default
            let folderURL = LCPath.tweakPath.appendingPathComponent(name)
            if !fm.fileExists(atPath: folderURL.path) {
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
            let destURL = folderURL.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tempURL, to: destURL)
            try await LCUtils.signTweaks(tweakFolderUrl: folderURL, force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // 与源页 LCSourcesView.download 一致：下载到文档目录后弹分享框
    @MainActor
    private func downloadFromPanel(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                let fileName = downloadURL.lastPathComponent
                let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destURL = docsURL.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
                await MainActor.run {
                    shareFileFromPanel(at: destURL)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func shareFileFromPanel(at url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        rootVC.present(activityVC, animated: true)
    }
}

// 顶部状态栏（App 面板与源面板共用）：最前面是与快捷栏同款
// 的三个固定按钮（收起/最小化/关闭全部，用户要求加的），后面
// 横排已打开的 App：点按最大化打开，长按小窗口打开（用户定）。
// 整条放在浅色圆角底板上，与下面的列表卡片区分开（UI 美化）。
@available(iOS 16.0, *)
private struct RunningAppsStripView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    let onSwitch: () -> Void

    var body: some View {
        // 没运行 App 时三个按钮均分整行：原来横滑布局里三个
        // 按钮全挤左边、右边空一大截，怎么看怎么偏；有运行
        // App 时仍走横滑，不影响
        Group {
            if dockManager.apps.isEmpty {
                HStack {
                    Spacer()
                    collapseStripButton
                    Spacer()
                    minimizeAllStripButton
                    Spacer()
                    closeAllStripButton
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        collapseStripButton
                        minimizeAllStripButton
                        closeAllStripButton
                        // 分隔线定死 64 高（46 图标+4 间距+约
                        // 14 文字行高）：原来 50 比图标+文字矮
                        // 一截看着断开；改随内容撑满后高度成环
                        // 形依赖，横滑条把整条撑到约 200 高
                        // （用户点名“这么大”的根因），定死即破环
                        Divider()
                            .frame(height: 64)
                        ForEach(dockManager.apps) { runningApp in
                            runningAppItem(runningApp)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                // 横滑条锁死内容高：不锁的话高度一含糊就
                // 跟着面板往上撑（与分隔线是同一类毛病）
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 两态同高：没运行 App 是均分 HStack、有运行 App
        // 是横滑 ScrollView，量出来都是 46 图标+4 间距+
        // caption2 一行+上下各 6 ≈ 75；下限钉 78，两态
        // 一分不差，列表不跟着伸缩；只钉下限，大字号
        // 下内容长高仍能撑开，不裁字
        .frame(minHeight: 78)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // 三个固定按钮：两态共用同一份定义，改一处即两态一致
    // （原来两边各写一遍，改漏一边就两态不一致）。布局
    // （均分 Spacer / 横滑间距）仍是各分支自己的事。
    private var collapseStripButton: some View {
        fixedButton(systemImage: "chevron.down", tile: Color(.systemGray5), glyph: .primary, label: "收起") {
            dockManager.toggleDockCollapse()
            onSwitch()
        }
    }
    private var minimizeAllStripButton: some View {
        fixedButton(systemImage: "rectangle.stack.badge.minus", tile: Color(.systemGray5), glyph: .primary, label: "最小化") {
            dockManager.minimizeAllWindows()
            onSwitch()
        }
    }
    private var closeAllStripButton: some View {
        fixedButton(systemImage: "xmark", tile: Color.red.opacity(0.12), glyph: .red, label: "关闭全部") {
            dockManager.closeAllWindows()
            onSwitch()
        }
    }

    // 固定按钮：浅底 + 深色图标（原来整块实心灰/红加白描边太
    // 重，用户点名丑）；关闭全部保留红色语义，但改浅红底红图标
    private func fixedButton(systemImage: String, tile: Color, glyph: Color, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tile)
                    .frame(width: 46, height: 46)
                Image(systemName: systemImage)
                    .foregroundColor(glyph)
                    .font(.system(size: 18, weight: .semibold))
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 60)
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

    // 已打开的 App：点按切前台并最大化，长按切前台并小窗口
    // 打开。不用 Button 是免得长按时把点按也误触发（老毛病）。
    private func runningAppItem(_ runningApp: DockAppModel) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RunningAppIcon(appInfo: runningApp.appInfo)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 2)
                // 右上角小红 ✕：单独关掉这个 App（用户定）。
                // 高优先级手势独占这下点按，不触发图标本体的
                // 点按切换/长按小窗口；关掉后图标自动消失，
                // 面板不关（方便接着关下一个）
                ZStack {
                    Circle().fill(Color.red).frame(width: 18, height: 18)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .contentShape(Circle())
                .highPriorityGesture(TapGesture().onEnded {
                    dockManager.closeAppWindow(uuid: runningApp.appUUID)
                })
                .offset(x: 5, y: -4)
            }
            Text(runningApp.appName)
                .font(.caption2)
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: 60)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let _ = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
            dockManager.maximizeWindow(uuid: runningApp.appUUID)
            onSwitch()
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            let _ = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
            dockManager.restoreSmallWindow(uuid: runningApp.appUUID)
            onSwitch()
        }
    }
}

// 状态栏里的单个已打开 App 图标（异步加载方式与 AppCardRow 一致）
@available(iOS 16.0, *)
private struct RunningAppIcon: View {
    let appInfo: LCAppInfo?
    @State private var icon: UIImage?

    var body: some View {
        Group {
            if let icon = icon {
                Image(uiImage: icon)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .onAppear {
            guard let appInfo = appInfo else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = appInfo.iconIsDarkIcon(false)
                DispatchQueue.main.async {
                    self.icon = loaded
                }
            }
        }
    }
}

// App 页卡片的主色提取/可读文字色（LCAppBannerRootView
// 同名逻辑的 SwiftUI 侧同款实现，供 AppCardRow 与页面卡
// 保持同一套动态取色；结果同样缓存在 appInfo 上）。
@available(iOS 16.0, *)
private func czfBannerMainColor(appInfo: LCAppInfo, icon: UIImage, darkModeIcon: Bool) -> UIColor {
    if darkModeIcon, let cached = appInfo.cachedColorDark { return cached }
    if !darkModeIcon, let cached = appInfo.cachedColor { return cached }
    guard let cgImage = icon.cgImage else { return .clear }
    var pixelData = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(data: &pixelData, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .clear }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let average = UIColor(red: CGFloat(pixelData[0]) / 255, green: CGFloat(pixelData[1]) / 255, blue: CGFloat(pixelData[2]) / 255, alpha: 1)
    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
    average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    let color = (brightness < 0.1 && saturation < 0.1)
        ? UIColor.systemRed
        : UIColor(hue: hue, saturation: saturation, brightness: max(brightness, 0.3), alpha: 1)
    if darkModeIcon { appInfo.cachedColorDark = color } else { appInfo.cachedColor = color }
    return color
}

private func czfBannerReadableTextColor(for color: UIColor) -> UIColor {
    let traits = UITraitCollection.current
    let resolved = color.resolvedColor(with: traits)
    let bg = UIColor.systemBackground.resolvedColor(with: traits)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    var br: CGFloat = 0, bgc: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
    bg.getRed(&br, green: &bgc, blue: &bb, alpha: &ba)
    r = 0.5 * r + 0.5 * br; g = 0.5 * g + 0.5 * bgc; b = 0.5 * b + 0.5 * bb
    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let offset: CGFloat = lum < 0.5 ? 0.4 : -0.4
    return UIColor(red: min(max(r + offset, 0), 1), green: min(max(g + offset, 0), 1), blue: min(max(b + offset, 0), 1), alpha: 1)
}

// MARK: - App Card Row (same style as App tab)
@available(iOS 16.0, *)
struct AppCardRow: View {
    @ObservedObject var app: LCAppModel
    let dockManager: MultitaskDockManager
    let onLaunch: () -> Void
    let onMinimizeOpen: () -> Void
    let onSmallWindowOpen: () -> Void
    @ObservedObject private var pinnedStore = CZFPinnedAppsStore.shared
    @State private var appIcon: UIImage?

    // 标志与 App 页卡片（LCAppBannerRootView.update）同一
    // 套判定与顺序：VPN/共享/JIT/32 位/锁定。
    private var badges: [(symbol: String?, text: String?, color: Color)] {
        var list: [(String?, String?, Color)] = []
        if CZFVPNManager.isEnabled(for: app.appInfo) { list.append(("globe", nil, Color(.systemGreen))) }
        if app.uiIsShared { list.append(("arrowshape.turn.up.left.fill", nil, Color(.systemBlue))) }
        if app.uiIsJITNeeded && !app.uiIs32bit { list.append(("bolt.fill", nil, Color(.systemOrange))) }
        if app.uiIs32bit { list.append((nil, "32", Color(.systemPurple))) }
        if app.uiIsLocked && !app.uiIsHidden { list.append(("lock.fill", nil, Color(.systemRed))) }
        return list
    }

    // 与 App 页卡片同一套设置（LCAppBanner 两处 @AppStorage 同键）
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    // 动态取色口径与 LCAppBannerRootView.update 一字不差：
    // 主色 = 图标平均色相色（关动态取色时不算）；强调色 =
    // 主色或 FontColor；卡背 = 主色 50% 透明度或 AppBannerBG。
    private var accentUIColor: UIColor {
        guard dynamicColors, let icon = appIcon else { return UIColor(named: "FontColor") ?? .systemBlue }
        return czfBannerMainColor(appInfo: app.appInfo, icon: icon, darkModeIcon: darkModeIcon)
    }
    private var cardBackground: Color {
        if dynamicColors { return Color(accentUIColor.withAlphaComponent(0.5)) }
        return Color(UIColor(named: "AppBannerBG") ?? .secondarySystemBackground)
    }
    private var metaTextColor: Color {
        Color(czfBannerReadableTextColor(for: accentUIColor))
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // App icon
            Group {
                if let icon = appIcon {
                    Image(uiImage: icon)
                        .resizable()
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear { loadIcon() }
            
            // 信息与 App 页卡片一致（Campbell 2026-11-06 令）：
            // 名字上方一排标志，名字下面版本号、再下面备注；
            // 包名/UUID 等多余信息不显示。
            VStack(alignment: .leading, spacing: 1) {
                if !badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            ZStack {
                                if let symbol = badge.symbol {
                                    Image(systemName: symbol)
                                        .font(.system(size: 8))
                                        .foregroundColor(.white)
                                } else if let text = badge.text {
                                    Text(text)
                                        .font(.system(size: 8))
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(width: 16, height: 16)
                            .background(badge.color)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.bottom, 2)
                }
                Text(app.displayName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(app.version)
                    .font(.system(size: 11))
                    .foregroundColor(metaTextColor)
                    .lineLimit(1)
                if !app.uiRemark.isEmpty {
                    Text(app.uiRemark)
                        .font(.system(size: 10))
                        .foregroundColor(metaTextColor.opacity(0.8))
                        .lineLimit(1)
                }
            }
            
            Spacer()

            // 次级动作统一中性灰胶囊（原来蓝/紫糖果色三件套太花，
            // 用户点名丑）；只有主动作「打开/启动」保留实心色。
            // 三颗都不再用 Button（Campbell 2026-11-06 真机点
            // 名）：List 行里嵌 Button 又同行挂着滑动动作和长
            // 按菜单时，点按钮会连带触发另一条启动路，同一个
            // App 亚秒内被起两次、窗口直接「App 已被终止」
            // （滑动的小窗口不经按钮投递，所以正常）。改成
            // 胶囊视图 + 点按手势，样式一字不变；外层再有
            // AllAppsListView 的防双发闸兜底。App 页卡片是
            // UIKit 按钮，不受此问题影响，不动。
            Text("最小化")
                .font(.footnote)
                .foregroundColor(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
                .contentShape(Capsule())
                .onTapGesture { onMinimizeOpen() }

            Text("小窗口")
                .font(.footnote)
                .foregroundColor(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
                .contentShape(Capsule())
                .onTapGesture { onSmallWindowOpen() }

            Text(dockManager.apps.contains(where: { $0.appUUID == app.appInfo.dataUUID }) ? "打开" : "启动")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color(accentUIColor))
                .clipShape(Capsule())
                .contentShape(Capsule())
                .onTapGesture { onLaunch() }
        }
        .padding(10)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // 滑动动作（Campbell 2026-11-06 定，回退后按其点名
        // 保留）：与 App 页卡片同款滑动，方向按面板动作改
        // 派：左滑（尾侧）= 启动/打开（滑满直接触发，未运行
        // 蓝色、运行中绿色）；右滑（首侧）= 小窗口（灰）。
        // 卡面三按钮按 Campbell 后令保留，与滑动并存。
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                onLaunch()
            } label: {
                Label(dockManager.apps.contains(where: { $0.appUUID == app.appInfo.dataUUID }) ? "打开" : "启动", systemImage: "play.fill")
            }
            .tint(dockManager.apps.contains(where: { $0.appUUID == app.appInfo.dataUUID }) ? .green : Color(accentUIColor))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onSmallWindowOpen()
            } label: {
                Label("小窗口", systemImage: "pip.enter")
            }
            .tint(.gray)
        }
        // 长按行：最小化（与卡面按钮并存）、固定到面板顶部
        // / 取消固定（用户定）；正在运行的还多两个：重启
        // （卡死时一步恢复）、关闭
        .contextMenu {
            Button {
                onMinimizeOpen()
            } label: {
                Label("最小化", systemImage: "minus.circle")
            }
            Button {
                pinnedStore.toggle(app)
            } label: {
                Label(pinnedStore.isPinned(app) ? "取消固定" : "固定到顶部",
                      systemImage: pinnedStore.isPinned(app) ? "pin.slash" : "pin")
            }
            if let uuid = app.appInfo.dataUUID,
               dockManager.apps.contains(where: { $0.appUUID == uuid }) {
                Button {
                    dockManager.restartApp(uuid: uuid)
                } label: {
                    Label("重启 App", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    dockManager.closeAppWindow(uuid: uuid)
                } label: {
                    Label("关闭 App", systemImage: "xmark.circle")
                }
            }
        }
    }
    
    private func loadIcon() {
        // 卡片图标走共享缓存：LazyVStack 的行滑出滑回都会重新
        // onAppear，原来每次都重新解一次图标；先查缓存命中直接
        // 用，未命中才后台解一次并写回。键用 Bundle ID + dataUUID，
        // 与 dock 那边名字_UUID 的键不同，不会串深色/浅色图标。
        let cacheKey = "\(app.appInfo.bundleIdentifier() ?? "")_\(app.appInfo.dataUUID ?? "")\(darkModeIcon ? "_dark" : "")"
        if let cached = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cached
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let icon = app.appInfo.iconIsDarkIcon(darkModeIcon)
            if let icon = icon {
                IconCacheManager.shared.setIcon(icon, for: cacheKey)
            }
            DispatchQueue.main.async {
                self.appIcon = icon
            }
        }
    }
}

// MARK: - Icon Cache Manager
// 面板图标缓存：原来是无上限字典，清理函数从没被
// 调过，图标只进不出。换 NSCache（200 个上限，
// 内存紧张时系统自动清），调用点一字不动。
class IconCacheManager {
    static let shared = IconCacheManager()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 200 }
    func getIcon(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }
    func setIcon(_ icon: UIImage, for key: String) {
        cache.setObject(icon, forKey: key as NSString)
    }
    func clearCache() {
        cache.removeAllObjects()
    }
}
// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    let app: DockAppModel
    @State private var isPressed = false
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    private var iconSize: CGFloat {
        return dockManager.adaptiveIconSize
    }
    
    var body: some View {
        Group {
            if isLoading && appIcon == nil {
                LoadingIconView()
            } else if let icon = appIcon {
                IconImageView(icon: icon)
            } else {
                RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
        .scaleEffect(isPressed ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .animation(.easeInOut(duration: MultitaskDockManager.Constants.standardAnimationDuration), value: dockManager.settingsChanged)
        .onAppear {
            loadAppIcon()
        }
        .onPressGesture(
            onPress: { 
                isPressed = true
            },
            onRelease: { location in 
                isPressed = false
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
                let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: location)
            }
        )
        .contentShape(Rectangle())
    }
    
    private func loadAppIcon() {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var finalIcon: UIImage?
            
            if let appInfo = self.app.appInfo {
                finalIcon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else {
                if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                    finalIcon = foundAppInfo.iconIsDarkIcon(darkModeIcon)
                }
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if let icon = finalIcon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Press Gesture Helper
extension View {
    func onPressGesture(onPress: @escaping () -> Void, onRelease: @escaping (_ location: CGPoint) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if value.translation == CGSize.zero {
                        onPress()
                    }
                }
                .onEnded { value in
                    onRelease(value.startLocation)
                }
        )
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}

// MARK: - 宿主 sendEvent 直读钩子（左滑出源面板专用，2026-11-04）
// 与客侧 TweakLoader 的 czf_sendEvent 同款：交换后本调用即原
// 实现，先原样转发，再纯观察（绝不拦截/改事件）。dynamic 必
// 须保留，否则 Swift 静态分发会自递归导致栈溢出。
extension UIWindow {
    @objc dynamic func czf_host_sendEvent(_ event: UIEvent) {
        self.czf_host_sendEvent(event)
        // MultitaskDockManager 带 @available(iOS 16.0, *)，文件级
        // extension 在类外、没有可用性上下文，直接引用会报
        // "'MultitaskDockManager' is only available in iOS 16.0 or
        // newer"（270 构建 #314 唯一红字）。照抄仓库既有 pattern
        // 包一层 #available，iOS 15 下跳过（管理器本身也不跑）。
        if #available(iOS 16.0, *) {
            MultitaskDockManager.czfHostOutwardObserve(window: self, event: event)
        }
    }
}

//
//  LCAppBannerViewController.swift
//  LiveContainerSwiftUI
//

import Foundation
import SwiftUI
import UIKit
import Combine

struct LCAppBannerConfiguration {
    let model: LCAppModel
    let dynamicColors: Bool
    let darkModeIcon: Bool
}


final class LCAppBannerViewController: UIViewController, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {

    private let delegate: LCAppBannerDelegate
    private let bannerView = LCAppBannerRootView()
    // 滑动操作层：容器装横滑按钮（右滑 VPN、左滑一颗尾钮），
    // bannerView 盖在上面，横拖时平移露出按钮（用户定版）。
    // 备份已按用户要求挪进长按菜单第一位，不再占横滑。
    private let swipeContainerView = UIView()
    private let vpnSwipeButton = LCBannerSwipeButton(symbol: "globe", title: "VPN", color: .systemGray)
    private let trailingSwipeButton = LCBannerSwipeButton(symbol: "trash.fill", title: "卸载", color: .systemRed)
    private var swipeOffset: CGFloat = 0
    private var swipeStartOffset: CGFloat = 0
    private var swipePanGesture: UIPanGestureRecognizer?
    private var swipeCloseTapGesture: UITapGestureRecognizer?
    private var swipeButtonTapGesture: UITapGestureRecognizer?
    // 归位动画逐帧补间（CADisplayLink）：卡片平移和按钮
    // 帧必须读同一个逐帧偏移，按钮才跟着卡片一起缩回、
    // 在卡片盖满瞬间才消失；早先在动画块里按最终偏移
    // 排帧，按钮会僵在原地最后突然消失（用户录屏指出）。
    private var swipeDisplayLink: CADisplayLink?
    private var swipeTweenFrom: CGFloat = 0
    private var swipeTweenTo: CGFloat = 0
    private var swipeTweenStart: CFTimeInterval = 0
    // 滑动归位（用户定：点其他位置就归位）：全列表只许
    // 一行滑开着，新行一滑开上一行自动收回；列表层点别
    // 处/开始滚动会发 czfCloseSwipeNotification，滑开着
    // 的行收到就收回（正在拖的那行除外）。
    static let czfCloseSwipeNotification = Notification.Name("CZFCloseOpenBannerSwipe")
    // 左滑尾钮的业务形态：普通 App 是卸载；开了分享的
    // App 不显示卸载，换成蓝色的「共享」开关钮（点按=
    // 取消分享，与设置页同款逻辑；LC2 形态下设置页不给
    // 取消分享，这里同样不出钮）。
    private enum TrailingSwipeKind { case uninstall, unshare, none }
    private var trailingSwipeKind: TrailingSwipeKind {
        if !configuration.model.uiIsShared { return .uninstall }
        return DataManager.shared.model.multiLCStatus != 2 ? .unshare : .none
    }
    private static weak var czfOpenSwipeBanner: LCAppBannerViewController?
    private var swipeCloseObserver: NSObjectProtocol?
    private var configuration: LCAppBannerConfiguration
    private var exportTemporaryDirectory: URL?
    // dock 条目变化时重绘画片（卡片状态读 dock 存活态，不订阅
    // 的话只在模型变化时重绘、窗口开关后仍是旧态）。
    private var dockAppsCancellable: AnyCancellable?
    // 长按启动调面板的时间戳：长按后抬手会顺带触发一次
    // touchUpInside，1.5 秒内的这次点按要吞掉，否则长按
    // 又出面板又启动，面板会被盖住。
    private var runControlLongPressAt: Date?
    
    init(delegate: LCAppBannerDelegate, config: LCAppBannerConfiguration) {
        self.delegate = delegate
        self.configuration = config
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        swipeContainerView.backgroundColor = .clear
        view = swipeContainerView

        // 滑动钮（设计不动、药丸会随拖动拉长）贴在容器
        // 左右边缘，卡片滑开时直接被「揭」出来，不再躲
        // 在半透明卡后缩放淡入。帧全手动（layoutSwipe
        // Buttons 按露出区排），不用约束。
        for button in [vpnSwipeButton, trailingSwipeButton] {
            button.isHidden = true
            swipeContainerView.addSubview(button)
        }

        bannerView.translatesAutoresizingMaskIntoConstraints = false
        swipeContainerView.addSubview(bannerView)

        NSLayoutConstraint.activate([
            bannerView.leadingAnchor.constraint(equalTo: swipeContainerView.leadingAnchor),
            bannerView.trailingAnchor.constraint(equalTo: swipeContainerView.trailingAnchor),
            bannerView.topAnchor.constraint(equalTo: swipeContainerView.topAnchor),
            bannerView.bottomAnchor.constraint(equalTo: swipeContainerView.bottomAnchor)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        preferredContentSize = CGSize(width: 0, height: LCAppBannerRootView.bannerHeight)
        bannerView.runControl.addTarget(self, action: #selector(runButtonTapped), for: .touchUpInside)
        // 长按启动调手势面板（全部卡片通用）：边缘手势在客
        // App 里有时不灵，长按启动是宿主侧的可靠触发；点按
        // 仍是启动（大窗口）。行菜单已排除 runControl 区域，
        // 长按不会同时弹出行菜单。
        let runLongPress = UILongPressGestureRecognizer(target: self, action: #selector(runControlLongPressed(_:)))
        bannerView.runControl.addGestureRecognizer(runLongPress)
        // 面板同款次级按钮（16+ 才建，见 RootView；16 以下为 nil，不挂）。
        if #available(iOS 16.0, *) {
            bannerView.minimizeControl?.addTarget(self, action: #selector(minimizeButtonTapped), for: .touchUpInside)
            bannerView.smallWindowControl?.addTarget(self, action: #selector(smallWindowButtonTapped), for: .touchUpInside)
        }
        bannerView.addInteraction(UIContextMenuInteraction(delegate: self))

        // 横滑露出操作按钮：左滑备份/卸载、右滑 VPN。
        let swipePan = UIPanGestureRecognizer(target: self, action: #selector(bannerSwiped(_:)))
        swipePan.delegate = self
        bannerView.addGestureRecognizer(swipePan)
        swipePanGesture = swipePan

        // 滑开后点卡片只收起、不触发卡片上的按钮。
        let closeTap = UITapGestureRecognizer(target: self, action: #selector(bannerCloseTapped))
        closeTap.cancelsTouchesInView = true
        closeTap.isEnabled = false
        bannerView.addGestureRecognizer(closeTap)
        swipeCloseTapGesture = closeTap

        swipeCloseObserver = NotificationCenter.default.addObserver(forName: Self.czfCloseSwipeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.swipeOffset != 0 else { return }
            let panning = self.swipePanGesture?.state == .began || self.swipePanGesture?.state == .changed
            if !panning {
                self.setSwipeOffset(0, animated: true)
            }
        }

        vpnSwipeButton.addTarget(self, action: #selector(vpnSwipeTapped), for: .touchUpInside)
        trailingSwipeButton.addTarget(self, action: #selector(trailingSwipeTapped), for: .touchUpInside)

        // 点按按钮要稳（用户先后实测：右滑 VPN 点不中、
        // 启动钮点了没反应）：列表层的 SwiftUI 点按手势会
        // 把控件的 touchUpInside 吞掉，所以容器上挂一个
        // 点按识别器统一接管卡片上的按钮——滑开时接管露
        // 出来的横滑钮，未滑开时接管启动钮和两个次级钮
        // （最小化/小窗口，同病同解）。手势识别器不吃这套
        // 取消，命中哪颗钮就执行哪颗；命中判定在代理
        // shouldReceive 里做，没命中按钮区就放行给别人。
        let buttonTap = UITapGestureRecognizer(target: self, action: #selector(swipeButtonAreaTapped(_:)))
        buttonTap.delegate = self
        buttonTap.cancelsTouchesInView = true
        swipeContainerView.addGestureRecognizer(buttonTap)
        swipeButtonTapGesture = buttonTap

        // dock 变化（窗口开关）即重绘画片，卡片状态才跟得上；
        // 订阅即发一次当前值，多一次无害重绘。
        if #available(iOS 16.0, *) {
            dockAppsCancellable = MultitaskDockManager.shared.$apps
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshView() }
        }

        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(bannerDoubleTapped))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.cancelsTouchesInView = false
        bannerView.addGestureRecognizer(doubleTapGesture)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSwipeButtons()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection == nil || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshView()
        }
    }

    deinit {
        swipeDisplayLink?.invalidate()
        if let swipeCloseObserver {
            NotificationCenter.default.removeObserver(swipeCloseObserver)
        }
        if Self.czfOpenSwipeBanner === self {
            Self.czfOpenSwipeBanner = nil
        }
        cleanupExportTemporaryDirectory()
    }

    func update(
        model: LCAppModel,
        dynamicColors: Bool,
        darkModeIcon: Bool
    ) {
        loadViewIfNeeded()
        configuration = LCAppBannerConfiguration(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon
        )
        // 模型换了就把横滑收回去，别把上一行的开合状态带过来。
        setSwipeOffset(0, animated: false)
        refreshView()
    }

    private func refreshView() {
        bannerView.update(
            model: configuration.model,
            appInfo: configuration.model.appInfo,
            dynamicColors: configuration.dynamicColors,
            darkModeIcon: configuration.darkModeIcon,
            traitCollection: traitCollection
        )
        // 横滑按钮态跟模型走：尾钮形态读 trailingSwipeKind
        // （卸载/取消分享/无），刷新时按形态换图标、文字、
        // 颜色；VPN 按钮绿=已开、灰=未开。
        switch trailingSwipeKind {
        case .uninstall:
            trailingSwipeButton.configure(symbol: "trash.fill", title: "卸载", color: .systemRed)
        case .unshare:
            // 共享开关钮（用户定，2026-11-06 改名）：文字只写「共享」，开了
            // 分享才是蓝色（关着的 VPN 钮灰色同理）；这颗
            // 只在已分享时出现，此时不显示卸载。
            trailingSwipeButton.configure(symbol: "person.2.fill", title: "共享", color: .systemBlue)
        case .none:
            break
        }
        layoutSwipeButtons()
        vpnSwipeButton.setColor(CZFVPNManager.isEnabled(for: configuration.model.appInfo) ? .systemGreen : .systemGray)
    }

    @objc private func bannerDoubleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        // 双击按钮区不进设置：原来只排除了启动 pill，两个新按钮
        // 同样排除（按钮是 bannerView 的直接子视图，frame 就是
        // bannerView 坐标系，不用逐个转坐标；16 以下新按钮为 nil，
        // 后两项恒为 false，行为与原来一致）。
        let location = gestureRecognizer.location(in: bannerView)
        guard !bannerView.runControl.frame.contains(location),
              !(bannerView.minimizeControl?.frame.contains(location) ?? false),
              !(bannerView.smallWindowControl?.frame.contains(location) ?? false) else {
            return
        }
        openSettings()
    }

    // 长按启动只调面板、不启动：.began 只发一次；抬手那下
    // 的 touchUpInside 由 runButtonTapped 里的时间戳吞掉。
    @objc private func runControlLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        if #available(iOS 16.0, *) {
            runControlLongPressAt = Date()
            MultitaskDockManager.shared.czfOpenAppPanel()
        }
    }

    @objc private func runButtonTapped() {
        if let pressedAt = runControlLongPressAt, Date().timeIntervalSince(pressedAt) < 1.5 {
            runControlLongPressAt = nil
            return
        }
        // 启动 = 大窗口（3.8.238 重修：3.8.237 只在 isUsing 门
        // 内的带回路上拉满，门一关（isUsing 不同步、或归属
        // 不明）就落到 runApp 空转、窗还是小的，用户看到的
        // 就是没修）。现改走面板同款 dock+路径归属路（最小
        // 化/小窗口按钮同款，已验证能顶回窗口）：dock 里有
        // 本条目、路径对得上就带回并拉满；归属对不上才走
        // runApp 拆容器起新窗。isUsing 门不再拦——dock 条目
        // 本身就是窗口在跑的证据，面板两路同样不查它。
        if #available(iOS 16.0, *),
           let uuid = bannerInstanceUUID() {
            let dockManager = MultitaskDockManager.shared
            if let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }) {
                let belongsToOther: Bool
                if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                    belongsToOther = runningPath != configuration.model.appInfo.relativeBundlePath
                } else {
                    belongsToOther = true
                }
                if !belongsToOther {
                    var brought = false
                    if #available(iOS 16.1, *) {
                        brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
                    }
                    if !brought {
                        brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
                    }
                    // 带回成功拉满；带回失败但条目还在且不是本次
                    // C4 清掉的死窗（窗已在前台、只是 bring 没抬动）
                    // 同样拉满，别再静默空转回小窗。
                    let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == uuid
                    let entryGone = !dockManager.apps.contains(where: { $0.appUUID == uuid })
                    if brought || (!cleanedByC4 && !entryGone) {
                        // maximizeWindow 是切换式，先判 !isMaximized，
                        // 否则已是最大窗会被反切回小窗。
                        if let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
                           !vc.isMaximized {
                            vc.maximizeWindow()
                        }
                        return
                    }
                }
            } else {
                // 没有 dock 条目（原生窗口模式等）：保留旧行为，
                // 只带回不拉满（没 decorated VC 可拉），带回失败
                // 再落到 runApp。
                var brought = false
                if #available(iOS 16.1, *) {
                    brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
                }
                if !brought {
                    brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
                }
                if brought {
                    return
                }
            }
        }

        Task { [weak self] in
            await self?.runApp()
            // 新开路拉满（3.8.240）：App 没在跑时启动只管起新窗、
            // 起完没人拉满——上次关时是小窗就还是小窗，3.8.238
            // 只修了在跑的带回拉满。起完等新窗进 dock 再拉满一次，
            // 不管上次关时大小；小窗/最小化按钮不走这里。
            await MainActor.run {
                if #available(iOS 16.0, *) {
                    self?.pollAndMaximizeFreshWindow()
                }
            }
        }
    }

    // 启动新开路拉满（3.8.240）：runApp 起完新窗可能还没进
    // dock（签名耗时），0.3 秒×20 次轮询等它出现；归属按路径
    // 验，别人的窗口占着 uuid 就停表不碰；vc 没就绪继续等；
    // 拉满动画重入守卫吞掉的那次下个 tick 重试（isMaximized
    // 没翻就说明没拉上），20 次后停。启动失败已有 launch 侧
    // showError，这里到期不重复报错。
    @available(iOS 16.0, *)
    private func pollAndMaximizeFreshWindow() {
        let expectedPath = configuration.model.appInfo.relativeBundlePath
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            attempts += 1
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard let uuid = self.bannerInstanceUUID(),
                  let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }) else {
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

    private func runApp(multitask: Bool? = nil) async {
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                showError(error.localizedDescription)
                return
            }
        }

        do {
            try await configuration.model.runApp(multitask: multitask)
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - 面板同款：最小化 / 小窗口（主列表卡片）
    // 面板行是 AppCardRow（LCAppModel）配三个闭包，本卡是 UIKit
    // banner，入口不同但语义照抄面板的 minimizeOpenApp /
    // smallWindowOpenApp：已在运行按实例 UUID 找 dock 条目、
    // 验相对路径归属；未运行先启动再最小化/还原小窗。
    // 实例 UUID 取选中容器的 folderName（与 runButtonTapped 的
    // currentDataFolder 同款），dataUUID 作回落。

    private func bannerInstanceUUID() -> String? {
        configuration.model.uiSelectedContainer?.folderName ?? configuration.model.appInfo.dataUUID
    }

    // 面板 private 的 unmaximizeWindow 同款（那边是 AllAppsListView
    // 私有方法，本卡调不到，照抄三行）：窗口已最大化时点一下
    // 还原成小窗；静态方法，不捕获 self，回调里可直接调。
    @available(iOS 16.0, *)
    private static func unmaximizeWindow(uuid: String) {
        guard let runningApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
              vc.isMaximized else { return }
        vc.maximizeWindow()
        // 小窗口打开默认不收快捷栏（Campbell 2026-11-06，与
        // 面板同款）：还原成小窗后把落地最大化时自动收起的
        // 快捷栏展开回来；全屏打开不经此路，仍默认收起。
        MultitaskDockManager.shared.czfExpandDockIfCollapsed()
    }

    // 小窗口回落路专用（3.8.239）：czfOnWindowAppeared 是“同 uuid
    // 条目已存在就立即回调”、不验归属——同容器被别的条目占着时，
    // 回调会把别人的窗口还原成小窗。动作前再按路径复验一次，
    // 对不上/验不出就什么都不做，别动别人的窗口。
    @available(iOS 16.0, *)
    private static func unmaximizeWindowIfOwned(uuid: String, expectedPath: String?) {
        guard let expectedPath,
              let runningApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty,
              runningPath == expectedPath else { return }
        unmaximizeWindow(uuid: uuid)
    }

    // 未运行分支的启动（含锁屏认证，与本卡 runApp 同款逻辑，
    // 只多一个 containerFolderName 参数，面板两路都带它；
    // 容器删光时传 nil，runApp 会重建容器，见 L14）。
    private func launchForAux(multitask: Bool?, containerFolderName: String?) async {
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                showError(error.localizedDescription)
                return
            }
        }
        do {
            try await configuration.model.runApp(multitask: multitask, containerFolderName: containerFolderName)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func minimizeButtonTapped() {
        guard #available(iOS 16.0, *) else { return }
        // 容器删光（L14）：先启动（runApp 会重建容器），容器一
        // 出现就重走正常路；20 次内没出现就停（启动失败已由
        // launch 侧 showError，不在这里重复报错）。
        guard let uuid = bannerInstanceUUID() else {
            Task { [weak self] in
                await self?.launchForAux(multitask: true, containerFolderName: nil)
            }
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
                attempts += 1
                if self?.bannerInstanceUUID() != nil {
                    timer.invalidate()
                    self?.minimizeButtonTapped()
                } else if attempts >= 20 {
                    timer.invalidate()
                }
            }
            return
        }
        let dockManager = MultitaskDockManager.shared
        // 已在运行：归属对不上（共用容器的别的条目）不碰它，
        // 落到下面启动分支起自己的窗口。归属先验相对路径；
        // 但条目 appInfo 若是按存盘 bundlePath 重建的，就没有
        // relativeBundlePath，路径根本验不了——原来一律当
        // 别人的（?? true）落到启动分支，点最小化等于点启动
        // （用户实测报的毛病）。改为路径缺失时用 bundleId
        // 兜底验：同 uuid 条目、bundleId 相同就是本 App 的
        // 窗口，直接最小化；bundleId 对不上才是共用容器里
        // 别的 App 占着，照旧不碰。
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }) {
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != configuration.model.appInfo.relativeBundlePath
            } else if let runningInfo = runningApp.appInfo {
                belongsToOther = runningInfo.bundleIdentifier() != configuration.model.appInfo.bundleIdentifier()
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                dockManager.minimizeWindow(uuid: uuid)
                return
            }
        }
        // 未运行：照小窗口同款——先注册窗口出现回调，再以多
        // 任务方式启动；窗口一出现（0.35 秒后，与小窗口同款延
        // 迟）复验归属再最小化。效果与手动「点小窗口 → 点黄
        // 色减号」一致：窗口以小窗出现、随即收进右侧 dock。
        // 旧路是 multitask:nil 全屏直启 + 0.3 秒×20 次轮询等
        // apps 条目：全屏场景的条目键与容器 uuid 对不上，轮询
        // 基本等不到，窗口就挂在那儿——用户实测点最小化等于
        // 点启动。回调由 czfOnWindowAppeared 的 30 秒超时兜底，
        // 窗口不出现就自动放弃，不留野观察者。
        let expectedPath = configuration.model.appInfo.relativeBundlePath
        let expectedBundleId = configuration.model.appInfo.bundleIdentifier()
        dockManager.czfOnWindowAppeared(uuid: uuid, timeout: 30) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                // 归属复验与已运行分支同款：路径优先，
                // 路径缺失用 bundleId 兜底；占着 uuid 的若是
                // 别人的窗口，什么都不做。
                guard let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }) else { return }
                let owned: Bool
                if let entryPath = entry.appInfo?.relativeBundlePath, !entryPath.isEmpty {
                    owned = entryPath == expectedPath
                } else if let entryInfo = entry.appInfo {
                    owned = entryInfo.bundleIdentifier() == expectedBundleId
                } else {
                    owned = false
                }
                if owned {
                    MultitaskDockManager.shared.minimizeWindow(uuid: uuid)
                }
            }
        }
        Task { [weak self] in
            await self?.launchForAux(multitask: true, containerFolderName: uuid)
        }
    }

    @objc private func smallWindowButtonTapped() {
        guard #available(iOS 16.0, *) else { return }
        // 容器删光（L14）：先启动（runApp 会重建容器），容器一
        // 出现就重走正常路；20 次内没出现就停（启动失败已由
        // launch 侧 showError）。
        guard let uuid = bannerInstanceUUID() else {
            Task { [weak self] in
                await self?.launchForAux(multitask: true, containerFolderName: nil)
            }
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
                attempts += 1
                if self?.bannerInstanceUUID() != nil {
                    timer.invalidate()
                    self?.smallWindowButtonTapped()
                } else if attempts >= 20 {
                    timer.invalidate()
                }
            }
            return
        }
        let dockManager = MultitaskDockManager.shared
        // 已在运行：归属不明一律视为别的条目（面板同款），不顶
        // 窗口、直接落到启动分支；带回成功还原小窗，带回失败
        // 且条目不是本次清掉的死窗、也没消失时同样只还原不重起。
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }) {
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != configuration.model.appInfo.relativeBundlePath
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                let brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
                if brought {
                    Self.unmaximizeWindow(uuid: uuid)
                    return
                }
                let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == uuid
                let entryGone = !dockManager.apps.contains(where: { $0.appUUID == uuid })
                if !cleanedByC4 && !entryGone {
                    Self.unmaximizeWindow(uuid: uuid)
                    return
                }
            }
        }
        // 未运行：先注册窗口出现回调、再启动（面板 C6 同款顺序），
        // 窗出来 0.35 秒后还原为小窗；30 秒未出现放弃，不留野观察者。
        // 回调动作前按路径复验归属（L5）：同 uuid 条目已存在时回调
        // 立即触发、不验归属——占着 uuid 的若是别人的窗口，复验
        // 拦住，别把别人的窗口还原成小窗。
        let expectedPath = configuration.model.appInfo.relativeBundlePath
        dockManager.czfOnWindowAppeared(uuid: uuid, timeout: 30) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Self.unmaximizeWindowIfOwned(uuid: uuid, expectedPath: expectedPath)
            }
        }
        Task { [weak self] in
            await self?.launchForAux(multitask: true, containerFolderName: uuid)
        }
    }

    // MARK: - 长按系统菜单（用户定版）
    // 2026-11-06 曾按令换成自制半屏 sheet，同日用户令
    // 改回系统菜单，本节即系统 UIMenu。前四行顺序为
    // 同日定版：设置、备份、恢复备份、导出应用；之后
    // 依次是容器切换（多容器才有）、数据文件夹、模块
    // 文件夹、添加到主屏幕。每一栏各自独立成组——系
    // 统在组与组之间画分隔线，于是每一栏下面都有横
    // 线。头部不带名称/Bundle ID 行（用户早先拍板去
    // 掉，卡片上就有名字，不用在菜单里再写一遍）。

    private func makeContextMenu() -> UIMenu {
        let model = configuration.model
        var menuChildren: [UIMenuElement] = []

        // 一栏一组：每行单独包一个 displayInline 组，分隔
        // 线就出现在每一栏之间。
        func rowGroup(_ element: UIMenuElement) -> UIMenu {
            UIMenu(title: "", options: .displayInline, children: [element])
        }

        menuChildren.append(rowGroup(UIAction(
            title: "lc.tabView.settings".loc,
            image: UIImage(systemName: "gear")
        ) { [weak self] _ in
            self?.openSettings()
        }))

        menuChildren.append(rowGroup(UIAction(
            title: "备份",
            image: UIImage(systemName: "tray.and.arrow.down.fill")
        ) { [weak self] _ in
            self?.backupApp()
        }))

        menuChildren.append(rowGroup(UIAction(
            title: "恢复备份",
            image: UIImage(systemName: "tray.and.arrow.up.fill")
        ) { [weak self] _ in
            self?.restoreBackup()
        }))

        // 导出应用（2026-11-06 由「分享IPA」改名）：把当
        // 前 App 打包成 IPA 弹分享表递出去；注意与横滑那
        // 颗「共享」钮不是一回事（那是 App 共享开关）。
        menuChildren.append(rowGroup(UIAction(
            title: "导出应用",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.exportAppIPA()
        }))

        // Containers Picker（多容器才出现，原样保留）
        if model.uiContainers.count > 1 {
            let containerActions = model.uiContainers.map { [weak self] container in
                UIAction(
                    title: container.name,
                    state: container == model.uiSelectedContainer ? .on : .off
                ) { _ in
                    // 只改 uiSelectedContainer 不持久：模型重载时选中会按
                    // dataUUID 重算回旧容器，等于白选。三个一起改，
                    // 选了哪个、启动就用哪个、重进还是哪个。
                    model.uiSelectedContainer = container
                    model.uiDefaultDataFolder = container.folderName
                    model.appInfo.dataUUID = container.folderName
                    self?.refreshView()
                }
            }
            menuChildren.append(UIMenu(title: "Containers", options: .displayInline, children: containerActions))
        }

        if !model.uiIsShared, model.uiSelectedContainer != nil {
            menuChildren.append(rowGroup(UIAction(
                title: "数据文件夹",
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in
                self?.openDataFolder()
            }))
        }

        // Tweak/Module Picker（多选：点一下勾上/再点取消，
        // 可同时选多个模块文件夹，启动时逐个加载；「无」清空）
        let selectedFolders = LCAppModel.czfSplitTweakFolders(model.uiTweakFolder)
        var tweakMenuActions: [UIAction] = [
            UIAction(
                title: "lc.common.none".loc,
                state: selectedFolders.isEmpty ? .on : .off
            ) { _ in
                model.uiTweakFolder = nil
            }
        ]
        tweakMenuActions += DataManager.shared.model.tweakFolderNames.map { folderName in
            UIAction(
                title: folderName,
                state: selectedFolders.contains(folderName) ? .on : .off
            ) { _ in
                model.toggleTweakFolder(folderName)
            }
        }
        // 子菜单也单独成组：包一层 displayInline，子菜单本
        // 身照旧是带箭头的子菜单行，前后都有分隔线。
        menuChildren.append(rowGroup(UIMenu(
            title: "lc.appSettings.tweakFolder".loc,
            image: UIImage(systemName: "wrench.and.screwdriver"),
            children: tweakMenuActions
        )))

        let addToHomeScreenMenu = UIMenu(
            title: "lc.appBanner.addToHomeScreen".loc,
            image: UIImage(systemName: "plus.app"),
            children: [
                UIAction(title: "lc.appBanner.copyLaunchUrl".loc, image: UIImage(systemName: "link")) { [weak self] _ in
                    self?.copyLaunchUrl()
                },
                UIAction(title: "lc.appBanner.saveAppIcon".loc, image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.saveIcon()
                    }
                },
                UIAction(title: "lc.appBanner.createAppClip".loc, image: UIImage(systemName: "appclip")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.createAppClip()
                    }
                }
            ]
        )
        menuChildren.append(rowGroup(addToHomeScreenMenu))

        return UIMenu(title: "", children: menuChildren)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeContextMenu()
        }
    }

    // MARK: - 横滑操作（左滑尾钮、右滑 VPN）

    // 两侧各一颗钮，单颗宽 70（系统列表口径）；尾钮无
    // 形态（LC2 共享态）时左滑宽度为 0、左滑不出钮。
    private var leftSwipeWidth: CGFloat { 70 }
    private var rightSwipeWidth: CGFloat {
        trailingSwipeKind == .none ? 0 : 70
    }

    // 卡面是半透明的（动态取色 50% 透明），按钮光躲在卡片
    // 后面会被透出来（3.8.2 实测教训）：静止时必须真隐藏。
    // 显示时不整排点亮——每颗钮的可见性由 layoutSwipe
    // Buttons 按当前偏移方向单独决定：左滑只出左滑的钮，
    // 右滑的钮保持隐藏（用户实测：左滑时右滑图标也冒头）。
    private func setSwipeButtonsVisible(_ visible: Bool) {
        if visible {
            layoutSwipeButtons()
        } else {
            vpnSwipeButton.isHidden = true
            trailingSwipeButton.isHidden = true
        }
    }

    // 两颗钮的帧 = 各自的露出区：钮内部的圆药丸随露出
    // 变宽「拉长成椭圆」，和节点行原生横滑的动效一致
    // （用户拿录屏定的）：药丸随拖动一路长，拖过钮宽后
    // 继续拉长（全滑信号）。按钮设计（颜色/图标/下方
    // 文字）不动，变的只有药丸宽。排帧只读 swipeOffset，
    // 归位补间逐帧改这个值，帧就逐帧跟着走。
    private func layoutSwipeButtons() {
        let bounds = swipeContainerView.bounds
        let height = bounds.height
        let width = bounds.width
        guard height > 0, width > 0 else { return }
        let offset = swipeOffset
        if offset > 0 {
            vpnSwipeButton.frame = CGRect(x: 0, y: 0, width: offset, height: height)
        } else if offset < 0 {
            let reveal = -offset
            trailingSwipeButton.frame = CGRect(x: width - reveal, y: 0, width: reveal, height: height)
        }
        // 可见性跟方向走：只有正在露出的那一侧钮可见，
        // 另一侧哪怕帧还留着旧值也保持隐藏、不会透出。
        vpnSwipeButton.isHidden = offset <= 0
        trailingSwipeButton.isHidden = offset >= 0 || trailingSwipeKind == .none
    }

    private func setSwipeOffset(_ offset: CGFloat, animated: Bool) {
        // 全局唯一滑开：本行定住打开时，先把上一行收回
        if offset != 0 {
            if Self.czfOpenSwipeBanner !== self {
                Self.czfOpenSwipeBanner?.setSwipeOffset(0, animated: true)
                Self.czfOpenSwipeBanner = self
            }
        } else if Self.czfOpenSwipeBanner === self {
            Self.czfOpenSwipeBanner = nil
        }
        swipeCloseTapGesture?.isEnabled = offset != 0
        if offset != 0 {
            setSwipeButtonsVisible(true)
        }
        if animated {
            startSwipeTween(to: offset)
        } else {
            stopSwipeTween()
            swipeOffset = offset
            bannerView.transform = CGAffineTransform(translationX: offset, y: 0)
            layoutSwipeButtons()
            if offset == 0 {
                setSwipeButtonsVisible(false)
            }
        }
    }

    // 归位/打开的逐帧补间：easeOut 三次方、0.25 秒，和
    // 原 UIView 动画观感一致，但偏移是逐帧写回的，按钮
    // 帧跟着卡片同步收放，不再僵住后突然消失。
    private func startSwipeTween(to target: CGFloat) {
        stopSwipeTween()
        swipeTweenFrom = swipeOffset
        swipeTweenTo = target
        swipeTweenStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(swipeTweenTick(_:)))
        link.add(to: .main, forMode: .common)
        swipeDisplayLink = link
    }

    private func stopSwipeTween() {
        swipeDisplayLink?.invalidate()
        swipeDisplayLink = nil
    }

    @objc private func swipeTweenTick(_ link: CADisplayLink) {
        let t = min((CACurrentMediaTime() - swipeTweenStart) / 0.25, 1)
        let eased = 1 - pow(1 - t, 3)
        let value = swipeTweenFrom + (swipeTweenTo - swipeTweenFrom) * CGFloat(eased)
        swipeOffset = value
        bannerView.transform = CGAffineTransform(translationX: value, y: 0)
        layoutSwipeButtons()
        if t >= 1 {
            stopSwipeTween()
            if swipeTweenTo == 0 {
                setSwipeButtonsVisible(false)
            }
        }
    }

    @objc private func bannerSwiped(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // 手刚落下就先收回别行滑开的按钮，不等本行定住
            if Self.czfOpenSwipeBanner !== self {
                Self.czfOpenSwipeBanner?.setSwipeOffset(0, animated: true)
            }
            // 拖动接管偏移：停掉可能在跑的归位补间
            stopSwipeTween()
            swipeStartOffset = swipeOffset
            setSwipeButtonsVisible(true)
            layoutSwipeButtons()
        case .changed:
            // 夹取放宽到整行：滑到底（触发卸载/VPN）要能拖
            // 过半行，途中边缘钮跟着变宽，与节点行全滑同款
            let raw = swipeStartOffset + gesture.translation(in: swipeContainerView).x
            let rowWidth = max(swipeContainerView.bounds.width, 1)
            let clamped = min(max(raw, -rowWidth), rowWidth)
            swipeOffset = clamped
            bannerView.transform = CGAffineTransform(translationX: clamped, y: 0)
            layoutSwipeButtons()
        case .ended, .cancelled, .failed:
            let total = swipeStartOffset + gesture.translation(in: swipeContainerView).x
            let velocity = gesture.velocity(in: swipeContainerView).x
            let rowWidth = max(swipeContainerView.bounds.width, 1)
            // 滑到底（过半行）：左滑到底 = 尾钮（卸载/取消
            // 分享），右滑到底 = VPN 开/关——与点按那颗钮
            // 同一动作，先归位再执行（卸载自带确认、VPN
            // 是开关）。尾钮无形态时左滑到底只归位。
            if total <= -rowWidth * 0.5 {
                setSwipeOffset(0, animated: true)
                if trailingSwipeKind != .none {
                    trailingSwipeTapped()
                }
                return
            }
            if total >= rowWidth * 0.5 {
                setSwipeOffset(0, animated: true)
                vpnSwipeTapped()
                return
            }
            var target: CGFloat = 0
            if total <= -rightSwipeWidth * 0.4 || (total < -12 && velocity < -600) {
                target = -rightSwipeWidth
            } else if total >= leftSwipeWidth * 0.4 || (total > 12 && velocity > 600) {
                target = leftSwipeWidth
            }
            setSwipeOffset(target, animated: true)
        default:
            break
        }
    }

    @objc private func bannerCloseTapped() {
        setSwipeOffset(0, animated: true)
    }

    @objc private func vpnSwipeTapped() {
        let appInfo = configuration.model.appInfo
        setSwipeOffset(0, animated: true)
        // 用户定版：右滑 VPN 就是单纯的单 App VPN 开关——
        // 点一下开、再点一下关，不打开 App。
        CZFVPNManager.setEnabled(!CZFVPNManager.isEnabled(for: appInfo), for: appInfo)
        refreshView()
    }

    @objc private func trailingSwipeTapped() {
        switch trailingSwipeKind {
        case .uninstall:
            setSwipeOffset(0, animated: true)
            Task { [weak self] in await self?.uninstall() }
        case .unshare:
            setSwipeOffset(0, animated: true)
            Task { [weak self] in await self?.unshareApp() }
        case .none:
            break
        }
    }

    // 容器级点按识别器的落点分发：命中哪颗钮就走哪颗的
    // 动作（与全滑、控件点按同一入口）。未滑开时命中启
    // 动钮/次级钮走各自的点按处理（启动钮的长按吞噬时间
    // 戳在 runButtonTapped 里，长按调面板后抬手这一下照
    // 样被吞，不会误启动）；识别器 cancelsTouchesInView
    // 会取消控件自身的触摸，touchUpInside 不会再重复触发。
    @objc private func swipeButtonAreaTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: swipeContainerView)
        if swipeOffset == 0 {
            if bannerView.runControl.frame.insetBy(dx: -4, dy: -6).contains(point) {
                runButtonTapped()
            } else if let minimize = bannerView.minimizeControl, minimize.frame.contains(point) {
                minimizeButtonTapped()
            } else if let small = bannerView.smallWindowControl, small.frame.contains(point) {
                smallWindowButtonTapped()
            }
            return
        }
        if !vpnSwipeButton.isHidden, vpnSwipeButton.frame.contains(point) {
            vpnSwipeTapped()
        } else if !trailingSwipeButton.isHidden, trailingSwipeButton.frame.contains(point) {
            trailingSwipeTapped()
        }
    }

    // 取消分享：与设置页 movePrivateDoc 同一套动作（确认
    // 文案用同一组本地化串）——被其他 LC 占用先报错；确认
    // 后把 App 本体、各数据容器、模块文件夹从共享目录搬
    // 回私有目录，名单与共享标记同步翻转。
    private func unshareApp() async {
        let model = configuration.model
        let appInfo = model.appInfo
        let sharedModel = DataManager.shared.model
        for container in appInfo.containers {
            if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
                showError("lc.appSettings.appOpenInOtherLc %@ %@".localizeWithFormat(runningLC, runningLC))
                return
            }
        }
        let confirmed = await presentConfirmation(
            title: "lc.appSettings.toPrivateApp".loc,
            message: "lc.appSettings.toPrivateAppDesc".loc,
            confirmTitle: "lc.common.move".loc,
            cancelTitle: "lc.common.cancel".loc
        )
        guard confirmed == true else { return }
        do {
            var moves: [(URL, URL)] = []
            moves.append((
                URL(fileURLWithPath: appInfo.bundlePath()),
                LCPath.bundlePath.appendingPathComponent(appInfo.relativeBundlePath)
            ))
            for container in model.uiContainers {
                if container.storageBookMark != nil { continue }
                moves.append((
                    LCPath.lcGroupDataPath.appendingPathComponent(container.folderName),
                    LCPath.dataPath.appendingPathComponent(container.folderName)
                ))
            }
            if let tweakFolder = appInfo.tweakFolder, tweakFolder.count > 0 {
                for name in LCAppModel.czfSplitTweakFolders(tweakFolder) {
                    for candidate in [name, name + ".disabled"] {
                        let src = LCPath.lcGroupTweakPath.appendingPathComponent(candidate)
                        if FileManager.default.fileExists(atPath: src.path) {
                            moves.append((src, LCPath.tweakPath.appendingPathComponent(candidate)))
                        }
                    }
                }
            }
            try LCUtils.moveFilesAtomicallyAfterPreflight(moves)
            for container in model.uiContainers {
                if container.storageBookMark != nil { continue }
                sharedModel.appDataFolderNames.append(container.folderName)
            }
            if let tweakFolder = appInfo.tweakFolder, tweakFolder.count > 0 {
                for name in LCAppModel.czfSplitTweakFolders(tweakFolder) where !sharedModel.tweakFolderNames.contains(name) {
                    sharedModel.tweakFolderNames.append(name)
                }
                model.uiTweakFolder = tweakFolder
            }
            appInfo.setBundlePath(LCPath.bundlePath.appendingPathComponent(appInfo.relativeBundlePath).path)
            appInfo.isShared = false
            model.uiIsShared = false
            for container in model.uiContainers {
                container.isShared = false
            }
            refreshView()
        } catch {
            showError(error.localizedDescription)
        }
    }

    // 与数据管理里的手动备份同一套、同一位置（Documents/
    // Backups + 同步外部备份文件夹 + 刷新设置备份），所以
    // 重装这个 App 时自动恢复也能查到这份备份。
    private func backupApp() {
        let app = configuration.model
        let name = app.displayName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let message: String
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                let root = docs.appendingPathComponent("Backups")
                do {
                    try fm.createDirectory(at: root, withIntermediateDirectories: true)
                    let one = try LCDataManagementView.backupOneAppSync(app, backupRoot: root, fm: fm)
                    LCDataManagementView.syncBackupsToExternalFolder(appNames: [one.folderName], backupRoot: root)
                    _ = LCDataManagementView.writeCZFSettingsBackup()
                    message = "「\(name)」已备份：容器 \(one.containerCount) 个 · 钥匙串 \(one.keychainCount) 条"
                } catch {
                    message = "「\(name)」备份失败：\(LCUtils.czfFriendlyError(error))"
                }
            } else {
                message = "「\(name)」备份失败：找不到文档目录"
            }
            DispatchQueue.main.async {
                self?.showInfo(message)
            }
        }
    }

    // 恢复备份（2026-11-06 新增）：找这个 App 在本地备
    // 份目录（Documents/Backups，与「备份」行同一位置）
    // 里的备份文件夹，没有就直接提示还没备份；有就先让
    // 用户选恢复范围（与数据管理恢复弹窗同两档：只恢复
    // 登录态不动现有数据 / 恢复全部数据会覆盖当前数
    // 据），选完走数据管理同一套 restoreOneApp，完事报
    // 结果。外部文件夹（iCloud）里的备份不在这找，仍
    // 去数据管理页恢复。
    private func restoreBackup() {
        let app = configuration.model
        let name = app.displayName
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            showInfo("「\(name)」恢复备份失败：找不到文档目录")
            return
        }
        let root = docs.appendingPathComponent("Backups")
        let folderName = LCDataManagementView.backupFolderName(for: app, backupRoot: root, fm: fm)
        let folder = root.appendingPathComponent(folderName)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
              LCDataManagementView.isValidBackupFolder(folder) else {
            showInfo("「\(name)」还没有备份，先用上面的「备份」备一份")
            return
        }
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "恢复「\(name)」的备份", message: "只恢复登录态：只写回登录，现有数据不动。\n恢复全部数据：会覆盖当前数据。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "只恢复登录态", style: .default) { [weak self] _ in
            self?.runRestoreBackup(app: app, name: name, folder: folder, loginOnly: true)
        })
        alert.addAction(UIAlertAction(title: "恢复全部数据", style: .destructive) { [weak self] _ in
            self?.runRestoreBackup(app: app, name: name, folder: folder, loginOnly: false)
        })
        alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel))
        present(alert, animated: true)
    }

    private func runRestoreBackup(app: LCAppModel, name: String, folder: URL, loginOnly: Bool) {
        Task { [weak self] in
            do {
                let outcome = try await LCDataManagementView.restoreOneApp(appFolder: folder, app: app, loginOnly: loginOnly)
                let message: String
                if outcome.ok {
                    var text = "「\(name)」已恢复备份：钥匙串写回 \(outcome.keychainImported) 条"
                    if outcome.keychainQueued > 0 {
                        text += "，另有 \(outcome.keychainQueued) 条已排队，下次打开该 App 时写回"
                    }
                    message = text
                } else {
                    message = "「\(name)」没有恢复出数据（备份里数据容器 \(outcome.containerFolderCount) 个，合并登录文件 \(outcome.mergedLoginFiles) 个，钥匙串找到 \(outcome.keychainFound) 条）"
                }
                DispatchQueue.main.async {
                    self?.showInfo(message)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showInfo("「\(name)」恢复备份失败：\(LCUtils.czfFriendlyError(error))")
                }
            }
        }
    }

    // 导出当前 App 的 IPA 包（Campbell 2026-11-06 追加、
    // 同日菜单行由「分享IPA」改名「导出应用」）：
    // 把已安装的 .app 本体原样复制进 Payload/ 再压成
    // IPA（经 LCUtils.czfZippedData(for:) 走 PassKitCore 的
    // PKZipArchiver，与多开管理打包 LC 本体同一个打包
    // 器、同一套 Payload 在根的布局；那个类是私有类，
    // Swift 里不能直接引用），不重签、不改包——装回去
    // 时 LC 照常走它自己的签名流程。打包放后台队列，
    // 完事弹系统分享表递文件；分享结束删临时 IPA（工
    // 作目录打包完即删），失败弹原因。
    private func exportAppIPA() {
        let app = configuration.model
        let name = app.displayName
        let bundlePath = app.appInfo.bundlePath()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            do {
                guard let bundlePath = bundlePath, !bundlePath.isEmpty else {
                    throw NSError(domain: "CZFShareIPA", code: -1, userInfo: [NSLocalizedDescriptionKey: "找不到这个 App 的包路径"])
                }
                let src = URL(fileURLWithPath: bundlePath)
                let work = fm.temporaryDirectory.appendingPathComponent("CZFShareIPA-\(UUID().uuidString)")
                let payload = work.appendingPathComponent("Payload", isDirectory: true)
                try fm.createDirectory(at: payload, withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: payload.appendingPathComponent(src.lastPathComponent))
                guard let zipData = LCUtils.czfZippedData(for: work) else {
                    try? fm.removeItem(at: work)
                    throw NSError(domain: "CZFShareIPA", code: -2, userInfo: [NSLocalizedDescriptionKey: "打包失败"])
                }
                try? fm.removeItem(at: work)
                let safeName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
                let ipaURL = fm.temporaryDirectory.appendingPathComponent("\(safeName.isEmpty ? "App" : safeName).ipa")
                try? fm.removeItem(at: ipaURL)
                try zipData.write(to: ipaURL)
                DispatchQueue.main.async {
                    czfPresentActivitySheet(items: [ipaURL]) {
                        try? FileManager.default.removeItem(at: ipaURL)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showInfo("「\(name)」导出应用失败：\(LCUtils.czfFriendlyError(error))")
                }
            }
        }
    }

    private func showInfo(_ message: String) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default))
        present(alert, animated: true)
    }

    // MARK: - 手势代理

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 横滑只认横向速度占优的拖动，纵向拖动留给列表滚动。
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: bannerView)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 按钮区点按识别器只在落点确实命中它接管的按钮时
        // 才接管这次触摸，其余一律放行：滑开着认露出的横
        // 滑钮；未滑开认启动钮（命中区按它 point(inside:)
        // 的外扩口径 -4/-6）和两个次级钮。bannerView 铺满
        // 容器，未滑开时变换为零，按钮帧就是容器坐标系。
        if gestureRecognizer === swipeButtonTapGesture {
            let point = touch.location(in: swipeContainerView)
            if swipeOffset != 0 {
                if !vpnSwipeButton.isHidden, vpnSwipeButton.frame.contains(point) { return true }
                if !trailingSwipeButton.isHidden, trailingSwipeButton.frame.contains(point) { return true }
                return false
            }
            if bannerView.runControl.frame.insetBy(dx: -4, dy: -6).contains(point) { return true }
            if let minimize = bannerView.minimizeControl, minimize.frame.contains(point) { return true }
            if let small = bannerView.smallWindowControl, small.frame.contains(point) { return true }
            return false
        }
        return true
    }

    private func openSettings() {
        delegate.openNavigationView(view: AnyView(LCAppSettingsView(model: configuration.model)))
    }

    private func openDataFolder() {
        // 容器名含空格时 URL(string:) 直接返回 nil；先 percent-encoding 再拼
        //（与容器设置页同款），拼不出弹提示而不是静默 return。
        guard let folderName = configuration.model.uiSelectedContainer?.folderName,
              let encodedName = folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(encodedName)") else {
            let alert = UIAlertController(title: nil, message: "无法打开数据文件夹", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
            return
        }
        UIApplication.shared.open(url)
    }

    private func uninstall() async {
        let appInfo = configuration.model.appInfo
        let displayName = appInfo.displayName() ?? configuration.model.displayName
        // 已锁定的 App 不许卸载（Campbell 2026-11-06 令）：
        // 拦在最前面，连确认框都不弹，提示先解锁。解锁走
        // 卡面现成的锁定开关（要过验证），这里只拦不卸。
        if appInfo.isLocked {
            showInfo("「\(displayName)」已锁定，请先解锁再卸载")
            return
        }
        let shouldUninstall = await presentConfirmation(
            title: "lc.appBanner.confirmUninstallTitle".loc,
            message: "lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(displayName),
            confirmTitle: "lc.appBanner.uninstall".loc,
            cancelTitle: "lc.common.cancel".loc
        )
        guard shouldUninstall == true else {
            return
        }

        var shouldRemoveAppFolders = false
        let containers = appInfo.containers
        if !containers.isEmpty {
            shouldRemoveAppFolders = await presentConfirmation(
                title: "lc.appBanner.deleteDataTitle".loc,
                message: "lc.appBanner.deleteDataMsg %@".localizeWithFormat(displayName),
                confirmTitle: "lc.common.delete".loc,
                cancelTitle: "lc.common.no".loc
            ) == true
        }

        do {
            guard let bundlePath = appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }

            let fileManager = FileManager.default
            try fileManager.removeItem(atPath: bundlePath)
            delegate.removeApp(app: configuration.model)

            if shouldRemoveAppFolders {
                // 逐个删容器：原来循环里任一 removeItem 抛错就进
                // catch，App 已从列表消失，剩下的容器和钥匙串留在
                // 磁盘上且不再属于任何条目。现单步失败不中断：文件
                // 夹删失败的容器跳过钥匙串与名单清理（文件夹还在，
                // 钥匙串与名单留着才对得上），最后汇总报一次。
                var failedContainers: [String] = []
                for container in containers {
                    let dataUUID = container.folderName
                    do {
                        try fileManager.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
                    } catch {
                        failedContainers.append(dataUUID)
                        continue
                    }
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
                }
                if !failedContainers.isEmpty {
                    showError("以下容器删除失败，已保留：\(failedContainers.joined(separator: "、"))")
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }



    private func copyLaunchUrl() {
        guard let relativeBundlePath = configuration.model.appInfo.relativeBundlePath else {
            return
        }

        // 文件夹名/容器名可能含空格，直接拼出的链接粘贴后打不开；先编码。
        let encodedBundlePath = relativeBundlePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relativeBundlePath
        if let folderName = configuration.model.uiSelectedContainer?.folderName {
            let encodedFolder = folderName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folderName
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(encodedBundlePath)&container-folder-name=\(encodedFolder)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(encodedBundlePath)"
        }
    }

    private func createAppClip() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let profile = configuration.model.appInfo.generateWebClipConfig(
                withContainerId: configuration.model.uiSelectedContainer?.folderName,
                iconStyle: style
            ) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            delegate.installMdm(data: data)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveIcon() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let image = configuration.model.appInfo.generateLiveContainerWrappedIcon(with: style),
                  let imageData = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }

            cleanupExportTemporaryDirectory()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let rawDisplayName = configuration.model.appInfo.displayName() ?? configuration.model.displayName
            let displayName = rawDisplayName.replacingOccurrences(of: "/", with: "_")
            let fileURL = temporaryDirectory.appendingPathComponent("\(displayName) Icon.png")
            try imageData.write(to: fileURL, options: .atomic)
            exportTemporaryDirectory = temporaryDirectory

            guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                cleanupExportTemporaryDirectory()
                return
            }

            let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            documentPicker.delegate = self
            documentPicker.presentationController?.delegate = self
            present(documentPicker, animated: true)
        } catch {
            cleanupExportTemporaryDirectory()
            showError(error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanupExportTemporaryDirectory()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupExportTemporaryDirectory()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cleanupExportTemporaryDirectory()
    }

    private func cleanupExportTemporaryDirectory() {
        guard let exportTemporaryDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: exportTemporaryDirectory)
        self.exportTemporaryDirectory = nil
    }
}


// MARK: - 横滑圆形按钮（圆图标 + 下方小字，与项目页滑动按钮同款式）

// 滑动操作钮：圆形色钮 + 下方小字（设计定版：颜色/
// 图标/文字布局不动）。动效仿节点行原生横滑：色钮是
// 一颗高度 48 的药丸，宽随露出区变——拖动时从圆拉长
// 成椭圆；图标居中于药丸，文字在药丸正下方居中。药
// 丸太窄时图标/文字先藏住，免得挤成一团。
final class LCBannerSwipeButton: UIControl {
    private let pillView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    init(symbol: String, title: String, color: UIColor) {
        super.init(frame: .zero)

        pillView.isUserInteractionEnabled = false
        pillView.backgroundColor = color
        pillView.clipsToBounds = true
        addSubview(pillView)

        iconView.isUserInteractionEnabled = false
        iconView.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        iconView.tintColor = .white
        iconView.contentMode = .center
        pillView.addSubview(iconView)

        titleLabel.isUserInteractionEnabled = false
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 药丸左右各留 11：帧宽 70（停住位）时药丸 48 =
        // 正圆，与原样式严丝合缝；帧更宽就拉长成椭圆。
        // 药丸+文字整组按钮高（=卡片高）上下居中（用户：
        // 图标没和卡片上下居中）——原来药丸贴顶 y=2，整组
        // 偏上；现在先算整组高再取居中起点，图标自然落在
        // 卡片的垂直中线上。
        let pillWidth = max(bounds.width - 22, 0)
        let groupHeight: CGFloat = 48 + 3 + 14
        let top = max((bounds.height - groupHeight) / 2, 0)
        pillView.frame = CGRect(x: 11, y: top, width: pillWidth, height: 48)
        pillView.layer.cornerRadius = min(24, pillWidth / 2)
        iconView.frame = pillView.bounds
        iconView.alpha = min(max((pillWidth - 16) / 16, 0), 1)
        titleLabel.frame = CGRect(x: 0, y: top + 48 + 3, width: bounds.width, height: 14)
        titleLabel.alpha = min(max((pillWidth - 28) / 18, 0), 1)
    }

    func setColor(_ color: UIColor) {
        pillView.backgroundColor = color
    }

    // 整颗换装（尾钮在卸载/取消分享之间切换时用）：图标、
    // 下方文字、药丸色一起换，布局尺寸不动。
    func configure(symbol: String, title: String, color: UIColor) {
        iconView.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        titleLabel.text = title
        pillView.backgroundColor = color
    }

    override var isHighlighted: Bool {
        didSet {
            pillView.alpha = isHighlighted ? 0.72 : 1
        }
    }
}


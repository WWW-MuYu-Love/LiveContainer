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
    // 滑动操作层：容器装横滑按钮（左 VPN、右备份/卸载），
    // bannerView 盖在上面，横拖时平移露出按钮（用户定版）。
    private let swipeContainerView = UIView()
    private let vpnSwipeButton = LCBannerSwipeButton(symbol: "globe", title: "VPN", color: .systemGray)
    private let backupSwipeButton = LCBannerSwipeButton(symbol: "tray.and.arrow.down.fill", title: "备份", color: .systemBlue)
    private let uninstallSwipeButton = LCBannerSwipeButton(symbol: "trash.fill", title: "卸载", color: .systemRed)
    private let rightSwipeStack = UIStackView()
    private var swipeOffset: CGFloat = 0
    private var swipeStartOffset: CGFloat = 0
    private var swipePanGesture: UIPanGestureRecognizer?
    private var swipeCloseTapGesture: UITapGestureRecognizer?
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

        vpnSwipeButton.translatesAutoresizingMaskIntoConstraints = false
        vpnSwipeButton.isHidden = true
        swipeContainerView.addSubview(vpnSwipeButton)

        rightSwipeStack.axis = .horizontal
        rightSwipeStack.spacing = 4
        rightSwipeStack.alignment = .center
        rightSwipeStack.translatesAutoresizingMaskIntoConstraints = false
        rightSwipeStack.addArrangedSubview(backupSwipeButton)
        rightSwipeStack.addArrangedSubview(uninstallSwipeButton)
        rightSwipeStack.isHidden = true
        swipeContainerView.addSubview(rightSwipeStack)

        bannerView.translatesAutoresizingMaskIntoConstraints = false
        swipeContainerView.addSubview(bannerView)

        NSLayoutConstraint.activate([
            vpnSwipeButton.leadingAnchor.constraint(equalTo: swipeContainerView.leadingAnchor, constant: 2),
            vpnSwipeButton.centerYAnchor.constraint(equalTo: swipeContainerView.centerYAnchor),
            vpnSwipeButton.widthAnchor.constraint(equalToConstant: 62),
            vpnSwipeButton.heightAnchor.constraint(equalToConstant: 72),

            rightSwipeStack.trailingAnchor.constraint(equalTo: swipeContainerView.trailingAnchor, constant: -2),
            rightSwipeStack.centerYAnchor.constraint(equalTo: swipeContainerView.centerYAnchor),

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

        vpnSwipeButton.addTarget(self, action: #selector(vpnSwipeTapped), for: .touchUpInside)
        backupSwipeButton.addTarget(self, action: #selector(backupSwipeTapped), for: .touchUpInside)
        uninstallSwipeButton.addTarget(self, action: #selector(uninstallSwipeTapped), for: .touchUpInside)

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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection == nil || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshView()
        }
    }

    deinit {
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
        // 横滑按钮态跟模型走：共享 App 不给卸载；VPN 按钮
        // 绿=已开、灰=未开。
        uninstallSwipeButton.isHidden = configuration.model.uiIsShared
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
                await self?.launchForAux(multitask: nil, containerFolderName: nil)
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
        // 未运行：先启动，面板同款 0.3 秒×20 次轮询等窗口出现
        // 再最小化；轮询只认归属对得上的条目，别人的窗口占着
        // uuid 时直接停表、不碰它（自己的新窗若拆容器会换 uuid，
        // 等这个 uuid 也等不来）。启动失败只走 showError，
        // 轮询 20 次后自停——到期分不清失败还是拆容器换号，
        // 不在这里误报错。
        Task { [weak self] in
            await self?.launchForAux(multitask: nil, containerFolderName: uuid)
        }
        let expectedPath = configuration.model.appInfo.relativeBundlePath
        let expectedBundleId = configuration.model.appInfo.bundleIdentifier()
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            attempts += 1
            if let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }) {
                // 归属验法与上面已运行分支同款：路径优先，
                // 路径缺失用 bundleId 兜底。
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
                timer.invalidate()
            } else if attempts >= 20 {
                timer.invalidate()
            }
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
    // 删：多任务、用 VPN 打开、卸载；设置置顶，数据文件夹
    // 改名放第二，之后模块文件夹、添加到主屏幕。头部用分
    // 区标题一行显示「名称 · Bundle ID」：自绘卡片试过，
    // 样子不行，用户拍板换回系统菜单、一行标题。

    private func makeContextMenu() -> UIMenu {
        let model = configuration.model
        var menuChildren: [UIMenuElement] = []

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

        var sectionChildren: [UIMenuElement] = []
        sectionChildren.append(UIAction(
            title: "lc.tabView.settings".loc,
            image: UIImage(systemName: "gear")
        ) { [weak self] _ in
            self?.openSettings()
        })

        if !model.uiIsShared, model.uiSelectedContainer != nil {
            sectionChildren.append(UIAction(
                title: "数据文件夹",
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in
                self?.openDataFolder()
            })
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
        sectionChildren.append(UIMenu(
            title: "lc.appSettings.tweakFolder".loc,
            image: UIImage(systemName: "wrench.and.screwdriver"),
            children: tweakMenuActions
        ))

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
        sectionChildren.append(addToHomeScreenMenu)

        menuChildren.append(UIMenu(
            title: "\(model.displayName) · \(model.bundleIdentifier)",
            options: .displayInline,
            children: sectionChildren
        ))
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

    // MARK: - 横滑操作（左滑备份/卸载、右滑 VPN）

    private var leftSwipeWidth: CGFloat { 70 }
    private var rightSwipeWidth: CGFloat {
        // 按钮宽 62、间距 4、右侧留 2，与 loadView 布局一致。
        let count = uninstallSwipeButton.isHidden ? 1 : 2
        return CGFloat(62 * count + 4 * (count - 1) + 6)
    }

    // 卡面是半透明的（动态取色 50% 透明），按钮光躲在卡片
    // 后面会被透出来（3.8.2 实测教训）：静止时必须真隐藏，
    // 只有横滑开始/打开着才显示。
    private func setSwipeButtonsVisible(_ visible: Bool) {
        vpnSwipeButton.isHidden = !visible
        rightSwipeStack.isHidden = !visible
    }

    private func setSwipeOffset(_ offset: CGFloat, animated: Bool) {
        swipeOffset = offset
        swipeCloseTapGesture?.isEnabled = offset != 0
        if offset != 0 {
            setSwipeButtonsVisible(true)
        }
        let apply = { self.bannerView.transform = CGAffineTransform(translationX: offset, y: 0) }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: apply) { _ in
                if self.swipeOffset == 0 {
                    self.setSwipeButtonsVisible(false)
                }
            }
        } else {
            apply()
            if offset == 0 {
                setSwipeButtonsVisible(false)
            }
        }
    }

    @objc private func bannerSwiped(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            swipeStartOffset = swipeOffset
            setSwipeButtonsVisible(true)
        case .changed:
            let raw = swipeStartOffset + gesture.translation(in: swipeContainerView).x
            let clamped = min(max(raw, -rightSwipeWidth), leftSwipeWidth)
            swipeOffset = clamped
            bannerView.transform = CGAffineTransform(translationX: clamped, y: 0)
        case .ended, .cancelled, .failed:
            let total = swipeStartOffset + gesture.translation(in: swipeContainerView).x
            let velocity = gesture.velocity(in: swipeContainerView).x
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

    @objc private func uninstallSwipeTapped() {
        setSwipeOffset(0, animated: true)
        Task { [weak self] in await self?.uninstall() }
    }

    @objc private func backupSwipeTapped() {
        setSwipeOffset(0, animated: true)
        backupApp()
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

final class LCBannerSwipeButton: UIControl {
    private let circleView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    override var intrinsicContentSize: CGSize {
        CGSize(width: 62, height: 72)
    }

    init(symbol: String, title: String, color: UIColor) {
        super.init(frame: .zero)

        circleView.isUserInteractionEnabled = false
        circleView.backgroundColor = color
        circleView.layer.cornerRadius = 24
        circleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(circleView)

        iconView.isUserInteractionEnabled = false
        iconView.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        iconView.tintColor = .white
        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints = false
        circleView.addSubview(iconView)

        titleLabel.isUserInteractionEnabled = false
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            circleView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            circleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            circleView.widthAnchor.constraint(equalToConstant: 48),
            circleView.heightAnchor.constraint(equalToConstant: 48),
            iconView.leadingAnchor.constraint(equalTo: circleView.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: circleView.trailingAnchor),
            iconView.topAnchor.constraint(equalTo: circleView.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: circleView.bottomAnchor),
            titleLabel.topAnchor.constraint(equalTo: circleView.bottomAnchor, constant: 3),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setColor(_ color: UIColor) {
        circleView.backgroundColor = color
    }

    override var isHighlighted: Bool {
        didSet {
            circleView.alpha = isHighlighted ? 0.72 : 1
        }
    }
}

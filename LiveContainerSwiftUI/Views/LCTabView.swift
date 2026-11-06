//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI

/// 搜索（用户定版，回到最初）：没有全局搜索了——底部浮
/// 动搜索键、胶囊搜索栏、下拉唤起都已删掉。每页用自己
/// 的系统搜索框（.searchable 挂导航栏），词各页独立：
/// 源/应用读各自的 searchContext（0.2 秒防抖、过滤规则
/// 不变，应用页的浏览器两行也挂在它上面），模块/设置读
/// 本页的状态词按原规则过滤。代理页不参与搜索。

struct LCTabView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject var downloadHelper = DownloadHelper()
    // 「源」标签的更新红点数字（源页算好写进来的）
    @AppStorage("CZFUpdatableAppCount") var updatableAppCount = 0

    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    
    var body: some View {
        rootTabs
        .overlay(
            VStack {
                Spacer()
            }
        )
        .onAppear {
            // 搜索标签与代理标签都已去掉：残留的 .search /
            // .vpn 选中值没有标签可落，回落到应用页，免得白屏。
            if sharedModel.selectedTab == .search || sharedModel.selectedTab == .vpn {
                sharedModel.selectedTab = .apps
            }
            // 提前把多任务管理器建起来：全局手势识别器和 Darwin
            // 监听都在它的 init 里装配，懒到第一个 App 打开才建，
            // 刚进 LiveContainer 在主界面就滑不出面板（用户实测）。
            // 管理器是 iOS 16+ 类型，与 AppDelegate 部署插件同款守卫
            if #available(iOS 16.0, *) {
                _ = MultitaskDockManager.shared
            }
            // 每次打开 App 通知源页自动刷新一次（节流在源页那边）
            NotificationCenter.default.post(name: Notification.Name("CZFRefreshSourcesRequest"), object: nil)
            // 预热节点核心：有标了 VPN 的 App 时提前起核心，
            // 第一个 VPN App 点开不用等冷启动
            CZFVPNManager.shared.prewarmIfNeeded()
            // 定时备份/定时清理的到点检查：原来只挂在数据管理页
            // 的 onAppear 上，不去那页就永远不触发（审计发现）。
            // 改成打开 LiveContainer 就查，到没到点由各自的
            // 日期+时间守卫决定，静默执行不弹窗
            Task {
                await LCDataManagementView.runScheduledBackupIfDue()
                await LCDataManagementView.runScheduledCacheIfDue()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            // 从后台切回前台时也预热一次（核心可能已被自动停）
            if newPhase == .active {
                CZFVPNManager.shared.prewarmIfNeeded()
            }
        }
        .environmentObject(downloadHelper)
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if #available(iOS 16.0, *) {
                            if let log = UserDefaults.lcShared().url(forKey: "LC32BitTranslationLayerLogFile") {
                                ShareLink(item: log)
                            } else {
                                ShareLink(item: errorInfo)
                            }
                        } else {
                            Button("lc.common.copy".loc) {
                                copyError()
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkAndSaveBundleId()
            checkGetTaskAllow()
            checkPrivateContainerBookmark()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
    }
    
    // 根标签栏：iOS 26+ 用系统新标签栏（Tab 新 API），以下
    // 用旧标签栏。搜索不在这里：每页用自己的系统搜索框
    // （见文件头注释）。代理已不在标签栏（Campbell 定）：
    // 移入设置 → 应用设置最下方「代理设置」，LCVPNView
    // 改由那边推进；LCTabIdentifier.vpn 只留作兼容值。
    @ViewBuilder private var rootTabs: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $sharedModel.selectedTab) {
                if DataManager.shared.model.multiLCStatus != 2 {
                    Tab("lc.tabView.sources".loc, systemImage: "books.vertical", value: LCTabIdentifier.sources) {
                        LCSourcesView()
                    }
                    .badge(updatableAppCount > 0 ? updatableAppCount : 0)
                }
                Tab("应用", systemImage: "square.grid.2x2.fill", value: LCTabIdentifier.apps) {
                    LCAppListView()
                }
                if DataManager.shared.model.multiLCStatus != 2 {
                    Tab("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver", value: LCTabIdentifier.tweaks) {
                        LCTweaksView()
                    }
                }
                Tab("lc.tabView.settings".loc, systemImage: "gearshape.fill", value: LCTabIdentifier.settings) {
                    LCSettingsView()
                }
            }
        } else {
            TabView(selection: $sharedModel.selectedTab) {
                if DataManager.shared.model.multiLCStatus != 2 {
                    LCSourcesView()
                        .tabItem {
                            Label("lc.tabView.sources".loc, systemImage: "books.vertical")
                        }
                        .badge(updatableAppCount > 0 ? updatableAppCount : 0)
                        .tag(LCTabIdentifier.sources)
                }
                LCAppListView()
                    .tabItem {
                        // 底部这个标签改名「应用」、图标换四宫格
                        // （用户定版，仿图片底部栏同款）。
                        Label("应用", systemImage: "square.grid.2x2.fill")
                    }
                    .tag(LCTabIdentifier.apps)
                if DataManager.shared.model.multiLCStatus != 2 {
                    LCTweaksView()
                        .tabItem{
                            Label("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver")
                        }
                        .tag(LCTabIdentifier.tweaks)
                }
                LCSettingsView()
                    .tabItem {
                        Label("lc.tabView.settings".loc, systemImage: "gearshape.fill")
                    }
                    .tag(LCTabIdentifier.settings)
            }
        }
    }


    func dispatchURL(url: URL) {
        repeat {
            if url.isFileURL {
                sharedModel.selectedTab = .apps
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.selectedTab = .apps
                break
            }
            
            guard let host = url.host?.lowercased() else {
                return
            }
            
            switch host {
            case "livecontainer-launch", "install", "open-web-page", "open-url":
                sharedModel.selectedTab = .apps
            case "certificate":
                sharedModel.selectedTab = .settings
            case "source":
                sharedModel.selectedTab = .sources
            default:
                return
            }
            
        } while(false)

        sharedModel.deepLink = url
    }
    
    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }
    
    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")
        
        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
        
        guard let errorStr else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }
            
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }
        
        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }
        
        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }
    
    func checkAndSaveBundleId() {
        if DataManager.shared.model.multiLCStatus == 2 {
            let scheme = UserDefaults.lcAppUrlScheme() ?? ""
            LCUtils.appGroupUserDefault.set(Bundle.main.bundleIdentifier, forKey: "LCBundleID.\(scheme)")
        }
        
        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }
        
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        
        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }
        
        if(bundleId != correctBundleId) {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }
    
    func checkGetTaskAllow() {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
    
    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }
        
        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}

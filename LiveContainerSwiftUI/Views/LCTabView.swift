//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI

/// 全局搜索中枢（用户定版，仿 SideKite / iOS 26 新标签栏）：
/// 底部搜索键点开后按当前标签页搜当前菜单——App 页/源页把
/// 词同步进各自已有的 searchContext（走现成过滤），设置页
/// 按段标题过滤，模块页按文件名过滤。状态全应用一份，各
/// 页 @ObservedObject 订它；切标签页时 LCTabView 清关键词
/// （新页面重新搜），取消则全清。呈现分两条路：iOS 26+ 用
/// 系统搜索标签（rootTabs），以下用浮动键+胶囊框（旧路）。
final class CZFSearchCenter: ObservableObject {
    static let shared = CZFSearchCenter()
    @Published var isActive = false
    @Published var query = ""
    // 最近一次的内容标签（非搜索）：选中值变成 .search 后
    // 搜索标签内容靠它镜像进搜索前的那一页。
    var lastContentTab: LCTabIdentifier = .apps
    private init() {}
}

/// 标记「本页正嵌在 iOS 26 搜索标签里」：嵌着时页面关掉
/// 自己的搜索栏（系统搜索框接管，词经 CZFSearchCenter
/// 同步进来照常过滤），不在搜索标签里时一切照旧。
private struct CZFInSearchTabKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var czfInSearchTab: Bool {
        get { self[CZFInSearchTabKey.self] }
        set { self[CZFInSearchTabKey.self] = newValue }
    }
}

extension View {
    /// 可关版 searchable：disabled 时原样返回（给嵌在搜索
    /// 标签里的页面用），否则挂上搜索栏。
    @ViewBuilder func czfSearchable(text: Binding<String>, placement: SearchFieldPlacement, disabled: Bool) -> some View {
        if disabled {
            self
        } else {
            self.searchable(text: text, placement: placement)
        }
    }
}

/// iOS 26 搜索标签的内容：就是当前页本身（按 selectedTab
/// 取同一页），系统搜索框绑定 CZFSearchCenter.query，各页
/// 已有的 onChange 同步把词带进各自过滤，效果与在原页搜
/// 一致；出现/消失同步 isActive（各页靠它决定同步与清理）。
@available(iOS 26.0, *)
private struct CZFSearchTabContent: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var globalSearch = CZFSearchCenter.shared

    // 镜像目标：选中值是 .search 时按上一个内容标签，
    // 否则就是当前标签本身。
    private var effectiveTab: LCTabIdentifier {
        sharedModel.selectedTab == .search ? globalSearch.lastContentTab : sharedModel.selectedTab
    }

    var body: some View {
        Group {
            switch effectiveTab {
            case .sources:
                LCSourcesView()
            case .apps:
                LCAppListView()
            case .tweaks:
                LCTweaksView()
            case .settings, .vpn:
                LCSettingsView()
            case .search:
                LCAppListView()
            }
        }
        .environment(\.czfInSearchTab, true)
        .searchable(text: $globalSearch.query)
        .onAppear { globalSearch.isActive = true }
        .onDisappear { globalSearch.isActive = false }
    }
}

struct LCTabView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject var downloadHelper = DownloadHelper()
    @ObservedObject private var globalSearch = CZFSearchCenter.shared
    @FocusState private var searchFieldFocused: Bool
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
        .onChange(of: sharedModel.selectedTab) { newTab in
            // 记住最后一个内容标签，搜索标签靠它镜像页面。
            if newTab != .search {
                globalSearch.lastContentTab = newTab
            }
            // 换页重新搜：关键词不带去新页面，占位与过滤
            // 都按新页面走；搜索框保持开着。
            if globalSearch.isActive {
                globalSearch.query = ""
            }
        }
        .onAppear {
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
        .downloadAlert(helper: downloadHelper)
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
    
    // 根标签栏，两条路（用户定版「就像 iOS 26 新标签栏那样」）：
    // iOS 26+ 用系统新标签栏：Tab 新 API + 一个 role 为 search
    // 的搜索标签——标签栏右侧自带独立圆形搜索键，点开后搜索
    // 框浮在键盘上方（与用户图片一致），内容是当前页本身
    // （CZFSearchTabContent），词走 CZFSearchCenter 同步过滤。
    // iOS 26 以下没有这个 API，沿用旧标签栏 + 浮动搜索键 +
    // 底部胶囊搜索框那套。VPN 标签两条路都不再有（入口在
    // 设置页「代理设置」），LCTabIdentifier.vpn 枚举留着不动，
    // 免得旧的选中标签值对不上号。
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
                Tab("搜索", systemImage: "magnifyingglass", value: LCTabIdentifier.search, role: .search) {
                    CZFSearchTabContent()
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
            .overlay(alignment: .bottomTrailing) {
                globalSearchButton
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                globalSearchBar
            }
            .onChange(of: globalSearch.isActive) { active in
                if active {
                    searchFieldFocused = true
                }
            }
        }
    }

    // 底部圆形搜索键（iOS 26 以下的旧路）：浮在标签栏上方
    // 右侧，不挡任何标签的点击。
    @ViewBuilder private var globalSearchButton: some View {
        if !globalSearch.isActive {
            Button {
                globalSearch.isActive = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .background {
                        Circle()
                            .fill(Color(UIColor.secondarySystemBackground))
                            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
                    }
                    .overlay {
                        Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, 92)
        }
    }

    // 点开后浮出的搜索框（仿图片：胶囊条 + 右侧取消），
    // 挂底部安全区：键盘起来时贴在键盘上方，没键盘时
    // 停在标签栏上方。
    @ViewBuilder private var globalSearchBar: some View {
        if globalSearch.isActive {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(globalSearchPlaceholder, text: $globalSearch.query)
                    .focused($searchFieldFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !globalSearch.query.isEmpty {
                    Button {
                        globalSearch.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button("取消") {
                    closeGlobalSearch()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background {
                Capsule()
                    .fill(Color(UIColor.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 3)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private var globalSearchPlaceholder: String {
        // .search 只在 iOS 26 搜索标签下出现，那条路不用这个
        // 占位文案；真遇到时按上一个内容标签取，保持穷尽。
        let tab = sharedModel.selectedTab == .search ? globalSearch.lastContentTab : sharedModel.selectedTab
        switch tab {
        case .sources: return "搜索源"
        case .apps: return "搜索 App"
        case .tweaks: return "搜索模块"
        case .settings, .vpn: return "搜索设置"
        case .search: return "搜索 App"
        }
    }

    private func closeGlobalSearch() {
        globalSearch.query = ""
        globalSearch.isActive = false
        searchFieldFocused = false
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

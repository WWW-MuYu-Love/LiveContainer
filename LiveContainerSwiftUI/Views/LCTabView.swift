//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI

/// 全局搜索中枢（用户定版）：底部圆形搜索键点开后，胶囊
/// 搜索框浮在键盘上方、停留在当前页内搜当前菜单——App 页/
/// 源页把词同步进各自已有的 searchContext（走现成过滤），
/// 设置页按段标题过滤，模块页按文件名过滤。状态全应用一
/// 份，各页 @ObservedObject 订它；切标签页时 LCTabView 清
/// 关键词（新页面重新搜），取消则全清。呈现全系统统一走
/// 浮动键+胶囊框（原 iOS 26 系统搜索标签那条路用户不要：
/// 它会切去一个镜像页，不是视频里那种当前页浮框样式）。
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
            // 搜索标签已去掉：旧版本残留的 .search 选中值没有
            // 标签可落，回落到上一个内容标签，免得白屏。
            if sharedModel.selectedTab == .search {
                sharedModel.selectedTab = globalSearch.lastContentTab
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
    
    // 根标签栏：iOS 26+ 用系统新标签栏（Tab 新 API），以下
    // 用旧标签栏；搜索两条路统一为浮动圆形键 + 底部胶囊框
    // （用户看视频定版的样式：停留在当前页、框浮在键盘上
    // 方）。原 iOS 26 的系统搜索标签会切去镜像页，用户不要，
    // 已去掉。「代理」是独立标签（LCTabIdentifier.vpn），
    // 在设置左手边，多开副容器时不显示。
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
                if DataManager.shared.model.multiLCStatus != 2 {
                    Tab("代理", systemImage: "network", value: LCTabIdentifier.vpn) {
                        LCVPNView()
                    }
                }
                Tab("lc.tabView.settings".loc, systemImage: "gearshape.fill", value: LCTabIdentifier.settings) {
                    LCSettingsView()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                globalSearchButton
            }
            .overlay {
                // 搜索开着时，点页面其他任何地方：键盘与
                // 搜索栏一起收起（用户定）。透明层只接点
                // 按，滚动拖动照常穿透到底下页面；底部让
                // 出搜索栏 + 标签栏的高度，那片不归它管
                // （取消钮、输入框、标签照常可点）。
                if globalSearch.isActive {
                    Color.clear
                        .contentShape(Rectangle())
                        .padding(.bottom, 140)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                closeGlobalSearch()
                            }
                        )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                globalSearchBar
            }
            .onChange(of: globalSearch.isActive) { active in
                if active {
                    searchFieldFocused = true
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
                if DataManager.shared.model.multiLCStatus != 2 {
                    LCVPNView()
                        .tabItem {
                            Label("代理", systemImage: "network")
                        }
                        .tag(LCTabIdentifier.vpn)
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
            .overlay {
                // 搜索开着时，点页面其他任何地方：键盘与
                // 搜索栏一起收起（用户定）。透明层只接点
                // 按，滚动拖动照常穿透到底下页面；底部让
                // 出搜索栏 + 标签栏的高度，那片不归它管
                // （取消钮、输入框、标签照常可点）。
                if globalSearch.isActive {
                    Color.clear
                        .contentShape(Rectangle())
                        .padding(.bottom, 140)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                closeGlobalSearch()
                            }
                        )
                }
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

    // 圆形搜索键与标签栏的对齐：iOS 26 的标签栏是浮动胶
    // 囊，搜索键与它同高并排——直径就取胶囊高（用户截图
    // 实测约 63pt），底边与胶囊底边对齐即圆心对齐（此
    // 前 52 直径 + 36 间距，键又小又骑在胶囊右上角）。
    // 旧标签栏是全宽贴底，键浮在它上方（92 不变）。
    private var searchButtonBottomPadding: CGFloat {
        if #available(iOS 26.0, *) { return 3 }
        return 92
    }

    // iOS 26 液态玻璃背景：系统玻璃（可交互版给按钮用，
    // 按压有玻璃回弹），旧系统退回超薄材质 + 同款阴影与
    // 描边。玻璃自带高光边缘，26 上不再叠手动阴影。
    // 泛型要约束到 InsettableShape：strokeBorder 只在
    // 它上面有，只写 Shape 编译不过（3.8.5 首构建实测）
    private struct CZFGlassBackground<S: InsettableShape>: ViewModifier {
        let shape: S
        let interactive: Bool
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                if interactive {
                    content.glassEffect(.regular.interactive(), in: shape)
                } else {
                    content.glassEffect(.regular, in: shape)
                }
            } else {
                content
                    .background {
                        shape
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 3)
                    }
                    .overlay {
                        shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    }
            }
        }
    }

    // 底部圆形搜索键：浮在标签栏右侧，不挡任何标签的点击。
    @ViewBuilder private var globalSearchButton: some View {
        if !globalSearch.isActive {
            Button {
                globalSearch.isActive = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 63, height: 63)
                    .modifier(CZFGlassBackground(shape: Circle(), interactive: true))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, searchButtonBottomPadding)
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
            .modifier(CZFGlassBackground(shape: Capsule(), interactive: false))
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }

    private var globalSearchPlaceholder: String {
        // .search 已无标签可落（搜索标签已去掉）；真遇到时按
        // 上一个内容标签取，保持 switch 穷尽。
        let tab = sharedModel.selectedTab == .search ? globalSearch.lastContentTab : sharedModel.selectedTab
        switch tab {
        case .sources: return "搜索源"
        case .apps: return "搜索 App"
        case .tweaks: return "搜索模块"
        case .settings: return "搜索设置"
        case .vpn: return "搜索"
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

// 下拉到顶唤起搜索（用户加定）：各页滚到顶后手指再往下
// 拉过门槛，就打开全局搜索——胶囊栏弹出、键盘随焦点跟上
// （与点浮动键等效）；收起仍走点旁边/取消的老路。探针是
// 个零尺寸 UIKit 视图，挂在页面根视图的背景里：逐层往
// 上找「子树里含滚动视图的最低祖先」，再在那棵子树里广
// 度优先取最浅的 UIScrollView（即页面主滚动视图），KVO
// 盯它的 contentOffset。触发要同时满足：搜索没开、手指
// 正拉着（isTracking，惯性回弹不算）、偏移越过静止位
// 55pt——只有真下拉才到得了。
struct CZFPullToSearchProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.attachIfNeeded()
    }

    final class ProbeView: UIView {
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard window != nil, observedScrollView == nil else { return }
            var ancestor: UIView? = superview
            while let node = ancestor {
                if let scroll = Self.shallowestScrollView(in: node) {
                    observedScrollView = scroll
                    observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                        self?.check(scrollView)
                    }
                    return
                }
                ancestor = node.superview
            }
        }

        private static func shallowestScrollView(in root: UIView) -> UIScrollView? {
            var queue: [UIView] = [root]
            var index = 0
            while index < queue.count {
                let view = queue[index]
                index += 1
                if let scroll = view as? UIScrollView {
                    return scroll
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }

        private func check(_ scrollView: UIScrollView) {
            guard scrollView.isTracking else { return }
            guard !CZFSearchCenter.shared.isActive else { return }
            let rest = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y < rest - 55 {
                DispatchQueue.main.async {
                    if !CZFSearchCenter.shared.isActive {
                        CZFSearchCenter.shared.isActive = true
                    }
                }
            }
        }
    }
}

extension View {
    // 给页面根视图挂下拉唤起搜索（探针见上）。
    func czfPullToSearch() -> some View {
        background(
            CZFPullToSearchProbe()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}

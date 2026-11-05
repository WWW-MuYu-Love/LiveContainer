//
//  LCVPNView.swift
//  LiveContainerSwiftUI
//
//  「代理」独立标签页（在设置左手边）：曾撤进设置页
//  做子页「代理设置」，用户定版又搬回底部标签栏并改
//  名「代理」、恢复自带导航栈。节点区按小火箭式分组：本地组（手
//  填/单个导入）+ 每订阅一组（可折叠、组头带流量/到期、
//  可单独刷新/删组），导入订阅新建组、不再整体替换。
//  顶部状态卡 + 核心起停/测速/核心选项逻辑原样保留。
//

import CoreImage
import Foundation
import LiveContainerShared
import SwiftUI

struct LCVPNView: View {
    @State var errorShow = false
    @State var errorInfo = ""
    @State var successShow = false
    @State var successInfo = ""

    @State var vpnCoreRunning = false
    @State var vpnStatusMessage: String?
    @State var vpnNewNodeText = ""
    @State var vpnSubURL: String = UserDefaults.standard.string(forKey: "CZFVPNSubscriptionURL") ?? ""
    @State var vpnSubBusy = false
    @State var vpnNodes: [String] = []
    @State var vpnGroups: [CZFVPNManager.CZFVPNNodeGroup] = []
    @State var vpnGroupBusyId: String?
    @State var groupInfoTarget: CZFVPNManager.CZFVPNNodeGroup?
    @State var showGroupInfo = false
    // 组头左滑二维码的展示目标、左滑删除的待确认组、改名
    // 弹窗的目标与输入（改名从组信息弹窗的「编辑名称」进）
    @State var groupQRTarget: CZFVPNManager.CZFVPNNodeGroup?
    @State var groupPendingDelete: CZFVPNManager.CZFVPNNodeGroup?
    @State var showGroupDeleteConfirm = false
    @State var groupRenameTarget: CZFVPNManager.CZFVPNNodeGroup?
    @State var groupRenameText = ""
    @State var showGroupRename = false
    @State var vpnHostProxy = false
    @AppStorage("CZFVPNPrewarm") var vpnPrewarm = true
    @AppStorage("CZFVPNAutoRotate") var vpnAutoRotate = true
    @AppStorage("CZFVPNAutoStopMinutes") var vpnAutoStopMinutes = 10
    @State var vpnActiveIndex = 0
    @State var vpnPingResults: [Int: CZFVPNManager.CZFNodePingResult] = [:]
    @State var vpnPingStaleIndices: Set<Int> = []
    @State var vpnSinglePinging = false
    @State var vpnSinglePingIndex: Int?
    @State var showDeleteActiveConfirm = false
    // 节点多选删除：长按行进多选（链接作键，分组/导入换列表不错位），
    // 全选/删除选中/取消在这组状态上跑，删在用节点走已有确认框。
    @State var vpnNodeSelecting = false
    // 节点点选防抖：同一节点 0.4 秒内的重复触发直接吞掉
    // （双指点、连点会把行动作重复投递，核心被反复停启
    // 有闪退风险；见 nodeRow 的点按手势）。
    @State private var lastNodeTapLink: String?
    @State private var lastNodeTapAt = Date.distantPast
    @State var vpnSelectedNodeLinks: Set<String> = []
    @State var pendingDeleteLinks: Set<String> = []
    @State var vpnPinging = false
    @State var vpnPingRejected = false
    // 单测被核心占用拒写过的节点链接（CZF，3.8.237）：
    // 核心在跑时临时探针实例起不来、测速被占用拒掉，
    // 旧值与·旧都保留、用户在行上看不出任何变化；
    // 用链接集合标记（不用下标，删/排/导都不错位），
    // 行上直接显示“核心占用”，不再让用户猜。
    // 单测成功写回时清该条、整表成功时全清；只存会话，
    // 不落盘、不参与清理/排序判定（绝不冒充测速结果）。
    @State var vpnSingleRejectedLinks: Set<String> = []
    @State var vpnPingDone = 0
    @State var vpnPingTotal = 0
    @State var vpnPingPhase = "测速"
    @State var vpnPrewarmSuppressed = false
    @State private var showVPNHelp = false
    // 有没有“默认顺序”存档（第一次延迟排序时存下）：决定
    // 默认排序按钮与批量行要不要出现。
    @State var hasDefaultOrderSnapshot = false

    /// 测完后有没有批量操作可做（切到最快/清理不通/延迟排序/
    /// 默认排序任一出现）：批量操作行只在此时才出现，平时不占一行。
    /// 清理只认网络失败——转换失败（不支持）的不算，避免只剩
    /// 不支持节点时出现一行空按钮。
    private var hasVPNBatchActions: Bool {
        vpnPingResults.contains(where: { $0.value.success && $0.key != vpnActiveIndex })
            || vpnPingResults.contains(where: { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex })
            || vpnPingResults.count > 1
            || hasDefaultOrderSnapshot
    }

    var body: some View {
        // 独立标签页「代理」（用户定版）：自带导航栈，
        // 不再借设置页推进；下面的 Form 与确认框/提示框
        // 原样，行为不变。
        NavigationView {
            formContent
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var formContent: some View {
        Form {
            statusSection
            vpnSection
        }
        .navigationBarTitle("代理")
            .alert("删除在用节点？", isPresented: $showDeleteActiveConfirm) {
                Button("删除并停核心", role: .destructive) {
                    CZFVPNManager.shared.removeNodeLinks(pendingDeleteLinks)
                    pendingDeleteLinks = []
                    vpnSelectedNodeLinks = []
                    vpnNodeSelecting = false
                    vpnPingResults = [:]
                    refreshVPNState()
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    pendingDeleteLinks = []
                }
            } message: {
                Text("删掉在用节点后核心会停掉，不会自动切到别的节点继续跑")
            }
            .alert(groupInfoTarget?.name ?? "", isPresented: $showGroupInfo) {
                if let g = groupInfoTarget, !g.isLocal {
                    // 名称处加改名入口：点它进改名弹窗，改完
                    // 同步组头卡片，且订阅刷新不覆盖（管理层
                    // 记 customName）。本弹窗先关，改名弹窗延
                    // 一拍再弹，免得两个弹窗打架。
                    Button("编辑名称") {
                        groupRenameTarget = g
                        groupRenameText = g.name
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showGroupRename = true
                        }
                    }
                    Button("删除整组", role: .destructive) {
                        deleteGroup(g)
                    }
                }
                Button("好", role: .cancel) {}
            } message: {
                Text(groupInfoTarget.map { groupDetailText($0) } ?? "")
            }
            .alert("编辑名称", isPresented: $showGroupRename) {
                TextField("名称", text: $groupRenameText)
                Button("保存") {
                    saveGroupRename()
                }
                Button("lc.common.cancel".loc, role: .cancel) {}
            } message: {
                Text("改完同步到订阅卡片上，之后刷新订阅也不会被覆盖")
            }
            .alert("删除订阅组", isPresented: $showGroupDeleteConfirm) {
                Button("删除整组", role: .destructive) {
                    if let g = groupPendingDelete {
                        deleteGroup(g)
                    }
                    groupPendingDelete = nil
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    groupPendingDelete = nil
                }
            } message: {
                Text(groupPendingDelete.map { "「\($0.name)」及其 \($0.links.count) 个节点会被删除" } ?? "")
            }
            .sheet(item: $groupQRTarget) { group in
                groupQRCodeSheet(group)
            }
            .alert("lc.common.error".loc, isPresented: $errorShow){
            } message: {
                Text(errorInfo)
            }
            .alert("lc.common.success".loc, isPresented: $successShow){
            } message: {
                Text(successInfo)
            }
        // 切回前台刷新核心状态：核心在后台被自动停、被别的
        // App 起停后，设置页按钮还是旧状态，下一按钮一刷新
        // 才翻出来、看起来像那个按钮切的；切回前台就刷新，
        // 按钮先对上真实状态。测速中刷新不翻核心按钮（见
        // refreshVPNState 里的测速中守卫），不会打断测速。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshVPNState()
        }
    }

    // MARK: - 顶部状态卡：一眼看清核心在跑没、在用哪个节点
    @ViewBuilder private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((vpnCoreRunning ? Color.green : Color.gray).opacity(0.15))
                        .frame(width: 46, height: 46)
                    Image(systemName: vpnCoreRunning ? "shield.fill" : "shield")
                        .font(.system(size: 22))
                        .foregroundStyle(vpnCoreRunning ? Color.green : Color.gray)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(vpnCoreRunning ? "核心运行中" : "核心未启动")
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Circle()
                    .fill(vpnCoreRunning ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 10, height: 10)
            }
            .padding(.vertical, 4)
        }
    }

    private var statusSubtitle: String {
        if vpnNodes.indices.contains(vpnActiveIndex) {
            return "在用节点：" + CZFVPNManager.nodeDisplay(for: vpnNodes[vpnActiveIndex]).name
        }
        return vpnNodes.isEmpty ? "还没有节点，先添加或导入订阅" : (vpnStatusMessage ?? "点下方启动核心开始使用")
    }

    @ViewBuilder private var vpnSection: some View {
        Section {
            VStack(spacing: 8) {
                HStack {
                    TextField("粘贴节点链接（vless://…）", text: $vpnNewNodeText)
                        .textInputAutocapitalization(.never)
                    Button("添加") {
                        // 重复添加不再静默：addNode 返回 false
                        // 时提示已存在，输入框留着、不清结果。
                        // 手填节点自动归本地组（分组靠管理器读
                        // 时校准，见 nodeGroups()）。
                        if CZFVPNManager.shared.addNode(vpnNewNodeText) {
                            vpnNewNodeText = ""
                            vpnPingResults = [:]
                            refreshVPNState()
                        } else {
                            errorInfo = "节点已存在，未重复添加"
                            errorShow = true
                        }
                    }
                    .disabled(vpnNewNodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vpnPinging || vpnSinglePinging)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                Divider()
            }
            .listRowSeparator(.hidden)
            VStack(spacing: 8) {
                HStack {
                    TextField("粘贴订阅地址（https://…）", text: $vpnSubURL)
                        .textInputAutocapitalization(.never)
                    Button(vpnSubBusy ? "拉取中…" : "导入订阅") {
                        importSubscription()
                    }
                    .disabled(vpnSubBusy || vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vpnPinging || vpnSinglePinging)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                Divider()
            }
            .listRowSeparator(.hidden)
            HStack {
                // 测延迟与启动/停止核心已对调位置（用户定）：
                // 测延迟在前，核心开关在后。
                Button(vpnPinging ? (vpnPingTotal > 0 ? "\(vpnPingPhase) \(vpnPingDone)/\(vpnPingTotal)" : "测速中…") : "测延迟") {
                    startVPNPing()
                }
                .disabled(vpnPinging || vpnSinglePinging || vpnNodes.isEmpty)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                Button(vpnCoreRunning ? "停止核心" : "启动核心") {
                    CZFVPNManager.shared.noteManualCoreToggle(started: !vpnCoreRunning)
                    if vpnCoreRunning {
                        CZFVPNManager.shared.stop()
                    } else {
                        _ = CZFVPNManager.shared.start()
                    }
                    refreshVPNState()
                }
                // 测速中置灰：测速中亲手起停核心会和测速
                // 的 deferred 逻辑插队，状态容易翻；测速
                // 本身又不切核心，测速中起停没有意义，
                // 测完再点。
                .disabled(vpnPinging || vpnSinglePinging)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(vpnCoreRunning ? .red : .blue)
                Spacer()
            }
            .onAppear {
                hasDefaultOrderSnapshot = !Self.loadDefaultOrderMap().isEmpty
                refreshVPNState()
            }
            // 测完后的批量操作单独放一行：原来启动/测延迟/
            // 切最快/清理/排序/被拒提示/状态全挤在一行，
            // 按钮一多就互相挤压截断；拆开后主操作行永远
            // 只有两个按钮加状态，批量行只在有操作时出现。
            if hasVPNBatchActions {
            HStack {
                // 测完后一键切到最快的（只认测通的节点；
                // 已经是最快时不显示，省得误会）
                if let fastest = vpnPingResults.filter({ $0.value.success }).min(by: { $0.value.delay < $1.value.delay }), fastest.key != vpnActiveIndex {
                    Button("切到最快") {
                        CZFVPNManager.shared.setActiveNode(at: fastest.key)
                        refreshVPNState()
                    }
                    .disabled(vpnPinging || vpnSinglePinging)
                    .buttonStyle(.borderless)
                }
                // 测完后一键清理不通的节点：只删明确测
                // 出网络不通的、且不是当前在用节点的——在用
                // 节点即使某次测速失败也不删（核心在跑且
                // 实际上网是更强的证据，见上面「在用」
                // 的例外）；转换失败（不支持）的也不删——
                // 它们不是网络不通，删了等于删协议，留着等
                // 换协议或走原始 JSON 出站绕法。按链接删，
                // 分组自动跟上；清理不碰核心：在用节点不
                // 在删除集里，核心在跑继续用它、停着继续停着。
                if vpnPingResults.contains(where: { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex }) {
                    Button("清理不通") {
                        let failedLinks = Set(vpnPingResults.filter { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex }.compactMap { vpnNodes.indices.contains($0.key) ? vpnNodes[$0.key] : nil })
                        CZFVPNManager.shared.removeNodeLinks(failedLinks)
                        vpnNodes = CZFVPNManager.shared.nodeLinks
                        vpnPingResults = [:]
                        savePingResults()
                        refreshVPNState()
                    }
                    // 被拒时不再禁清理：被拒结果已不再覆写
                    // 界面和缓存，清理按上次真测结果走；
                    // 测速中仍禁，免得按还没重试完的临时
                    // 失败删节点。
                    .disabled(vpnPinging || vpnSinglePinging)
                    .buttonStyle(.borderless)
                }
                // 测完后按延迟从低到高重排：分组后只在
                // 各组内部排序（不通的沉底、没测到的最后），
                // 在用节点在自己组内固定原位不动、只排其余——
                // 跨组搬家会打乱订阅归属；在用节点按内容
                // 跟随、不重启核心。
                if vpnPingResults.count > 1 {
                    Button("延迟排序") {
                        snapshotDefaultOrderIfNeeded()
                        sortGroupsByPing()
                    }
                    .disabled(vpnPinging || vpnSinglePinging)
                    .buttonStyle(.borderless)
                }
                // 默认排序（与延迟排序成对，用户定）：恢复成
                // 延迟排序之前的组内顺序；之后新加的节点按
                // 当前相对顺序接在后面，不删不丢。
                if hasDefaultOrderSnapshot {
                    Button("默认排序") {
                        restoreDefaultOrder()
                    }
                    .disabled(vpnPinging || vpnSinglePinging)
                    .buttonStyle(.borderless)
                }
            }
            }
            // 被拒提示独立一行：原来它和一串按钮挤在同一行，
            // 长文字把按钮全挤没了；单独一行文字自然换行，
            // 按钮放下面一行，不再抢宽度。
            if vpnPingRejected && !vpnPinging {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上次测速被在跑的核心占用，结果没更新：先停核心再测更准，清理/排序按上次真测结果")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    // startVPNPing 已包办停核心→测速→重启，
                    // 这里不用再手动 stop（原来两处停逻辑漂移）。
                    Button("停核心重测") {
                        startVPNPing()
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("节点管理")
        }
        // 分组：本地组 + 每订阅一组，各自一个 Section，
        // 组头可折叠、订阅组带流量/到期与刷新/信息。
        ForEach(vpnGroups) { group in
            groupSection(group)
        }
        // 多选删除操作条：只在长按进多选后出现（独立成段，
        // 不再挤在节点行之间）；全选按链接集合算，
        // 删选中走 deleteSelectedVPNNodeLinks（在用节点走确认框）。
        if vpnNodeSelecting {
            Section {
                HStack {
                    Button(vpnSelectedNodeLinks == Set(vpnNodes) && !vpnNodes.isEmpty ? "取消全选" : "全选") {
                        if vpnSelectedNodeLinks == Set(vpnNodes) {
                            vpnSelectedNodeLinks = []
                        } else {
                            vpnSelectedNodeLinks = Set(vpnNodes)
                        }
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("删除选中 (\(vpnSelectedNodeLinks.count))") {
                        deleteSelectedVPNNodeLinks()
                    }
                    .disabled(vpnSelectedNodeLinks.isEmpty)
                    .foregroundStyle(Color.red)
                    .buttonStyle(.borderless)
                    Button("取消") {
                        vpnNodeSelecting = false
                        vpnSelectedNodeLinks = []
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        Section {
            Toggle(isOn: $vpnPrewarm) {
                HStack {
                    // 只动这两处图标观感：底色统一降到 0.85 不透明度，
                    // 橙/绿区分保留但不再刺眼；LCSettingsIcon 本体不动，
                    // 其他行的图标不受影响。尺寸 30pt、圆角、15pt
                    // semibold 白字仍走共用组件，不改布局。
                    LCSettingsIcon(systemName: "flame.fill", color: .orange.opacity(0.85))
                    Text("打开时预热节点核心")
                }
            }
            .onChange(of: vpnPrewarm) { _ in
                // 亲手拨一次预热开关：清掉测速后的预热抑制，
                // 之后预热照常工作；拨开关本身不动核心状态。
                CZFVPNManager.shared.notePrewarmSwitchToggled()
                refreshVPNState()
            }
            // 预热抑制可见：开关开着、测速后核心停着时，
            // 预热其实被压着不工作，以前界面上看不出，
            // 用户只会以为预热坏了；现在把状态说出来。
            if vpnPrewarmSuppressed && vpnPrewarm && !vpnCoreRunning {
                Text("测速后预热已暂停：拨一次预热开关可恢复")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Toggle(isOn: $vpnAutoRotate) {
                HStack {
                    LCSettingsIcon(systemName: "arrow.triangle.2.circlepath", color: .blue.opacity(0.85))
                    Text("节点自动轮换")
                }
            }
            .onChange(of: vpnAutoRotate) { newValue in
                CZFVPNManager.setAutoRotate(newValue)
                refreshVPNState()
            }
            Toggle(isOn: $vpnHostProxy) {
                HStack {
                    // 原来是 arrow.down.circle：带圈轮廓的符号在实心
                    // 圆底上显得又小又淡，跟 flame.fill 的实心符号
                    // 不是一套。换成无圈的 arrow.down，同样 15pt
                    // 白字实心圆底，两行符号粗细、视觉分量一致。
                    LCSettingsIcon(systemName: "arrow.down", color: .green.opacity(0.85))
                    Text("源和下载也走内置节点")
                }
            }
                .onChange(of: vpnHostProxy) { newValue in
                    CZFVPNManager.isHostProxyEnabled = newValue
                    if newValue {
                        CZFVPNManager.shared.ensureRunningForHost()
                    }
                    refreshVPNState()
                }
            Picker(selection: $vpnAutoStopMinutes) {
                Text("5 分钟").tag(5)
                Text("10 分钟").tag(10)
                Text("30 分钟").tag(30)
            } label: {
                HStack {
                    LCSettingsIcon(systemName: "timer", color: .red.opacity(0.85))
                    Text("核心关闭后自动停")
                }
            }
        } header: {
            Text("核心选项")
        } footer: {
            // 原来这里是一整段 400 多字说明，常驻占十几行。
            // 改成默认只剩一行入口，点开才看精简版：关键意思
            // 都还在（切换/删除、订阅分组、测速、开 VPN、预热、
            // 源下载走节点、自动停、最小化不算关），但平时
            // 设置页不再被这段顶下去。
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    showVPNHelp.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("VPN 说明")
                        Image(systemName: showVPNHelp ? "chevron.up" : "chevron.down")
                    }
                }
                .font(.footnote)
                .buttonStyle(.plain)
                if showVPNHelp {
                    Text("点节点行切换（核心在跑时立即生效），左滑删除；节点按组管理：手填/单个导入的在「本地节点」组，每个订阅是一个组，导入新订阅新建组、重导同一订阅刷新该组，组头可折叠，订阅组可单独刷新或整组删除。\n测延迟是真实请求往返毫秒数，不切换核心，通的节点先显示；测延迟会在核心在跑时先停核心、测完重启原来那条；核心没在跑时直接测、不启动。\n给 App 开 VPN：去该 App 设置页打开「VPN 打开（内置节点）」；标记的 App 打开时核心自启，全部关掉后按上面分钟数自停，期间重开会取消这次自停。\n预热开着进 App 就先热好核心；源和下载走节点只对境外源有用。\n最小化不算关，核心继续跑。\n节点行会显示协议（vless/vmess/trojan/ss/socks/hysteria2/tuic/anytls 等）；核心（sing-box）只认这几类，未列出的链接会标“不支持”——不是网络不通，“清理不通”不会删它们。\n绕法：可以把出站写成原始 sing-box 出站 JSON 当节点粘贴，名字会显示成“节点”；测速与启动都走同一套配置生成，JSON 节点同样能测。注意：老 Xray 格式的 JSON 不再适用。\n节点自动轮换开着时，核心在跑的 App 连续失败就自动按列表顺序换下一个支持的节点并重启核心，一圈都不通就停下来等手动处理。")
                }
            }
        }
    }

    // MARK: - 分组段：组头（折叠/组名/流量到期/刷新/信息）+ 组内节点行

    @ViewBuilder private func groupSection(_ group: CZFVPNManager.CZFVPNNodeGroup) -> some View {
        Section {
            // 组头是段内第一行（不再用 section header）：
            // header 的系统内边距比行大一圈，卡片会比下面
            // 的节点卡短一截、中间还隔着系统间距——用户实
            // 图指出边框一长一短、一个订阅被拆成两张卡。
            // 组头进段后与节点同卡同宽、上下紧贴无留空。
            groupHeader(group)
            if !group.collapsed {
                if group.links.isEmpty {
                    Text(group.isLocal ? "暂无本地节点：粘贴链接添加，或导入订阅" : "暂无节点，点组头刷新按钮拉取")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(group.links, id: \.self) { link in
                    nodeRow(link: link)
                }
                .onDelete { offsets in
                    // 测速中左滑也禁删：.disabled 不一定挡得住
                    // List 的左滑删除，动作里再守一次，免得
                    // 测速中列表变了、结果下标错位。
                    guard !vpnPinging && !vpnSinglePinging else { return }
                    // 删在用节点先弹确认：manager 侧删在用
                    // 节点已改成停核心不自动切，界面再确认
                    // 一次，免得左滑手误把在用节点删了。
                    let links = offsets.map { group.links[$0] }
                    if vpnNodes.indices.contains(vpnActiveIndex), links.contains(vpnNodes[vpnActiveIndex]) {
                        pendingDeleteLinks = Set(links)
                        showDeleteActiveConfirm = true
                    } else {
                        CZFVPNManager.shared.removeNodeLinks(Set(links))
                        vpnPingResults = [:]
                        refreshVPNState()
                    }
                }
                // 测速中节点行置灰：测速中点节点行只会把勾
                // 先动、核心切换被挡下测完才补跑，看起来
                // 像切了其实还没切；置灰后测速中点不动，
                // 测完再点才是真切。单节点复测同理。
                .disabled(vpnPinging || vpnSinglePinging)
            }
        }
    }

    @ViewBuilder private func groupHeader(_ group: CZFVPNManager.CZFVPNNodeGroup) -> some View {
        // 组头即按钮（照小火箭）：组头行就是段卡的第一行，
        // 与节点同卡、同宽、紧贴无留空。布局：左大箭头，
        // 中间一列组名 + 紧贴其下的信息行（流量/到期，对
        // 齐组名不缩进到箭头下），右侧刷新/信息两颗 19 号
        // 钮贴右并排。整行高约 48：无信息行的本地组用
        // minHeight 36 撑到同高，与订阅组卡片大小一致。
        // 点行身（除两颗钮）展开/收起。左右滑（仅订阅
        // 组）：右滑测试（=只测本组延迟）/更新，左滑二维
        // 码/删除，与节点行的滑动同一套。
        HStack(spacing: 8) {
            // 三角不换图（与源卡片头同一个坑、同一个修法）：
            // chevron.right/down 本宽不同，换图瞬间组名整列
            // 被顶得左右移；固定一颗右箭头在定宽框里原地
            // 旋转 90°，展开收起布局纹丝不动。
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // 订阅组信息行：流量与到期，紧挨组名（同列
                // 第二行，不再隔着按钮行高留空）。
                if group.upload != nil || group.download != nil || group.total != nil || group.expire != nil {
                    groupInfoLine(group)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !group.isLocal {
                if vpnGroupBusyId == group.id {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                } else {
                    Button {
                        refreshGroup(group)
                    } label: {
                        // 与最右信息圆圈同为 19 号（用户定：
                        // 两颗一样大），点击区 30 见方。
                        Image(systemName: "arrow.2.circlepath")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(vpnPinging || vpnSinglePinging || vpnGroupBusyId != nil)
                }
            }
            Button {
                groupInfoTarget = group
                showGroupInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(.blue)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            CZFVPNManager.shared.setGroupCollapsed(id: group.id, collapsed: !group.collapsed)
            refreshVPNState()
        }
        .frame(minHeight: 36)
        // 行内边距与节点行同宽对齐（左右 16），段卡即它
        // 的边框，不再自带圆角卡背景。
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !group.isLocal {
                Button {
                    startGroupPing(group)
                } label: {
                    Label("测试", systemImage: "speedometer")
                }
                .tint(.green)
                .disabled(vpnPinging || vpnSinglePinging || vpnGroupBusyId != nil)
                Button {
                    refreshGroup(group)
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .tint(.gray)
                .disabled(vpnPinging || vpnSinglePinging || vpnGroupBusyId != nil)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !group.isLocal {
                Button(role: .destructive) {
                    groupPendingDelete = group
                    showGroupDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    groupQRTarget = group
                } label: {
                    Label("二维码", systemImage: "qrcode")
                }
                .tint(.gray)
            }
        }
    }

    // 组头信息行：↑已用 ↓已用 · 共总量 · 到期日，有哪项显哪项
    private func groupInfoLine(_ group: CZFVPNManager.CZFVPNNodeGroup) -> Text {
        var parts: [Text] = []
        if let u = group.upload {
            parts.append(Text("\(Image(systemName: "arrow.up")) \(fmtBytes(u))"))
        }
        if let d = group.download {
            parts.append(Text("\(Image(systemName: "arrow.down")) \(fmtBytes(d))"))
        }
        if let t = group.total {
            parts.append(Text("共 \(fmtBytes(t))"))
        }
        if let e = group.expire {
            parts.append(Text("\(expireText(e)) 到期"))
        }
        var result = Text("")
        for (i, p) in parts.enumerated() {
            if i > 0 { result = result + Text(" · ") }
            result = result + p
        }
        return result
    }

    private func expireText(_ ts: TimeInterval) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date(timeIntervalSince1970: ts))
    }

    private func fmtBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            let s = String(format: gb >= 100 ? "%.0f" : "%.1f", gb)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + " GB"
        }
        let mb = Double(bytes) / 1_048_576
        if mb >= 0.1 {
            let s = String(format: "%.1f", mb)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + " MB"
        }
        return "\(bytes) B"
    }

    // 组信息弹窗正文（节点数/来源/流量/到期）
    private func groupDetailText(_ group: CZFVPNManager.CZFVPNNodeGroup) -> String {
        var lines = ["节点数：\(group.links.count)"]
        if let url = group.sourceURL {
            lines.append("订阅地址：\(url)")
        } else {
            lines.append("手动添加的节点都在这个组里")
        }
        var traffic: [String] = []
        if let u = group.upload { traffic.append("上传 \(fmtBytes(u))") }
        if let d = group.download { traffic.append("下载 \(fmtBytes(d))") }
        if let t = group.total { traffic.append("总量 \(fmtBytes(t))") }
        if !traffic.isEmpty {
            lines.append("流量：" + traffic.joined(separator: " · "))
        }
        if let e = group.expire {
            lines.append("到期：\(expireText(e))")
        }
        return lines.joined(separator: "\n")
    }

    // 单个节点行：扁平下标按链接内容现查（分组重排/导入
    // 换组都不错位），行内动作与分组前完全一致。
    @ViewBuilder private func nodeRow(link: String) -> some View {
        let index = vpnNodes.firstIndex(of: link) ?? -1
        // 行点击不用 Button：Button 与 onLongPressGesture 同
        // 挂一行时，List 的手势仲裁会把轻点也先喂给长按识
        // 别器，点选直接失效（3.8.3 分组改版引入长按多选
        // 后用户实测点节点选不中）。改成内容视图 + 点按/
        // 长按双手势：轻点是点选、按住 0.5 秒进多选，系统
        // 自己仲裁，两边都稳。测速中置灰仍靠段上的
        // .disabled（对手势同样生效）。
        HStack(spacing: 8) {
            if vpnNodeSelecting {
                Image(systemName: vpnSelectedNodeLinks.contains(link) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(vpnSelectedNodeLinks.contains(link) ? Color.blue : Color.secondary)
            }
            CZFVPNNodeLabel(
                link: link,
                ping: index >= 0 ? vpnPingResults[index] : nil,
                isActive: index >= 0 && index == vpnActiveIndex,
                coreRunning: vpnCoreRunning,
                pinging: vpnPinging,
                isSinglePingTarget: index >= 0 && vpnSinglePingIndex == index,
                isRejected: vpnSingleRejectedLinks.contains(link),
                isStale: index >= 0 && vpnPingStaleIndices.contains(index)
            )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if vpnNodeSelecting {
                if vpnSelectedNodeLinks.contains(link) {
                    vpnSelectedNodeLinks.remove(link)
                } else {
                    vpnSelectedNodeLinks.insert(link)
                }
            } else if index >= 0 {
                // 同一节点 0.4 秒内的第二次触发（双指/连点
                // 的重复投递）不重复切核心，直接吞掉。
                let now = Date()
                if lastNodeTapLink == link, now.timeIntervalSince(lastNodeTapAt) < 0.4 {
                    return
                }
                lastNodeTapLink = link
                lastNodeTapAt = now
                CZFVPNManager.shared.setActiveNode(at: index)
                refreshVPNState()
            }
        }
        // 长按行进多选删除：原来长按菜单的复测与右滑
        // 测速同一入口（startSinglePing），复测仍可右滑；
        // 长按现在进多选，点行勾选、全选、删除选中。
        .onLongPressGesture {
            if !vpnNodeSelecting {
                vpnNodeSelecting = true
            }
            vpnSelectedNodeLinks.insert(link)
        }
        // 右滑测速：整表测速太慢时只测这一条，
        // 与原长按复测同一入口；左滑删除不动。
        // allowsFullSwipe 关掉：测速要占 isPinging、
        // 挡核心切换，滑满就触发太容易误触。
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                if index >= 0 {
                    startSinglePing(index)
                }
            } label: {
                Label("测速", systemImage: "speedometer")
            }
            .tint(.blue)
            .disabled(vpnPinging || vpnSinglePinging)
        }
    }

    /// 订阅导入：新建组或刷新同地址的组（不再整体替换，
    /// 别的组与手填节点不动）；名字对回也在拉取里完成。
    func importSubscription() {
        vpnSubBusy = true
        let url = vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        CZFVPNManager.fetchSubscription(urlString: vpnSubURL) { result in
            DispatchQueue.main.async {
                vpnSubBusy = false
                switch result {
                case .success(let fetch):
                    let r = CZFVPNManager.shared.upsertSubscriptionGroup(url: url, fetch: fetch)
                    UserDefaults.standard.set(url, forKey: "CZFVPNSubscriptionURL")
                    vpnPingResults = [:]
                    refreshVPNState()
                    successInfo = r.isNew
                        ? "已导入订阅「\(r.name)」：\(r.count) 个节点（新建分组）"
                        : "订阅「\(r.name)」已刷新：\(r.count) 个节点"
                    successShow = true
                case .failure(let error):
                    errorInfo = error.localizedDescription
                    errorShow = true
                }
            }
        }
    }

    /// 单独刷新一个订阅组（组头刷新按钮）。
    func refreshGroup(_ group: CZFVPNManager.CZFVPNNodeGroup) {
        guard let url = group.sourceURL, vpnGroupBusyId == nil else { return }
        vpnGroupBusyId = group.id
        CZFVPNManager.fetchSubscription(urlString: url) { result in
            DispatchQueue.main.async {
                vpnGroupBusyId = nil
                switch result {
                case .success(let fetch):
                    let r = CZFVPNManager.shared.upsertSubscriptionGroup(url: url, fetch: fetch)
                    vpnPingResults = [:]
                    refreshVPNState()
                    successInfo = "「\(r.name)」已刷新：\(r.count) 个节点"
                    successShow = true
                case .failure(let error):
                    errorInfo = error.localizedDescription
                    errorShow = true
                }
            }
        }
    }

    /// 删整组（组信息弹窗里的危险按钮）。
    func deleteGroup(_ group: CZFVPNManager.CZFVPNNodeGroup) {
        CZFVPNManager.shared.deleteSubscriptionGroup(id: group.id)
        vpnPingResults = [:]
        refreshVPNState()
        successInfo = "已删除分组「\(group.name)」及其节点"
        successShow = true
    }

    // 组头右滑「测试」：只测这一组的节点，规则与全量测
    // 速一致（核心在跑先停、测完重启原来那条、被拒不覆
    // 写旧结果）；结果按扁平下标合并进结果表并逐条落缓
    // 存，其他组的结果不动。
    func startGroupPing(_ group: CZFVPNManager.CZFVPNNodeGroup) {
        guard !vpnPinging && !vpnSinglePinging && vpnGroupBusyId == nil else { return }
        let indices = group.links.compactMap { vpnNodes.firstIndex(of: $0) }
        guard !indices.isEmpty else { return }
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnPinging = true
        vpnPingRejected = false
        vpnPingDone = 0
        vpnPingTotal = indices.count
        vpnPingPhase = "测速"
        CZFVPNManager.shared.pingNodes(atIndices: indices, onProgress: { done, total, phase in
            vpnPingDone = done
            vpnPingTotal = total
            vpnPingPhase = phase
        }) { pairs, rejected in
            if rejected {
                vpnPingRejected = true
            } else {
                for (idx, r) in pairs where vpnNodes.indices.contains(idx) {
                    vpnPingResults[idx] = r
                    vpnPingStaleIndices.remove(idx)
                    vpnSingleRejectedLinks.remove(vpnNodes[idx])
                    savePingResult(link: vpnNodes[idx], result: r)
                }
                vpnPingRejected = false
            }
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            vpnPinging = false
            vpnPingDone = 0
            vpnPingTotal = 0
            refreshVPNState()
        }
    }

    // 改名保存：落到管理层记自定义名，组头卡片立即同步，
    // 订阅刷新沿用新名不覆盖；信息弹窗的目标也跟着换新。
    func saveGroupRename() {
        guard let g = groupRenameTarget else { return }
        CZFVPNManager.shared.renameGroup(id: g.id, name: groupRenameText)
        refreshVPNState()
        if groupInfoTarget?.id == g.id {
            groupInfoTarget = vpnGroups.first(where: { $0.id == g.id }) ?? groupInfoTarget
        }
        groupRenameTarget = nil
    }

    // 组头左滑「二维码」面板：订阅地址的二维码（别人扫
    // 了直接导入）+ 地址原文 + 系统分享。
    @ViewBuilder private func groupQRCodeSheet(_ group: CZFVPNManager.CZFVPNNodeGroup) -> some View {
        NavigationView {
            VStack(spacing: 18) {
                if let url = group.sourceURL, let img = qrCodeImage(url) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                }
                if let url = group.sourceURL {
                    Text(url)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    if let url = group.sourceURL {
                        shareItems([url])
                    }
                } label: {
                    Label("分享订阅地址", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                Spacer()
            }
            .padding(24)
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { groupQRTarget = nil }
                }
            }
        }
    }

    // 二维码生成：系统 CIQRCodeGenerator，放大 10 倍出
    // 图，显示层关插值保持锐利。
    private func qrCodeImage(_ string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // 系统分享面板（从当前最顶层控制器present，面板里
    // 调用时顶层就是二维码面板自己）。
    private func shareItems(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }

    // 默认顺序存档：组 id → 延迟排序之前的组内链接顺序，
    // 存 UserDefaults（JSON）。第一次延迟排序时按组存下，
    // 之后不再覆盖，保证默认排序回到的永远是最初顺序。
    private static let defaultOrderKey = "CZFVPNDefaultGroupOrder"

    static func loadDefaultOrderMap() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: defaultOrderKey),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return map
    }

    func snapshotDefaultOrderIfNeeded() {
        var map = Self.loadDefaultOrderMap()
        var changed = false
        for group in vpnGroups where map[group.id] == nil {
            map[group.id] = group.links
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: Self.defaultOrderKey)
            hasDefaultOrderSnapshot = true
        }
    }

    /// 默认排序：各组恢复存档顺序；存档里没有的（后来新加
    /// 的）按当前相对顺序接在后面，存档里已删掉的自动跳过。
    func restoreDefaultOrder() {
        let map = Self.loadDefaultOrderMap()
        guard !map.isEmpty else { return }
        var groups = vpnGroups
        for gi in groups.indices {
            guard let saved = map[groups[gi].id] else { continue }
            let current = groups[gi].links
            groups[gi].links = saved.filter { current.contains($0) } + current.filter { !saved.contains($0) }
        }
        CZFVPNManager.shared.saveGroupOrder(groups)
        refreshVPNState()
    }

    /// 按延迟排序（分组版）：各组内部按同一把尺子排（通的
    /// 按延迟升序、不通的沉底、没测到的最后），在用节点在
    /// 自己组内钉住原位；只落盘组内顺序，不动扁平列表。
    func sortGroupsByPing() {
        let activeLink: String? = vpnNodes.indices.contains(vpnActiveIndex) ? vpnNodes[vpnActiveIndex] : nil
        func key(for link: String) -> Int {
            guard let idx = vpnNodes.firstIndex(of: link), let r = vpnPingResults[idx] else { return Int.max }
            return r.success ? r.delay : Int.max - 1
        }
        var groups = vpnGroups
        for gi in groups.indices {
            let links = groups[gi].links
            guard links.count > 1 else { continue }
            let activePos = activeLink.flatMap { links.firstIndex(of: $0) }
            let rest = links.enumerated()
                .filter { $0.offset != activePos }
                .sorted { key(for: $0.element) < key(for: $1.element) }
                .map { $0.element }
            var sorted = rest
            if let activePos, let activeLink {
                sorted.insert(activeLink, at: min(activePos, sorted.count))
            }
            groups[gi].links = sorted
        }
        CZFVPNManager.shared.saveGroupOrder(groups)
        vpnPingResults = [:]
        refreshVPNState()
    }

    // 测延迟的实际动作（测延迟按钮与被拒时的
    // “停核心重测”共用，免得两处逻辑漂移）：
    // 进度按批回主线程，按钮显示“测速 3/10”/
    // “重试 2/5”，不再只有一句测速中。
    func startVPNPing() {
        // 测速期间保留旧结果不清空：原来一开测就清表，
        // 测速中界面是空的、要等整轮测完才回来；现在旧
        // 结果先留着（按钮进度另行显示“测速 3/10”），
        // 测完由 completion 整表替换，被拒也不覆写。
        // 用户 2026-11-03 定的“停止测速启动”：核心在跑时
        // 先停、测完重启原来那条；核心没在跑时直接测、
        // 测完不启动。停核心在测速标志立起来之前做，免得
        // 测速窗口内起停被 deferred 逻辑插队。
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnPinging = true
        vpnPingRejected = false
        vpnPingDone = 0
        vpnPingTotal = vpnNodes.count
        vpnPingPhase = "测速"
        CZFVPNManager.shared.pingAllNodes(onPartial: { partial in
            // 通的先显示：只合并通的节点，不通的
            // 留空继续显示“测速中”，等最终结果；
            // 不在这里 save，最终结果才落盘。
            // 刚测通的节点同步清掉 stale 标记：别等整表
            // completion，测速中先显示的通节点一直灰色“·旧”
            // 是纯显示问题。
            for (i, r) in partial.enumerated() where r.success {
                vpnPingResults[i] = r
                vpnPingStaleIndices.remove(i)
            }
        }, onProgress: { done, total, phase in
            vpnPingDone = done
            vpnPingTotal = total
            vpnPingPhase = phase
        }) { results, rejected in
            if rejected {
                // 被拒那批全是失败，不是节点真不通：
                // 不覆写界面结果、不落盘，免得污染上次
                // 真测结果、清理/排序按假不通走；只出警告，
                // 清理/排序继续用上次真测结果。测速开始
                // 时已不再清空旧表，这里也不清空，直接
                // 保留旧结果即可，不用再靠缓存恢复。
                vpnPingRejected = true
            } else {
                var map: [Int: CZFVPNManager.CZFNodePingResult] = [:]
                for (i, r) in results.enumerated() { map[i] = r }
                vpnPingResults = map
                vpnPingStaleIndices = []
                vpnSingleRejectedLinks = []
                vpnPingRejected = false
                savePingResults()
            }
            // 停过的核心测完重启原来那条（没停过就不启动）；
            // 放 refresh 之前，状态行直接显示重启后的状态。
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            vpnPinging = false
            vpnPingDone = 0
            vpnPingTotal = 0
            refreshVPNState()
        }
    }

    // 单节点复测（长按行菜单）：只测这一条，不清整表。
    // 被拒时不覆写旧结果、只出警告；成功时只更新该节点
    // 的结果与缓存时间戳，其余节点结果不动。按链接内容
    // 对回下标，测速中列表变了也不错位。
    func startSinglePing(_ index: Int) {
        guard vpnNodes.indices.contains(index) else { return }
        // 滑动动作的 .disabled 不一定挡得住 List 行动作
        //（左滑删除已有同款教训、动作里另守一次），
        // 入口再守一次：测速中不叠加开第二轮单测。
        guard !vpnPinging && !vpnSinglePinging else { return }
        let link = vpnNodes[index]
        // 单测与批量同规则（251 只修了批量，行长按复测仍
        // 是老逻辑、核心在跑就拒，TUIC 行一直挂“核心占用”
        // 就是这么来的）：核心在跑先停、测完重启原来那条；
        // 没在跑直接测、测完不启动。停核心在测速标志立
        // 起来之前做，免得测速窗口内起核心让探针被占用挡下、测速结果不准。
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnSinglePingIndex = index
        vpnSinglePinging = true
        CZFVPNManager.shared.pingSingleNode(at: index) { result, rejected in
            vpnSinglePinging = false
            vpnSinglePingIndex = nil
            if rejected {
                vpnPingRejected = true
                vpnSingleRejectedLinks.insert(link)
            } else if let result, let currentIndex = vpnNodes.firstIndex(of: link) {
                vpnPingResults[currentIndex] = result
                vpnPingStaleIndices.remove(currentIndex)
                vpnSingleRejectedLinks.remove(link)
                // 只写该条缓存，别刷全表时间戳（见 savePingResult）。
                savePingResult(link: link, result: result)
            }
            // 停过的核心测完重启原来那条（没停过就不启动）；
            // 放 refresh 之前，状态行直接显示重启后的状态。
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            refreshVPNState()
        }
    }

    // 多选删除：按链接删（含在用节点走已有确认框，确认后
    // 退出多选；不含直接删）。链接作键，分组/导入换列表不错位。
    func deleteSelectedVPNNodeLinks() {
        guard !vpnPinging && !vpnSinglePinging else { return }
        guard !vpnSelectedNodeLinks.isEmpty else { return }
        if vpnNodes.indices.contains(vpnActiveIndex), vpnSelectedNodeLinks.contains(vpnNodes[vpnActiveIndex]) {
            pendingDeleteLinks = vpnSelectedNodeLinks
            showDeleteActiveConfirm = true
        } else {
            CZFVPNManager.shared.removeNodeLinks(vpnSelectedNodeLinks)
            vpnSelectedNodeLinks = []
            vpnNodeSelecting = false
            vpnPingResults = [:]
            refreshVPNState()
        }
    }

    func refreshVPNState() {
        vpnNodes = CZFVPNManager.shared.nodeLinks
        vpnGroups = CZFVPNManager.shared.nodeGroups()
        // 核心占用标记按当前列表剪枝：删节点/订阅替换后孤儿标记
        // 自动掉，删掉重加同一条不会没测过就显示“核心占用”。
        // 链接集合标记，删/排/导都不错位，剪枝只删不在列表的。
        vpnSingleRejectedLinks = vpnSingleRejectedLinks.filter { vpnNodes.contains($0) }
        vpnActiveIndex = CZFVPNManager.shared.activeNodeIndex
        // 测速中不翻核心按钮：测速期间任何 onAppear/刷新
        // 都不该把按钮从停止翻成启动，核心状态以测速前为准，
        // 测完由 completion 一次性刷新。
        if !vpnPinging {
            vpnCoreRunning = CZFVPNManager.shared.isRunning
        }
        vpnStatusMessage = CZFVPNManager.shared.lastError
        vpnHostProxy = CZFVPNManager.isHostProxyEnabled
        vpnPrewarmSuppressed = CZFVPNManager.shared.isPrewarmSuppressedAfterPing
        // 内存里的测速结果被清空（增删/导入/排序都会清）时，
        // 从落盘缓存按节点内容重建，没测过的节点不显示
        if vpnPingResults.isEmpty && !vpnPinging {
            restorePingResults()
        }
    }

    // MARK: - 测速结果持久化（打磨：以前只存内存，增删/导入任一
    // 节点就整表清零、重启也没了，而测速要停一次核心，代价不小。
    // 按节点链接内容存：增删别的节点不影响已有结果，重排后按
    // 内容对回新下标。编码：≥0 = 通的延迟 ms；-1 = 不通；-2 = 超时；-3 = 不支持（转换失败）
    // 新格式每条带时间戳（v = 延迟码，t = 测于何时的秒时间戳）：
    // 超 24 小时的结果界面灰色显示“·旧”，别按旧延迟误切节点。
    // 旧格式（直接存 Int）兼容读，时间戳按 0 计、即直接算旧。
    private static let pingCacheKey = "CZFVPNPingCache"
    private static let pingCacheStaleAfter: TimeInterval = 86400

    private func readPingCache() -> [String: (code: Int, time: TimeInterval)] {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.pingCacheKey) else { return [:] }
        var out: [String: (code: Int, time: TimeInterval)] = [:]
        for (link, value) in raw {
            if let dict = value as? [String: Any] {
                let code = (dict["v"] as? NSNumber)?.intValue ?? 0
                let time = (dict["t"] as? NSNumber)?.doubleValue ?? 0
                out[link] = (code: code, time: time)
            } else if let num = value as? NSNumber {
                out[link] = (code: num.intValue, time: 0)
            }
        }
        return out
    }

    private func writePingCache(_ cache: [String: (code: Int, time: TimeInterval)]) {
        var out: [String: [String: Any]] = [:]
        for (link, entry) in cache {
            out[link] = ["v": entry.code, "t": entry.time]
        }
        UserDefaults.standard.set(out, forKey: Self.pingCacheKey)
    }

    private func savePingResults() {
        // 先剪掉已不在列表里的节点，缓存不无限长
        var merged = readPingCache().filter { vpnNodes.contains($0.key) }
        let now = Date().timeIntervalSince1970
        for (index, result) in vpnPingResults {
            guard vpnNodes.indices.contains(index) else { continue }
            merged[vpnNodes[index]] = (code: Self.pingCacheCode(for: result), time: now)
        }
        writePingCache(merged)
    }

    /// 测速结果落盘编码（与 restorePingResults 的解码对应）：
    /// ≥0 = 通的延迟 ms；-1 = 不通；-2 = 超时；-3 = 不支持。
    private static func pingCacheCode(for result: CZFVPNManager.CZFNodePingResult) -> Int {
        result.success ? result.delay : (result.conversionFailed ? -3 : (result.delay == 11000 ? -2 : -1))
    }

    /// 单测只写该条缓存：以前单测调全量 savePingResults，
    /// 全表时间戳都被刷成“刚才”，几天前的旧结果杀掉重进后
    /// “·旧”消失、冒充新鲜。整表测速仍走全量（确实全测了）。
    private func savePingResult(link: String, result: CZFVPNManager.CZFNodePingResult) {
        var merged = readPingCache().filter { vpnNodes.contains($0.key) }
        merged[link] = (code: Self.pingCacheCode(for: result), time: Date().timeIntervalSince1970)
        writePingCache(merged)
    }

    private func restorePingResults() {
        let cache = readPingCache()
        guard !cache.isEmpty else { return }
        var map: [Int: CZFVPNManager.CZFNodePingResult] = [:]
        var stale: Set<Int> = []
        let now = Date().timeIntervalSince1970
        for (index, link) in vpnNodes.enumerated() {
            guard let entry = cache[link] else { continue }
            let v = entry.code
            if v >= 0 {
                map[index] = CZFVPNManager.CZFNodePingResult(success: true, delay: v)
            } else if v == -2 {
                map[index] = CZFVPNManager.CZFNodePingResult(success: false, delay: 11000)
            } else if v == -3 {
                map[index] = CZFVPNManager.CZFNodePingResult(success: false, delay: 10000, conversionFailed: true)
            } else {
                map[index] = CZFVPNManager.CZFNodePingResult(success: false, delay: 10000)
            }
            if entry.time == 0 || now - entry.time > Self.pingCacheStaleAfter {
                stale.insert(index)
            }
        }
        if !map.isEmpty {
            vpnPingResults = map
            vpnPingStaleIndices = stale
        }
    }
}

// 节点行显示部分（小火箭式）：橙点标在用、国旗、名称、
// 协议小字行、右侧延迟状态。切换、复测、删除动作留在
// 父视图。行显示与 vpnSection 解耦后，无关设置项变化
// 不再重建整行显示树。
private struct CZFVPNNodeLabel: View {
    let link: String
    let ping: CZFVPNManager.CZFNodePingResult?
    let isActive: Bool
    let coreRunning: Bool
    let pinging: Bool
    let isSinglePingTarget: Bool
    let isRejected: Bool
    let isStale: Bool

    var body: some View {
        let display = CZFVPNManager.nodeDisplay(for: link)
        let flag = CZFVPNManager.nodeFlagEmoji(for: link)
        // 名字自带国旗时把它挪到国旗位，名字里不再重复
        var name = display.name
        if name.hasPrefix(flag) {
            name = String(name.dropFirst(flag.count)).trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty { name = display.name }
        var protoLine = CZFVPNManager.nodeProtocolLine(for: link)
        if CZFSingBoxRouting.showsInsecureMark(for: link) {
            protoLine += " · 不验证书"
        }
        return HStack(spacing: 10) {
            // 在用标记：小火箭式橙点（不在用时留空占位，行不位移）
            Circle()
                .fill(isActive ? Color.orange : Color.clear)
                .frame(width: 9, height: 9)
            Text(flag)
                .font(.system(size: 19))
            VStack(alignment: .leading, spacing: 2) {
                // 字号按用户要求调小（16→13.5）：长名字在行里
                // 不再早早截断、撑出按钮框。
                Text(name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(protoLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            pingStatus
        }
    }

    @ViewBuilder private var pingStatus: some View {
        // 延迟测试结果（点下面的「测延迟」
        // 后显示）：绿 <300ms、橙 <800ms、
        // 红 ≥800ms；失败显示 超时/不通。
        // 例外：在用节点且核心在跑时，测速失败
        // 不显示不通——核心在跑且实际能上网
        // 是比一次测速样本更强的证据，显示
        // 不通只会逼用户误换 IP（养号大忌）
        if let ping, !ping.success, isActive, coreRunning {
            Text("在用")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.green)
        } else if (pinging || isSinglePingTarget) && ping == nil {
            Text("测速中")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.gray)
        } else if isSinglePingTarget {
            Text("测速中")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.gray)
        } else if isRejected {
            // 单测被拒：只剩测速中途核心又被起起来的竞
            // 态（单测与批量一样先停核心再测，见
            // startSinglePing）；旧值原样保留，行上直接
            // 写“核心占用”，别让用户对着不变的数字猜。
            Text("核心占用")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.orange)
        } else if ping == nil, !CZFVPNManager.isSupportedNodeScheme(CZFVPNManager.nodeScheme(for: link)) {
            // 未测到的不支持节点：按协议清单静态分级，
            // 直接标“不支持”（橙色，与实测失败的红色区分），
            // 不等人测完才知道它跑不了。
            Text("不支持")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.orange)
        } else if let ping {
            // 超 24 小时的缓存结果：灰色加“·旧”，
            // 别按新鲜延迟的颜色误导切节点。
            if ping.success {
                Text(isStale ? "\(ping.delay)ms·旧" : "\(ping.delay)ms")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isStale ? .gray : (ping.delay < 300 ? .green : (ping.delay < 800 ? .orange : .red)))
            } else {
                // 转换失败与网络失败分开显示：配置生成拒收
                // 是协议不支持，不是网络不通。
                Text((ping.conversionFailed ? "不支持" : (ping.delay == 11000 ? "超时" : "不通")) + (isStale ? "·旧" : ""))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isStale ? .gray : .red)
            }
        }
    }
}

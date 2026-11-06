//
//  LCMultitaskSettingView.swift
//  LiveContainer
//
//  Created by s s on 2026/3/21.
//

import SwiftUI

struct LCMultitaskSettingView: View {
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    // 默认值 2026-11-06 由 Campbell 改为开：没设过 = 开；
    // 用户亲手关过（键已存 false）仍按关算。读取侧
    // LCAppModel.shouldLaunchInMultitaskMode 与
    // DecoratedAppSceneViewController 的 _isMaximized
    // 初始值同改为「键不存在 = 开」，三处保持一致。
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = true
    @AppStorage("LCLaunchMultitaskMaximized") var launchMultitaskMaximized = true
    @AppStorage("LCMultitaskBottomWindowBar", store: LCUtils.appGroupUserDefault) var bottomWindowBar = false
    @AppStorage("LCAutoEndPiP", store: LCUtils.appGroupUserDefault) var autoEndPiP = false
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    @AppStorage("LCRestartTerminatedApp", store: LCUtils.appGroupUserDefault) var restartTerminatedApp = false
    @AppStorage("LCMaxOneAppOnStage", store: LCUtils.appGroupUserDefault) var onlyOneAppOnStage = false
    @AppStorage("LCDockWidth", store: LCUtils.appGroupUserDefault) var dockWidth: Double = 25
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    // 隐藏快捷栏（CZF）：整条竖栏都不显示，有手势就够了；
    // 默认关（保持现有行为），开后快捷栏不再弹出
    @AppStorage("LCHideDock", store: LCUtils.appGroupUserDefault) var hideDock: Bool = false
    @AppStorage("LCRedirectURLToHost", store: LCUtils.appGroupUserDefault) var redirectURLToHost = false
    // 窗口状态还原（CZF）：关窗时记下窗口大小/位置/全屏状态，
    // 下次打开自动还原（DecoratedAppSceneViewController 读写，
    // 标准 UserDefaults，与那边 lcUserDefaults 同一本）
    @AppStorage("CZFRestoreWindowState") var restoreWindowState = true
    // 边缘手势（CZF）：开关与灵敏度 2026-11-06 已按
    // Campbell 令拆分并迁进专门的「手势控制」页
    // （LCEdgeGestureSettingView），入口在本页「窗口与
    // 手势」段；宿主判定侧在 MultitaskDockView 按分项读。
    // 最小化省电（CZF）：两条都有开关，默认都开，关了即回旧行为。
    // 键在 appGroup，ObjC 侧（Decorated）和 Swift 侧（DockManager）
    // 按“键不存在 = 开”同款读法，@AppStorage 初始值 true 与之对齐。
    @AppStorage("CZFMinPowerSavingEnabled", store: LCUtils.appGroupUserDefault) var minPowerSavingEnabled = true
    @AppStorage("CZFMinAutoCloseEnabled", store: LCUtils.appGroupUserDefault) var minAutoCloseEnabled = true
    // 最小化自动关时长（CZF，可调）：10 / 30 / 60 分钟，默认 30
    // 分钟（以前写死 30 分钟）。Dock 侧按“键不存在 = 30”同款读法。
    @AppStorage("CZFMinAutoCloseMinutes", store: LCUtils.appGroupUserDefault) var minAutoCloseMinutes = 30
    // 窗口缩放（CZF，用户令从应用设置挪进本页）：
    // 自适应/默认缩放。标准 UserDefaults，与窗口侧
    // lcUserDefaults 同一本，窗口侧读法不变，只是设置
    // 入口换到这里。（窗口按钮大小、固定分辨率两项设置
    // 已按 Campbell 2026-11-06 令删除。）
    @AppStorage("CZFAdaptiveScaleEnabled") var adaptiveScaleEnabled = false
    @AppStorage("CZFWindowScaleRatio") var windowScaleRatio: Double = 1.0
    // 最大化时收起快捷栏（CZF）：标准 UserDefaults，窗口
    // 侧同键读取；没设过 = 开。开时窗口一最大化（包含以
    // 最大化状态打开）快捷栏自动收起；还原不自动展开。
    @AppStorage("CZFCollapseDockWhenMaximized") var collapseDockWhenMaximized = true

    // 本页自己的搜索（同款按段关键词过滤）：原来没有
    // 搜索，上面两页搜到这里也只给入口，本页四段（模
    // 式/快捷栏/最小化省电/窗口手势）自己也要能搜。
    @State private var searchText = ""

    private func czfMtSearchVisible(_ keywords: String) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return keywords.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        List {
            if czfMtSearchVisible("多任务 模式 虚拟窗口 原生窗口 启动 最大化 画中画 pip 跳过 终止 底部栏 链接 重定向 只留一个 快捷栏 收起") {
            Section {
                if(UIApplication.shared.supportsMultipleScenes) {
                    Picker(selection: $multitaskMode) {
                        Text("lc.settings.multitaskMode.virtualWindow".loc).tag(MultitaskMode.virtualWindow)
                        Text("lc.settings.multitaskMode.nativeWindow".loc).tag(MultitaskMode.nativeWindow)
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "rectangle.stack", color: .purple)
                            Text("lc.settings.multitaskMode".loc)
                        }
                    }
                }
                Toggle(isOn: $launchInMultitaskMode) {
                    HStack {
                        LCSettingsIcon(systemName: "play.fill", color: .green)
                        Text("lc.settings.autoLaunchInMultitaskMode".loc)
                    }
                }
                
                if multitaskMode == .virtualWindow {
                    Toggle(isOn: $launchMultitaskMaximized) {
                        HStack {
                            LCSettingsIcon(systemName: "arrow.up.left.and.arrow.down.right", color: .blue)
                            Text("lc.settings.launchMultitaskMaximized".loc)
                        }
                    }
                    if launchMultitaskMaximized {
                        Toggle(isOn: $onlyOneAppOnStage) {
                            HStack {
                                LCSettingsIcon(systemName: "square.stack", color: .purple)
                                Text("lc.settings.onlyOneAppOnStage".loc)
                            }
                        }
                    }
                    Toggle(isOn: $autoEndPiP) {
                        HStack {
                            LCSettingsIcon(systemName: "pip", color: .gray)
                            Text("lc.settings.autoEndPiP".loc)
                        }
                    }
                    Toggle(isOn: $skipTerminatedScreen) {
                        HStack {
                            LCSettingsIcon(systemName: "forward.fill", color: .gray)
                            Text("lc.settings.skipTerminatedScreen".loc)
                        }
                    }
                    if skipTerminatedScreen {
                        Toggle(isOn: $restartTerminatedApp) {
                            HStack {
                                LCSettingsIcon(systemName: "arrow.clockwise", color: .green)
                                Text("lc.settings.restartTerminatedApp".loc)
                            }
                        }
                    }
                    Toggle(isOn: $bottomWindowBar) {
                        HStack {
                            LCSettingsIcon(systemName: "menubar.rectangle", color: .gray)
                            Text("lc.settings.bottomWindowBar".loc)
                        }
                    }
                    Toggle(isOn: $collapseDockWhenMaximized) {
                        HStack {
                            LCSettingsIcon(systemName: "dock.rectangle", color: .gray)
                            Text("最大化时收起快捷栏")
                        }
                    }
                    Toggle(isOn: $redirectURLToHost) {
                        HStack {
                            LCSettingsIcon(systemName: "link", color: .blue)
                            Text("lc.settings.redirectURLToHost".loc)
                        }
                    }

                }
            }
            }
            if czfMtSearchVisible("快捷栏 宽度 隐藏 收起 dock 面板") {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        LCSettingsIcon(systemName: "dock.rectangle", color: .blue)
                        Text("lc.settings.dockWidth".loc)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(Int(dockWidth))px")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    Slider(value: $dockWidth, in: 20...120, step: 5) {
                        Text("lc.settings.dockWidth".loc)
                    }
                    .tint(.accentColor)
                }
                .padding(.vertical, 4)
                Toggle(isOn: $hideCollapsedDock) {
                    HStack {
                        LCSettingsIcon(systemName: "eye.slash", color: .gray)
                        Text("lc.settings.hideCollapsedDock".loc)
                    }
                }
                Toggle(isOn: $hideDock) {
                    HStack {
                        LCSettingsIcon(systemName: "eye.slash.fill", color: .red)
                        Text("隐藏快捷栏")
                    }
                }
            }
            }
            if czfMtSearchVisible("最小化 省电 自动关 后台 分钟 时间") {
            Section {
                Toggle(isOn: $minPowerSavingEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "moon.fill", color: .indigo)
                        Text("最小化进后台省电")
                    }
                }
                Toggle(isOn: $minAutoCloseEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "timer", color: .red)
                        Text("最小化自动关")
                    }
                }
                if minAutoCloseEnabled {
                    Picker(selection: $minAutoCloseMinutes) {
                        Text("10 分钟").tag(10)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "clock.fill", color: .orange)
                            Text("自动关时间")
                        }
                    }
                }
            } header: {
                Text("最小化省电")
            } footer: {
                Text("最小化进后台：窗口最小化后把它的场景置为后台，让它自己停渲染、停视频、停定时器，叫回台前自动恢复前台；画中画不受影响。自动关：最小化满上面选的分钟数还没叫回来就直接关窗，彻底停掉；恢复可见后重新计时间，画中画和保活白名单里的 App 豁免。两条关了都回旧行为：最小化只藏视图、一直以前台跑。")
            }
            }
            if czfMtSearchVisible("窗口 手势 记住 位置 灵敏度 边缘 还原 面板 切换 应用 隐藏 快捷栏 控制") {
            Section {
                Toggle(isOn: $restoreWindowState) {
                    HStack {
                        LCSettingsIcon(systemName: "clock.fill", color: .orange)
                        Text("记住窗口位置")
                    }
                }
                NavigationLink {
                    LCEdgeGestureSettingView()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "hand.draw.fill", color: .blue)
                        Text("手势控制")
                    }
                }
            } header: {
                Text("窗口与手势")
            } footer: {
                Text("记住窗口位置：关掉 App 窗口时记下它的大小、位置和全屏状态，下次打开自动还原。边缘手势的开关和灵敏度都在「手势控制」里：四项手势（App 面板/源面板/切换应用/隐藏快捷栏）各自独立开关、各自一份灵敏度（影响启用范围和触发距离，低档更防误触、高档更好触发）。")
            }
            }
            if czfMtSearchVisible("缩放 比例 自适应 默认 窗口") {
            Section {
                Toggle(isOn: $adaptiveScaleEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "aspectratio", color: .purple)
                        Text("自适应缩放比例")
                    }
                }
                if !adaptiveScaleEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            LCSettingsIcon(systemName: "magnifyingglass", color: .gray)
                            Text("默认缩放比例")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(Int((windowScaleRatio * 100).rounded()))%")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        Slider(value: $windowScaleRatio, in: 0.5...2.0, step: 0.05) {
                            Text("默认缩放比例")
                        }
                        .tint(.accentColor)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("缩放比例")
            } footer: {
                Text("自适应开：窗口缩放按窗口宽度与全屏宽度的比自动算，整个界面等比缩进窗口；改窗口大小、最大化/还原后会重算。关：新窗口用默认比例。窗口标题菜单里的滑杆仍可单独调每个窗口，仅当次有效。")
            }
            }
        }
        // 搜索栏与框架和源页同款（Campbell 定）：段间距
        // 10、搜索栏导航栏下方常显。
        .czfListSectionSpacing(10)
        .navigationTitle("lc.appBanner.multitask".loc)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索设置")
    }
}

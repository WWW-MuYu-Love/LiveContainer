//
//  LCEdgeGestureSettingView.swift
//  LiveContainer
//
//  手势控制页（CZF，2026-11-06 Campbell 令新设）：边缘手势
//  的四项开关与四份灵敏度都收进这一页，从多任务设置「窗
//  口与手势」段的入口进入。宿主判定侧在 MultitaskDockView
//  按分项键读取（开关 czfSplitEdgeGestureEnabled、灵敏度
//  czfSplitEdgeSensitivity）。
//

import SwiftUI

struct LCEdgeGestureSettingView: View {
    // 四项开关 + 四份灵敏度：初始值在 init 里播种——新键存
    // 过值用新键；开关没存过而旧总开关 CZFEdgeGesturesEnabled
    // 存过值就继承旧值（用户手动关过的总开关，四项初始全
    // 关）；灵敏度没存过就继承旧共用键 CZFEdgeSensitivity；
    // 都没存过 = 开关开、灵敏度中（1）。
    @AppStorage("CZFEdgeGestureAppPanelEnabled") var appPanelGestureEnabled = true
    @AppStorage("CZFEdgeGestureSourcesPanelEnabled") var sourcesPanelGestureEnabled = true
    @AppStorage("CZFEdgeGestureAppSwitchEnabled") var appSwitchGestureEnabled = true
    @AppStorage("CZFEdgeGestureHideDockEnabled") var hideDockGestureEnabled = true
    @AppStorage("CZFEdgeGestureAppPanelSensitivity") var appPanelSensitivity = 1
    @AppStorage("CZFEdgeGestureSourcesPanelSensitivity") var sourcesPanelSensitivity = 1
    @AppStorage("CZFEdgeGestureAppSwitchSensitivity") var appSwitchSensitivity = 1
    @AppStorage("CZFEdgeGestureHideDockSensitivity") var hideDockSensitivity = 1

    init() {
        let d = UserDefaults.standard
        func seedSwitch(_ key: String) -> Bool {
            if d.object(forKey: key) != nil { return d.bool(forKey: key) }
            if d.object(forKey: "CZFEdgeGesturesEnabled") == nil { return true }
            return d.bool(forKey: "CZFEdgeGesturesEnabled")
        }
        func seedSensitivity(_ key: String) -> Int {
            if let v = d.object(forKey: key) as? Int { return v }
            return d.object(forKey: "CZFEdgeSensitivity") as? Int ?? 1
        }
        _appPanelGestureEnabled = AppStorage(wrappedValue: seedSwitch("CZFEdgeGestureAppPanelEnabled"), "CZFEdgeGestureAppPanelEnabled")
        _sourcesPanelGestureEnabled = AppStorage(wrappedValue: seedSwitch("CZFEdgeGestureSourcesPanelEnabled"), "CZFEdgeGestureSourcesPanelEnabled")
        _appSwitchGestureEnabled = AppStorage(wrappedValue: seedSwitch("CZFEdgeGestureAppSwitchEnabled"), "CZFEdgeGestureAppSwitchEnabled")
        _hideDockGestureEnabled = AppStorage(wrappedValue: seedSwitch("CZFEdgeGestureHideDockEnabled"), "CZFEdgeGestureHideDockEnabled")
        _appPanelSensitivity = AppStorage(wrappedValue: seedSensitivity("CZFEdgeGestureAppPanelSensitivity"), "CZFEdgeGestureAppPanelSensitivity")
        _sourcesPanelSensitivity = AppStorage(wrappedValue: seedSensitivity("CZFEdgeGestureSourcesPanelSensitivity"), "CZFEdgeGestureSourcesPanelSensitivity")
        _appSwitchSensitivity = AppStorage(wrappedValue: seedSensitivity("CZFEdgeGestureAppSwitchSensitivity"), "CZFEdgeGestureAppSwitchSensitivity")
        _hideDockSensitivity = AppStorage(wrappedValue: seedSensitivity("CZFEdgeGestureHideDockSensitivity"), "CZFEdgeGestureHideDockSensitivity")
    }

    // 本页自己的搜索（同其它设置页的款式：每段按关键词过滤）
    @State private var searchText = ""
    private func czfGestureSearchVisible(_ keywords: String) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return keywords.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        List {
            if czfGestureSearchVisible("app 面板 左缘 向内 灵敏度 手势") {
            Section {
                Toggle(isOn: $appPanelGestureEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "square.grid.2x2.fill", color: .blue)
                        Text("App 面板手势")
                    }
                }
                if appPanelGestureEnabled {
                    sensitivityPicker(selection: $appPanelSensitivity)
                }
            } header: {
                Text("App 面板")
            } footer: {
                Text("左边缘向内拖（手指右移）打开或关闭 App 面板；面板打开时从源面板切回 App 面板也归这项管。")
            }
            }
            if czfGestureSearchVisible("源 面板 左缘 向外 灵敏度 手势") {
            Section {
                Toggle(isOn: $sourcesPanelGestureEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "tray.full.fill", color: .teal)
                        Text("源面板手势")
                    }
                }
                if sourcesPanelGestureEnabled {
                    sensitivityPicker(selection: $sourcesPanelSensitivity)
                }
            } header: {
                Text("源面板")
            } footer: {
                Text("左边缘向外弹（手指左移）打开或关闭源面板；面板打开时从 App 面板切去源面板也归这项管。")
            }
            }
            if czfGestureSearchVisible("切换 应用 右缘 灵敏度 手势") {
            Section {
                Toggle(isOn: $appSwitchGestureEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "arrow.left.arrow.right", color: .orange)
                        Text("切换应用手势")
                    }
                }
                if appSwitchGestureEnabled {
                    sensitivityPicker(selection: $appSwitchSensitivity)
                }
            } header: {
                Text("切换应用")
            } footer: {
                Text("右边缘向内滑切上一个、向外滑切下一个已打开的 App；任意位置起手拖到右边缘 = 下一个。")
            }
            }
            if czfGestureSearchVisible("隐藏 快捷栏 左缘 灵敏度 手势") {
            Section {
                Toggle(isOn: $hideDockGestureEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "sidebar.left", color: .gray)
                        Text("隐藏快捷栏手势")
                    }
                }
                if hideDockGestureEnabled {
                    sensitivityPicker(selection: $hideDockSensitivity)
                }
            } header: {
                Text("隐藏快捷栏")
            } footer: {
                Text("任意位置起手拖到左边缘，收起快捷栏。")
            }
            }
        }
        // 搜索栏与框架和源页同款（Campbell 定）：段间距
        // 10、搜索栏导航栏下方常显（本页原先没写 placement，
        // 用的是默认自动收起，一并对齐）。
        .czfListSectionSpacing(10)
        .navigationTitle("手势控制")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索设置")
        .czfKeepNavBarDuringSearch()
    }

    private func sensitivityPicker(selection: Binding<Int>) -> some View {
        Picker(selection: selection) {
            Text("低").tag(0)
            Text("中").tag(1)
            Text("高").tag(2)
        } label: {
            HStack {
                LCSettingsIcon(systemName: "slider.horizontal.3", color: .purple)
                Text("手势灵敏度")
            }
        }
    }
}

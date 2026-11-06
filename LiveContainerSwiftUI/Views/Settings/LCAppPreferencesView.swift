//
//  LCAppPreferencesView.swift
//  LiveContainerSwiftUI
//
//  「应用设置」子页：原设置页杂项段的开关整体收进这里，
//  设置主页只留一行入口（与存储管理同款）。各开关的
//  AppStorage 键与行为原样保留。
//

import Foundation
import SwiftUI
import UserNotifications

struct LCAppPreferencesView: View {
    @AppStorage("LCFrameShortcutIcons") var frameShortIcon = false
    @AppStorage("LCSwitchAppWithoutAsking") var silentSwitchApp = false
    @AppStorage("LCDontSignApp", store: LCUtils.appGroupUserDefault) var dontSignApp = false
    @AppStorage("LCStrictHiding", store: LCUtils.appGroupUserDefault) var strictHiding = false
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    // 后台保活（从设置主页移入，键不变）：默认开，掉线根因
    // 见 LCSettingsView 静态同步函数注释——重装归零会让
    // 切后台就被挂起断网，默认开 + 启动同步兜底。
    @AppStorage("LCKeepAliveEnabled") var keepAliveEnabled = true

    private var store: Store { LCUtils.store() }

    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined

    // 本页自己的搜索（与设置主页同款：本页字段写本页
    // 词、按段关键词过滤）。原来这页没有搜索：主页搜
    // 「多」只给得出本页入口，本页里的多任务/保活/界
    // 面根本搜不到，这次补齐。
    @State private var searchText = ""

    private func czfPrefsSearchVisible(_ keywords: String) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return keywords.localizedCaseInsensitiveContains(q)
    }

    @EnvironmentObject private var sharedModel : SharedModel

    private var notificationAuthText: String {
        switch notificationAuthStatus {
        case .authorized: return "已开启"
        case .denied: return "已关闭"
        case .notDetermined: return "未申请"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时"
        @unknown default: return "未知"
        }
    }
    private func refreshNotificationAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { notificationAuthStatus = settings.authorizationStatus }
        }
    }

    var body: some View {
        Form {
            if czfPrefsSearchVisible("边框 快捷图标 静默 切换 严格隐藏 不签名 通知 权限 清除通知") {
            Section {
            Toggle(isOn: $frameShortIcon) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        LCSettingsIcon(systemName: "plus.app", color: .green)
                        Text("lc.settings.FrameIcon".loc)
                    }
                    Text("lc.settings.FrameIconDesc".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $silentSwitchApp) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        LCSettingsIcon(systemName: "eye.slash", color: .gray)
                        Text("lc.settings.silentSwitchApp".loc)
                    }
                    Text("lc.settings.silentSwitchAppDesc".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if sharedModel.isHiddenAppUnlocked {
                Toggle(isOn: $strictHiding) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "hand.raised.fill", color: .red)
                            Text("lc.settings.strictHiding".loc)
                        }
                        Text("lc.settings.strictHidingDesc".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(isOn: $dontSignApp) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        LCSettingsIcon(systemName: "signature", color: .orange)
                        Text("lc.settings.dontSign".loc)
                    }
                    Text("lc.settings.dontSignDesc".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                clearNotifications()
            } label: {
                HStack {
                    LCSettingsIcon(systemName: "bell.slash.fill", color: .red)
                    Text("lc.settings.clearNotifications".loc)
                }
            }
            // 通知权限行：状态从系统实时读；未申请点一下
            // 直接申请，已拒绝点一下跳系统设置，已开启不
            // 显示按钮。从系统设置回来时刷新一次状态。
            HStack {
                LCSettingsIcon(systemName: "bell.fill", color: .orange)
                Text("通知权限")
                Spacer()
                Text(notificationAuthText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if notificationAuthStatus != .authorized {
                    Button(notificationAuthStatus == .denied ? "去设置" : "开启") {
                        if notificationAuthStatus == .denied {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } else {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                                refreshNotificationAuth()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onAppear { refreshNotificationAuth() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                refreshNotificationAuth()
            }
            }
            }
            if czfPrefsSearchVisible("界面 外观 动态取色 深色图标 颜色 横幅") { interfaceSection }
            if czfPrefsSearchVisible("多开 分身 管理 multi 第二个") { multiLCSection }
            if czfPrefsSearchVisible("多任务 multitask 窗口 缩放 比例") { multitaskSection }
            if czfPrefsSearchVisible("保活 后台 无声音频 音频") { keepAliveSection }
        }
        .navigationTitle("应用设置")
        .searchable(text: $searchText, placement: .automatic, prompt: "搜索设置")
    }

    @ViewBuilder private var interfaceSection: some View {
        // 界面区：说明从 footer 挪到各行下面的小字，
        // 深色图标那行原来没有说明（footer 只讲动态颜色），
        // 现在补上“横幅用 App 的深色图标”，两行说明各对各行。
        Section{
            Toggle(isOn: $dynamicColors) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        LCSettingsIcon(systemName: "paintpalette.fill", color: .purple)
                        Text("lc.settings.dynamicColors".loc)
                    }
                    Text("lc.settings.dynamicColors.desc".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if #available(iOS 18.0, *) {
                Toggle(isOn: $darkModeIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            LCSettingsIcon(systemName: "moon.fill", color: .indigo)
                            Text("lc.settings.darkModeIcon".loc)
                        }
                        Text("App 横幅用 App 的深色图标")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("lc.settings.interface".loc)
        }
    }

    @ViewBuilder private var multiLCSection: some View {
        if (store != .Unknown && store != .ADP) || LCUtils.isAppGroupAltStoreLike() {
            Section{
                NavigationLink {
                    LCMultiLCManagementView()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "apps.iphone", color: .blue)
                        if sharedModel.multiLCStatus == 0 {
                            Text("lc.settings.multiLC".loc)
                        } else if sharedModel.multiLCStatus == 2 {
                            Text("lc.settings.multiLCIsSecond".loc)
                        }
                    }
                }
                .disabled(sharedModel.multiLCStatus == 2)

                if(sharedModel.multiLCStatus == 2) {
                    NavigationLink {
                        LCJITLessDiagnoseView()
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "wrench.and.screwdriver", color: .gray)
                            Text("lc.settings.jitlessDiagnose".loc)
                        }
                    }
                }
            } footer: {
                Text("lc.settings.multiLCDesc".loc)
            }
        }
    }

    @ViewBuilder private var multitaskSection: some View {
        if #available(iOS 16.1, *) {
            Section {
                NavigationLink {
                    LCMultitaskSettingView()
                } label: {
                    HStack {
                        LCSettingsIcon(systemName: "rectangle.stack", color: .purple)
                        Text("lc.appBanner.multitask".loc)
                    }
                }
            } footer: {
                Text("lc.settings.multitaskDesc".loc)
            }
        }
    }

    @ViewBuilder private var keepAliveSection: some View {
        // 后台保活（从设置主页移入，用户定版）：开关与行为
        // 原样，同步走 LCSettingsView 的静态版（启动同步
        // 共用同一份），刷新宿主保活状态同旧段。
        Section(header: Text("后台保活")) {
            Toggle(isOn: $keepAliveEnabled) {
                HStack {
                    LCSettingsIcon(systemName: "heart.fill", color: .red)
                    Text("保活（无声音频）")
                }
            }
            .onChange(of: keepAliveEnabled) { newValue in
                LCSettingsView.syncKeepAliveTweak(enabled: newValue, forceSign: false)
                CZFHostKeepAlive.shared.refresh()
            }
            .onAppear {
                LCSettingsView.syncKeepAliveTweak(enabled: keepAliveEnabled, forceSign: false)
                CZFHostKeepAlive.shared.refresh()
            }
        }
    }

    func clearNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
        if #available(iOS 16.0, *) {
            notificationCenter.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }
}

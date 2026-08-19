import AppKit
import HerdrKit
import Sparkle
import SwiftUI

@main
struct HerdrMApp: App {
    @AppStorage("app.theme") private var themePreference = "system"
    @AppStorage("menuBar.enabled") private var menuBarEnabled = true
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owned here so the window and the menu bar extra observe one model.
    @StateObject private var model = AppModel()

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onAppear { Self.applyTheme(themePreference) }
                .onChange(of: themePreference) { _, newValue in
                    Self.applyTheme(newValue)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
            CommandGroup(after: .newItem) {
                Button("New Agent…") { model.showNewAgent = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Space…") { model.showNewSpace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Search…") { model.showSearch = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        // Agents waiting on you, reachable without bringing the window forward.
        MenuBarExtra(
            "herdrm",
            systemImage: model.blockedCount > 0 ? "bell.badge.fill" : "bell",
            isInserted: $menuBarEnabled
        ) {
            MenuBarContent(model: model)
        }

        Settings {
            SettingsView()
        }
    }

    static func applyTheme(_ preference: String) {
        switch preference {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// Menu bar rundown of everything that wants attention, across every device.
struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let waiting = model.attentionAgents
        if waiting.isEmpty {
            Text("No agents waiting")
        } else {
            ForEach(waiting) { entry in
                Button(label(for: entry)) { open(entry) }
            }
        }
        Divider()
        Button("New Agent…") {
            NSApp.activate(ignoringOtherApps: true)
            model.showNewAgent = true
        }
        Button("Open herdrm") {
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit herdrm") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func label(for entry: AppModel.AgentEntry) -> String {
        let mark = entry.agent.status == .blocked ? "●" : "✓"
        let space = model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID)
        let location = model.showsDeviceBadges ? "\(space) · \(entry.device.name)" : space
        return "\(mark)  \(entry.agent.title) — \(location)"
    }

    private func open(_ entry: AppModel.AgentEntry) {
        NSApp.activate(ignoringOtherApps: true)
        model.reveal(entry.ref)
    }
}

/// Detaches every kept-alive terminal on quit, so no `ssh`/`herdr agent attach`
/// child outlives the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            TerminalSessionStore.shared.closeAll()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420)
    }
}

struct TerminalSettingsView: View {
    @AppStorage(TerminalDefaults.fontNameKey) private var fontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage("terminal.mouseReporting") private var mouseReporting = true

    private let families = TerminalDefaults.monospacedFamilies()

    var body: some View {
        Form {
            Picker("Font", selection: $fontName) {
                Text("System Mono (SF Mono)").tag("")
                Divider()
                ForEach(families, id: \.self) { family in
                    Text(family).tag(family)
                }
            }

            HStack {
                Slider(value: $fontSize, in: 9...22, step: 0.5) {
                    Text("Size")
                }
                Text(String(format: "%.1f pt", fontSize))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                Stepper("", value: $fontSize, in: 9...22, step: 0.5)
                    .labelsHidden()
            }

            Toggle(isOn: $mouseReporting) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mouse reporting")
                    Text("Forwards clicks and drags to TUI apps that ask for them. Turn off to always select text with the mouse — Shift-drag selects either way.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            Button("Reset to Defaults") {
                fontName = ""
                fontSize = TerminalDefaults.defaultFontSize
                mouseReporting = true
            }

            Section {
                Text("Preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("❯ herdr agent attach w1:p1 — 中文 ABC 0123")
                    .font(Font(TerminalDefaults.font(name: fontName, size: fontSize)))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20)
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("app.theme") private var themePreference = "system"
    @AppStorage("menuBar.enabled") private var menuBarEnabled = true

    var body: some View {
        Form {
            Picker("Theme", selection: $themePreference) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Text("The terminal follows the app theme.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Toggle("Show in the menu bar", isOn: $menuBarEnabled)
            Text("Lists every agent that is blocked or done, on any device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct NotificationSettingsView: View {
    @AppStorage("notifications.enabled") private var enabled = true

    var body: some View {
        Form {
            Toggle("Notify when an agent finishes or needs input", isOn: $enabled)
            Text("Finished agents only notify while you're not watching them — herdr reports panes you have open as idle, not done.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Text("herdrm — a native macOS console for herdr.")
                .font(.system(size: 12.5))
            Text("Devices are managed from the switcher in the sidebar footer.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

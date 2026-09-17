import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "ShotShelf Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SettingsView(settings: .shared, updater: .shared))
        window.setContentSize(NSSize(width: 500, height: 720))
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        ToggleTriggers.shared.setSuspended(false)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: Updater
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Saving") {
                LabeledContent("Save screenshots to") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: settings.saveFolder.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(settings.saveFolder.lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    Button("Choose Folder…", action: chooseFolder)
                    Button("Show in Finder") { NSWorkspace.shared.open(settings.saveFolder) }
                    Spacer()
                    if settings.saveFolder.standardizedFileURL != AppSettings.desktopURL.standardizedFileURL {
                        Button("Use Desktop") { settings.saveFolder = AppSettings.desktopURL }
                    }
                }
                Picker("Closing a screenshot (×)", selection: $settings.closeScreenshotAction) {
                    ForEach(DisposeAction.allCases) { Text($0.label).tag($0) }
                }
                Picker("Closing the shelf", selection: $settings.closeShelfAction) {
                    ForEach(DisposeAction.allCases) { Text($0.label).tag($0) }
                }
                Text("Screenshots land in this folder when you close them. Trashed screenshots can still be recovered from the Trash. Quitting ShotShelf always saves.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Shelf") {
                LabeledContent("Appears in corner") {
                    CornerPicker(selection: Binding(
                        get: { settings.anchorCorner },
                        set: { if let corner = $0 { settings.anchorCorner = corner } }))
                }
                Toggle("Turn off the macOS preview thumbnail", isOn: $settings.hideSystemPreview)
                Text("The floating macOS thumbnail delays the shelf by a few seconds.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Show and Hide") {
                LabeledContent("Keyboard shortcut") {
                    ShortcutRecorder(shortcut: $settings.toggleShortcut)
                }
                LabeledContent("Mouse button") {
                    MouseTriggerRecorder(trigger: $settings.toggleMouseTrigger)
                }
                Toggle("Hot corner", isOn: Binding(
                    get: { settings.hotCorner != nil },
                    set: { settings.hotCorner = $0 ? (settings.hotCorner ?? .bottomRight) : nil }))
                if settings.hotCorner != nil {
                    LabeledContent("Corner") {
                        CornerPicker(selection: $settings.hotCorner)
                    }
                    Picker("Trigger", selection: $settings.hotCornerAction) {
                        ForEach(HotCornerAction.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.hotCornerAction == .horizontalScroll {
                        Toggle("Swap directions", isOn: $settings.swapScrollDirections)
                    }
                    Text(hotCornerHint)
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section("Appearance") {
                Toggle("Show in menu bar", isOn: $settings.showMenuBarIcon)
                Toggle("Show in Dock", isOn: $settings.showDockIcon)
                LabeledContent("Icon") {
                    IconPicker(selection: $settings.icon)
                }
                if !settings.showMenuBarIcon && !settings.showDockIcon {
                    Label("With both icons off, open Settings from the gear on the shelf, or by opening ShotShelf again from Applications.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section("Updates") {
                LabeledContent("Version") { Text(updater.currentVersion) }
                LabeledContent("Status") { UpdateStatusView(updater: updater) }
                Toggle("Check for and download updates automatically", isOn: $settings.autoCheckUpdates)
                    .disabled(updater.repository == nil)
                    .onChange(of: settings.autoCheckUpdates) { _ in updater.startAutomaticChecks() }
                if let page = updater.repositoryPage {
                    Link("All releases on GitHub", destination: page).font(.caption)
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                HStack {
                    Button("Open Staging Folder") { NSWorkspace.shared.open(ShelfStore.stagingURL) }
                    Spacer()
                    Button("Quit ShotShelf") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 500)
    }

    private var hotCornerHint: String {
        switch settings.hotCornerAction {
        case .enter:
            return "Turn off the macOS hot corner for this corner (System Settings › Desktop & Dock › Hot Corners), otherwise both will fire."
        case .horizontalScroll:
            let show = settings.swapScrollDirections ? "right" : "left"
            let hide = settings.swapScrollDirections ? "left" : "right"
            return "With the pointer in the corner, scroll \(show) to show the shelf and \(hide) to hide it, for example with the thumb wheel on a Logitech mouse. Sideways scrolling anywhere else is ignored. Wrong way round? Turn on Swap directions."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ShotShelf: could not change the login item: %@", String(describing: error))
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Components

/// A tiny screen where you click a corner.
struct CornerPicker: View {
    @Binding var selection: ScreenCorner?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            ForEach(ScreenCorner.allCases) { corner in
                Button { selection = corner } label: {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(selection == corner ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: 16, height: 11)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(corner.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: Alignment(horizontal: corner.isLeft ? .leading : .trailing,
                                            vertical: corner.isTop ? .top : .bottom))
                .padding(5)
            }
        }
        .frame(width: 84, height: 52)
    }
}

struct IconPicker: View {
    @Binding var selection: IconChoice

    var body: some View {
        HStack(spacing: 4) {
            ForEach(IconChoice.allCases) { choice in
                Button { selection = choice } label: {
                    Image(nsImage: choice.symbol)
                        .renderingMode(.template)
                        .frame(width: 26, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selection == choice ? Color.accentColor.opacity(0.25) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(selection == choice ? Color.accentColor : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Press a shortcut…" : (shortcut?.display ?? "Record"))
                    .frame(minWidth: 150)
            }
            if shortcut != nil && !recording {
                ClearButton { shortcut = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        ToggleTriggers.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
            } else if let recorded = KeyShortcut(event: event) {
                shortcut = recorded
                stop()
            } else {
                NSSound.beep() // needs at least one modifier, except for function keys
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { ToggleTriggers.shared.setSuspended(false) }
        recording = false
    }
}

/// Records an extra mouse button (middle, back, forward, …).
struct MouseTriggerRecorder: View {
    @Binding var trigger: MouseTrigger?
    @State private var recording = false
    @State private var monitors: [Any] = []

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Press an extra mouse button…" : (trigger?.name ?? "Record"))
                    .frame(minWidth: 150)
            }
            if trigger != nil && !recording {
                ClearButton { trigger = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        ToggleTriggers.shared.setSuspended(true)
        let capture: (NSEvent) -> Void = { event in
            trigger = .button(event.buttonNumber)
            stop()
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { capture($0); return nil }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown, handler: capture) {
            monitors.append(global)
        }
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if Int(event.keyCode) == kVK_Escape { stop(); return nil }
            return event
        }) {
            monitors.append(escape)
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if recording { ToggleTriggers.shared.setSuspended(false) }
        recording = false
    }
}

private struct ClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear")
    }
}

struct UpdateStatusView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.state {
        case .notConfigured:
            Text("No update source configured").foregroundColor(.secondary)
        case .idle:
            Button("Check Now") { updater.check() }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate(let date):
            HStack(spacing: 6) {
                Label("Up to date", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                Button("Check Again") { updater.check() }
                    .help("Last checked at \(date.formatted(date: .omitted, time: .shortened))")
            }
        case .available(let version):
            HStack(spacing: 6) {
                Text("Version \(version) available")
                Button("Download") { updater.download() }
            }
        case .downloading(let version, let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 90)
                Text("Downloading \(version)…")
            }
        case .ready(let version):
            HStack(spacing: 6) {
                Text("\(version) is ready")
                Button("Relaunch and Install") { updater.installAndRelaunch() }
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Text(message).foregroundColor(.secondary).lineLimit(2)
                Button("Check Again") { updater.check() }
            }
        }
    }
}

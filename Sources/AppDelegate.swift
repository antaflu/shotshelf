import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let updater = Updater.shared
    private let controller = ShelfController()
    private let watcher = ScreenshotWatcher(directory: ShelfStore.stagingURL)
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    private enum Key {
        static let savedLocation = "OriginalCaptureLocation"
        static let hadLocation = "HadOriginalCaptureLocation"
        static let savedThumbnail = "OriginalShowThumbnail"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()
        setUpStatusItem()
        applyAppearance()
        redirectScreenshots()

        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        ToggleTriggers.shared.onToggle = { [weak self] in self?.controller.toggle() }
        ToggleTriggers.shared.onShow = { [weak self] in self?.controller.show(allowEmpty: true) }
        ToggleTriggers.shared.onHide = { [weak self] in self?.controller.hide() }
        ToggleTriggers.shared.start()

        watcher.onNewScreenshot = { [weak self] url in self?.handleNewScreenshot(url) }
        // Screenshots left over from a previous session go back on the shelf.
        for url in watcher.existingFiles() { controller.store.add(url) }
        watcher.start()
        if !controller.store.isEmpty { controller.show() }

        Publishers.Merge3(
            settings.$showDockIcon.map { _ in () },
            settings.$showMenuBarIcon.map { _ in () },
            settings.$icon.map { _ in () })
            .dropFirst(3)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyAppearance() }
            .store(in: &cancellables)
        settings.$hideSystemPreview
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applySystemPreview()
                CapturePrefs.reloadUI()
            }
            .store(in: &cancellables)

        updater.startAutomaticChecks()
    }

    /// Reopening from Finder or the Dock shows Settings, so they are always
    /// reachable, even with both the menu bar and Dock icons turned off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        restoreScreenshotSettings()
        controller.store.flushAll()
        updater.installOnQuitIfReady()
    }

    // MARK: - Nieuw screenshot

    private func handleNewScreenshot(_ url: URL) {
        guard controller.store.add(url) else { return }
        ShelfStore.copyToPasteboard(url)
        controller.show()
    }

    // MARK: - Windows

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show()
    }

    // MARK: - Appearance

    private func applyAppearance() {
        let settingsVisible = settingsWindow?.window?.isVisible == true
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        NSApp.applicationIconImage = settings.showDockIcon ? DockIcon.image(for: settings.icon) : nil

        statusItem?.isVisible = settings.showMenuBarIcon
        let image = settings.icon.symbol
        image.isTemplate = true
        statusItem?.button?.image = image

        // Switching the Dock icon on or off can push the Settings window to the back.
        if settingsVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.settingsWindow?.show() }
        }
    }

    // MARK: - macOS screenshot settings

    /// Makes macOS save screenshots to our staging folder instead of the Desktop.
    private func redirectScreenshots() {
        let staging = ShelfStore.stagingURL.path
        let current = CapturePrefs.string("location")
        let defaults = UserDefaults.standard

        if current != staging {
            defaults.set(current, forKey: Key.savedLocation)
            defaults.set(current != nil, forKey: Key.hadLocation)
        }
        CapturePrefs.set("location", staging as CFString)
        applySystemPreview()
        CapturePrefs.reloadUI()
    }

    private func applySystemPreview() {
        let defaults = UserDefaults.standard
        if settings.hideSystemPreview {
            if defaults.object(forKey: Key.savedThumbnail) == nil {
                defaults.set(CapturePrefs.bool("show-thumbnail") ?? true, forKey: Key.savedThumbnail)
            }
            CapturePrefs.set("show-thumbnail", false as CFBoolean)
        } else if let saved = defaults.object(forKey: Key.savedThumbnail) as? Bool {
            CapturePrefs.set("show-thumbnail", saved as CFBoolean)
            defaults.removeObject(forKey: Key.savedThumbnail)
        }
    }

    /// Restores the user's original settings.
    private func restoreScreenshotSettings() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Key.hadLocation), let saved = defaults.string(forKey: Key.savedLocation) {
            CapturePrefs.set("location", saved as CFString)
        } else {
            CapturePrefs.set("location", nil) // back to the default: the Desktop
        }
        if let saved = defaults.object(forKey: Key.savedThumbnail) as? Bool {
            CapturePrefs.set("show-thumbnail", saved as CFBoolean)
            defaults.removeObject(forKey: Key.savedThumbnail)
        }
        CapturePrefs.reloadUI()
    }

    // MARK: - Menus

    /// Only visible with the Dock icon on, but ⌘, ⌘W and ⌘Q always work.
    private func setUpMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ShotShelf",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ShotShelf", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ShotShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// The menu is rebuilt every time it opens, so it reflects the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = menu.addItem(withTitle: controller.isVisible ? "Hide Shelf" : "Show Shelf",
                                  action: #selector(toggleShelf), keyEquivalent: "")
        toggle.target = self
        if let shortcut = settings.toggleShortcut {
            toggle.title += "   \(shortcut.display)"
        }

        let flush = menu.addItem(withTitle: "Move All to \(settings.saveFolder.lastPathComponent)",
                                 action: #selector(flushAll), keyEquivalent: "")
        flush.target = self
        flush.isEnabled = !controller.store.isEmpty
        menu.autoenablesItems = false

        if case .ready(let version) = updater.state {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Install Update \(version) and Relaunch",
                         action: #selector(installUpdate), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ShotShelf", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func toggleShelf() { controller.toggle() }
    @objc private func flushAll() { controller.dismiss() }
    @objc private func installUpdate() { updater.installAndRelaunch() }
    @objc private func quit() { NSApp.terminate(nil) }
}

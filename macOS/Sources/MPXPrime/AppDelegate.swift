// macOS-only (SwiftUI GUI): the Linux CLI build excludes this file.
#if os(macOS)

import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation
import MPXPrimeCore
import MPXPrimeUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    private let configPath: String
    private let runSeconds: Double?
    private var window: NSWindow?
    private var model: MPXPrimeViewModel?
    private var scopesWindow: NSWindow?
    private var spectrumWindow: NSWindow?
    private var preMPXSpectrumWindow: NSWindow?
    private var levelsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(configPath: String, runSeconds: Double?) {
        self.configPath = configPath
        self.runSeconds = runSeconds
    }

    private func restoreFrame(for window: NSWindow, autosaveName: String) {
        window.setFrameAutosaveName(autosaveName)
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
    }

    private func revealWindow(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == window {
            sender.orderOut(nil)
            return false
        } else if sender == scopesWindow {
            model?.scopesWindowVisible = false
            sender.orderOut(nil)
            return false
        } else if sender == spectrumWindow {
            model?.spectrumWindowVisible = false
            sender.orderOut(nil)
            return false
        } else if sender == preMPXSpectrumWindow {
            model?.preMPXSpectrumWindowVisible = false
            sender.orderOut(nil)
            return false
        } else if sender == levelsWindow {
            model?.levelsWindowVisible = false
            sender.orderOut(nil)
            return false
        } else if sender == aboutWindow {
            sender.orderOut(nil)
            return false
        } else if sender == helpWindow {
            sender.orderOut(nil)
            return false
        } else if sender == settingsWindow {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        showMainWindow()
        return true
    }

    // MARK: - Visibility-driven monitor refresh rate

    @objc private func appBecameActive() {
        model?.setAppActive(true)
    }

    @objc private func appResignedActive() {
        model?.setAppActive(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard (notification.object as AnyObject?) === window else { return }
        model?.setMainWindowMinimized(true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard (notification.object as AnyObject?) === window else { return }
        model?.setMainWindowMinimized(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        let visible = w.occlusionState.contains(.visible)
        model?.setMainWindowOccluded(!visible)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = makeMPXPrimeAppIcon()
        NSApp.activate(ignoringOtherApps: true)

        let vm = MPXPrimeViewModel(configPath: configPath)
        model = vm
        setupMainMenu()

        let root = RootView(model: vm)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.center()
        w.title = "MPX Prime Studio"
        w.titleVisibility = .visible
        w.minSize = NSSize(width: 900, height: 620)
        w.delegate = self
        // Host via contentViewController (not a bare contentView) so the
        // SwiftUI .toolbar content in RootView bridges to the window's
        // unified title-bar toolbar and NavigationSplitView's sidebar-collapse
        // toggle appears. Matches how the secondary windows are hosted.
        w.toolbarStyle = .unified
        let mainHost = NSHostingController(rootView: root)
        // Do NOT let the hosting controller drive the window size from the
        // SwiftUI content's ideal size (the default .preferredContentSize):
        // the tall NavigationSplitView would otherwise push the window past
        // the screen and the sidebar would scroll beyond the window. The
        // window manages its own frame; the content fills and scrolls within.
        mainHost.sizingOptions = []
        restoreFrame(for: w, autosaveName: kMainWindowAutosaveName)
        w.contentViewController = mainHost
        w.makeKeyAndOrderFront(nil)
        window = w

        vm.startMonitoringTimer()

        // Drop the meter / scope refresh rate when the app is inactive,
        // minimized, or fully occluded. The on-screen rate is restored
        // immediately when any of these flips back.
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appResignedActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        if vm.autoStartEnabled {
            // The Stop+Start watchdog that used to live here was a
            // workaround for AVAudioEngine's first-start failure on
            // non-default input devices. The input path now uses a
            // direct AUHAL audio unit (`InputAUHAL`) per TN2091,
            // which doesn't have that bug — auto-start delivers
            // frames immediately on the first try.
            DispatchQueue.main.async { [weak vm] in
                vm?.startOrStopTransport(forceStart: true)
            }
        }

        if let secs = runSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(applyPendingChanges) {
            menuItem.title = model?.runtimeApplyButtonTitle ?? "Apply Restart"
            return model?.runtimeApplyPending ?? false
        }
        if menuItem.action == #selector(toggleInspector) {
            menuItem.state = (model?.inspectorVisible ?? false) ? .on : .off
            return true
        }
        // Composite-domain windows are meaningless in processed-audio output;
        // disable them (and the RDS section jump). Use the Audio Spectrum window
        // for the processed L/R spectrum.
        if let action = menuItem.action, model?.processedAudioOutputActive == true {
            if action == #selector(showSpectrumWindow) || action == #selector(showScopesWindow)
                || action == #selector(goToRDS) {
                return false
            }
        }
        if let action = menuItem.action,
           action == #selector(goToMonitoring) || action == #selector(goToProcessing)
               || action == #selector(goToRDS) || action == #selector(goToTools) {
            let targetGroup: Stage.Group
            switch action {
            case #selector(goToMonitoring): targetGroup = .monitoring
            case #selector(goToProcessing): targetGroup = .processing
            case #selector(goToRDS): targetGroup = .rds
            default: targetGroup = .tools
            }
            menuItem.state = (model?.selectedStage.group == targetGroup) ? .on : .off
            return true
        }
        return true
    }

    private func setupMainMenu() {
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "MPX Prime Studio"
        let mainMenu = NSMenu()

        // App Menu (unchanged)
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        let aboutItem = appMenu.addItem(
            withTitle: "About \(appName)", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = NSMenu(
            title: "Services")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File Menu
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(openConfig), keyEquivalent: "o")
        openItem.target = self
        let saveItem = fileMenu.addItem(withTitle: "Save", action: #selector(saveConfig), keyEquivalent: "s")
        saveItem.target = self
        let saveAsItem = fileMenu.addItem(withTitle: "Save As…", action: #selector(saveConfigAs), keyEquivalent: "S")
        saveAsItem.target = self
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit Menu — without these items the responder chain never routes
        // cut / copy / paste / select all to the focused text field, so those
        // keyboard shortcuts silently do nothing.
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        let dictationItem = editMenu.addItem(
            withTitle: "Start Dictation…",
            action: Selector(("startDictation:")),
            keyEquivalent: "")
        dictationItem.isEnabled = true
        let emojiItem = editMenu.addItem(
            withTitle: "Emoji & Symbols",
            action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
            keyEquivalent: " ")
        emojiItem.keyEquivalentModifierMask = [.control, .command]
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // View Menu — toggles for the right-pane Inspector and other
        // workspace-level visibility states. Standard ⌥⌘I shortcut for
        // inspector matches Pages, Keynote, Logic Pro, Final Cut.
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        let inspectorItem = viewMenu.addItem(
            withTitle: "Inspector",
            action: #selector(toggleInspector),
            keyEquivalent: "i")
        inspectorItem.target = self
        inspectorItem.keyEquivalentModifierMask = [.command, .option]

        viewMenu.addItem(NSMenuItem.separator())
        let testToneItem = viewMenu.addItem(
            withTitle: "Test Tone…",
            action: #selector(showTestToneTab),
            keyEquivalent: "t")
        testToneItem.target = self
        testToneItem.keyEquivalentModifierMask = [.command]

        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Go Menu — ⌘1-⌘4 jump to a sidebar section. Matches the
        // section-shortcut pattern in Mail, Music, Notes (sidebar-driven
        // macOS apps). Each item remembers the last sub-tab visited
        // in that group, so ⌘2 from RDS returns to the Processing
        // sub-tab the operator was last editing.
        let goItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        let goMenu = NSMenu(title: "Go")
        let goMonitoring = goMenu.addItem(
            withTitle: "Monitoring",
            action: #selector(goToMonitoring),
            keyEquivalent: "1")
        goMonitoring.target = self
        let goProcessing = goMenu.addItem(
            withTitle: "Processing",
            action: #selector(goToProcessing),
            keyEquivalent: "2")
        goProcessing.target = self
        let goRDS = goMenu.addItem(
            withTitle: "RDS",
            action: #selector(goToRDS),
            keyEquivalent: "3")
        goRDS.target = self
        let goTools = goMenu.addItem(
            withTitle: "Tools",
            action: #selector(goToTools),
            keyEquivalent: "4")
        goTools.target = self
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        // Control Menu
        let transportItem = NSMenuItem(title: "Control", action: nil, keyEquivalent: "")
        let transportMenu = NSMenu(title: "Control")

        // ⌘T is reserved for "New Tab" per macOS convention; use ⌘Return for
        // the transport toggle instead.
        let startStopItem = transportMenu.addItem(
            withTitle: "Start/Stop", action: #selector(toggleTransport), keyEquivalent: "\r"
        )
        startStopItem.target = self
        startStopItem.keyEquivalentModifierMask = [.command]
        let bypassItem = transportMenu.addItem(
            withTitle: "Bypass", action: #selector(toggleBypass), keyEquivalent: "b")
        bypassItem.target = self
        let resetPeaksItem = transportMenu.addItem(
            withTitle: "Reset Peaks", action: #selector(resetPeaks), keyEquivalent: "r")
        resetPeaksItem.target = self
        transportMenu.addItem(NSMenuItem.separator())
        let applyItem = transportMenu.addItem(
            withTitle: "Apply Restart", action: #selector(applyPendingChanges), keyEquivalent: "A")
        applyItem.target = self
        applyItem.keyEquivalentModifierMask = [.command, .shift]

        transportItem.submenu = transportMenu
        mainMenu.addItem(transportItem)

        // Window Menu
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")

        // No keyEquivalent: ⌘1 is reserved by the Go menu for "Monitoring".
        // Operators jump back to the main window via the Window menu or
        // by clicking on it; this entry just brings it forward when it
        // was hidden behind a detached window.
        let mainWindowItem = windowMenu.addItem(withTitle: "Main", action: #selector(showMainWindow), keyEquivalent: "")
        mainWindowItem.target = self
        let preMPXSpectrumItem = windowMenu.addItem(withTitle: kAudioSpectrumWindowTitle, action: #selector(showPreMPXSpectrumWindow), keyEquivalent: "7")
        preMPXSpectrumItem.target = self
        let spectrumItem = windowMenu.addItem(withTitle: kMPXSpectrumWindowTitle, action: #selector(showSpectrumWindow), keyEquivalent: "8")
        spectrumItem.target = self
        let levelsItem = windowMenu.addItem(withTitle: kLevelsWindowTitle, action: #selector(showLevelsWindow), keyEquivalent: "9")
        levelsItem.target = self
        // ⌘0 is reserved for "Actual Size" per macOS convention. Use ⇧⌘0 so
        // the numeric-window mnemonic is preserved without stepping on zoom.
        let scopesItem = windowMenu.addItem(withTitle: kScopesWindowTitle, action: #selector(showScopesWindow), keyEquivalent: "0")
        scopesItem.target = self
        scopesItem.keyEquivalentModifierMask = [.command, .shift]

        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")

        let openHelp = NSMenuItem(title: "MPX Prime Studio Help", action: #selector(showHelp), keyEquivalent: "/")
        openHelp.target = self
        openHelp.keyEquivalentModifierMask = [.command, .shift]
        helpMenu.addItem(openHelp)

        helpMenu.addItem(NSMenuItem.separator())

        let docs = NSMenuItem(title: "Online Documentation", action: #selector(openDocs), keyEquivalent: "")
        docs.target = self
        docs.isEnabled = true
        helpMenu.addItem(docs)

        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        if let existing = aboutWindow {
            revealWindow(existing)
            return
        }
        let aboutView = AboutSectionView()
        let hostingController = NSHostingController(rootView: aboutView)
        let w = NSWindow(contentViewController: hostingController)
        w.title = "About MPX Prime Studio"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 400, height: 560))
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kAboutWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        aboutWindow = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func showHelp() {
        if let existing = helpWindow {
            revealWindow(existing)
            return
        }
        let helpView = HelpWindowView()
        let hostingController = NSHostingController(rootView: helpView)
        let w = NSWindow(contentViewController: hostingController)
        w.title = "MPX Prime Studio Help"
        // Utility/documentation windows should not minimize (macOS HIG —
        // matches About / Settings styleMasks). Resizable so long help
        // text remains usable on smaller displays.
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 560))
        w.minSize = NSSize(width: 520, height: 420)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kHelpWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        helpWindow = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func openDocs() {
        NSWorkspace.shared.open(kProjectURL)
    }

    @objc private func showSettings() {
        if let existing = settingsWindow {
            revealWindow(existing)
            return
        }
        guard let vm = model else { return }
        let settingsView = SettingsWindowView(model: vm)
        let hostingController = NSHostingController(rootView: settingsView)
        let w = NSWindow(contentViewController: hostingController)
        w.title = "Settings"
        // Settings windows should not minimize (macOS HIG). Keep resizable so
        // long device lists remain usable on small displays.
        w.styleMask = [.titled, .closable, .resizable]
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 780, height: 620))
        w.minSize = NSSize(width: 700, height: 520)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kSettingsWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        settingsWindow = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func toggleInspector() {
        guard let vm = model else { return }
        vm.inspectorVisible.toggle()
    }

    @objc private func showTestToneTab() {
        guard let vm = model else { return }
        vm.selectedStage = .testTone
        // Bring the main window forward so ⌘T from a detached
        // visualizer still feels right (the new tab is the focus).
        if let w = window { w.makeKeyAndOrderFront(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func toggleTransport() {
        model?.startOrStopTransport()
    }

    @objc private func toggleBypass() {
        model?.toggleBypass()
    }

    @objc private func resetPeaks() {
        model?.resetPeaks()
    }

    @objc private func goToMonitoring() { model?.goToGroup(.monitoring) }
    @objc private func goToProcessing() { model?.goToGroup(.processing) }
    @objc private func goToRDS() { model?.goToGroup(.rds) }
    @objc private func goToTools() { model?.goToGroup(.tools) }

    @objc private func saveConfig() {
        model?.saveCurrentConfig()
    }

    @objc private func applyPendingChanges() {
        model?.applyPendingRuntimeChanges()
    }

    @objc private func showMainWindow() {
        if let existing = window {
            revealWindow(existing)
            return
        }
        guard let vm = model else { return }
        let root = RootView(model: vm)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.center()
        w.title = "MPX Prime Studio"
        w.titleVisibility = .visible
        w.minSize = NSSize(width: 900, height: 620)
        w.delegate = self
        w.toolbarStyle = .unified
        let mainHost = NSHostingController(rootView: root)
        // See applicationDidFinishLaunching: keep the window sizing itself,
        // not driven by the SwiftUI content's ideal size.
        mainHost.sizingOptions = []
        restoreFrame(for: w, autosaveName: kMainWindowAutosaveName)
        w.contentViewController = mainHost
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func showScopesWindow() {
        // Composite scope is meaningless in processed-audio output.
        if model?.processedAudioOutputActive == true { return }
        if let existing = scopesWindow {
            revealWindow(existing)
            model?.scopesWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let scopesView = ScopesOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: scopesView)
        // Flexibly sized: the window drives the size and the SwiftUI content
        // fills it, so suppress the hosting controller's auto-added min /
        // intrinsic / max Auto Layout constraints. On a high-refresh window
        // this avoids per-update constraint recomputation piling up in AppKit's
        // layout engine -- a documented long-running SwiftUI-on-macOS slowdown.
        hostingController.sizingOptions = []
        let w = NSWindow(contentViewController: hostingController)
        w.title = kScopesWindowTitle
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: kWindowWidth, height: kWindowHeight))
        w.minSize = NSSize(width: kWindowMinWidth, height: kWindowMinHeight)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kScopesWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        scopesWindow = w
        model?.scopesWindowVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Close the composite-only auxiliary windows (MPX Spectrum, Scopes). Invoked
    /// when the engine (re)starts in processed-audio mode so a window left open
    /// from composite mode doesn't keep showing a now-meaningless view.
    @objc func closeCompositeOnlyAuxWindows() {
        scopesWindow?.close()
        spectrumWindow?.close()
    }

    @objc func showSpectrumWindow() {
        // The composite (MPX) spectrum is meaningless in processed-audio output;
        // the Audio Spectrum window shows the processed L/R spectrum instead.
        if model?.processedAudioOutputActive == true { return }
        if let existing = spectrumWindow {
            revealWindow(existing)
            model?.spectrumWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let spectrumView = SpectrumOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: spectrumView)
        hostingController.sizingOptions = []  // window drives size; avoid per-update constraint churn (see Scopes window)
        let w = NSWindow(contentViewController: hostingController)
        w.title = kMPXSpectrumWindowTitle
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: kWindowWidth, height: kWindowHeight))
        w.minSize = NSSize(width: kWindowMinWidth, height: kWindowMinHeight)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kSpectrumWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        spectrumWindow = w
        model?.spectrumWindowVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func showPreMPXSpectrumWindow() {
        if let existing = preMPXSpectrumWindow {
            revealWindow(existing)
            model?.preMPXSpectrumWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let spectrumView = PreMPXSpectrumOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: spectrumView)
        hostingController.sizingOptions = []  // window drives size; avoid per-update constraint churn (see Scopes window)
        let w = NSWindow(contentViewController: hostingController)
        w.title = kAudioSpectrumWindowTitle
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: kWindowWidth, height: kWindowHeight))
        w.minSize = NSSize(width: kWindowMinWidth, height: kWindowMinHeight)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kPreMPXSpectrumWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        preMPXSpectrumWindow = w
        model?.preMPXSpectrumWindowVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func showLevelsWindow() {
        if let existing = levelsWindow {
            revealWindow(existing)
            model?.levelsWindowVisible = true
            return
        }
        guard let vm = model else { return }
        let levelsView = LevelsOnlyView(model: vm)
        let hostingController = NSHostingController(rootView: levelsView)
        hostingController.sizingOptions = []  // window drives size; avoid per-update constraint churn (see Scopes window)
        let w = NSWindow(contentViewController: hostingController)
        w.title = kLevelsWindowTitle
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: kLevelsWindowWidth, height: kLevelsWindowHeight))
        w.minSize = NSSize(width: kLevelsWindowMinWidth, height: kLevelsWindowMinHeight)
        w.isReleasedWhenClosed = false
        w.delegate = self
        restoreFrame(for: w, autosaveName: kLevelsWindowAutosaveName)
        w.makeKeyAndOrderFront(nil)
        levelsWindow = w
        model?.levelsWindowVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func openConfig() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = Self.iniContentTypes
        openPanel.message = "Choose a configuration file to open"
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false

        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            self?.model?.loadConfigFromFile(url.path)
        }
    }

    /// Accepted content types for INI config file dialogs. Falls back to
    /// `UTType.propertyList` if the system cannot resolve a UTType for the
    /// literal `ini` extension (avoids a force-unwrap crash on older systems).
    private static var iniContentTypes: [UTType] {
        if let ini = UTType(filenameExtension: "ini") {
            return [ini]
        }
        return [.propertyList, .plainText]
    }

    @objc private func saveConfigAs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = Self.iniContentTypes
        savePanel.message = "Save configuration as…"
        savePanel.nameFieldStringValue = "config.ini"

        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            self?.model?.saveConfigToFile(url.path)
        }
    }

}

#endif  // os(macOS)

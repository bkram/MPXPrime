import AppKit
import SwiftUI

// Hosts the single Meter window. Built programmatically (no nib): NSWindow +
// NSHostingController with sizingOptions = [] so a Canvas repaint never
// re-runs window Auto Layout (the documented freeze guard). Mirrors the
// MPX Prime transmit AppDelegate window pattern.
@MainActor
final class MeterAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let vm = MeterViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: RootMeterView(vm: vm))
        hosting.sizingOptions = []

        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "MPX Prime Meter"
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 1040, height: 820))
        w.setFrameAutosaveName("MeterMainWindow")
        if w.frame.origin == .zero { w.center() }
        window = w

        setupMainMenu()
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore the input device's prior sample rate.
        vm.stop()
    }

    // Minimal main menu: app (About/Quit), Edit (so text selection/copy works
    // in the RDS readout), Window.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MPX Prime Meter",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MPX Prime Meter",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

import AppKit
import Combine
import SwiftUI

// Hosts the single Meter window. Built programmatically (no nib): NSWindow +
// NSHostingController with sizingOptions = [] so a Canvas repaint never
// re-runs window Auto Layout (the documented freeze guard). Mirrors the
// MPX Prime transmit AppDelegate window pattern.
@MainActor
final class MeterAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let vm = MeterViewModel()
    private let autoStartSDRFreqMHz: Double?
    private var subtitleCancellable: AnyCancellable?

    init(autoStartSDRFreqMHz: Double? = nil) {
        self.autoStartSDRFreqMHz = autoStartSDRFreqMHz
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: RootMeterView(vm: vm))
        hosting.sizingOptions = []

        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "MPX Prime Meter"
        w.toolbarStyle = .unified
        // Use the operator's screen well: default to most of the visible frame
        // (the spectrum row absorbs the extra height), bounded so it stays sane
        // on very large displays. The autosaved frame (below) wins on relaunch.
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        w.setContentSize(NSSize(
            width: min(1480, visible.width - 80),
            height: min(1100, visible.height - 60)))
        w.contentMinSize = NSSize(width: 1020, height: 700)
        w.setFrameAutosaveName("MeterMainWindow")
        if w.frame.origin == .zero { w.center() }
        // Status line lives in the native window subtitle (HIG) rather than a
        // content-area status bar; statusText changes only on start/stop/error.
        w.subtitle = vm.statusText
        subtitleCancellable = vm.$statusText.sink { [weak w] text in
            w?.subtitle = text
        }
        window = w

        applyAppIcon()
        setupMainMenu()
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Don't leave the Frequency text field first-responder (and its contents
        // selected) on launch -- start with no focused field.
        DispatchQueue.main.async { [weak w] in w?.makeFirstResponder(nil) }

        // Launched via run-meter-sdr.sh --gui: pre-tune the SDR and start.
        if let freq = autoStartSDRFreqMHz, vm.sdrAvailable {
            vm.inputKind = .sdr
            vm.frequencyMHz = freq
            vm.start()
        } else if vm.inputKind == .sdr, SDRLibraryInputSource.deviceCount() > 0 {
            // A dongle is present: start capturing (with audio monitoring) right
            // away so the app opens live in SDR mode instead of idle.
            vm.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist the last-used settings, then restore the input device rate.
        vm.saveSettings()
        vm.stop()
    }

    // Standard macOS main menu: App (About / Hide / Quit), Edit (text
    // selection/copy in the RDS readout), Window, Help.
    private func setupMainMenu() {
        let app = "MPX Prime Meter"
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(app)",
                        action: #selector(showAboutPanel), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(app)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(app)",
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

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "\(app) Help",
                         action: #selector(openManual), keyEquivalent: "?").target = self
        helpItem.submenu = helpMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - About / Help / icon

    private static let projectURL = URL(string: "https://github.com/bkram/MPXPrime")!
    private static let manualURL = URL(string: "https://github.com/bkram/MPXPrime/blob/main/docs/manual-meter.md")!
    private static let licenseURL = URL(string: "https://github.com/bkram/MPXPrime/blob/main/LICENSE")!

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    @objc private func openManual() {
        NSWorkspace.shared.open(Self.manualURL)
    }

    /// A proper About: the native panel with a description, clickable links, and
    /// the README's canonical disclaimer key phrase (single source of truth --
    /// the full disclaimer lives in README, GPL-3.0 terms in LICENSE).
    @objc private func showAboutPanel() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        credits.append(NSAttributedString(
            string: "Companion analyzer to MPX Prime Studio: decodes an FM MPX "
                + "composite (stereo + RDS) from an audio device or RTL-SDR.\n\n",
            attributes: body))

        func link(_ text: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .link: url, .font: NSFont.systemFont(ofSize: 11)
            ])
        }
        credits.append(link("GitHub", Self.projectURL))
        credits.append(NSAttributedString(string: "   ", attributes: body))
        credits.append(link("User Manual", Self.manualURL))
        credits.append(NSAttributedString(string: "   ", attributes: body))
        credits.append(link("License", Self.licenseURL))
        credits.append(NSAttributedString(
            string: "\n\nExperimental and not certified -- no conformity or "
                + "compliance is promised. See the README for intended use and "
                + "the GPL-3.0 license (provided without warranty).",
            attributes: body))

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para,
                             range: NSRange(location: 0, length: credits.length))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MPX Prime Meter",
            .applicationVersion: appVersion,
            .version: "GPL-3.0",
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Set the running process's Dock + About icon. The bundled .app already
    /// gets its Finder icon from CFBundleIconFile; this also gives the
    /// *unbundled* `swift run` / CLI binary a real Dock icon (no bundle exists
    /// for LaunchServices to read). Prefer the bundled .icns if present, else
    /// draw it at runtime (same art as generate_meter_icon.swift).
    private func applyAppIcon() {
        if let url = Bundle.main.url(forResource: "MPXPrimeMeter", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        } else {
            NSApp.applicationIconImage = MeterIcon.image(size: 512)
        }
    }
}

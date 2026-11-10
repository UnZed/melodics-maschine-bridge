import AppKit

final class BridgeApp: NSObject, NSApplicationDelegate {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 235),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered, defer: false
    )
    private let status = NSTextField(wrappingLabelWithString: "Ready to start the bridge.")
    private let action = NSButton(title: "Start Bridge", target: nil, action: nil)
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Melodics Maschine Bridge/bridge.log")
    private var bridge: Process?
    private var timer: Timer?
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let title = NSTextField(labelWithString: "Melodics → Maschine")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let instruction = NSTextField(wrappingLabelWithString:
            "Connect your Maschine over USB. Start the bridge, then open Melodics and select MLP Maschine 4x4.")
        instruction.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13, weight: .medium)
        action.target = self
        action.action = #selector(toggleBridge)
        action.keyEquivalent = "\r"
        let log = NSButton(title: "Open Log", target: self, action: #selector(openLog))
        let buttons = NSStackView(views: [action, log])
        buttons.spacing = 10

        let content = NSStackView(views: [title, instruction, status, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 15
        content.edgeInsets = NSEdgeInsets(top: 23, left: 24, bottom: 20, right: 24)
        window.contentView = content
        instruction.widthAnchor.constraint(lessThanOrEqualToConstant: 412).isActive = true
        status.widthAnchor.constraint(lessThanOrEqualToConstant: 412).isActive = true
        window.title = "Melodics Maschine Bridge"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(item)
    }

    @objc private func toggleBridge() {
        if let bridge {
            stopping = true
            status.stringValue = "Stopping…"
            action.isEnabled = false
            bridge.interrupt()
            return
        }
        guard let resources = Bundle.main.resourceURL else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-B", resources.appendingPathComponent("ipc_bridge.py").path, "--native-4x4"]
        child.currentDirectoryURL = resources
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: logURL, options: .atomic)
            let output = try FileHandle(forWritingTo: logURL)
            defer { try? output.close() }
            child.standardOutput = output
            child.standardError = output
            try child.run()
            bridge = child
            stopping = false
            action.title = "Stop Bridge"
            status.stringValue = "Connecting to Maschine…"
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        } catch {
            status.stringValue = "Could not start. \(error.localizedDescription)"
        }
    }

    private func refresh() {
        guard let bridge else { return }
        if !bridge.isRunning {
            timer?.invalidate()
            self.bridge = nil
            action.isEnabled = true
            action.title = "Start Bridge"
            status.stringValue = stopping ? "Bridge stopped." : "The bridge stopped. Open the log for details."
        } else if !stopping && status.stringValue == "Connecting to Maschine…" {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if log.contains("READY: MLP Maschine 4x4") {
                status.stringValue = "Running · MLP Maschine 4x4"
            }
        }
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            status.stringValue = "The log is created when the bridge starts."
            return
        }
        NSWorkspace.shared.open(logURL)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let bridge, bridge.isRunning { bridge.interrupt() }
    }
}

let application = NSApplication.shared
let delegate = BridgeApp()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()

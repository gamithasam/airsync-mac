import AppKit

final class HandoffDockDelegate: NSObject, NSApplicationDelegate {
    private var connection: HandoffChannel?
    private var state: HandoffDockState?
    private var opening = false
    private var watchdog: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--socket"), args.indices.contains(index + 1),
              let link = try? HandoffChannel.connect(path: args[index + 1]) else {
            NSApp.terminate(nil)
            return
        }
        connection = link
        link.onPacket = { [weak self] packet in
            DispatchQueue.main.async {
                switch packet.kind {
                case .update:
                    if let state = packet.state, let data = try? JSONEncoder().encode(state) { self?.update(data) }
                case .result:
                    self?.opening = false
                    if let error = packet.error {
                        let alert = NSAlert()
                        alert.messageText = "Couldn't open app"
                        alert.informativeText = error
                        alert.runModal()
                    }
                case .shutdown: NSApp.terminate(nil)
                default: break
                }
            }
        }
        link.onClose = { DispatchQueue.main.async { NSApp.terminate(nil) } }
        link.start()
        link.send(HandoffPacket(kind: .snapshot))
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.connection?.send(HandoffPacket(kind: .snapshot))
        }
    }

    func update(_ data: Data) {
        DispatchQueue.main.async {
            guard let state = try? JSONDecoder().decode(HandoffDockState.self, from: data) else { return }
            self.state = state
            let base = state.iconPNG.flatMap(NSImage.init(data:)) ?? NSImage(named: NSImage.applicationIconName)
            let image = NSImage(size: NSSize(width: 128, height: 128))
            image.lockFocus()
            base?.draw(in: NSRect(x: 8, y: 8, width: 112, height: 112))
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 83, y: 0, width: 44, height: 48), xRadius: 12, yRadius: 12).fill()
            NSImage(systemSymbolName: "iphone", accessibilityDescription: "From Android phone")?
                .draw(in: NSRect(x: 92, y: 6, width: 26, height: 36))
            image.unlockFocus()
            NSApp.applicationIconImage = image
        }
    }

    func shutdown() { DispatchQueue.main.async { NSApp.terminate(nil) } }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHandoff()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let state else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Open \(state.appName) from \(state.phoneName)", action: #selector(openHandoff), keyEquivalent: "")
        item.target = self
        let dismiss = menu.addItem(withTitle: "Dismiss", action: #selector(dismissHandoff), keyEquivalent: "")
        dismiss.target = self
        return menu
    }

    @objc private func openHandoff() {
        guard let state, !opening else { return }
        opening = true
        connection?.send(HandoffPacket(kind: .open, eventID: state.eventID))
    }

    @objc private func dismissHandoff() {
        guard let state else { return }
        connection?.send(HandoffPacket(kind: .dismiss, eventID: state.eventID))
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog?.invalidate()
        connection?.close()
    }
}

let application = NSApplication.shared
let delegate = HandoffDockDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()

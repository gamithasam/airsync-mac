import AppKit

/// Run with the built helper bundle path. Exercises real LaunchServices reopen and IPC.
final class HelperIntegration {
    var link: HandoffChannel?
    var app: NSRunningApplication?
    var connected = false
    var opened = false
    var state = HandoffDockState(eventID: "test:1", appName: "Test App", phoneName: "Test Phone", iconPNG: nil)
    func accept(_ channel: HandoffChannel) {
        precondition(channel.peerIsCurrentUser && channel.peerPID != nil)
        link = channel
        channel.onPacket = { packet in
            DispatchQueue.main.async {
                if packet.kind == .snapshot {
                    self.connected = true
                    channel.send(HandoffPacket(kind: .update, state: self.state))
                } else if packet.kind == .open {
                    self.opened = packet.eventID == self.state.eventID
                    channel.send(HandoffPacket(kind: .result))
                }
            }
        }
        channel.start()
    }
}

@main struct HandoffHelperIntegration {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the built helper .app path") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let host = HelperIntegration()
        let listener = try HandoffSocketListener()
        listener.start { channel in DispatchQueue.main.async { host.accept(channel) } }
        defer { listener.close(); host.link?.close(); host.app?.terminate() }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.arguments = ["--socket", listener.path]
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            precondition(error == nil, "Helper failed to launch: \(String(describing: error))")
            host.app = app
        }
        func wait(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            precondition(predicate(), "Helper timed out")
        }
        wait { host.connected && host.app != nil }
        precondition(host.app?.activationPolicy == .regular)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID,
                     "Helper stole focus on launch")
        let reopen = NSWorkspace.OpenConfiguration()
        reopen.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: reopen) { _, _ in }
        wait { host.opened }
        host.state = HandoffDockState(eventID: "test:2", appName: "Updated App", phoneName: "Test Phone", iconPNG: nil)
        host.link?.send(HandoffPacket(kind: .update, state: host.state))
        host.link?.send(HandoffPacket(kind: .shutdown))
        wait { host.app?.isTerminated == true }
        host.connected = false
        host.app = nil
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            precondition(error == nil)
            host.app = app
        }
        wait { host.connected && host.app != nil }
        host.link?.close()
        wait { host.app?.isTerminated == true }
        listener.close()
        print("Dock helper launch without focus, IPC snapshot, reopen, update, shutdown, and IPC loss cleanup passed")
    }
}

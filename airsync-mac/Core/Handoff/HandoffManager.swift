import AppKit
import Combine

/// Owns the foreground app handoff and routes launches. The Dock app only presents it.
final class HandoffManager: NSObject, ObservableObject {
    static let shared = HandoffManager()
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "handoffEnabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "handoffEnabled")
            if !isEnabled { clear() }
            else { WebSocketServer.shared.requestHandoff() }
        }
    }
    @Published private(set) var error: String?
    private var current: (package: String, dock: HandoffDockState)?
    private var memory = HandoffMemory()
    private var opening = false
    private var listener: HandoffSocketListener?
    private var connection: HandoffChannel?
    private var helper: NSRunningApplication?
    private var launchingHelper = false
    private var generation = UUID()
    private var peerSupported = false
    private var cancellables = Set<AnyCancellable>()
    private var recovery: DispatchWorkItem?

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AirSync Handoff.app")
    }

    override private init() {
        super.init()
        AppState.shared.$device.receive(on: DispatchQueue.main).sink { [weak self] device in
            if device == nil { self?.resetSession() }
        }.store(in: &cancellables)
        AppState.shared.$androidApps.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshIcon()
        }.store(in: &cancellables)
        Publishers.CombineLatest3(AppState.shared.$notificationLaunchPreferences, AppState.shared.$adbConnected, AppState.shared.$isPlus)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, self.peerSupported, self.isEnabled else { return }
                if let current = self.current, !self.hasRoute(current.package) { self.clear() }
                WebSocketServer.shared.requestHandoff()
            }.store(in: &cancellables)
    }

    func beginSession(version: Int) {
        resetSession()
        peerSupported = version == 1
    }

    func receive(_ data: [String: Any]) {
        guard isEnabled, peerSupported, AppState.shared.device != nil,
              let package = data["package"] as? String, !package.isEmpty, package.count < 256,
              let event = data["eventID"] as? String, !event.isEmpty, event.count < 128,
              let name = data["displayName"] as? String, !name.isEmpty else { return }
        guard memory.accept(HandoffActivity(package: package, name: name, eventID: event), eligible: hasRoute(package)) else {
            clear()
            return
        }
        error = nil
        current = (package, HandoffDockState(eventID: event, appName: String(name.prefix(128)),
                   phoneName: AppState.shared.device?.name ?? "Phone", iconPNG: icon(package)))
        publish()
    }

    func unavailable() { clear() }
    func resetSession() {
        peerSupported = false
        memory.reset()
        clear()
    }

    private func targets(_ package: String) -> HandoffTargets {
        let defaults = NotificationLaunchDefaults.findDefault(for: package)
        return HandoffTargets(preference: AppState.shared.notificationLaunchPreferences[package]?.target,
                              defaultBundle: defaults?.macBundleID, defaultWebsite: defaults?.webFallbackURL)
    }
    private func macTarget(_ package: String) -> String? { targets(package).macBundle }
    private func website(_ package: String) -> URL? { targets(package).website }
    private func isDisabled(_ package: String) -> Bool { targets(package).disabled }
    private var canMirror: Bool {
        AppState.shared.device != nil && AppState.shared.adbConnected && AppState.shared.isPlus &&
        ADBConnector.findExecutable(named: "scrcpy", fallbackPaths: ADBConnector.possibleScrcpyPaths) != nil
    }
    private func hasRoute(_ package: String) -> Bool {
        let target = targets(package)
        let installed = target.macBundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil
        return !target.routes(macInstalled: installed, mirrorReady: canMirror).isEmpty
    }

    private func icon(_ package: String) -> Data? {
        if let path = AppState.shared.androidApps[package]?.iconUrl,
           let image = NSImage(contentsOfFile: path) { return png(image) }
        return png(NSApp.applicationIconImage)
    }
    private func png(_ image: NSImage?) -> Data? {
        guard let image else { return nil }
        let scaled = NSImage(size: NSSize(width: 128, height: 128))
        scaled.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        scaled.unlockFocus()
        return scaled.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
    }
    private func refreshIcon() {
        guard let old = current else { return }
        let updated = icon(old.package)
        guard updated != old.dock.iconPNG else { return }
        current = (old.package, HandoffDockState(eventID: old.dock.eventID, appName: old.dock.appName,
                    phoneName: old.dock.phoneName, iconPNG: updated))
        publish()
    }
    private var encoded: Data? { current.flatMap { try? JSONEncoder().encode($0.dock) } }

    private func publish() {
        if let connection, let encoded {
            if let state = try? JSONDecoder().decode(HandoffDockState.self, from: encoded) { connection.send(HandoffPacket(kind: .update, state: state)) }
        } else if !launchingHelper {
            launchHelper()
        }
    }
    private func launchHelper() {
        guard current != nil else { return }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            error = "AirSync Handoff helper is missing. Reinstall or rebuild AirSync."
            return
        }
        do {
            let server = try HandoffSocketListener()
            listener = server
            let socketPath = server.path
            server.start { [weak self] channel in
                DispatchQueue.main.async { self?.accept(channel, socketPath: socketPath) }
            }
            launchingHelper = true
            let token = generation
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.arguments = ["--socket", server.path]
            NSWorkspace.shared.openApplication(at: helperURL, configuration: config) { app, failure in
                DispatchQueue.main.async {
                    guard token == self.generation else { app?.terminate(); return }
                    self.helper = app
                    if let failure {
                        self.error = failure.localizedDescription
                        self.stopHelper()
                    } else {
                        self.scheduleHealthCheck()
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stopHelper()
        }
    }
    private func scheduleHealthCheck() {
        recovery?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.current != nil else { return }
            if self.helper?.isTerminated != false || self.connection == nil {
                self.stopHelper()
                self.launchHelper()
            } else { self.scheduleHealthCheck() }
        }
        recovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
    private func accept(_ channel: HandoffChannel, socketPath: String) {
        guard listener?.path == socketPath, current != nil, connection == nil,
              channel.peerIsCurrentUser, let pid = channel.peerPID,
              NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL == helperURL.standardizedFileURL else {
            channel.start()
            channel.close()
            return
        }
        connection = channel
        launchingHelper = false
        channel.onPacket = { [weak self, weak channel] packet in
            DispatchQueue.main.async {
                guard let self, let channel, self.connection === channel else { return }
                switch packet.kind {
                case .snapshot:
                    if let current = self.current { channel.send(HandoffPacket(kind: .update, state: current.dock)) }
                    else { channel.send(HandoffPacket(kind: .shutdown)) }
                case .open:
                    if let id = packet.eventID {
                        self.open(id) { error in channel.send(HandoffPacket(kind: .result, error: error)) }
                    }
                case .dismiss:
                    if let id = packet.eventID { self.dismiss(id) }
                default: break
                }
            }
        }
        channel.onClose = { [weak self, weak channel] in
            DispatchQueue.main.async {
                guard let self, let channel, self.connection === channel else { return }
                self.connection = nil
            }
        }
        channel.start()
        publish()
    }
    func snapshot(withReply reply: @escaping (Data?) -> Void) {
        DispatchQueue.main.async { reply(self.encoded) }
    }
    func dismiss(_ eventID: String) {
        DispatchQueue.main.async {
            guard self.current?.dock.eventID == eventID else { return }
            self.memory.consume(eventID)
            self.clear()
        }
    }
    func open(_ eventID: String, withReply reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            guard let handoff = self.current, handoff.dock.eventID == eventID, !self.opening,
                  self.isEnabled, !self.isDisabled(handoff.package) else {
                reply("This handoff is no longer available.")
                return
            }
            self.opening = true
            let session = self.generation
            self.launch(handoff.package, session: session) { success in
                guard session == self.generation else { reply("The phone disconnected."); return }
                self.opening = false
                if success {
                    self.memory.consume(eventID)
                    reply(nil)
                    if self.current?.dock.eventID == eventID { self.clear() }
                } else {
                    self.error = "No Mac app, Android mirroring, or website could be opened. Check the app mapping and mirroring connection in AirSync."
                    reply(self.error)
                }
            }
        }
    }
    private func launch(_ package: String, session: UUID, completion: @escaping (Bool) -> Void) {
        if let bundle = macTarget(package), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, error in
                DispatchQueue.main.async {
                    if app != nil && error == nil { completion(true) }
                    else { self.launchMirrorOrWeb(package, session: session, completion: completion) }
                }
            }
        } else { launchMirrorOrWeb(package, session: session, completion: completion) }
    }
    private func launchMirrorOrWeb(_ package: String, session: UUID, completion: @escaping (Bool) -> Void) {
        guard generation == session, isEnabled, !isDisabled(package) else { completion(false); return }
        let web = {
            guard self.generation == session, self.isEnabled, !self.isDisabled(package) else { completion(false); return }
            completion(self.website(package).map { NSWorkspace.shared.open($0) } ?? false)
        }
        if canMirror, let device = AppState.shared.device {
            ADBConnector.startScrcpy(ip: device.ipAddress, port: AppState.shared.adbPort, deviceName: device.name,
                                    package: package, completion: { success in
                DispatchQueue.main.async { if success { completion(true) } else { web() } }
            })
        } else { web() }
    }
    private func clear() {
        memory.clear()
        current = nil
        opening = false
        generation = UUID()
        stopHelper()
    }
    private func stopHelper() {
        recovery?.cancel()
        recovery = nil
        connection?.send(HandoffPacket(kind: .shutdown))
        connection?.close()
        connection = nil
        helper?.terminate()
        helper = nil
        listener?.close()
        listener = nil
        launchingHelper = false
    }
}

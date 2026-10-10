import Foundation

struct HandoffActivity: Equatable {
    let package: String
    let name: String
    let eventID: String
}

/// Session-only memory for the currently foreground app.
struct HandoffMemory {
    private(set) var current: HandoffActivity?
    private var consumed = Set<String>()
    mutating func accept(_ activity: HandoffActivity, eligible: Bool) -> Bool {
        guard eligible, !consumed.contains(activity.eventID) else { current = nil; return false }
        current = activity
        return true
    }
    mutating func consume(_ eventID: String) {
        consumed.insert(eventID)
        if current?.eventID == eventID { current = nil }
    }
    mutating func clear() { current = nil }
    mutating func reset() { current = nil; consumed.removeAll() }
}

struct HandoffTargets {
    enum Route: Equatable { case mac(String), mirror, web(URL) }
    let macBundle: String?
    let website: URL?
    let disabled: Bool

    init(preference: MacAppLaunchPreference.LaunchTarget?, defaultBundle: String?, defaultWebsite: String?) {
        var bundle = defaultBundle
        var link = defaultWebsite
        var disabled = false
        if let preference {
            switch preference {
            case .disabled: disabled = true; bundle = nil; link = nil
            case .macApp(let value, _): bundle = value
            case .webURL(let value): bundle = nil; link = value
            }
        }
        if let value = link, !value.contains("://") { link = "https://" + value }
        let url = link.flatMap(URL.init(string:))
        website = url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil }
        macBundle = bundle
        self.disabled = disabled
    }

    func routes(macInstalled: Bool, mirrorReady: Bool) -> [Route] {
        guard !disabled else { return [] }
        var routes: [Route] = []
        if macInstalled, let macBundle { routes.append(.mac(macBundle)) }
        if mirrorReady { routes.append(.mirror) }
        if let website { routes.append(.web(website)) }
        return routes
    }
}

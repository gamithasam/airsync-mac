import Foundation

@main struct HandoffBehaviorTests {
    static func main() {
        let url = URL(string: "https://example.com")!
        let defaults = HandoffTargets(preference: nil, defaultBundle: "example.mac", defaultWebsite: url.absoluteString)
        precondition(defaults.routes(macInstalled: true, mirrorReady: true) == [.mac("example.mac"), .mirror, .web(url)])
        precondition(defaults.routes(macInstalled: false, mirrorReady: true) == [.mirror, .web(url)])
        precondition(defaults.routes(macInstalled: false, mirrorReady: false) == [.web(url)])
        let disabled = HandoffTargets(preference: .disabled, defaultBundle: "example.mac", defaultWebsite: url.absoluteString)
        precondition(disabled.routes(macInstalled: true, mirrorReady: true).isEmpty)
        let custom = HandoffTargets(preference: .macApp(bundleID: "custom.mac", appName: "Custom"), defaultBundle: "example.mac", defaultWebsite: url.absoluteString)
        precondition(custom.routes(macInstalled: true, mirrorReady: false) == [.mac("custom.mac"), .web(url)])
        let customWeb = HandoffTargets(preference: .webURL(urlString: "example.com"), defaultBundle: "example.mac", defaultWebsite: nil)
        precondition(customWeb.routes(macInstalled: true, mirrorReady: true) == [.mirror, .web(url)])
        let invalid = HandoffTargets(preference: .webURL(urlString: "file:///etc/passwd"), defaultBundle: nil, defaultWebsite: nil)
        precondition(invalid.routes(macInstalled: false, mirrorReady: false).isEmpty)
        var memory = HandoffMemory()
        let a = HandoffActivity(package: "a", name: "A", eventID: "session:1")
        let b = HandoffActivity(package: "b", name: "B", eventID: "session:2")
        precondition(memory.accept(a, eligible: true))
        precondition(!memory.accept(b, eligible: false) && memory.current == nil)
        precondition(memory.accept(b, eligible: true))
        memory.consume(a.eventID) // Completing an older launch must preserve a newer tile.
        precondition(memory.current == b)
        memory.consume(b.eventID)
        precondition(memory.current == nil && !memory.accept(b, eligible: true))
        memory.clear()
        precondition(!memory.accept(b, eligible: true))
        memory.reset()
        precondition(memory.accept(b, eligible: true))
        print("Handoff routing and session-lifetime checks passed")
    }
}

import Foundation
import Darwin

struct HandoffDockState: Codable {
    let eventID: String
    let appName: String
    let phoneName: String
    let iconPNG: Data?
}

struct HandoffPacket: Codable {
    enum Kind: String, Codable { case snapshot, update, open, dismiss, result, shutdown }
    let kind: Kind
    var state: HandoffDockState?
    var eventID: String?
    var error: String?
}

// NSXPCListenerEndpoint can only be transferred by NSXPCCoder, not archived to a
// file. A private Unix socket avoids a persistent launch agent or IPC broker.
final class HandoffChannel {
    private let fd: Int32
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "AirSync.Handoff.writer")
    private var closing = false
    var onPacket: ((HandoffPacket) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32) {
        self.fd = fd
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    static func connect(path: String) throws -> HandoffChannel {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError() }
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else { throw socketError() }
            }
        } catch { Darwin.close(fd); throw error }
        return HandoffChannel(fd: fd)
    }
    var peerPID: pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
        return pid
    }
    var peerIsCurrentUser: Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
    func start() {
        DispatchQueue.global(qos: .utility).async {
            defer {
                self.lock.lock()
                self.closing = true
                Darwin.close(self.fd)
                self.lock.unlock()
                self.onClose?()
            }
            while let header = self.read(count: 4) {
                let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard count > 0, count <= 512 * 1024,
                      let data = self.read(count: Int(count)),
                      let packet = try? JSONDecoder().decode(HandoffPacket.self, from: data) else { return }
                self.onPacket?(packet)
            }
        }
    }
    private func read(count: Int) -> Data? {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < count {
                let received = Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                if received <= 0 { return false }
                offset += received
            }
            return true
        }
        return success ? data : nil
    }
    func send(_ packet: HandoffPacket) {
        guard let payload = try? JSONEncoder().encode(packet), payload.count <= 512 * 1024 else { return }
        var count = UInt32(payload.count).bigEndian
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(payload)
        writer.async {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.closing else { return }
            let success = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < data.count {
                    let sent = Darwin.send(self.fd, buffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
                    if sent < 0 && errno == EINTR { continue }
                    if sent <= 0 { return false }
                    offset += sent
                }
                return true
            }
            if !success { self.closing = true; Darwin.shutdown(self.fd, SHUT_RDWR) }
        }
    }
    func close() {
        lock.lock()
        if !closing { closing = true; Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }
}

final class HandoffSocketListener {
    let path: String
    private let directory: URL
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    init() throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("socket").path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw socketError() }
        do {
            try withAddress(path) { address, length in
                guard bind(fd, address, length) == 0 else { throw socketError() }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            guard listen(fd, 4) == 0 else { throw socketError() }
        } catch {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func start(accept: @escaping (HandoffChannel) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            defer { Darwin.close(self.fd) }
            while true {
                let client = Darwin.accept(self.fd, nil, nil)
                if client < 0 { return }
                let channel = HandoffChannel(fd: client)
                accept(channel)
            }
        }
    }
    func close() {
        lock.lock()
        if !stopped {
            stopped = true
            Darwin.shutdown(fd, SHUT_RDWR)
            try? FileManager.default.removeItem(at: directory)
        }
        lock.unlock()
    }
}

private func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
private func withAddress<T>(_ path: String, body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG)) }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

import Darwin
import Foundation

/// E1.31 (sACN) data packets: what Lightkey sent the room, so the nodes on
/// the lighting network need no change.
public enum SACNPacket {
    public static let port: UInt16 = 5568
    public static let length = 638
    /// The default priority. A source at a higher one wins at the node.
    public static let defaultPriority: UInt8 = 100

    /// 239.255.<high>.<low> for a universe.
    public static func multicastAddress(universe: Int) -> String {
        "239.255.\((universe >> 8) & 0xFF).\(universe & 0xFF)"
    }

    public static func make(
        universe: Int, slots: [UInt8], sequence: UInt8, cid: UUID, sourceName: String,
        priority: UInt8 = defaultPriority, terminated: Bool = false
    ) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: length)
        func put16(_ at: Int, _ v: Int) { p[at] = UInt8((v >> 8) & 0xFF); p[at + 1] = UInt8(v & 0xFF) }
        func put32(_ at: Int, _ v: UInt32) { for i in 0..<4 { p[at + i] = UInt8((v >> (24 - 8 * UInt32(i))) & 0xFF) } }

        // Root layer
        put16(0, 0x0010)
        put16(2, 0x0000)
        p.replaceSubrange(4..<16, with: Array("ASC-E1.17".utf8) + [0, 0, 0])
        put16(16, 0x7000 | (length - 16))
        put32(18, 0x0000_0004)
        withUnsafeBytes(of: cid.uuid) { p.replaceSubrange(22..<38, with: $0) }

        // Framing layer
        put16(38, 0x7000 | (length - 38))
        put32(40, 0x0000_0002)
        let name = Array(sourceName.utf8.prefix(63))
        p.replaceSubrange(44..<(44 + name.count), with: name)
        p[108] = priority
        put16(109, 0) // no synchronisation
        p[111] = sequence
        p[112] = terminated ? 0x40 : 0
        put16(113, universe)

        // DMP layer
        put16(115, 0x7000 | (length - 115))
        p[117] = 0x02
        p[118] = 0xA1
        put16(119, 0x0000)
        put16(121, 0x0001)
        put16(123, 513)
        p[125] = 0 // DMX start code
        let data = slots.prefix(512)
        p.replaceSubrange(126..<(126 + data.count), with: data)
        return p
    }

    public struct Header: Equatable, Sendable {
        public var cid: UUID
        public var sourceName: String
        public var universe: Int
        public var priority: UInt8
        public var terminated: Bool
    }

    /// The source of a data packet, or nil for anything that isn't one.
    public static func parse(_ bytes: [UInt8]) -> Header? {
        guard bytes.count >= 126,
              Array(bytes[4..<13]) == Array("ASC-E1.17".utf8),
              bytes[18..<22].elementsEqual([0, 0, 0, 4]),
              bytes[40..<44].elementsEqual([0, 0, 0, 2])
        else { return nil }
        let cidBytes = Array(bytes[22..<38])
        let cid = cidBytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        let nameBytes = bytes[44..<108].prefix { $0 != 0 }
        return Header(
            cid: cid, sourceName: String(decoding: nameBytes, as: UTF8.self),
            universe: Int(bytes[113]) << 8 | Int(bytes[114]),
            priority: bytes[108], terminated: bytes[112] & 0x40 != 0)
    }
}

/// An IPv4 network this Mac is on.
public struct NetworkInterface: Hashable, Sendable, Identifiable {
    public var name: String
    public var address: String
    public var id: String { name }

    /// Up, IPv4, not loopback.
    public static func all() -> [NetworkInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [NetworkInterface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Self-assigned addresses are a cable with nothing at the end.
            if address.hasPrefix("169.254.") { continue }
            result.append(NetworkInterface(name: String(validatingCString: entry.pointee.ifa_name) ?? "", address: address))
        }
        return result
    }
}

private func makeAddress(_ ip: String, port: UInt16) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
    return addr
}

/// Sends frames as sACN multicast on the chosen networks, and to any
/// unicast addresses given (for a node that doesn't listen to multicast).
public final class SACNSender: FrameSink, @unchecked Sendable {
    public let cid: UUID
    public let sourceName: String
    public let priority: UInt8

    private let lock = NSLock()
    private var sockets: [Int32] = []
    /// Unicast has its own socket, so it works with no multicast network
    /// chosen at all.
    private var unicastSocket: Int32 = -1
    private var unicast: [sockaddr_in] = []
    private var sequences: [Int: UInt8] = [:]

    public init(cid: UUID, sourceName: String = "Hope Lights", priority: UInt8 = SACNPacket.defaultPriority) {
        self.cid = cid
        self.sourceName = sourceName
        self.priority = priority
    }

    deinit { closeAll() }

    /// One socket per network, so multicast leaves on each of them rather
    /// than only on whichever one macOS routes 239.x to (often Wi-Fi).
    public func configure(interfaces: [NetworkInterface], unicastAddresses: [String]) {
        lock.withLock {
            closeAllLocked()
            for interface in interfaces {
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { continue }
                var ifAddr = in_addr()
                inet_pton(AF_INET, interface.address, &ifAddr)
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
                var ttl: UInt8 = 8
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
                // Looped back so the monitor on this Mac sees our own
                // packets; it skips them by CID.
                var loop: UInt8 = 1
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
                sockets.append(fd)
            }
            unicast = unicastAddresses.compactMap { makeAddress($0, port: SACNPacket.port) }
            if !unicast.isEmpty { unicastSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP) }
        }
    }

    public func send(_ frame: DMXFrame) {
        lock.withLock {
            for (universe, slots) in frame.universes.sorted(by: { $0.key < $1.key }) {
                let sequence = sequences[universe, default: 0] &+ 1
                sequences[universe] = sequence
                transmitLocked(SACNPacket.make(
                    universe: universe, slots: slots, sequence: sequence, cid: cid,
                    sourceName: sourceName, priority: priority), universe: universe)
            }
        }
    }

    /// E1.31 asks for three terminated packets.
    public func stop(universes: [Int]) {
        lock.withLock {
            for _ in 0..<3 {
                for universe in universes {
                    let sequence = sequences[universe, default: 0] &+ 1
                    sequences[universe] = sequence
                    transmitLocked(SACNPacket.make(
                        universe: universe, slots: [], sequence: sequence, cid: cid,
                        sourceName: sourceName, priority: priority, terminated: true), universe: universe)
                }
            }
        }
    }

    private func transmitLocked(_ packet: [UInt8], universe: Int) {
        guard var group = makeAddress(SACNPacket.multicastAddress(universe: universe), port: SACNPacket.port) else { return }
        packet.withUnsafeBytes { bytes in
            for fd in sockets {
                withUnsafePointer(to: &group) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if unicastSocket >= 0 {
                let fd = unicastSocket
                for var target in unicast {
                    withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    private func closeAll() { lock.withLock { closeAllLocked() } }

    private func closeAllLocked() {
        for fd in sockets { close(fd) }
        sockets = []
        if unicastSocket >= 0 { close(unicastSocket) }
        unicastSocket = -1
    }
}

/// Listens for other sACN sources on our universes. Lightkey left open on
/// the booth Mac would fight this app for the same lights; this is how the
/// app notices and says so.
public final class SACNMonitor: @unchecked Sendable {
    public struct Source: Hashable, Sendable {
        public var name: String
        public var universes: [Int]
    }

    private let ownCID: UUID
    private let universes: [Int]
    private let onChange: @Sendable ([Source]) -> Void
    private let queue = DispatchQueue(label: "org.hopejc.lights.monitor")
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var pruner: DispatchSourceTimer?
    private var seen: [UUID: (name: String, universes: Set<Int>, last: TimeInterval)] = [:]
    private var reported: [Source] = []

    public init(ownCID: UUID, universes: [Int], onChange: @escaping @Sendable ([Source]) -> Void) {
        self.ownCID = ownCID
        self.universes = universes
        self.onChange = onChange
    }

    public func start(interfaces: [NetworkInterface]) {
        queue.async { [self] in
            stopLocked()
            fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            var any = sockaddr_in()
            any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            any.sin_family = sa_family_t(AF_INET)
            any.sin_port = SACNPacket.port.bigEndian
            any.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &any) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { close(fd); fd = -1; return }
            for universe in universes {
                for interface in interfaces {
                    var request = ip_mreq()
                    inet_pton(AF_INET, SACNPacket.multicastAddress(universe: universe), &request.imr_multiaddr)
                    inet_pton(AF_INET, interface.address, &request.imr_interface)
                    setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size))
                }
            }
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.receive() }
            reader.resume()
            self.reader = reader
            let pruner = DispatchSource.makeTimerSource(queue: queue)
            pruner.schedule(deadline: .now() + 1, repeating: 1)
            pruner.setEventHandler { [weak self] in self?.publish() }
            pruner.resume()
            self.pruner = pruner
        }
    }

    public func stop() { queue.async { [self] in stopLocked() } }

    private func stopLocked() {
        reader?.cancel()
        reader = nil
        pruner?.cancel()
        pruner = nil
        if fd >= 0 { close(fd) }
        fd = -1
        seen = [:]
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0, let header = SACNPacket.parse(Array(buffer[0..<count])),
              header.cid != ownCID, universes.contains(header.universe)
        else { return }
        if header.terminated {
            seen[header.cid] = nil
        } else {
            var entry = seen[header.cid] ?? (header.sourceName, [], 0)
            entry.name = header.sourceName
            entry.universes.insert(header.universe)
            entry.last = ProcessInfo.processInfo.systemUptime
            seen[header.cid] = entry
        }
    }

    private func publish() {
        // E1.31 drops a source after 2.5 s of silence; so do we.
        let now = ProcessInfo.processInfo.systemUptime
        seen = seen.filter { now - $0.value.last < 2.5 }
        let sources = seen.values
            .map { Source(name: $0.name.isEmpty ? "Another console" : $0.name, universes: $0.universes.sorted()) }
            .sorted { $0.name < $1.name }
        guard sources != reported else { return }
        reported = sources
        onChange(sources)
    }
}

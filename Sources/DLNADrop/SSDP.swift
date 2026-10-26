import Darwin
import Foundation

struct NetInterface {
    let name: String
    let address: in_addr
    let netmask: in_addr

    var ip: String {
        var a = address
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    func contains(_ other: in_addr) -> Bool {
        (address.s_addr & netmask.s_addr) == (other.s_addr & netmask.s_addr)
    }

    /// Up, multicast-capable IPv4 interfaces, excluding loopback and tunnels.
    static func all() -> [NetInterface] {
        var result: [NetInterface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask,
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_MULTICAST != 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            result.append(NetInterface(name: name, address: a, netmask: m))
        }
        return result
    }
}

/// SSDP discovery: answers M-SEARCH and periodically announces with NOTIFY.
final class SSDPService: @unchecked Sendable {
    private let uuid: String
    private let httpPort: UInt16
    private var sock: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dlnadrop.ssdp")
    private let group = "239.255.255.250"

    static let deviceType = "urn:schemas-upnp-org:device:MediaServer:1"
    static let services = [
        "urn:schemas-upnp-org:service:ContentDirectory:1",
        "urn:schemas-upnp-org:service:ConnectionManager:1",
        "urn:microsoft.com:service:X_MS_MediaReceiverRegistrar:1",
    ]

    init(uuid: String, httpPort: UInt16) {
        self.uuid = uuid
        self.httpPort = httpPort
    }

    /// (NT/ST, USN) pairs this device advertises.
    private var targets: [(String, String)] {
        let udn = "uuid:\(uuid)"
        return [("upnp:rootdevice", "\(udn)::upnp:rootdevice"), (udn, udn), (Self.deviceType, "\(udn)::\(Self.deviceType)")]
            + Self.services.map { ($0, "\(udn)::\($0)") }
    }

    func start() throws {
        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1
        // Share port 1900 with other UPnP software (e.g. Plex) already running.
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(sock); sock = -1; throw POSIXError(.EADDRINUSE) }
        joinGroups()

        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        source.setEventHandler { [weak self] in self?.readPacket() }
        source.resume()
        readSource = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 30)
        var burst = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.joinGroups()  // pick up interfaces that came up later (Wi-Fi reconnect)
            self.notify("ssdp:alive")
            if burst < 2 { burst += 1; self.queue.asyncAfter(deadline: .now() + 1) { self.notify("ssdp:alive") } }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        guard sock >= 0 else { return }
        queue.sync {
            notify("ssdp:byebye")
            timer?.cancel(); timer = nil
            readSource?.cancel(); readSource = nil
            close(sock); sock = -1
        }
    }

    private var joined: Set<UInt32> = []

    private func joinGroups() {
        for iface in NetInterface.all() where !joined.contains(iface.address.s_addr) {
            var mreq = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(group)), imr_interface: iface.address)
            if setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
                joined.insert(iface.address.s_addr)
            }
        }
    }

    private func readPacket() {
        var buf = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(sock, &buf, buf.count, 0, $0, &fromLen) }
        }
        guard n > 0 else { return }
        let text = String(decoding: buf[0..<n], as: UTF8.self)
        guard text.hasPrefix("M-SEARCH") else { return }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["MAN"]?.contains("ssdp:discover") == true, let st = headers["ST"] else { return }
        let matches = st == "ssdp:all" ? targets : targets.filter { $0.0.caseInsensitiveCompare(st) == .orderedSame }
        guard !matches.isEmpty, let location = location(reachableFrom: from.sin_addr) else { return }
        let mx = min(max(Double(headers["MX"] ?? "1") ?? 1, 0), 1)
        let reply = from
        queue.asyncAfter(deadline: .now() + Double.random(in: 0...mx) * 0.5) { [weak self] in
            guard let self, self.sock >= 0 else { return }
            for (nt, usn) in matches {
                let msg = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nDATE: \(HTTPServer.httpDate())\r\nEXT:\r\n"
                    + "LOCATION: \(location)\r\nSERVER: \(HTTPServer.serverHeader)\r\nST: \(nt)\r\nUSN: \(usn)\r\n"
                    + "BOOTID.UPNP.ORG: 1\r\nCONFIGID.UPNP.ORG: 1\r\n\r\n"
                self.send(msg, to: reply)
            }
        }
    }

    private func location(reachableFrom peer: in_addr) -> String? {
        let ifaces = NetInterface.all()
        guard let iface = ifaces.first(where: { $0.contains(peer) }) ?? ifaces.first else { return nil }
        return "http://\(iface.ip):\(httpPort)/description.xml"
    }

    private func notify(_ nts: String) {
        guard sock >= 0 else { return }
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        dest.sin_addr.s_addr = inet_addr(group)
        for iface in NetInterface.all() {
            var ifAddr = iface.address
            setsockopt(sock, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
            for (nt, usn) in targets {
                var msg = "NOTIFY * HTTP/1.1\r\nHOST: \(group):1900\r\nNT: \(nt)\r\nNTS: \(nts)\r\nUSN: \(usn)\r\n"
                if nts == "ssdp:alive" {
                    msg += "CACHE-CONTROL: max-age=1800\r\nLOCATION: http://\(iface.ip):\(httpPort)/description.xml\r\n"
                        + "SERVER: \(HTTPServer.serverHeader)\r\n"
                }
                msg += "BOOTID.UPNP.ORG: 1\r\nCONFIGID.UPNP.ORG: 1\r\n\r\n"
                send(msg, to: dest)
            }
        }
    }

    private func send(_ msg: String, to addr: sockaddr_in) {
        var addr = addr
        let bytes = Array(msg.utf8)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sock, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

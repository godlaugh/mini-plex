import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]  // lowercased names
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [(String, String)] = []
    var body: Data = Data()
    /// When set, the body is streamed from this file range instead of `body`.
    var file: (url: URL, range: ClosedRange<Int64>)?
    var headOnly = false

    static func text(_ status: Int, _ reason: String, _ text: String, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, headers: [("Content-Type", type)], body: Data(text.utf8))
    }

    static let notFound = text(404, "Not Found", "Not Found")
}

/// Minimal HTTP/1.1 server: one request per connection, file bodies streamed in chunks.
final class HTTPServer: @unchecked Sendable {
    static let serverHeader = "macOS UPnP/1.0 DLNADOC/1.50 DLNADrop/1.0"

    private let queue = DispatchQueue(label: "dlnadrop.http", attributes: .concurrent)
    private var listener: NWListener?
    private let handler: (HTTPRequest, NWConnection) -> HTTPResponse
    private let activity = StreamActivity()

    init(handler: @escaping (HTTPRequest, NWConnection) -> HTTPResponse) {
        self.handler = handler
    }

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHead(conn, buffer: Data())
    }

    private func receiveHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = buffer[end.upperBound...]
                self.parse(head: head, rest: Data(rest), conn: conn)
            } else if error != nil || done || buffer.count > 256 * 1024 {
                conn.cancel()
            } else {
                self.receiveHead(conn, buffer: buffer)
            }
        }
    }

    private func parse(head: String, rest: Data, conn: NWConnection) {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let make: (Data) -> Void = { body in
            let req = HTTPRequest(method: String(parts[0]).uppercased(), path: String(parts[1]), headers: headers, body: body)
            self.respond(self.handler(req, conn), on: conn)
        }
        if rest.count >= length {
            make(rest.prefix(length))
        } else {
            receiveBody(conn, buffer: rest, length: length, then: make)
        }
    }

    private func receiveBody(_ conn: NWConnection, buffer: Data, length: Int, then: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: length - buffer.count) { [weak self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count >= length { then(buffer) }
            else if error != nil || done { conn.cancel() }
            else { self?.receiveBody(conn, buffer: buffer, length: length, then: then) }
        }
    }

    private func respond(_ res: HTTPResponse, on conn: NWConnection) {
        var head = "HTTP/1.1 \(res.status) \(res.reason)\r\n"
        let length = res.file.map { $0.range.upperBound - $0.range.lowerBound + 1 } ?? Int64(res.body.count)
        var headers = res.headers
        headers.append(("Content-Length", String(length)))
        headers.append(("Date", Self.httpDate()))
        headers.append(("Server", Self.serverHeader))
        headers.append(("Connection", "close"))
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        if res.headOnly {
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
        } else if let file = res.file, let handle = try? FileHandle(forReadingFrom: file.url) {
            conn.send(content: Data(head.utf8), completion: .idempotent)
            try? handle.seek(toOffset: UInt64(file.range.lowerBound))
            activity.begin()
            streamFile(handle, remaining: length, conn: conn)
        } else {
            conn.send(content: Data(head.utf8) + res.body, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func streamFile(_ handle: FileHandle, remaining: Int64, conn: NWConnection) {
        let finish = { [activity] in
            try? handle.close()
            conn.cancel()
            activity.end()
        }
        guard remaining > 0 else { finish(); return }
        let chunk = Int(min(remaining, 1 << 20))
        guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { finish(); return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { finish(); return }
            self?.streamFile(handle, remaining: remaining - Int64(data.count), conn: conn)
        })
    }

    static func httpDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date())
    }
}

/// Keeps the Mac from idle-sleeping while a TV is streaming.
final class StreamActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var token: NSObjectProtocol?

    func begin() {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if count == 1 {
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Streaming video to a TV")
        }
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        count -= 1
        if count == 0, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}

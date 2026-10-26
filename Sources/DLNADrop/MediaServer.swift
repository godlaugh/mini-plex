import Foundation
import Network

/// UPnP AV MediaServer: device description, ContentDirectory, ConnectionManager,
/// X_MS_MediaReceiverRegistrar, and byte-range media streaming.
final class MediaServer: @unchecked Sendable {
    let uuid: String
    let port: UInt16
    var friendlyName: String

    private let library = Library.shared
    private lazy var http = HTTPServer { [unowned self] req, conn in self.handle(req, conn) }
    private lazy var ssdp = SSDPService(uuid: uuid, httpPort: port)

    init(uuid: String, port: UInt16, friendlyName: String) {
        self.uuid = uuid
        self.port = port
        self.friendlyName = friendlyName
    }

    func start() throws {
        try http.start(port: port)
        try ssdp.start()
    }

    func stop() {
        ssdp.stop()
        http.stop()
    }

    // MARK: Routing

    private func handle(_ req: HTTPRequest, _ conn: NWConnection) -> HTTPResponse {
        let path = req.path.components(separatedBy: "?")[0]
        let host = baseURL(req, conn)
        switch (req.method, path) {
        case ("GET", "/description.xml"):
            return xml(Descriptions.device(uuid: uuid, name: friendlyName))
        case ("GET", "/cds.xml"):
            return xml(Descriptions.contentDirectorySCPD)
        case ("GET", "/cms.xml"):
            return xml(Descriptions.connectionManagerSCPD)
        case ("GET", "/mrr.xml"):
            return xml(Descriptions.registrarSCPD)
        case ("POST", "/control/cds"), ("POST", "/control/cms"), ("POST", "/control/mrr"):
            return soap(req, host: host)
        case ("SUBSCRIBE", _):
            return HTTPResponse(status: 200, reason: "OK", headers: [
                ("SID", req.header("SID") ?? "uuid:\(UUID().uuidString.lowercased())"),
                ("TIMEOUT", "Second-1800"),
            ])
        case ("UNSUBSCRIBE", _):
            return HTTPResponse(status: 200, reason: "OK")
        case ("GET", _), ("HEAD", _):
            if path.hasPrefix("/media/") { return media(req, id: Self.objectID(path), subtitle: false) }
            if path.hasPrefix("/sub/") { return media(req, id: Self.objectID(path), subtitle: true) }
            if path == "/icon.png" { return icon(req) }
            return .notFound
        default:
            return HTTPResponse.text(405, "Method Not Allowed", "Method Not Allowed")
        }
    }

    /// `/media/<id>.mkv` -> `<id>`
    private static func objectID(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.components(separatedBy: ".")[0]
    }

    /// Like Plex, resource URLs use the address the renderer reached us on.
    private func baseURL(_ req: HTTPRequest, _ conn: NWConnection?) -> String {
        if let host = req.header("Host"), !host.isEmpty, !host.hasPrefix("[") {
            return "http://" + (host.contains(":") ? host : "\(host):\(port)")
        }
        if case .hostPort(let h, _)? = conn?.currentPath?.localEndpoint {
            let ip = "\(h)".components(separatedBy: "%")[0]
            return "http://\(ip):\(port)"
        }
        return "http://\(NetInterface.all().first?.ip ?? "127.0.0.1"):\(port)"
    }

    private func xml(_ s: String) -> HTTPResponse {
        HTTPResponse.text(200, "OK", s, type: "text/xml; charset=\"utf-8\"")
    }

    // MARK: Streaming

    private func media(_ req: HTTPRequest, id: String, subtitle: Bool) -> HTTPResponse {
        guard let video = library.url(forID: id) else { return .notFound }
        let url = subtitle ? Media.sidecarSubtitle(for: video) : video
        guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else {
            return .notFound
        }
        var res = HTTPResponse(status: 200, reason: "OK")
        res.headers = [
            ("Content-Type", subtitle ? Media.subtitleMime(for: url) : Media.mime(for: url)),
            ("Accept-Ranges", "bytes"),
        ]
        if !subtitle {
            res.headers += [
                ("transferMode.dlna.org", req.header("transferMode.dlna.org") ?? "Streaming"),
                ("contentFeatures.dlna.org", Media.dlnaFeatures),
            ]
            if req.header("getCaptionInfo.sec") != nil, let sub = Media.sidecarSubtitle(for: video) {
                res.headers.append(("CaptionInfo.sec", "\(baseURL(req, nil))/sub/\(id).\(sub.pathExtension.lowercased())"))
            }
        }
        var range: ClosedRange<Int64> = 0...max(size - 1, 0)
        if let header = req.header("Range") {
            guard let r = Self.parseRange(header, size: size) else {
                var bad = HTTPResponse.text(416, "Range Not Satisfiable", "")
                bad.headers.append(("Content-Range", "bytes */\(size)"))
                return bad
            }
            range = r
            res.status = 206
            res.reason = "Partial Content"
            res.headers.append(("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound)/\(size)"))
        }
        if size == 0 { return res }
        res.file = (url, range)
        res.headOnly = req.method == "HEAD"
        return res
    }

    static func parseRange(_ header: String, size: Int64) -> ClosedRange<Int64>? {
        guard header.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",")[0].trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let n = Int64(parts[1]), n > 0 else { return nil }
            return max(size - n, 0)...(size - 1)
        }
        guard let start = Int64(parts[0]), start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : min(Int64(parts[1]) ?? size - 1, size - 1)
        return end >= start ? start...end : nil
    }

    private func icon(_ req: HTTPRequest) -> HTTPResponse {
        guard let data = AppIcon.png else { return .notFound }
        var res = HTTPResponse(status: 200, reason: "OK", headers: [("Content-Type", "image/png")], body: data)
        res.headOnly = req.method == "HEAD"
        return res
    }

    // MARK: SOAP

    private func soap(_ req: HTTPRequest, host: String) -> HTTPResponse {
        let header = req.header("SOAPACTION") ?? ""
        let trimmed = header.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let hash = trimmed.lastIndex(of: "#") else { return fault(401, "Invalid Action") }
        let service = String(trimmed[..<hash])
        let action = String(trimmed[trimmed.index(after: hash)...])
        let body = String(decoding: req.body, as: UTF8.self)
        let arg = { (name: String) in Self.argument(name, in: body) }

        switch action {
        case "Browse":
            return browse(service: service, objectID: arg("ObjectID") ?? "0", flag: arg("BrowseFlag") ?? "",
                          start: Int(arg("StartingIndex") ?? "") ?? 0, count: Int(arg("RequestedCount") ?? "") ?? 0,
                          host: host)
        case "GetSystemUpdateID":
            return reply(service, action, [("Id", "\(library.systemUpdateID)")])
        case "GetSearchCapabilities":
            return reply(service, action, [("SearchCaps", "")])
        case "GetSortCapabilities":
            return reply(service, action, [("SortCaps", "")])
        case "X_GetFeatureList":  // Samsung TVs
            let list = """
                <Features xmlns="urn:schemas-upnp-org:av:avs" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
                xsi:schemaLocation="urn:schemas-upnp-org:av:avs http://www.upnp.org/schemas/av/avs.xsd">\
                <Feature name="samsung.com_BASICVIEW" version="1"><container id="0" type="object.item.videoItem"/></Feature></Features>
                """
            return reply(service, action, [("FeatureList", XML.escape(list))])
        case "GetProtocolInfo":
            let sinks = Set(Media.videoMime.values).sorted().map { "http-get:*:\($0):*" }.joined(separator: ",")
            return reply(service, action, [("Source", sinks), ("Sink", "")])
        case "GetCurrentConnectionIDs":
            return reply(service, action, [("ConnectionIDs", "0")])
        case "GetCurrentConnectionInfo":
            return reply(service, action, [
                ("RcsID", "-1"), ("AVTransportID", "-1"), ("ProtocolInfo", ""), ("PeerConnectionManager", ""),
                ("PeerConnectionID", "-1"), ("Direction", "Output"), ("Status", "OK"),
            ])
        case "IsAuthorized", "IsValidated":
            return reply(service, action, [("Result", "1")])
        case "RegisterDevice":
            return reply(service, action, [("RegistrationRespMsg", "")])
        default:
            return fault(401, "Invalid Action")
        }
    }

    private func browse(service: String, objectID: String, flag: String, start: Int, count: Int, host: String) -> HTTPResponse {
        var objects: [MediaObject]
        var total: Int
        if flag == "BrowseMetadata" {
            guard let obj = library.object(forID: objectID) else { return fault(701, "No such object") }
            objects = [obj]
            total = 1
        } else {
            guard let children = library.children(ofID: objectID) else { return fault(701, "No such object") }
            total = children.count
            let lower = min(max(start, 0), total)
            let upper = count > 0 ? min(lower + count, total) : total
            objects = Array(children[lower..<upper])
        }
        let didl = DIDL.render(objects, base: host)
        return reply(service, "Browse", [
            ("Result", XML.escape(didl)), ("NumberReturned", "\(objects.count)"),
            ("TotalMatches", "\(total)"), ("UpdateID", "\(library.systemUpdateID)"),
        ])
    }

    static func argument(_ name: String, in body: String) -> String? {
        let pattern = "<(?:[A-Za-z0-9_]+:)?\(name)(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_]+:)?\(name)>"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let r = Range(m.range(at: 1), in: body) else {
            return body.contains("<\(name)/>") ? "" : nil
        }
        return XML.unescape(String(body[r]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func reply(_ service: String, _ action: String, _ args: [(String, String)]) -> HTTPResponse {
        let inner = args.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
            <u:\(action)Response xmlns:u="\(service)">\(inner)</u:\(action)Response></s:Body></s:Envelope>
            """
        var res = xml(body)
        res.headers.append(("EXT", ""))
        return res
    }

    private func fault(_ code: Int, _ description: String) -> HTTPResponse {
        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
            <s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>\
            <UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode>\
            <errorDescription>\(description)</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
            """
        return HTTPResponse.text(500, "Internal Server Error", body, type: "text/xml; charset=\"utf-8\"")
    }
}

enum XML {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum DIDL {
    static func render(_ objects: [MediaObject], base: String) -> String {
        var s = """
            <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
            xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" \
            xmlns:sec="http://www.sec.co.kr/">
            """
        for o in objects {
            let title = XML.escape(o.title)
            switch o.kind {
            case .root, .folder:
                s += "<container id=\"\(o.id)\" parentID=\"\(o.parentID)\" restricted=\"1\" searchable=\"0\">"
                    + "<dc:title>\(title)</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>"
            case .video:
                guard let url = o.url else { continue }
                let ext = XML.escape(url.pathExtension.lowercased())
                s += "<item id=\"\(o.id)\" parentID=\"\(o.parentID)\" restricted=\"1\">"
                    + "<dc:title>\(title)</dc:title><upnp:class>object.item.videoItem</upnp:class>"
                // The video must be the first <res>: renderers play the first one they support.
                s += "<res size=\"\(o.size)\" protocolInfo=\"\(Media.protocolInfo(for: url))\">\(base)/media/\(o.id).\(ext)</res>"
                if let sub = Media.sidecarSubtitle(for: url) {
                    let subExt = XML.escape(sub.pathExtension.lowercased())
                    let subURL = "\(base)/sub/\(o.id).\(subExt)"
                    s += "<res protocolInfo=\"http-get:*:\(Media.subtitleMime(for: sub)):*\">\(subURL)</res>"
                    s += "<sec:CaptionInfoEx sec:type=\"\(subExt)\">\(subURL)</sec:CaptionInfoEx>"
                }
                s += "</item>"
            }
        }
        return s + "</DIDL-Lite>"
    }
}

import Foundation
import Network
import Security

enum InstallServerError: LocalizedError {
    case noIdentity
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noIdentity: return String(localized: "SwiftIPA couldn't prepare its local server certificate.")
        case .listenerFailed(let message): return message
        }
    }
}

enum InstallPresentationStyle {
    case direct
    case webView
}

struct InstallLink {
    let url: URL
    let presentationStyle: InstallPresentationStyle
}

enum InstallMode {
    case secureDirect
    case externalManifest

    var useSecureConnection: Bool {
        switch self {
        case .secureDirect: return true
        case .externalManifest: return false
        }
    }

    var presentationStyle: InstallPresentationStyle {
        switch self {
        case .secureDirect: return .direct
        case .externalManifest: return .webView
        }
    }
}

enum InstallStatus: Equatable {
    case preparing
    case waitingForSystem
    case sendingPayload(Double)
    case installing
    case failed(String)
}

final class InstallServer {
    static let shared = InstallServer()

    var onStatus: ((InstallStatus) -> Void)?

    private var listener: NWListener?
    private var ipaURL: URL?
    private var appName = ""
    private var bundleIdentifier = ""
    private var version = ""
    private var scheme = "http"
    private var host = "127.0.0.1"
    private var port: UInt16 = 8442
    private var currentMode: InstallMode = .secureDirect
    /// Random path segment, so nobody else on the network can guess where the IPA is served.
    private var token = UUID().uuidString.lowercased()
    private var stopWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.xsxs18.SwiftIPA.InstallServer")

    private init() {}

    func startInstall(
        ipaURL: URL,
        appName: String,
        bundleIdentifier: String,
        version: String,
        mode: InstallMode,
        preferLoopback: Bool = false
    ) async throws -> InstallLink {
        stop()

        self.ipaURL = ipaURL
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.scheme = mode.useSecureConnection ? "https" : "http"
        self.port = mode.useSecureConnection ? 8443 : 8442
        self.currentMode = mode
        self.token = UUID().uuidString.lowercased()

        self.host = preferLoopback ? "127.0.0.1" : (Self.wifiIPAddress() ?? "127.0.0.1")

        let parameters: NWParameters
        if mode.useSecureConnection {
            let (identity, _, _) = try LocalServerIdentity.ensureIdentity()
            guard let secIdentity = sec_identity_create(identity) else { throw InstallServerError.noIdentity }
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
            parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }
        parameters.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        let hasResumed = NSLock()
        var didResume = false

        return try await withCheckedThrowingContinuation { continuation in
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                hasResumed.lock()
                let alreadyResumed = didResume
                if !alreadyResumed { didResume = true }
                hasResumed.unlock()
                guard !alreadyResumed else { return }

                switch state {
                case .waiting(let error):
                    // E.g. the port is still taken. Waiting here would leave the install stuck on "Preparing".
                    newListener.cancel()
                    continuation.resume(throwing: InstallServerError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: InstallServerError.listenerFailed(String(localized: "The install was cancelled.")))
                case .ready:
                    switch mode.presentationStyle {
                    case .direct:
                        continuation.resume(returning: InstallLink(url: URL(string: self.itmsServicesLink)!, presentationStyle: .direct))
                    case .webView:
                        let pageURL = "\(self.scheme)://\(self.host):\(self.port)/\(self.token)/install"
                        continuation.resume(returning: InstallLink(url: URL(string: pageURL)!, presentationStyle: .webView))
                    }
                case .failed(let error):
                    continuation.resume(throwing: InstallServerError.listenerFailed(error.localizedDescription))
                default:
                    hasResumed.lock()
                    didResume = false
                    hasResumed.unlock()
                }
            }
            newListener.start(queue: self.queue)
        }
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        listener?.cancel()
        listener = nil
    }

    /// iOS fetches the IPA once. Keep serving for a bit in case it retries, then close the port.
    private func scheduleStop(after seconds: TimeInterval) {
        // listener and stopWork are only touched on the main queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            self.stopWork?.cancel()
            self.stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection: connection, buffer: Data())
    }

    private func readRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                let requestLine = String(data: headerData, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
                self.respond(to: requestLine, on: connection)
                return
            }

            if isComplete || error != nil || buffer.count > 8192 {
                connection.cancel()
                return
            }

            self.readRequest(connection: connection, buffer: buffer)
        }
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let prefix = "/\(token)"

        if path.hasPrefix(prefix + "/manifest.plist") {
            sendManifest(on: connection)
        } else if path.hasPrefix(prefix + "/app.ipa") {
            sendIPA(on: connection)
        } else if path.hasPrefix(prefix + "/install") {
            sendInstallPage(on: connection)
        } else {
            let body = "Not Found".data(using: .utf8)!
            sendResponse(status: "404 Not Found", contentType: "text/plain", body: body, on: connection)
        }
    }

    private var manifestSourceURL: URL {
        switch currentMode {
        case .secureDirect:
            return URL(string: "\(scheme)://\(host):\(port)/\(token)/manifest.plist")!
        case .externalManifest:
            let payloadURL = "\(scheme)://\(host):\(port)/\(token)/app.ipa"
            var components = URLComponents(string: "https://api.palera.in/genPlist")!
            components.queryItems = [
                URLQueryItem(name: "bundleid", value: bundleIdentifier),
                URLQueryItem(name: "name", value: appName),
                URLQueryItem(name: "version", value: version),
                URLQueryItem(name: "fetchurl", value: payloadURL)
            ]
            return components.url!
        }
    }

    private static let unreservedURLCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private var itmsServicesLink: String {
        let manifestString = manifestSourceURL.absoluteString
        let encoded = manifestString.addingPercentEncoding(withAllowedCharacters: Self.unreservedURLCharacters) ?? manifestString
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    private func sendInstallPage(on connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="background:#000;margin:0;height:100vh;">
        <script>window.location = "\(itmsServicesLink)";</script>
        </body>
        </html>
        """
        sendResponse(status: "200 OK", contentType: "text/html", body: Data(html.utf8), on: connection)
    }

    private func sendManifest(on connection: NWConnection) {
        let payload: [String: Any] = [
            "items": [
                [
                    "assets": [
                        [
                            "kind": "software-package",
                            "url": "\(scheme)://\(host):\(port)/\(token)/app.ipa"
                        ]
                    ],
                    "metadata": [
                        "bundle-identifier": bundleIdentifier,
                        "bundle-version": version,
                        "kind": "software",
                        "title": appName
                    ]
                ]
            ]
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0) else {
            connection.cancel()
            return
        }
        sendResponse(status: "200 OK", contentType: "application/xml", body: data, on: connection)
    }

    private func sendIPA(on connection: NWConnection) {
        guard let ipaURL, let handle = try? FileHandle(forReadingFrom: ipaURL) else {
            sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data(), on: connection)
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0

        report(.sendingPayload(0))
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            self?.streamFile(handle: handle, connection: connection, sent: 0, total: size)
        })
    }

    private func streamFile(handle: FileHandle, connection: NWConnection, sent: Int64, total: Int64) {
        guard let chunk = try? handle.read(upToCount: 262_144), !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            report(.installing)
            scheduleStop(after: 60)
            return
        }
        let newSent = sent + Int64(chunk.count)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            if total > 0 {
                self.report(.sendingPayload(Double(newSent) / Double(total)))
            }
            self.streamFile(handle: handle, connection: connection, sent: newSent, total: total)
        })
    }

    private func report(_ status: InstallStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(status)
        }
    }

    private func sendResponse(status: String, contentType: String, body: Data, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func wifiIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = pointer {
            defer { pointer = interface.pointee.ifa_next }
            // Some interfaces have no address at all, reading through it would crash.
            guard let socketAddress = interface.pointee.ifa_addr else { continue }
            guard socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name == "en0" else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            address = String(cString: hostBuffer)
        }
        return address
    }
}

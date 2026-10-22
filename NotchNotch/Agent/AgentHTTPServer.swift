//
//  AgentHTTPServer.swift
//  NotchNotch
//
//  Lightweight, zero-dependency embedded HTTP server for receiving
//  AI Agent lifecycle events on 127.0.0.1:7823/event.
//

import Foundation
import Network
import OSLog

enum AgentListenerEvent: Sendable {
    case ready
    case failed
}

/// Every mutable property is confined to `queue`, including the callbacks:
/// they are handed over in `start` on that queue, so the main thread never
/// writes what the server queue reads.
nonisolated final class AgentHTTPServer: @unchecked Sendable {

    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]
    private var nextConnectionID = 0
    private let queue = DispatchQueue(label: "co.jianyuelab.NotchNotch.agentServer", qos: .userInitiated)
    private var onDataReceived: (@Sendable (Data) -> Void)?
    private var onListenerEvent: (@Sendable (AgentListenerEvent) -> Void)?

    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 256 * 1024

    func start(
        port: UInt16 = 7823,
        onData: @escaping @Sendable (Data) -> Void,
        onEvent: @escaping @Sendable (AgentListenerEvent) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onDataReceived = onData
            self.onListenerEvent = onEvent
            self.startOnQueue(port: port)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue(port: UInt16) {
        if let listener {
            // Already bound or binding. Report a bound listener again: the caller
            // reset its status to "starting" and the first `.ready` has already gone.
            if case .ready = listener.state { emit(.ready) }
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Log.lifecycle.error("Invalid port \(port)")
            emit(.failed)
            return
        }

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = false
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            // `NWListener(using:on:)` binds the wildcard address. Hook scripts and the
            // settings copy both post to 127.0.0.1, so the socket has to match that.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, port: port)
            }
            // Assign before start. A synchronous `.failed` callback nils this out,
            // and assigning afterwards would resurrect the dead listener.
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            Log.lifecycle.error("Failed to start Agent HTTP listener on port \(port): \(error.localizedDescription)")
            emit(.failed)
        }
    }

    private func handleListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            Log.lifecycle.notice("Agent HTTP listener ready on 127.0.0.1:\(port)")
            emit(.ready)
        case .failed(let error):
            Log.lifecycle.error("Agent HTTP listener failed: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
            emit(.failed)
        case .cancelled:
            Log.lifecycle.notice("Agent HTTP listener cancelled")
        default:
            break
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func emit(_ event: AgentListenerEvent) {
        let callback = onListenerEvent
        DispatchQueue.main.async {
            callback?(event)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        guard connections.count < NotchConfiguration.agentHTTPMaxConnections else {
            connection.cancel()
            return
        }

        // A counter, not ObjectIdentifier: a recycled address would let an old
        // timeout close a newer connection.
        let id = nextConnectionID
        nextConnectionID &+= 1
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                self?.connections[id]?.cancel()
            case .cancelled:
                self?.connections.removeValue(forKey: id)
            default:
                break
            }
        }
        connection.start(queue: queue)

        // A client that connects and never finishes its request must not hold a slot.
        queue.asyncAfter(deadline: .now() + NotchConfiguration.agentHTTPRequestTimeout) { [weak self] in
            self?.connections[id]?.cancel()
        }

        receiveHeaders(connection: connection, accumulated: Data())
    }

    private func receiveHeaders(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if buffer.count > Self.maxHeaderBytes, buffer.range(of: Self.headerTerminator) == nil {
                self.sendResponse(connection: connection, statusCode: 431, reason: "Request Header Fields Too Large")
                return
            }

            if let headerEnd = buffer.range(of: Self.headerTerminator) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                let bodyPrefix = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
                self.acceptRequest(connection: connection, headerData: headerData, bodyPrefix: bodyPrefix)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveHeaders(connection: connection, accumulated: buffer)
        }
    }

    private func acceptRequest(connection: NWConnection, headerData: Data, bodyPrefix: Data) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, reason: "Bad Request")
            return
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, statusCode: 400, reason: "Bad Request")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST", parts[1] == "/event" else {
            sendResponse(connection: connection, statusCode: 404, reason: "Not Found")
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                sendResponse(connection: connection, statusCode: 400, reason: "Bad Request")
                return
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Two different lengths is a request-smuggling shape; refuse to pick one.
            if name == "content-length", let existing = headers[name], existing != value {
                sendResponse(connection: connection, statusCode: 400, reason: "Bad Request")
                return
            }
            headers[name] = value
        }

        // Any web page can reach 127.0.0.1 with a `no-cors` POST. Browsers always
        // attach Origin to one; hook scripts never do.
        guard headers["origin"] == nil else {
            sendResponse(connection: connection, statusCode: 403, reason: "Forbidden")
            return
        }

        // Also shuts out the form and text/plain bodies a `no-cors` request is limited to.
        let mediaType = headers["content-type"]?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard mediaType == "application/json" else {
            sendResponse(connection: connection, statusCode: 415, reason: "Unsupported Media Type")
            return
        }

        // Chunked bodies are not decoded, and a body without a length would be
        // read until the client closes.
        guard headers["transfer-encoding"] == nil else {
            sendResponse(connection: connection, statusCode: 501, reason: "Not Implemented")
            return
        }
        guard let rawLength = headers["content-length"] else {
            sendResponse(connection: connection, statusCode: 411, reason: "Length Required")
            return
        }
        guard let contentLength = Int(rawLength), contentLength >= 0 else {
            sendResponse(connection: connection, statusCode: 400, reason: "Bad Request")
            return
        }
        guard contentLength <= Self.maxBodyBytes else {
            sendResponse(connection: connection, statusCode: 413, reason: "Content Too Large")
            return
        }

        if bodyPrefix.count >= contentLength {
            finishRequest(connection: connection, body: bodyPrefix.prefix(contentLength))
            return
        }
        receiveBody(connection: connection, accumulated: bodyPrefix, needed: contentLength)
    }

    private func receiveBody(connection: NWConnection, accumulated: Data, needed: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if buffer.count >= needed {
                self.finishRequest(connection: connection, body: buffer.prefix(needed))
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveBody(connection: connection, accumulated: buffer, needed: needed)
        }
    }

    /// 200 only for a body the controller can use, so a hook script sees its mistake.
    private func finishRequest(connection: NWConnection, body: Data) {
        guard (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else {
            sendResponse(connection: connection, statusCode: 400, reason: "Bad Request")
            return
        }
        onDataReceived?(Data(body))
        sendResponse(connection: connection, statusCode: 200, reason: "OK")
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, reason: String) {
        let body = statusCode == 200 ? "{\"status\":\"ok\"}" : "{\"status\":\"error\"}"
        let response = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)
}

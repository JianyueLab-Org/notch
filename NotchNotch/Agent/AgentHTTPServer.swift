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

nonisolated final class AgentHTTPServer: @unchecked Sendable {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "co.jianyuelab.NotchNotch.agentServer", qos: .userInitiated)
    nonisolated(unsafe) var onDataReceived: (@Sendable (Data) -> Void)?
    nonisolated(unsafe) var onListenerEvent: (@Sendable (AgentListenerEvent) -> Void)?

    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 256 * 1024

    func start(port: UInt16 = 7823) {
        queue.async { [weak self] in
            self?.startOnQueue(port: port)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue(port: UInt16) {
        guard listener == nil else { return }

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
    }

    private func emit(_ event: AgentListenerEvent) {
        let callback = onListenerEvent
        DispatchQueue.main.async {
            callback?(event)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
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
                self.acceptRequest(
                    connection: connection,
                    headerData: headerData,
                    bodyPrefix: bodyPrefix,
                    connectionFinished: isComplete || error != nil
                )
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveHeaders(connection: connection, accumulated: buffer)
        }
    }

    private func acceptRequest(
        connection: NWConnection,
        headerData: Data,
        bodyPrefix: Data,
        connectionFinished: Bool
    ) {
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

        var contentLength: Int?
        for line in lines.dropFirst() {
            guard line.lowercased().hasPrefix("content-length:") else { continue }
            let raw = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
            guard let value = Int(raw), value >= 0 else {
                sendResponse(connection: connection, statusCode: 400, reason: "Bad Request")
                return
            }
            contentLength = value
        }

        if let contentLength {
            guard contentLength <= Self.maxBodyBytes else {
                sendResponse(connection: connection, statusCode: 413, reason: "Content Too Large")
                return
            }
            if bodyPrefix.count >= contentLength {
                deliver(bodyPrefix.prefix(contentLength))
                sendResponse(connection: connection, statusCode: 200, reason: "OK")
                return
            }
            receiveBody(connection: connection, accumulated: bodyPrefix, needed: contentLength)
            return
        }

        // Clients that omit Content-Length are finished when the connection closes.
        if connectionFinished {
            guard bodyPrefix.count <= Self.maxBodyBytes else {
                sendResponse(connection: connection, statusCode: 413, reason: "Content Too Large")
                return
            }
            deliver(bodyPrefix)
            sendResponse(connection: connection, statusCode: 200, reason: "OK")
            return
        }

        receiveBodyUntilClose(connection: connection, accumulated: bodyPrefix)
    }

    private func receiveBody(connection: NWConnection, accumulated: Data, needed: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if buffer.count >= needed {
                self.deliver(buffer.prefix(needed))
                self.sendResponse(connection: connection, statusCode: 200, reason: "OK")
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveBody(connection: connection, accumulated: buffer, needed: needed)
        }
    }

    private func receiveBodyUntilClose(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if buffer.count > Self.maxBodyBytes {
                self.sendResponse(connection: connection, statusCode: 413, reason: "Content Too Large")
                return
            }
            if isComplete || error != nil {
                self.deliver(buffer)
                self.sendResponse(connection: connection, statusCode: 200, reason: "OK")
                return
            }
            self.receiveBodyUntilClose(connection: connection, accumulated: buffer)
        }
    }

    private func deliver(_ body: any DataProtocol) {
        let data = Data(body)
        onDataReceived?(data)
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

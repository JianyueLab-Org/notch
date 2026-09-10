//
//  AgentHTTPServer.swift
//  NotchNotch
//
//  Lightweight, zero-dependency embedded HTTP server for receiving
//  AI Agent lifecycle events on localhost:7823/event.
//

import Foundation
import Network
import OSLog

nonisolated final class AgentHTTPServer: @unchecked Sendable {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "co.jianyuelab.NotchNotch.agentServer", qos: .userInitiated)
    nonisolated(unsafe) var onDataReceived: (@Sendable (Data) -> Void)?

    func start(port: UInt16 = 7823) {
        guard listener == nil else { return }

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = false
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                Log.lifecycle.error("Invalid port \(port)")
                return
            }

            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Log.lifecycle.notice("Agent HTTP listener ready on port \(port)")
                case .failed(let error):
                    Log.lifecycle.error("Agent HTTP listener failed: \(error.localizedDescription)")
                case .cancelled:
                    Log.lifecycle.notice("Agent HTTP listener cancelled")
                default:
                    break
                }
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Log.lifecycle.error("Failed to start Agent HTTP listener on port \(port): \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection: connection, accumulated: Data())
    }

    private func receiveRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                // Headers found; parse body
                let bodyData = buffer.subdata(in: headerEnd.upperBound..<buffer.count)
                self.onDataReceived?(bodyData)
                self.sendResponse(connection: connection, statusCode: 200, body: "{\"status\":\"ok\"}")
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            // Keep reading if headers not complete yet
            self.receiveRequest(connection: connection, accumulated: buffer)
        }
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, body: String) {
        let response = "HTTP/1.1 \(statusCode) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}

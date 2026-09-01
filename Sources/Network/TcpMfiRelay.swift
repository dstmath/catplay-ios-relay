import Foundation
import Network

enum TcpMfiRelayError: Error, LocalizedError {
    case invalidHost
    case invalidPort
    case requestRejected(String)
    case connectionFailed
    case connectionClosed
    case timeout
    case responseRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "Pi host is empty"
        case .invalidPort: return "Pi port is invalid"
        case let .requestRejected(reason): return "CMFI request rejected: \(reason)"
        case .connectionFailed: return "Could not connect to the Pi signer"
        case .connectionClosed: return "Pi signer closed the connection early"
        case .timeout: return "Pi signer exchange timed out"
        case let .responseRejected(reason): return "CMFI response rejected: \(reason)"
        }
    }
}
final class TcpMfiRelay {
    private let queue = DispatchQueue(label: "com.dstmath.catplay.iosrelay.tcp")

    func exchange(
        request: Data,
        host: String,
        port: UInt16,
        timeout: TimeInterval = 10,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            completion(.failure(TcpMfiRelayError.invalidHost))
            return
        }
        guard let networkPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            completion(.failure(TcpMfiRelayError.invalidPort))
            return
        }
        do {
            try CmfiFrame.validateComplete(request, direction: .request)
        } catch {
            completion(.failure(TcpMfiRelayError.requestRejected(error.localizedDescription)))
            return
        }

        queue.async {
            let connection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: networkPort, using: .tcp)
            var finished = false
            var requestSent = false
            var timeoutItem: DispatchWorkItem?

            func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                timeoutItem?.cancel()
                connection.stateUpdateHandler = nil
                connection.cancel()
                DispatchQueue.main.async { completion(result) }
            }

            func receiveResponse() {
                self.receiveExactly(connection: connection, byteCount: CmfiFrame.headerLength) { headerResult in
                    switch headerResult {
                    case let .failure(error):
                        finish(.failure(error))
                    case let .success(header):
                        let expectedLength: Int
                        do {
                            expectedLength = try CmfiFrame.expectedLength(fromHeader: header, direction: .response)
                        } catch {
                            finish(.failure(TcpMfiRelayError.responseRejected(error.localizedDescription)))
                            return
                        }
                        let payloadLength = expectedLength - CmfiFrame.headerLength
                        guard payloadLength > 0 else {
                            finish(.success(header))
                            return
                        }
                        self.receiveExactly(connection: connection, byteCount: payloadLength) { payloadResult in
                            switch payloadResult {
                            case let .failure(error):
                                finish(.failure(error))
                            case let .success(payload):
                                var response = header
                                response.append(payload)
                                finish(.success(response))
                            }
                        }
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready where !requestSent:
                    requestSent = true
                    connection.send(content: request, completion: .contentProcessed { error in
                        if error != nil {
                            finish(.failure(TcpMfiRelayError.connectionFailed))
                        } else {
                            receiveResponse()
                        }
                    })
                case .failed:
                    finish(.failure(TcpMfiRelayError.connectionFailed))
                case .cancelled where !finished:
                    finish(.failure(TcpMfiRelayError.connectionClosed))
                default:
                    break
                }
            }

            let deadline = DispatchWorkItem { finish(.failure(TcpMfiRelayError.timeout)) }
            timeoutItem = deadline
            self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
            connection.start(queue: self.queue)
        }
    }

    private func receiveExactly(
        connection: NWConnection,
        byteCount: Int,
        accumulated: Data = Data(),
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        if accumulated.count == byteCount {
            completion(.success(accumulated))
            return
        }
        let remaining = byteCount - accumulated.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { content, _, isComplete, error in
            if error != nil {
                completion(.failure(TcpMfiRelayError.connectionFailed))
                return
            }
            var next = accumulated
            if let content, !content.isEmpty {
                next.append(content)
            }
            if next.count == byteCount {
                completion(.success(next))
            } else if isComplete {
                completion(.failure(TcpMfiRelayError.connectionClosed))
            } else {
                self.receiveExactly(connection: connection, byteCount: byteCount, accumulated: next, completion: completion)
            }
        }
    }
}

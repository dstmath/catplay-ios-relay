import Combine
import Foundation
import UIKit

@MainActor
final class RelayViewModel: ObservableObject {
    @Published var host: String
    @Published var portText: String
    @Published private(set) var isRunning = false
    @Published private(set) var androidConnected = false
    @Published private(set) var hasInFlightRequest = false
    @Published private(set) var stateLabel = "Stopped"
    @Published private(set) var entries: [RelayLogEntry] = []

    private let defaults = UserDefaults.standard
    private let tcpRelay = TcpMfiRelay()
    private var bluetooth: BluetoothRelayPeripheral?
    private var generation: UInt64 = 0
    private var inFlightMessageID: UInt16?

    init() {
        host = UserDefaults.standard.string(forKey: "pi_host") ?? "192.168.33.204"
        let storedPort = UserDefaults.standard.integer(forKey: "pi_port")
        portText = String(storedPort == 0 ? 9000 : storedPort)
    }

    func start() {
        guard !isRunning else { return }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty,
              let portValue = UInt16(portText),
              portValue != 0 else {
            append("stage=relay.start status=failed reason=invalid_endpoint")
            stateLabel = "Invalid Pi endpoint"
            return
        }

        host = normalizedHost
        defaults.set(normalizedHost, forKey: "pi_host")
        defaults.set(Int(portValue), forKey: "pi_port")
        generation &+= 1
        isRunning = true
        stateLabel = "Starting BLE"
        UIApplication.shared.isIdleTimerDisabled = true

        let peripheral = BluetoothRelayPeripheral()
        peripheral.onAndroidConnectionChanged = { [weak self] connected in
            guard let self else { return }
            self.androidConnected = connected
            self.stateLabel = connected ? "Android connected" : "Waiting for Android"
            self.append("stage=relay.android status=\(connected ? "connected" : "disconnected")")
        }
        peripheral.onDiagnostic = { [weak self] message in self?.append(message) }
        peripheral.onRequest = { [weak self] messageID, request in
            self?.handle(messageID: messageID, request: request, host: normalizedHost, port: portValue)
        }
        bluetooth = peripheral
        peripheral.start()
        stateLabel = "Waiting for Android"
        append("stage=relay.start status=ok transport=ble_to_tcp endpoint_configured=true")
    }

    func stop(reason: String) {
        guard isRunning || bluetooth != nil else { return }
        generation &+= 1
        bluetooth?.stop()
        bluetooth = nil
        inFlightMessageID = nil
        hasInFlightRequest = false
        androidConnected = false
        isRunning = false
        stateLabel = "Stopped"
        UIApplication.shared.isIdleTimerDisabled = false
        append("stage=relay.stop status=ok reason=\(reason)")
    }

    private func handle(messageID: UInt16, request: Data, host: String, port: UInt16) {
        guard isRunning else { return }
        guard inFlightMessageID == nil else {
            bluetooth?.sendError(messageID: messageID, code: "relay_busy")
            append("stage=relay.request status=rejected reason=busy request_id=\(messageID)")
            return
        }
        do {
            try CmfiFrame.validateComplete(request, direction: .request)
        } catch {
            bluetooth?.sendError(messageID: messageID, code: "invalid_cmfi_request")
            append("stage=relay.request status=rejected reason=invalid_cmfi request_id=\(messageID)")
            return
        }

        let activeGeneration = generation
        inFlightMessageID = messageID
        hasInFlightRequest = true
        stateLabel = "Contacting Pi signer"
        append("stage=relay.tcp status=starting request_id=\(messageID) request_bytes=\(request.count)")
        tcpRelay.exchange(request: request, host: host, port: port) { [weak self] result in
            guard let self,
                  self.isRunning,
                  self.generation == activeGeneration,
                  self.inFlightMessageID == messageID else { return }
            self.inFlightMessageID = nil
            self.hasInFlightRequest = false
            switch result {
            case let .success(response):
                self.bluetooth?.sendResponse(messageID: messageID, payload: response)
                self.bluetooth?.updateStatus("signer_ready")
                self.stateLabel = "Signer ready"
                self.append(
                    "stage=relay.tcp status=ok request_id=\(messageID) response_bytes=\(response.count)"
                )
            case .failure:
                self.bluetooth?.sendError(messageID: messageID, code: "pi_exchange_failed")
                self.bluetooth?.updateStatus("signer_error")
                self.stateLabel = "Pi signer error"
                self.append("stage=relay.tcp status=failed request_id=\(messageID) endpoint_redacted=true")
            }
        }
    }

    private func append(_ message: String) {
        entries.append(RelayLogEntry(message: message))
        if entries.count > 200 {
            entries.removeFirst(entries.count - 200)
        }
    }
}

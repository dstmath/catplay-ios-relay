import CoreBluetooth
import Foundation

final class BluetoothRelayPeripheral: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "C47A0001-2E42-4D46-9A7B-5C8F0E6D1101")
    static let requestUUID = CBUUID(string: "C47A0002-2E42-4D46-9A7B-5C8F0E6D1101")
    static let responseUUID = CBUUID(string: "C47A0003-2E42-4D46-9A7B-5C8F0E6D1101")
    static let statusUUID = CBUUID(string: "C47A0004-2E42-4D46-9A7B-5C8F0E6D1101")

    var onRequest: ((UInt16, Data) -> Void)?
    var onAndroidConnectionChanged: ((Bool) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private var manager: CBPeripheralManager!
    private var requestCharacteristic: CBMutableCharacteristic?
    private var responseCharacteristic: CBMutableCharacteristic?
    private var statusCharacteristic: CBMutableCharacteristic?
    private var requestedStart = false
    private var serviceAdded = false
    private var reassembler = RelayMessageReassembler()
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var pendingResponsePackets: [Data] = []
    private var statusValue = Data("stopped".utf8)

    override init() {
        super.init()
        manager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
        )
    }

    func start() {
        requestedStart = true
        if manager.state == .poweredOn {
            configureService()
        } else {
            publishDiagnostic("stage=ble.start status=waiting bluetooth_state=\(manager.state.rawValue)")
        }
    }

    func stop() {
        requestedStart = false
        manager.stopAdvertising()
        manager.removeAllServices()
        serviceAdded = false
        requestCharacteristic = nil
        responseCharacteristic = nil
        statusCharacteristic = nil
        reassembler.reset()
        pendingResponsePackets.removeAll(keepingCapacity: false)
        subscribedCentrals.removeAll(keepingCapacity: false)
        statusValue = Data("stopped".utf8)
        onAndroidConnectionChanged?(false)
        publishDiagnostic("stage=ble.stop status=ok")
    }

    func sendResponse(messageID: UInt16, payload: Data) {
        enqueue(kind: .response, messageID: messageID, payload: payload)
    }

    func sendError(messageID: UInt16, code: String) {
        enqueue(kind: .error, messageID: messageID, payload: Data(code.prefix(96).utf8))
    }

    func updateStatus(_ value: String) {
        statusValue = Data(value.prefix(96).utf8)
        guard let statusCharacteristic else { return }
        _ = manager.updateValue(statusValue, for: statusCharacteristic, onSubscribedCentrals: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        publishDiagnostic("stage=ble.state status=changed state=\(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn, requestedStart {
            configureService()
        } else if peripheral.state != .poweredOn {
            peripheral.stopAdvertising()
            serviceAdded = false
            onAndroidConnectionChanged?(false)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID else { return }
        if error != nil {
            serviceAdded = false
            requestCharacteristic = nil
            responseCharacteristic = nil
            statusCharacteristic = nil
            publishDiagnostic("stage=ble.service status=failed")
            return
        }
        serviceAdded = true
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "CatPlay MFi Relay",
        ])
        updateStatus("ble_ready")
        publishDiagnostic("stage=ble.advertise status=starting")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        publishDiagnostic(error == nil ? "stage=ble.advertise status=ready" : "stage=ble.advertise status=failed")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        if characteristic.uuid == Self.responseUUID {
            subscribedCentrals[central.identifier] = central
            onAndroidConnectionChanged?(true)
            updateStatus("android_connected")
            publishDiagnostic("stage=ble.subscribe status=ok channel=response mtu=\(central.maximumUpdateValueLength)")
            flushResponsePackets()
        } else if characteristic.uuid == Self.statusUUID {
            publishDiagnostic("stage=ble.subscribe status=ok channel=status")
            if let statusCharacteristic {
                _ = peripheral.updateValue(statusValue, for: statusCharacteristic, onSubscribedCentrals: [central])
            }
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.responseUUID else {
            publishDiagnostic("stage=ble.unsubscribe status=ok channel=status")
            return
        }
        subscribedCentrals.removeValue(forKey: central.identifier)
        let connected = !subscribedCentrals.isEmpty
        onAndroidConnectionChanged?(connected)
        if !connected {
            pendingResponsePackets.removeAll(keepingCapacity: false)
            reassembler.reset()
            updateStatus("ble_ready")
        }
        publishDiagnostic("stage=ble.unsubscribe status=ok remaining=\(subscribedCentrals.count)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.statusUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        request.value = statusValue
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == Self.requestUUID, let value = request.value else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            do {
                if let completed = try reassembler.ingest(value) {
                    guard completed.kind == .request else {
                        throw RelayProtocolError.invalidKind(completed.kind.rawValue)
                    }
                    publishDiagnostic(
                        "stage=ble.request status=complete request_id=\(completed.messageID) bytes=\(completed.payload.count)"
                    )
                    onRequest?(completed.messageID, completed.payload)
                }
                peripheral.respond(to: request, withResult: .success)
            } catch {
                reassembler.reset()
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                publishDiagnostic("stage=ble.request status=failed category=protocol")
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushResponsePackets()
    }

    private func configureService() {
        guard requestedStart, !serviceAdded, requestCharacteristic == nil else { return }
        let request = CBMutableCharacteristic(
            type: Self.requestUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let response = CBMutableCharacteristic(
            type: Self.responseUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        let status = CBMutableCharacteristic(
            type: Self.statusUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [request, response, status]
        requestCharacteristic = request
        responseCharacteristic = response
        statusCharacteristic = status
        manager.add(service)
        publishDiagnostic("stage=ble.service status=adding")
    }

    private func enqueue(kind: RelayMessageKind, messageID: UInt16, payload: Data) {
        guard !subscribedCentrals.isEmpty else {
            publishDiagnostic("stage=ble.response status=dropped reason=no_subscriber request_id=\(messageID)")
            return
        }
        let packetLength = subscribedCentrals.values.map(\.maximumUpdateValueLength).min() ?? 20
        do {
            let packets = try RelayFragment.packets(
                kind: kind,
                messageID: messageID,
                payload: payload,
                maximumPacketLength: packetLength
            )
            pendingResponsePackets.append(contentsOf: packets)
            publishDiagnostic(
                "stage=ble.response status=queued request_id=\(messageID) bytes=\(payload.count) packets=\(packets.count)"
            )
            flushResponsePackets()
        } catch {
            publishDiagnostic("stage=ble.response status=failed category=fragmentation request_id=\(messageID)")
        }
    }

    private func flushResponsePackets() {
        guard let responseCharacteristic, !subscribedCentrals.isEmpty else { return }
        while let packet = pendingResponsePackets.first {
            let accepted = manager.updateValue(
                packet,
                for: responseCharacteristic,
                onSubscribedCentrals: Array(subscribedCentrals.values)
            )
            if !accepted { return }
            pendingResponsePackets.removeFirst()
        }
    }

    private func publishDiagnostic(_ message: String) {
        onDiagnostic?(message)
    }
}

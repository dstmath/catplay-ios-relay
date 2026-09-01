import Foundation

enum RelayMessageKind: UInt8 {
    case request = 1
    case response = 2
    case error = 3
}

struct RelayFragmentFlags: OptionSet {
    let rawValue: UInt8

    static let start = RelayFragmentFlags(rawValue: 1 << 0)
    static let end = RelayFragmentFlags(rawValue: 1 << 1)
}

enum RelayProtocolError: Error, LocalizedError {
    case packetTooShort
    case invalidMagic
    case unsupportedVersion(UInt8)
    case invalidKind(UInt8)
    case invalidLength
    case oversizedMessage(Int)
    case unexpectedFragment
    case messageMismatch
    case offsetMismatch(expected: Int, actual: Int)
    case missingEndFlag
    case packetBudgetTooSmall

    var errorDescription: String? {
        switch self {
        case .packetTooShort: return "BLE fragment is shorter than its header"
        case .invalidMagic: return "BLE fragment magic is invalid"
        case let .unsupportedVersion(version): return "BLE protocol version \(version) is unsupported"
        case let .invalidKind(kind): return "BLE message kind \(kind) is invalid"
        case .invalidLength: return "BLE fragment length is invalid"
        case let .oversizedMessage(length): return "BLE message exceeds the \(length)-byte safety limit"
        case .unexpectedFragment: return "BLE continuation arrived without a start fragment"
        case .messageMismatch: return "BLE fragment belongs to a different message"
        case let .offsetMismatch(expected, actual): return "BLE fragment offset mismatch: expected \(expected), got \(actual)"
        case .missingEndFlag: return "BLE message reached its declared length without an end flag"
        case .packetBudgetTooSmall: return "BLE negotiated packet size is too small"
        }
    }
}

struct RelayFragment {
    static let headerLength = 10
    static let maximumMessageLength = 8 * 1024
    static let version: UInt8 = 1
    private static let magic: (UInt8, UInt8) = (0x43, 0x52) // "CR"

    let kind: RelayMessageKind
    let flags: RelayFragmentFlags
    let messageID: UInt16
    let totalLength: Int
    let offset: Int
    let payload: Data

    func encode() throws -> Data {
        guard totalLength <= Self.maximumMessageLength,
              totalLength <= Int(UInt16.max),
              offset <= Int(UInt16.max),
              offset + payload.count <= totalLength else {
            throw RelayProtocolError.invalidLength
        }

        var packet = Data(capacity: Self.headerLength + payload.count)
        packet.append(Self.magic.0)
        packet.append(Self.magic.1)
        packet.append(Self.version)
        packet.append((kind.rawValue << 4) | (flags.rawValue & 0x0f))
        packet.appendUInt16BE(messageID)
        packet.appendUInt16BE(UInt16(totalLength))
        packet.appendUInt16BE(UInt16(offset))
        packet.append(payload)
        return packet
    }

    static func decode(_ packet: Data) throws -> RelayFragment {
        guard packet.count >= headerLength else { throw RelayProtocolError.packetTooShort }
        guard packet.byte(at: 0) == magic.0, packet.byte(at: 1) == magic.1 else {
            throw RelayProtocolError.invalidMagic
        }
        let receivedVersion = packet.byte(at: 2)
        guard receivedVersion == version else { throw RelayProtocolError.unsupportedVersion(receivedVersion) }

        let kindAndFlags = packet.byte(at: 3)
        let kindValue = kindAndFlags >> 4
        guard let kind = RelayMessageKind(rawValue: kindValue) else {
            throw RelayProtocolError.invalidKind(kindValue)
        }
        let flags = RelayFragmentFlags(rawValue: kindAndFlags & 0x0f)
        let messageID = packet.uint16BE(at: 4)
        let totalLength = Int(packet.uint16BE(at: 6))
        let offset = Int(packet.uint16BE(at: 8))
        let payload = packet.subdata(in: headerLength..<packet.count)
        guard totalLength <= maximumMessageLength else {
            throw RelayProtocolError.oversizedMessage(maximumMessageLength)
        }
        guard offset + payload.count <= totalLength else { throw RelayProtocolError.invalidLength }
        return RelayFragment(
            kind: kind,
            flags: flags,
            messageID: messageID,
            totalLength: totalLength,
            offset: offset,
            payload: payload
        )
    }

    static func packets(
        kind: RelayMessageKind,
        messageID: UInt16,
        payload: Data,
        maximumPacketLength: Int
    ) throws -> [Data] {
        guard payload.count <= maximumMessageLength else {
            throw RelayProtocolError.oversizedMessage(maximumMessageLength)
        }
        let payloadBudget = maximumPacketLength - headerLength
        guard payloadBudget > 0 else { throw RelayProtocolError.packetBudgetTooSmall }

        if payload.isEmpty {
            return [try RelayFragment(
                kind: kind,
                flags: [.start, .end],
                messageID: messageID,
                totalLength: 0,
                offset: 0,
                payload: Data()
            ).encode()]
        }

        var packets: [Data] = []
        var offset = 0
        while offset < payload.count {
            let length = min(payloadBudget, payload.count - offset)
            var flags: RelayFragmentFlags = []
            if offset == 0 { flags.insert(.start) }
            if offset + length == payload.count { flags.insert(.end) }
            let fragment = RelayFragment(
                kind: kind,
                flags: flags,
                messageID: messageID,
                totalLength: payload.count,
                offset: offset,
                payload: payload.subdata(in: offset..<(offset + length))
            )
            packets.append(try fragment.encode())
            offset += length
        }
        return packets
    }
}

struct CompletedRelayMessage {
    let kind: RelayMessageKind
    let messageID: UInt16
    let payload: Data
}

struct RelayMessageReassembler {
    private var activeKind: RelayMessageKind?
    private var activeMessageID: UInt16?
    private var expectedLength = 0
    private var buffer = Data()

    mutating func reset() {
        activeKind = nil
        activeMessageID = nil
        expectedLength = 0
        buffer.removeAll(keepingCapacity: false)
    }

    mutating func ingest(_ packet: Data) throws -> CompletedRelayMessage? {
        let fragment = try RelayFragment.decode(packet)
        if fragment.flags.contains(.start) {
            guard fragment.offset == 0 else { throw RelayProtocolError.invalidLength }
            activeKind = fragment.kind
            activeMessageID = fragment.messageID
            expectedLength = fragment.totalLength
            buffer = Data(capacity: expectedLength)
        } else if activeMessageID == nil {
            throw RelayProtocolError.unexpectedFragment
        }

        guard activeKind == fragment.kind,
              activeMessageID == fragment.messageID,
              expectedLength == fragment.totalLength else {
            throw RelayProtocolError.messageMismatch
        }
        guard fragment.offset == buffer.count else {
            throw RelayProtocolError.offsetMismatch(expected: buffer.count, actual: fragment.offset)
        }
        buffer.append(fragment.payload)
        guard buffer.count <= expectedLength else { throw RelayProtocolError.invalidLength }

        if fragment.flags.contains(.end) {
            guard buffer.count == expectedLength else { throw RelayProtocolError.invalidLength }
            let completed = CompletedRelayMessage(kind: fragment.kind, messageID: fragment.messageID, payload: buffer)
            reset()
            return completed
        }
        if buffer.count == expectedLength {
            throw RelayProtocolError.missingEndFlag
        }
        return nil
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func uint16BE(at offset: Int) -> UInt16 {
        (UInt16(byte(at: offset)) << 8) | UInt16(byte(at: offset + 1))
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}

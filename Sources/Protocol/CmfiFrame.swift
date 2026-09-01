import Foundation

enum CmfiDirection {
    case request
    case response
}

enum CmfiFrameError: Error, LocalizedError {
    case headerTooShort
    case invalidMagic
    case unsupportedVersion(UInt8)
    case reservedFlags
    case payloadTooLarge(Int)
    case lengthMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .headerTooShort: return "CMFI header is incomplete"
        case .invalidMagic: return "CMFI magic is invalid"
        case let .unsupportedVersion(version): return "CMFI version \(version) is unsupported"
        case .reservedFlags: return "CMFI reserved flags are non-zero"
        case let .payloadTooLarge(limit): return "CMFI payload exceeds \(limit) bytes"
        case let .lengthMismatch(expected, actual): return "CMFI length mismatch: expected \(expected), got \(actual)"
        }
    }
}

enum CmfiFrame {
    static let headerLength = 60
    static let maximumRequestPayload = 1_024
    static let maximumResponsePayload = 4_096
    private static let magic = Data([0x43, 0x4d, 0x46, 0x49]) // "CMFI"

    static func validateComplete(_ frame: Data, direction: CmfiDirection) throws {
        let expected = try expectedLength(fromHeader: frame, direction: direction)
        guard frame.count == expected else {
            throw CmfiFrameError.lengthMismatch(expected: expected, actual: frame.count)
        }
    }

    static func expectedLength(fromHeader header: Data, direction: CmfiDirection) throws -> Int {
        guard header.count >= headerLength else { throw CmfiFrameError.headerTooShort }
        guard header.prefix(4) == magic else { throw CmfiFrameError.invalidMagic }
        let version = header.byte(at: 4)
        guard version == 1 else { throw CmfiFrameError.unsupportedVersion(version) }
        guard header.byte(at: 6) == 0, header.byte(at: 7) == 0 else {
            throw CmfiFrameError.reservedFlags
        }
        let payloadLength = Int(header.uint32BE(at: 24))
        let maximum = direction == .request ? maximumRequestPayload : maximumResponsePayload
        guard payloadLength <= maximum else { throw CmfiFrameError.payloadTooLarge(maximum) }
        return headerLength + payloadLength
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func uint32BE(at offset: Int) -> UInt32 {
        (UInt32(byte(at: offset)) << 24)
            | (UInt32(byte(at: offset + 1)) << 16)
            | (UInt32(byte(at: offset + 2)) << 8)
            | UInt32(byte(at: offset + 3))
    }
}

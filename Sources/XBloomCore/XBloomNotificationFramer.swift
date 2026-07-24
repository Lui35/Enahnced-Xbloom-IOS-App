import Foundation

public struct XBloomNotificationFramer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func ingest(_ data: Data) -> [Data] {
        buffer.append(data)
        var packets: [Data] = []

        while buffer.count >= 10 {
            guard buffer.first == 0x58 || buffer.first == 0x02 else {
                buffer = Data(buffer.dropFirst())
                continue
            }

            let encodedLength = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self)
            }
            let length = Int(UInt32(littleEndian: encodedLength))
            guard (12...4_096).contains(length) else {
                buffer = Data(buffer.dropFirst())
                continue
            }
            guard buffer.count >= length else { break }

            packets.append(Data(buffer.prefix(length)))
            buffer = Data(buffer.dropFirst(length))
        }
        return packets
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

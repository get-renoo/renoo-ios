import Foundation

/// gzip (RFC 1952) without dependencies: Foundation's raw DEFLATE plus a gzip header and trailer.
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        // Magic, deflate, no flags, no mtime, no extra flags, OS unknown.
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        out.append(deflated)
        appendLittleEndian(crc32(data), to: &out)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    /// Inverse of `compress` for single-member gzip data. Used by tests.
    static func decompress(_ data: Data) -> Data? {
        guard data.count >= 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B,
              data[data.startIndex + 3] == 0 else { return nil }
        let body = data.subdata(in: (data.startIndex + 10)..<(data.endIndex - 8))
        guard let inflated = try? (body as NSData).decompressed(using: .zlib) as Data else { return nil }
        let trailer = data.suffix(8)
        let crc = trailer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        return crc == crc32(inflated) ? inflated : nil
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
}

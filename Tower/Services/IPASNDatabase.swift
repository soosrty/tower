import Darwin
import Foundation

struct NetworkOrganization: Hashable, Sendable {
    let asn: UInt32
    let name: String
}

/// Fixed-size sorted range records and a shared UTF-8 name pool, memory mapped.
/// Names are decoded only for a matched range, never into a whole-database dictionary.
struct IPASNDatabase: Sendable {
    private let ipv4: Data
    private let ipv6: Data
    private let names: Data

    init(bundle: Bundle = .main) {
        func load(_ name: String) -> Data {
            guard let url = bundle.url(forResource: name, withExtension: "bin", subdirectory: "IPCountry")
                ?? bundle.url(forResource: name, withExtension: "bin") else { return Data() }
            return (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        }
        self.init(ipv4: load("IPASNIPv4"), ipv6: load("IPASNIPv6"), names: load("IPASNNames"))
    }

    init(ipv4: Data, ipv6: Data, names: Data) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.names = names
    }

    func organization(forIPAddress address: String) -> NetworkOrganization? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { lookup(Array($0), in: ipv4) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { lookup(Array($0), in: ipv6) }
        }
        return nil
    }

    private func lookup(_ address: [UInt8], in data: Data) -> NetworkOrganization? {
        let width = address.count
        let stride = width * 2 + 10
        guard data.count.isMultiple(of: stride) else { return nil }
        var low = 0
        var high = data.count / stride
        while low < high {
            let mid = (low + high) / 2
            let offset = mid * stride
            let start = data[offset ..< offset + width]
            let end = data[offset + width ..< offset + width * 2]
            if address.lexicographicallyPrecedes(start) {
                high = mid
            } else if end.lexicographicallyPrecedes(address) {
                low = mid + 1
            } else {
                let metadata = offset + width * 2
                let asn = uint32(data, metadata)
                let nameOffset = Int(uint32(data, metadata + 4))
                let length = Int(data[metadata + 8]) * 256 + Int(data[metadata + 9])
                guard asn > 0, nameOffset <= names.count, length <= names.count - nameOffset,
                      let name = String(data: names[nameOffset ..< nameOffset + length], encoding: .utf8),
                      !name.isEmpty else { return nil }
                return NetworkOrganization(asn: asn, name: name)
            }
        }
        return nil
    }

    /// Every CIDR the database attributes to `asn`, IPv4 first, for clients
    /// such as sing-box that cannot match an AS number themselves.
    static func cidrs(forASN asn: UInt32) -> [String] {
        cacheLock.lock()
        if let cached = cache[asn] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let result = IPASNDatabase().cidrs(forASN: asn)
        cacheLock.lock()
        cache[asn] = result
        cacheLock.unlock()
        return result
    }

    nonisolated(unsafe) private static var cache: [UInt32: [String]] = [:]
    private static let cacheLock = NSLock()

    func cidrs(forASN asn: UInt32) -> [String] {
        typealias Word = IPCountryDatabase.AddressWord
        func ranges(in data: Data, width: Int) -> [(Word, Word)] {
            let stride = width * 2 + 10
            guard asn > 0, data.count.isMultiple(of: stride) else { return [] }
            func word(_ offset: Int) -> Word {
                var high: UInt64 = 0, low: UInt64 = 0
                for index in 0..<width {
                    let byte = UInt64(data[data.startIndex + offset + index])
                    if width == 16, index < 8 { high = high << 8 | byte } else { low = low << 8 | byte }
                }
                return Word(high: high, low: low)
            }
            var result: [(Word, Word)] = []
            for record in 0..<(data.count / stride) {
                let offset = record * stride
                guard uint32(data, data.startIndex + offset + width * 2) == asn else { continue }
                let start = word(offset), end = word(offset + width)
                if let last = result.last, last.1.successor == start {
                    result[result.count - 1].1 = end
                } else {
                    result.append((start, end))
                }
            }
            return result
        }
        return ranges(in: ipv4, width: 4).flatMap { IPCountryDatabase.blocks(from: $0.0, to: $0.1, width: 32) }
            + ranges(in: ipv6, width: 16).flatMap { IPCountryDatabase.blocks(from: $0.0, to: $0.1, width: 128) }
    }

    private func uint32(_ data: Data, _ index: Int) -> UInt32 {
        data[index ..< index + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

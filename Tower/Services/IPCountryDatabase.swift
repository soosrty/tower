import Darwin
import Foundation

struct IPCountryDatabase: @unchecked Sendable {
    static let dataVersion: String = {
        guard let url = Bundle.main.url(forResource: "IPCountryVersion", withExtension: "txt")
            ?? Bundle.main.url(forResource: "IPCountryVersion", withExtension: "txt", subdirectory: "IPCountry"),
              let version = try? String(contentsOf: url, encoding: .utf8) else { return "unversioned-v2" }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    private static let ipv4RecordSize = 10
    private static let ipv6RecordSize = 34

    private let ipv4Data: Data
    private let ipv6Data: Data

    init(bundle: Bundle = .main) {
        ipv4Data = Self.loadResource(named: "IPCountryIPv4", bundle: bundle)
        ipv6Data = Self.loadResource(named: "IPCountryIPv6", bundle: bundle)
    }

    init(ipv4Data: Data, ipv6Data: Data) {
        self.ipv4Data = ipv4Data
        self.ipv6Data = ipv6Data
    }

    func countryCode(forIPAddress address: String) -> String? {
        var ipv4Address = in_addr()
        if inet_pton(AF_INET, address, &ipv4Address) == 1 {
            return countryCode(forIPv4: UInt32(bigEndian: ipv4Address.s_addr))
        }

        var ipv6Address = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6Address) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6Address) { Array($0) }
            return countryCode(forIPv6: bytes)
        }
        return nil
    }

    private func countryCode(forIPv4 address: UInt32) -> String? {
        var lowerBound = 0
        var upperBound = ipv4Data.count / Self.ipv4RecordSize - 1

        while lowerBound <= upperBound {
            let record = lowerBound + (upperBound - lowerBound) / 2
            let offset = record * Self.ipv4RecordSize
            let start = readUInt32(from: ipv4Data, at: offset)
            let end = readUInt32(from: ipv4Data, at: offset + 4)

            if address < start {
                upperBound = record - 1
            } else if address > end {
                lowerBound = record + 1
            } else {
                return readCountryCode(from: ipv4Data, at: offset + 8)
            }
        }
        return nil
    }

    private func countryCode(forIPv6 address: [UInt8]) -> String? {
        guard address.count == 16 else { return nil }
        var lowerBound = 0
        var upperBound = ipv6Data.count / Self.ipv6RecordSize - 1

        while lowerBound <= upperBound {
            let record = lowerBound + (upperBound - lowerBound) / 2
            let offset = record * Self.ipv6RecordSize
            if compare(address, with: ipv6Data, at: offset) == .orderedAscending {
                upperBound = record - 1
            } else if compare(address, with: ipv6Data, at: offset + 16) == .orderedDescending {
                lowerBound = record + 1
            } else {
                return readCountryCode(from: ipv6Data, at: offset + 32)
            }
        }
        return nil
    }

    /// Every CIDR the database assigns to `countryCode`, IPv4 first. sing-box
    /// dropped its GeoIP database, so exported profiles spell `GEOIP,CN` out
    /// as the same address ranges the app uses to recognise node countries.
    static func cidrs(forCountry countryCode: String) -> [String] {
        let code = countryCode.uppercased()
        cidrCacheLock.lock()
        if let cached = cidrCache[code] { cidrCacheLock.unlock(); return cached }
        cidrCacheLock.unlock()
        let result = IPCountryDatabase().cidrs(forCountry: code)
        cidrCacheLock.lock()
        cidrCache[code] = result
        cidrCacheLock.unlock()
        return result
    }

    nonisolated(unsafe) private static var cidrCache: [String: [String]] = [:]
    private static let cidrCacheLock = NSLock()

    func cidrs(forCountry countryCode: String) -> [String] {
        let code = Array(countryCode.uppercased().utf8)
        guard code.count == 2 else { return [] }
        var ranges: [(AddressWord, AddressWord)] = []
        func matches(_ data: Data, _ offset: Int) -> Bool {
            data[data.startIndex + offset] == code[0] && data[data.startIndex + offset + 1] == code[1]
        }
        func append(_ start: AddressWord, _ end: AddressWord) {
            // Records are sorted; join neighbours so each block is as wide as possible.
            if let last = ranges.last, last.1.successor == start {
                ranges[ranges.count - 1].1 = end
            } else {
                ranges.append((start, end))
            }
        }
        for record in 0..<(ipv4Data.count / Self.ipv4RecordSize) {
            let offset = record * Self.ipv4RecordSize
            guard matches(ipv4Data, offset + 8) else { continue }
            append(AddressWord(high: 0, low: UInt64(readUInt32(from: ipv4Data, at: offset))),
                   AddressWord(high: 0, low: UInt64(readUInt32(from: ipv4Data, at: offset + 4))))
        }
        var result = ranges.flatMap { Self.blocks(from: $0.0, to: $0.1, width: 32) }
        ranges = []
        for record in 0..<(ipv6Data.count / Self.ipv6RecordSize) {
            let offset = record * Self.ipv6RecordSize
            guard matches(ipv6Data, offset + 32) else { continue }
            append(readWord(from: ipv6Data, at: offset), readWord(from: ipv6Data, at: offset + 16))
        }
        result += ranges.flatMap { Self.blocks(from: $0.0, to: $0.1, width: 128) }
        return result
    }

    /// A 128-bit address; IPv4 uses the low 32 bits.
    struct AddressWord: Equatable {
        var high: UInt64
        var low: UInt64

        var successor: AddressWord? {
            if low != .max { return AddressWord(high: high, low: low + 1) }
            return high == .max ? nil : AddressWord(high: high + 1, low: 0)
        }

        var trailingZeroBitCount: Int {
            low != 0 ? low.trailingZeroBitCount : (high != 0 ? 64 + high.trailingZeroBitCount : 128)
        }

        /// This address with its lowest `bits` bits set.
        func filling(_ bits: Int) -> AddressWord {
            if bits == 0 { return self }
            if bits < 64 { return AddressWord(high: high, low: low | ((1 << UInt64(bits)) - 1)) }
            let highBits = bits - 64
            return AddressWord(high: highBits == 64 ? .max : (highBits == 0 ? high : high | ((1 << UInt64(highBits)) - 1)), low: .max)
        }

        static func <= (lhs: AddressWord, rhs: AddressWord) -> Bool {
            lhs.high < rhs.high || (lhs.high == rhs.high && lhs.low <= rhs.low)
        }
    }

    /// The fewest aligned CIDR blocks covering `start...end`.
    static func blocks(from start: AddressWord, to end: AddressWord, width: Int) -> [String] {
        var result: [String] = []
        var current: AddressWord? = start
        while let base = current, base <= end {
            var size = min(base.trailingZeroBitCount, width)
            while size > 0, !(base.filling(size) <= end) { size -= 1 }
            result.append("\(format(base, width: width))/\(width - size)")
            let last = base.filling(size)
            current = last == end ? nil : last.successor
        }
        return result
    }

    private static func format(_ address: AddressWord, width: Int) -> String {
        if width == 32 {
            let value = UInt32(truncatingIfNeeded: address.low)
            return "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: address.high >> UInt64(56 - index * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: address.low >> UInt64(56 - index * 8))
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return bytes.withUnsafeBytes { raw in
            inet_ntop(AF_INET6, raw.baseAddress, &buffer, socklen_t(buffer.count)).map { String(cString: $0) } ?? ""
        }
    }

    private func readWord(from data: Data, at offset: Int) -> AddressWord {
        var high: UInt64 = 0, low: UInt64 = 0
        let start = data.startIndex + offset
        for index in 0..<8 {
            high = high << 8 | UInt64(data[start + index])
            low = low << 8 | UInt64(data[start + 8 + index])
        }
        return AddressWord(high: high, low: low)
    }

    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return (UInt32(data[start]) << 24)
            | (UInt32(data[start + 1]) << 16)
            | (UInt32(data[start + 2]) << 8)
            | UInt32(data[start + 3])
    }

    private func compare(_ address: [UInt8], with data: Data, at offset: Int) -> ComparisonResult {
        let start = data.startIndex + offset
        for index in 0..<16 {
            if address[index] < data[start + index] { return .orderedAscending }
            if address[index] > data[start + index] { return .orderedDescending }
        }
        return .orderedSame
    }

    private func readCountryCode(from data: Data, at offset: Int) -> String? {
        let start = data.startIndex + offset
        let bytes = [data[start], data[start + 1]]
        guard bytes.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    private static func loadResource(named name: String, bundle: Bundle) -> Data {
        let url = bundle.url(forResource: name, withExtension: "bin", subdirectory: "IPCountry")
            ?? bundle.url(forResource: name, withExtension: "bin")
        guard let url else { return Data() }
        return (try? Data(contentsOf: url, options: [.mappedIfSafe])) ?? Data()
    }
}

struct HostNetworkInfo: Sendable {
    let countryCode: String?
    let addresses: [String]
    let hasCountryConflict: Bool
}

actor IPCountryLookupService {
    private struct CachedResult {
        let info: HostNetworkInfo
        let expiresAt: Date
    }

    private nonisolated let database: IPCountryDatabase
    private let successTTL: TimeInterval
    private let failureTTL: TimeInterval
    private let resolver: @Sendable (String) async -> [String]
    private var cache: [String: CachedResult] = [:]
    private var inFlight: [String: Task<HostNetworkInfo, Never>] = [:]
    private var asnDatabase: IPASNDatabase?

    init(
        database: IPCountryDatabase = IPCountryDatabase(),
        // A proxy server's address rarely moves and the country database is
        // offline and fixed per release: a day is plenty. Only a DNS failure
        // is worth retrying soon, and not every half minute.
        successTTL: TimeInterval = 86_400,
        failureTTL: TimeInterval = 600,
        resolver: (@Sendable (String) async -> [String])? = nil
    ) {
        self.database = database
        self.successTTL = successTTL
        self.failureTTL = failureTTL
        self.resolver = resolver ?? { host in
            await Task.detached(priority: .utility) { Self.resolveIPAddresses(for: host) }.value
        }
    }

    func countryCode(forHost host: String) async -> String? {
        await info(forHost: host).countryCode
    }

    /// The country of a literal address, answered from the offline database
    /// without DNS; `nil` for host names. Cheap enough for a row to ask while
    /// it is being built, so an IP node never shows a placeholder first.
    nonisolated func countryCode(forLiteralAddress host: String) -> String? {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        var v6 = in6_addr()
        guard inet_pton(AF_INET, normalized, &v4) == 1 || inet_pton(AF_INET6, normalized, &v6) == 1 else { return nil }
        return database.countryCode(forIPAddress: normalized)
    }

    func organizations(forHost host: String) async -> [NetworkOrganization] {
        let info = await info(forHost: host)
        if asnDatabase == nil { asnDatabase = IPASNDatabase() }
        return Set(info.addresses.compactMap { asnDatabase?.organization(forIPAddress: $0) })
            .sorted { $0.asn < $1.asn }
    }

    func info(forHost host: String) async -> HostNetworkInfo {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = cache[normalized], cached.expiresAt > .now { return cached.info }
        if let task = inFlight[normalized] { return await task.value }
        let database = database
        let resolver = resolver
        let task = Task<HostNetworkInfo, Never> {
            let addresses: [String]
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, normalized, &v4) == 1 || inet_pton(AF_INET6, normalized, &v6) == 1 {
                addresses = [normalized]
            } else if normalized.isEmpty {
                addresses = []
            } else {
                addresses = Array(Set(await resolver(normalized))).sorted()
            }
            let codes = addresses.map { database.countryCode(forIPAddress: $0) }
            let known = Set(codes.compactMap { $0 })
            return HostNetworkInfo(
                countryCode: known.count == 1 && codes.allSatisfy({ $0 != nil }) ? known.first : nil,
                addresses: addresses,
                hasCountryConflict: known.count > 1
            )
        }
        inFlight[normalized] = task
        let info = await task.value
        inFlight[normalized] = nil
        if cache.count >= 8000 { cache = cache.filter { $0.value.expiresAt > .now } }
        if cache.count >= 8000 { cache.removeAll(keepingCapacity: true) }
        // Resolved but absent from the database is a settled answer, not a
        // failure: asking again returns the same thing. Only no address at
        // all (DNS failed) retries after the short failure window.
        cache[normalized] = CachedResult(info: info, expiresAt: .now.addingTimeInterval(
            info.addresses.isEmpty ? failureTTL : successTTL
        ))
        return info
    }

    nonisolated private static func resolveIPAddresses(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let address = String(cString: buffer)
                if !addresses.contains(address) { addresses.append(address) }
            }
            current = info.pointee.ai_next
        }
        return addresses
    }
}

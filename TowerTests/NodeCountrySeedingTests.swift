import XCTest
@testable import Tower

/// A node whose name says nothing about its country used to show a protocol
/// icon until its row scrolled into view and an asynchronous lookup landed,
/// so the same list mixed flags and protocol icons (2026-09-29 report).
final class NodeCountrySeedingTests: XCTestCase {
    @MainActor
    func testLiteralAddressNodesKnowTheirCountryImmediately() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PersistenceStore(fileURL: url)
        let model = AppModel(persistence: store, arguments: [])
        try model.addLocalNode(name: "Test", uri: "trojan://pw@8.8.8.8:443?sni=example.com#Test")
        let node = try XCTUnwrap(model.localNodes.first)
        XCTAssertNil(NodeRegionResolver.countryCode(for: node), "名字里没有国家")
        XCTAssertEqual(model.countryCode(for: node), "US")
        XCTAssertTrue(model.hasResolvedIPCountry(for: node))

        // A relaunch knows it before any row asks.
        let reloaded = AppModel(persistence: store, arguments: [])
        let restored = try XCTUnwrap(reloaded.localNodes.first)
        XCTAssertEqual(reloaded.countryCode(for: restored), "US")
    }

    @MainActor
    func testHostNamesStillWaitForALookup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(persistence: PersistenceStore(fileURL: url), arguments: [])
        try model.addLocalNode(name: "Test", uri: "trojan://pw@node.example.com:443#Test")
        let node = try XCTUnwrap(model.localNodes.first)
        XCTAssertNil(model.countryCode(for: node))
        XCTAssertFalse(model.hasResolvedIPCountry(for: node))
    }

    func testLiteralLookupIgnoresHostNames() {
        let service = IPCountryLookupService()
        XCTAssertEqual(service.countryCode(forLiteralAddress: " 8.8.8.8 "), "US")
        XCTAssertEqual(service.countryCode(forLiteralAddress: "[2001:4860:4860::8888]"), "US")
        XCTAssertNil(service.countryCode(forLiteralAddress: "dns.google"))
    }
}

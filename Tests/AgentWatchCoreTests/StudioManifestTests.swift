import XCTest
@testable import AgentWatchCore
private actor ManifestTransport: StudioHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [StudioHTTPResponse]
    init(_ responses: [StudioHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest, origin: StudioOrigin) async throws -> StudioHTTPResponse {
        requests.append(request); return responses.removeFirst()
    }
    func tags() -> [String?] { requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } }
}
final class StudioManifestTests: XCTestCase {
    func testConditionalRefreshAndRevocationAreIndependentOfCachedGrant() async throws {
        let data = Data("""
        {"schema_version":1,"revision":"\(String(repeating: "a", count: 64))","org_id":"00000000-0000-4000-8000-000000000001","user":{"id":"00000000-0000-4000-8000-000000000002","display_name":"Member","role":"member","active":true,"version":1,"team_id":"00000000-0000-4000-8000-000000000003","team_name":"Team"},"key_id":"00000000-0000-4000-8000-000000000004","expires_at":"2099-01-01T00:00:00Z","refresh_seconds":300,"models":[],"codex_catalog":{"models":[]}}
        """.utf8)
        let expired = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "2099-01-01", with: "2000-01-01").utf8)
        let transport = ManifestTransport([.init(status: 200, body: data), .init(status: 304, body: Data()), .init(status: 401, body: Data()), .init(status: 200, body: expired)])
        let client = StudioClient(transport: transport), origin = try StudioOrigin("https://studio.test")
        let first = try await client.configuration(origin: origin, key: "test-key", previous: nil)
        let cached = try await client.configuration(origin: origin, key: "test-key", previous: first)
        XCTAssertEqual(cached.revision, first.revision)
        do { _ = try await client.configuration(origin: origin, key: "test-key", previous: cached); XCTFail("revocation must win over cache") }
        catch { XCTAssertEqual(error as? StudioError, .invalidKey) }
        do { _ = try await client.configuration(origin: origin, key: "test-key", previous: nil); XCTFail("expired manifest must disable credentials") }
        catch { XCTAssertEqual(error as? StudioError, .invalidKey) }
        let tags = await transport.tags()
        XCTAssertNil(tags[0]); XCTAssertEqual(tags[1], "\"" + first.revision + "\"")
        let wrong = try StudioProfile(origin: origin, id: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try first.validate(profile: wrong))
    }
}

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
    func testRealURLSessionAcceptsNotModifiedManifestWithoutFollowingRedirects() async throws {
        let script = #"""
import http.server, json, signal
signal.alarm(20)
revision = "a" * 64
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer fixture-key":
            self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.headers.get("If-None-Match") == '"' + revision + '"':
            self.send_response(304); self.end_headers(); return
        data = {"schema_version":1,"revision":revision,"org_id":"00000000-0000-4000-8000-000000000001","user":{"id":"00000000-0000-4000-8000-000000000002","display_name":"Fixture","role":"member","active":True,"version":1,"team_id":"00000000-0000-4000-8000-000000000003"},"key_id":"00000000-0000-4000-8000-000000000004","expires_at":"2099-01-01T00:00:00Z","refresh_seconds":300,"models":[],"codex_catalog":{"models":[]}}
        body = json.dumps(data).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
server = http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var line = Data()
        while line.count < 32 {
            let byte = pipe.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([10]) { break }; line.append(byte)
        }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)))
        let origin = try StudioOrigin("http://127.0.0.1:\(port)"), client = StudioClient()
        let first = try await client.configuration(origin: origin, key: "fixture-key", previous: nil)
        let second = try await client.configuration(origin: origin, key: "fixture-key", previous: first)
        XCTAssertEqual(second.revision, first.revision)
        do { _ = try await client.configuration(origin: origin, key: "revoked-fixture", previous: first); XCTFail("304 support must not bypass authorization") }
        catch { XCTAssertEqual(error as? StudioError, .invalidKey) }
    }
    func testNotModifiedWithoutCachedManifestIsInvalid() async throws {
        let client = StudioClient(transport: ManifestTransport([.init(status: 304, body: Data())]))
        do { _ = try await client.configuration(origin: StudioOrigin("https://studio.test"), key: "fixture-key", previous: nil); XCTFail() }
        catch { XCTAssertEqual(error as? StudioError, .invalidResponse) }
    }
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

import XCTest
@testable import Feralin

/// Madde 15: ESP tıklama adresi çözücü ve push açılışı.
final class EngagementTests: XCTestCase {
    func testTrackedLinkResolverReadsRedirectsWithoutFollowing() async {
        let hops: [String: (Int, String?)] = [
            "https://click.esp.example/ls/click?upn=abc": (302, "https://feralin.com/l/abc123"),
            "https://feralin.com/l/abc123": (200, nil),
            "https://click.esp.example/goreli": (301, "/l/xyz"),
            "https://click.esp.example/l/xyz": (200, nil),
            "https://dongu.example/a": (302, "https://dongu.example/a"),
            "https://guvensiz.example/a": (302, "http://feralin.com/l/abc"),
        ]
        let resolver = TrackedLinkResolver(open: { url in
            guard let hop = hops[url.absoluteString] else { throw URLError(.cannotFindHost) }
            return (status: hop.0, location: hop.1)
        })
        let resolve = { (raw: String) async -> String in await resolver.resolve(URL(string: raw)!).absoluteString }
        let esp = await resolve("https://click.esp.example/ls/click?upn=abc")
        XCTAssertEqual(esp, "https://feralin.com/l/abc123")
        let relative = await resolve("https://click.esp.example/goreli")
        XCTAssertEqual(relative, "https://click.esp.example/l/xyz")
        let loop = await resolve("https://dongu.example/a")
        XCTAssertEqual(loop, "https://dongu.example/a")
        let insecure = await resolve("https://guvensiz.example/a")
        XCTAssertEqual(insecure, "http://feralin.com/l/abc")
        let unknown = await resolve("https://bilinmeyen.example/x")
        XCTAssertEqual(unknown, "https://bilinmeyen.example/x")
    }

    func testPushOpenCarriesOnlyCampaignFields() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, platform: "ios")
        let first = try await client.trackPushOpen(userInfo: ["utm_campaign": "kis-indirimi", "utm_source": "braze", "baslik": "Gizli metin", "fr_push_id": "p-1", "aps": ["alert": "Merhaba"]])
        let check = try await client.trackPushOpen(userInfo: ["fr_uninstall_check": "1"])
        let plain = try await client.trackPushOpen(userInfo: [:])
        XCTAssertNotNil(first)
        XCTAssertNil(check, "kaldırma ölçümü bildirimi açılış sayılmaz")
        XCTAssertNotNil(plain)
        _ = try await client.flush()
        let opens = try transport.events(0).filter { $0["event_name"] as? String == "fr_push_open" }
        XCTAssertEqual(opens.count, 2)
        let props = try XCTUnwrap(opens[0]["properties"] as? [String: Any])
        XCTAssertEqual(props["utm_campaign"] as? String, "kis-indirimi")
        XCTAssertEqual(props["utm_medium"] as? String, "push")
        XCTAssertEqual(props["push_id"] as? String, "p-1")
        XCTAssertNil(props["baslik"])
        XCTAssertEqual((opens[1]["properties"] as? [String: Any])?["utm_medium"] as? String, "push")
    }
}

import Foundation
import XCTest
@testable import Feralin

final class LinksTests: XCTestCase {
    private let attribution = AttributionConfiguration(apiURL: "https://api.example.test/", projectID: "proj_1")
    private let adConsent = Consent(analytics: true, advertising: true)
    private let click = "clk0123456789abcdefABCDEF"
    private let hosts = ["kisa.example", "go.marka.example"]

    private func matched(path: String? = "/urun/42") -> String {
        let pathJSON = path.map { "\"\($0)\"" } ?? "null"
        return """
        {"status":"matched","reason":null,"retry_after_seconds":null,"link":{"decision_id":"dec_1","link_code":"kis","deep_link_path":\(pathJSON),"utm":{"source":"instagram","campaign":"kis"},"evidence_class":"probabilistic_match","confidence":"low","attribution_source":"none","decided_at":"2026-11-18T10:00:00.000Z"}}
        """
    }

    private let pending = """
    {"status":"pending","reason":null,"retry_after_seconds":3,"link":null}
    """

    // MARK: Saf çözümleme

    func testClickIDIsReadOnlyWhenWellFormed() throws {
        XCTAssertEqual(FeralinLinks.clickID(in: try XCTUnwrap(URL(string: "https://kisa.example/l/kis?fr_click=\(click)&utm_source=x"))), click)
        XCTAssertNil(FeralinLinks.clickID(in: try XCTUnwrap(URL(string: "https://kisa.example/l/kis"))))
        XCTAssertNil(FeralinLinks.clickID(in: try XCTUnwrap(URL(string: "https://kisa.example/l/kis?fr_click=kisa"))), "kısa kimlik biçime uymaz")
        XCTAssertNil(FeralinLinks.clickID(in: try XCTUnwrap(URL(string: "https://kisa.example/l/kis?fr_click=bo%C5%9Fluk%20var%20ve%20uzun%20deger"))))
    }

    func testDestinationKeepsPathAndDropsFeralinParameters() throws {
        XCTAssertEqual(FeralinLinks.destination(of: try XCTUnwrap(URL(string: "https://app.example/urun/42?renk=mavi&fr_click=\(click)&fr_link=kis"))), "/urun/42?renk=mavi")
        XCTAssertEqual(FeralinLinks.destination(of: try XCTUnwrap(URL(string: "https://app.example/urun/42?fr_click=\(click)"))), "/urun/42")
        XCTAssertEqual(FeralinLinks.destination(of: try XCTUnwrap(URL(string: "https://app.example"))), "/")
        XCTAssertEqual(FeralinLinks.destination(of: try XCTUnwrap(URL(string: "https://app.example/a%20b?q=x%26y"))), "/a%20b?q=x%26y", "kodlama korunur")
    }

    func testClipboardAcceptsOnlyOwnShortLinkWithClickID() {
        XCTAssertEqual(FeralinLinks.clipboardClick("https://kisa.example/l/kis?fr_click=\(click)", linkHosts: hosts), click)
        XCTAssertEqual(FeralinLinks.clipboardClick("  https://kampanya.go.marka.example/kis?fr_click=\(click)\n", linkHosts: hosts), click, "alt alan ve çevre boşluğu kabul")
        XCTAssertEqual(FeralinLinks.clipboardClick("https://KISA.example/l/kis?fr_click=\(click)", linkHosts: hosts), click)
        // Başka host, benzer adlı host, http, tıklama kimliği olmayan adres ve adres olmayan metin reddedilir.
        XCTAssertNil(FeralinLinks.clipboardClick("https://baska.example/l/kis?fr_click=\(click)", linkHosts: hosts))
        XCTAssertNil(FeralinLinks.clipboardClick("https://kisa.example.saldirgan.test/l/kis?fr_click=\(click)", linkHosts: hosts))
        XCTAssertNil(FeralinLinks.clipboardClick("https://sahtekisa.example/l/kis?fr_click=\(click)", linkHosts: hosts))
        XCTAssertNil(FeralinLinks.clipboardClick("http://kisa.example/l/kis?fr_click=\(click)", linkHosts: hosts))
        XCTAssertNil(FeralinLinks.clipboardClick("https://kisa.example/l/kis", linkHosts: hosts))
        XCTAssertNil(FeralinLinks.clipboardClick("parolam: hunter2 https://kisa.example/l/kis?fr_click=\(click)", linkHosts: hosts))
        XCTAssertNil(FeralinLinks.clipboardClick("TR00 0000 0000 0000 0000 0000 00", linkHosts: hosts))
        XCTAssertNil(FeralinLinks.clipboardClick("https://kisa.example/l/kis?fr_click=\(click)", linkHosts: []), "host listesi boşsa hiçbir adres kabul edilmez")
        XCTAssertNil(FeralinLinks.clipboardClick(String(repeating: "a", count: 600), linkHosts: hosts))
    }

    // MARK: Olaylar

    func testUniversalLinkTracksDeepLinkOpenedWithClick() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, consent: adConsent, platform: "ios")
        let open = try await client.handleUniversalLink(try XCTUnwrap(URL(string: "https://kisa.example/urun/42?renk=mavi&fr_click=\(click)")))
        XCTAssertEqual(open.destination, "/urun/42?renk=mavi")
        XCTAssertTrue(open.hasClickID)
        XCTAssertEqual(open.event?.eventName, "deep_link_opened")
        _ = try await client.flush()
        let properties = try XCTUnwrap(try transport.events(0)[0]["properties"] as? [String: Any])
        XCTAssertEqual(properties["fr_click"] as? String, click)
        XCTAssertEqual(properties["attribution_source"] as? String, "universal_link")
    }

    // MARK: Fera Fly kısa link çözümlemesi

    func testIsShortLinkAcceptsShortDomainAndSubdomains() throws {
        XCTAssertTrue(FeralinLinks.isShortLink(try XCTUnwrap(URL(string: "https://fera.fly/a7kd2xq"))))
        XCTAssertTrue(FeralinLinks.isShortLink(try XCTUnwrap(URL(string: "https://marka.fera.fly/a7kd2xq"))))
        XCTAssertFalse(FeralinLinks.isShortLink(try XCTUnwrap(URL(string: "http://fera.fly/a7kd2xq"))), "yalnız https")
        XCTAssertFalse(FeralinLinks.isShortLink(try XCTUnwrap(URL(string: "https://sahtefera.fly/a7kd2xq"))))
        XCTAssertTrue(FeralinLinks.isShortLink(try XCTUnwrap(URL(string: "https://go.marka.example/kis")), linkHosts: hosts))
    }

    func testShortLinkResolvesDeepPathAndClick() async throws {
        let resolved = "{\"code\":\"a7kd2xq\",\"destination\":\"https://apps.apple.com/app/id1\",\"deep_link_path\":\"/urun/42\",\"utm\":{\"campaign\":\"bahar\"},\"click_id\":\"\(click)\",\"rule\":\"ios_url\"}"
        let transport = FakeTransport([.respond(200, resolved, ["Content-Type": "application/vnd.feralin.link+json"])])
        let client = try makeClient(transport: transport, consent: adConsent, platform: "ios")
        let open = await client.handleShortLink(try XCTUnwrap(URL(string: "https://marka.fera.fly/a7kd2xq")))
        XCTAssertEqual(open.destination, "/urun/42")
        XCTAssertTrue(open.hasClickID)
        let request = transport.request(0)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://marka.fera.fly/a7kd2xq")
        XCTAssertEqual(request.headers["Accept"], "application/vnd.feralin.link+json")
        XCTAssertNil(request.headers["Feralin-Attribution"], "reklam izni varken kanıt kapatılmaz")
        XCTAssertNil(request.headers["X-Feralin-Project-Key"], "proje anahtarı kısa link hostuna gitmez")
        XCTAssertTrue(request.headers["User-Agent"]?.contains("iPhone") ?? false)
        _ = try await client.flush()
        let properties = try XCTUnwrap(try transport.events(1)[0]["properties"] as? [String: Any])
        XCTAssertEqual(properties["fr_click"] as? String, click)
        XCTAssertEqual(properties["link_code"] as? String, "a7kd2xq")
    }

    func testShortLinkWithoutAdvertisingConsentAsksRouterNotToWriteEvidence() async throws {
        let resolved = "{\"code\":\"a7kd2xq\",\"destination\":\"https://site.example/\",\"deep_link_path\":null,\"utm\":{},\"click_id\":null,\"rule\":\"default_url\"}"
        let transport = FakeTransport([.respond(200, resolved, [:])])
        let client = try makeClient(transport: transport, consent: Consent(analytics: true), platform: "ios")
        let open = await client.handleShortLink(try XCTUnwrap(URL(string: "https://fera.fly/a7kd2xq")))
        XCTAssertEqual(open.destination, "/", "derin yol yoksa kök")
        XCTAssertFalse(open.hasClickID)
        XCTAssertEqual(transport.request(0).headers["Feralin-Attribution"], "off")
    }

    func testShortLinkFallsBackToUniversalLinkOnFailureOrForeignHost() async throws {
        let failing = FakeTransport([.respond(404, "{}", [:])])
        let client = try makeClient(transport: failing, consent: adConsent, platform: "ios")
        let open = await client.handleShortLink(try XCTUnwrap(URL(string: "https://fera.fly/yok-kod")))
        XCTAssertEqual(open.destination, "/yok-kod", "çözümlenemezse yol olduğu gibi döner")
        let foreign = FakeTransport()
        let other = try makeClient(transport: foreign, consent: adConsent, platform: "ios")
        let direct = await other.handleShortLink(try XCTUnwrap(URL(string: "https://app.example/urun/42?fr_click=\(click)")))
        XCTAssertEqual(direct.destination, "/urun/42")
        XCTAssertTrue(direct.hasClickID)
        _ = try await other.flush()
        XCTAssertEqual(foreign.request(0).method, "POST", "başka hostta çözümleme isteği yapılmaz, yalnız olay gönderilir")
    }

    func testClickIsDroppedWithoutAdvertisingConsent() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, consent: Consent(analytics: true), platform: "ios")
        let open = try await client.handleUniversalLink(try XCTUnwrap(URL(string: "https://kisa.example/urun/42?fr_click=\(click)")))
        XCTAssertEqual(open.destination, "/urun/42", "yol izinden bağımsız döner")
        try await client.trackFirstOpen(clickID: click, source: "clipboard")
        _ = try await client.flush()
        for event in try transport.events(0) {
            let properties = event["properties"] as? [String: Any]
            XCTAssertNil(properties?["fr_click"], "reklam izni yokken tıklama kimliği gönderilmez")
        }
    }

    func testFirstOpenCarriesClipboardClickAndSource() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, consent: adConsent, platform: "ios")
        let event = try await client.trackFirstOpen(clickID: click, source: "clipboard")
        XCTAssertEqual(event?.eventName, "app_first_open")
        try await client.trackFirstOpen(clickID: "kisa", source: "clipboard")
        try await client.trackFirstOpen()
        _ = try await client.flush()
        let events = try transport.events(0)
        let first = try XCTUnwrap(events[0]["properties"] as? [String: Any])
        XCTAssertEqual(first["fr_click"] as? String, click)
        XCTAssertEqual(first["attribution_source"] as? String, "clipboard")
        XCTAssertNil((events[1]["properties"] as? [String: Any])?["fr_click"], "biçimi bozuk kimlik gönderilmez")
        XCTAssertNil((events[2]["properties"] as? [String: Any])?["fr_click"])
    }

    // MARK: Pano

    func testClipboardIsNotReadWithoutAdvertisingConsent() async throws {
        let client = try makeClient(transport: FakeTransport(), consent: Consent(analytics: true), platform: "ios")
        let link = "https://kisa.example/l/kis?fr_click=\(click)"
        let result = await client.clipboardClickID(linkHosts: hosts, reader: {
            XCTFail("izinsiz pano okunmamalı")
            return link
        })
        XCTAssertNil(result)
    }

    func testClipboardReturnsClickOnlyForOwnLink() async throws {
        let client = try makeClient(transport: FakeTransport(), consent: adConsent, platform: "ios")
        let link = "https://kisa.example/l/kis?fr_click=\(click)"
        let own = await client.clipboardClickID(linkHosts: hosts, reader: { link })
        XCTAssertEqual(own, click)
        let foreign = await client.clipboardClickID(linkHosts: hosts, reader: { "gizli not: toplantı 15:00" })
        XCTAssertNil(foreign)
        let empty = await client.clipboardClickID(linkHosts: hosts, reader: { nil })
        XCTAssertNil(empty)
    }

    // MARK: Ertelenmiş derin bağlantı

    func testDeferredLinkRetriesWhilePendingThenReturnsPath() async throws {
        let transport = FakeTransport([.respond(200, pending, [:]), .respond(200, pending, [:]), .respond(200, matched(), [:])])
        let store = InMemoryInstallIDStore(value: "01JC0000000000000000INSTAL")
        let client = try makeClient(transport: transport, consent: adConsent, attribution: attribution, platform: "ios", store: store)
        let waits = Waits()
        let result = await client.fetchDeferredDeepLink(sleep: { seconds in await waits.add(seconds) })
        guard case .matched(let link) = result else { return XCTFail("matched bekleniyordu: \(result)") }
        XCTAssertEqual(link.deepLinkPath, "/urun/42")
        XCTAssertEqual(link.linkCode, "kis")
        XCTAssertEqual(link.utm["source"], "instagram")
        XCTAssertEqual(link.evidenceClass, "probabilistic_match")
        let recorded = await waits.values
        XCTAssertEqual(recorded, [3, 3])
        XCTAssertEqual(transport.count, 3)
        let request = transport.request(0)
        XCTAssertEqual(request.url.absoluteString, "https://api.example.test/v1/projects/proj_1/attribution/deferred-link")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(testKey)")
        let body = try transport.body(0)
        XCTAssertEqual(body["install_id"] as? String, "01JC0000000000000000INSTAL")
        XCTAssertEqual(body["consent"] as? Bool, true)
        XCTAssertEqual(body.count, 2)
    }

    func testDeferredLinkStopsAfterMaxAttemptsAndReportsOtherOutcomes() async throws {
        let stillPending = try makeClient(transport: FakeTransport([.respond(200, pending, [:]), .respond(200, pending, [:])]), consent: adConsent, attribution: attribution, platform: "ios")
        let first = await stillPending.fetchDeferredDeepLink(maxAttempts: 2, sleep: { _ in })
        XCTAssertEqual(first, .pending)

        let noMatch = try makeClient(transport: FakeTransport([.respond(200, "{\"status\":\"no_match\",\"reason\":\"ios_no_deterministic_signal\",\"retry_after_seconds\":null,\"link\":null}", [:])]), consent: adConsent, attribution: attribution, platform: "ios")
        let second = await noMatch.fetchDeferredDeepLink(sleep: { _ in })
        XCTAssertEqual(second, .noMatch(reason: "ios_no_deterministic_signal"))

        let withoutPath = try makeClient(transport: FakeTransport([.respond(200, matched(path: nil), [:])]), consent: adConsent, attribution: attribution, platform: "ios")
        guard case .matched(let link) = await withoutPath.fetchDeferredDeepLink(sleep: { _ in }) else { return XCTFail("matched bekleniyordu") }
        XCTAssertNil(link.deepLinkPath, "atıf var, yol yok")

        let rejected = try makeClient(transport: FakeTransport([.respond(404, "{\"type\":\"urn:feralin:problem:project_not_found\",\"title\":\"Not Found\",\"status\":404}", [:])]), consent: adConsent, attribution: attribution, platform: "ios")
        guard case .rejected(let status, _) = await rejected.fetchDeferredDeepLink(sleep: { _ in }) else { return XCTFail("rejected bekleniyordu") }
        XCTAssertEqual(status, 404)

        let failing = try makeClient(transport: FakeTransport([.fail("ağ yok")]), consent: adConsent, attribution: attribution, platform: "ios")
        guard case .temporaryFailure(let failStatus, _) = await failing.fetchDeferredDeepLink(sleep: { _ in }) else { return XCTFail("temporaryFailure bekleniyordu") }
        XCTAssertEqual(failStatus, 0)
    }

    func testDeferredLinkNeedsConsentAndConfiguration() async throws {
        let transport = FakeTransport()
        let noConsent = try makeClient(transport: transport, consent: Consent(analytics: true), attribution: attribution, platform: "ios")
        let first = await noConsent.fetchDeferredDeepLink(sleep: { _ in })
        XCTAssertEqual(first, .skippedNoConsent)
        let noConfiguration = try makeClient(transport: transport, consent: adConsent, platform: "ios")
        let second = await noConfiguration.fetchDeferredDeepLink(sleep: { _ in })
        XCTAssertEqual(second, .notConfigured)
        XCTAssertEqual(transport.count, 0, "izinsiz ya da ayarsız istek gönderilmez")
    }
}

actor Waits {
    private(set) var values: [TimeInterval] = []

    func add(_ seconds: TimeInterval) {
        values.append(seconds)
    }
}

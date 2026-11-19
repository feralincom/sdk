import Foundation
import XCTest
@testable import Feralin

/// SDK imzası, kurulum kaynağı ve simülatör bildirimi (Adjust karşılaştırması madde 8). Beklenen özetler bilinen sınama vektörleridir.
final class IntegrityTests: XCTestCase {
    private let key = SigningKey(id: "sgn_0123456789abcdef", secret: "fsk_gizli_anahtar_degeri")

    func testSHA256KnownVectors() {
        // FIPS 180-4 örnekleri.
        XCTAssertEqual(SHA256.hex(SHA256.digest([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(SHA256.digest(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            SHA256.hex(SHA256.digest(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        // Blok sınırı: 55, 56 ve 64 baytlık girdiler dolgu yolunun üç dalını sınar (değerler Node ile hesaplandı).
        XCTAssertEqual(SHA256.hex(SHA256.digest([UInt8](repeating: 0x61, count: 55))), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        XCTAssertEqual(SHA256.hex(SHA256.digest([UInt8](repeating: 0x61, count: 56))), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        XCTAssertEqual(SHA256.hex(SHA256.digest([UInt8](repeating: 0x61, count: 64))), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }

    func testHMACKnownVectors() {
        // RFC 4231 sınama durumu 2.
        XCTAssertEqual(
            SHA256.hex(SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
        // RFC 4231 sınama durumu 6: blok boyundan uzun anahtar önce özetlenir.
        XCTAssertEqual(
            SHA256.hex(SHA256.hmac(key: [UInt8](repeating: 0xaa, count: 131), message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        )
    }

    func testSignatureMatchesServer() {
        // Sunucu uygulamasıyla (Node, HMAC-SHA256) aynı girdiden hesaplanan değer; Android SDK testi de aynı vektörü kullanır.
        let signature = EventSigner.sign(key: SigningKey(id: "sgn_0123456789abcdef", secret: "fsk_gizli"), atSeconds: 1_795_000_000, eventID: "evt-1", eventName: "app_first_open", anonymousID: "anon-1")
        XCTAssertEqual(signature, "v1.sgn_0123456789abcdef.1795000000.6f939a78369f2fb6cb3aa73fcc800d17e783292a926b865e2becac05f6b6def7")
    }

    func testSigningKeyValidationAndDescription() throws {
        XCTAssertTrue(key.isValid)
        XCTAssertFalse(SigningKey(id: "anahtar", secret: "fsk_gizli_anahtar_degeri").isValid)
        XCTAssertFalse(SigningKey(id: "sgn_0123456789abcdef", secret: "kisa").isValid)
        XCTAssertFalse("\(key)".contains("fsk_"), "anahtar değeri dökümde görünmez")
        XCTAssertThrowsError(try makeClient(transport: FakeTransport(), signingKey: SigningKey(id: "bozuk", secret: "fsk_gizli_anahtar_degeri")))
    }

    func testAttributionEventsAreSignedAndOthersAreNot() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, platform: "ios", signingKey: key)
        try await client.trackFirstOpen()
        try await client.track("level_up", properties: ["level": 2])
        _ = try await client.flush()
        let events = try transport.events(0)
        let first = events[0]
        let signature = try XCTUnwrap((first["properties"] as? [String: Any])?["fr_sig"] as? String)
        let parts = signature.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[1], "sgn_0123456789abcdef")
        // Sunucu aynı dizgiyi olayın kendi alanlarından kurar.
        let expected = EventSigner.sign(key: key, atSeconds: try XCTUnwrap(Int64(parts[2])), eventID: try XCTUnwrap(first["event_id"] as? String), eventName: "app_first_open", anonymousID: try XCTUnwrap(first["anonymous_id"] as? String))
        XCTAssertEqual(signature, expected)
        XCTAssertNil((events[1]["properties"] as? [String: Any])?["fr_sig"], "atıf olayı olmayan olay imzalanmaz")
        XCTAssertFalse(String(decoding: transport.request(0).body, as: UTF8.self).contains("fsk_gizli"), "anahtar değeri gövdede geçmez")
    }

    func testNoSignatureWithoutKey() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, platform: "ios")
        try await client.trackFirstOpen()
        _ = try await client.flush()
        XCTAssertNil((try transport.events(0)[0]["properties"] as? [String: Any])?["fr_sig"])
    }

    func testInstallStoreAcceptsOnlyKnownValues() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, platform: "ios")
        try await client.trackFirstOpen(installStore: FeralinInstallSource.testFlight)
        try await client.trackFirstOpen(installStore: "com.ornek.pazaryeri")
        _ = try await client.flush()
        let events = try transport.events(0)
        XCTAssertEqual((events[0]["properties"] as? [String: Any])?["install_store"] as? String, "testflight")
        XCTAssertNil((events[1]["properties"] as? [String: Any])?["install_store"], "listede olmayan değer gönderilmez")
    }

    // MARK: Çocuklara yönelik uygulama ve izin süresi

    func testChildDirectedForcesAdvertisingOff() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, consent: Consent(analytics: true, advertising: true, personalization: true), platform: "ios", childDirected: true)
        try await client.trackFirstOpen(clickID: "clk_0123456789abcdef0123", source: "clipboard")
        _ = try await client.flush()
        let event = try transport.events(0)[0]
        XCTAssertNil((event["properties"] as? [String: Any])?["fr_click"], "çocuk kipinde tıklama kimliği gönderilmez")
        let consent = try XCTUnwrap(event["consent"] as? [String: Any])
        XCTAssertEqual(consent["advertising"] as? Bool, false)
        XCTAssertEqual(consent["personalization"] as? Bool, false)
        let status = await client.status()
        XCTAssertFalse(status.consent.advertising)
    }

    func testConsentAgeExpiresAndRenews() async throws {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let clock = TestClock(start)
        let transport = FakeTransport()
        let ad = Consent(analytics: true, advertising: true)
        let client = try makeClient(transport: transport, consent: ad, platform: "ios", now: { clock.now() }, consentMaxAgeDays: 30, advertisingConsentGrantedAt: start)
        var expired = await client.advertisingConsentExpired
        XCTAssertFalse(expired)
        try await client.trackFirstOpen()
        clock.advance(31 * 86_400)
        expired = await client.advertisingConsentExpired
        XCTAssertTrue(expired, "31. günde izin süresi dolmuştur")
        try await client.trackFirstOpen()
        await client.setConsent(ad, grantedAt: clock.now())
        expired = await client.advertisingConsentExpired
        XCTAssertFalse(expired, "yeniden onay süreyi yeniler")
        _ = try await client.flush()
        let events = try transport.events(0)
        XCTAssertNotNil((events[0]["properties"] as? [String: Any])?["consent_at"], "izinli atıf olayı izin anını taşır")
        XCTAssertEqual((events[0]["consent"] as? [String: Any])?["advertising"] as? Bool, true)
        XCTAssertEqual((events[1]["consent"] as? [String: Any])?["advertising"] as? Bool, false, "süresi dolan izin kapalı gider")
        XCTAssertNil((events[1]["properties"] as? [String: Any])?["consent_at"])
    }

    func testAdvertisingIDOnlyWithAdvertisingConsent() async throws {
        let idfa = "38400000-8CF0-11BD-B23E-10B96E40000D"
        XCTAssertEqual(FeralinInstallSource.normalizedAdvertisingID(idfa), "38400000-8cf0-11bd-b23e-10b96e40000d")
        XCTAssertNil(FeralinInstallSource.normalizedAdvertisingID("00000000-0000-0000-0000-000000000000"))
        XCTAssertNil(FeralinInstallSource.normalizedAdvertisingID("kimlik"))
        XCTAssertNil(FeralinInstallSource.normalizedAdvertisingID(nil))
        func sent(consent: Consent, childDirected: Bool = false, id: String? = idfa) async throws -> Any? {
            let transport = FakeTransport()
            let client = try makeClient(transport: transport, consent: consent, platform: "ios", childDirected: childDirected)
            try await client.trackFirstOpen(advertisingID: id)
            _ = try await client.flush()
            return (try transport.events(0)[0]["properties"] as? [String: Any])?["advertising_id"]
        }
        let granted = Consent(analytics: true, advertising: true)
        let withConsent = try await sent(consent: granted)
        XCTAssertEqual(withConsent as? String, "38400000-8cf0-11bd-b23e-10b96e40000d")
        let withoutConsent = try await sent(consent: Consent(analytics: true))
        XCTAssertNil(withoutConsent, "reklam izni yokken kimlik gönderilmez")
        let child = try await sent(consent: granted, childDirected: true)
        XCTAssertNil(child, "çocuk kipinde kimlik gönderilmez")
        let notGiven = try await sent(consent: granted, id: nil)
        XCTAssertNil(notGiven, "uygulama vermediyse kimlik yoktur")
    }

    func testPushTokenAndUninstallCheck() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, platform: "ios")
        let token = Data((0..<32).map { UInt8($0) })
        let first = try await client.setPushToken(token)
        let repeated = try await client.setPushToken(token)
        let short = try await client.setPushToken(Data([1, 2, 3]))
        XCTAssertNotNil(first)
        XCTAssertNil(repeated, "aynı belirteç ikinci kez gitmez")
        XCTAssertNil(short, "kısa belirteç gitmez")
        _ = try await client.flush()
        let events = try transport.events(0).filter { $0["event_name"] as? String == "fr_push_token" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual((events[0]["properties"] as? [String: Any])?["push_token"] as? String, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        XCTAssertTrue(FeralinClient.isUninstallCheck(["fr_uninstall_check": "1", "aps": ["content-available": 1]]))
        XCTAssertFalse(FeralinClient.isUninstallCheck(["aps": ["alert": "Merhaba"]]))
    }

    func testPreviousInstallIDFromVault() async throws {
        let vault = InMemoryInstallIDStore()
        vault.save("onceki-kurulum-01")
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, platform: "ios", installVault: vault)
        try await client.trackFirstOpen()
        _ = try await client.flush()
        let first = try transport.events(0)[0]
        XCTAssertEqual((first["properties"] as? [String: Any])?["previous_install_id"] as? String, "onceki-kurulum-01")
        // Kasa bu kurulumun kimliğiyle güncellenir: aynı kurulumun sonraki ilk açılışı yeniden kurulum sayılmaz.
        XCTAssertEqual(vault.load(), first["anonymous_id"] as? String)
        try await client.trackFirstOpen()
        _ = try await client.flush()
        XCTAssertNil((try transport.events(1)[0]["properties"] as? [String: Any])?["previous_install_id"])
    }

    func testOSVersionFormat() {
        XCTAssertEqual(FeralinInstallSource.formatOSVersion(OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 1)), "17.4.1")
        XCTAssertEqual(FeralinInstallSource.formatOSVersion(OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0)), "18.0")
        // Linux'ta sürüm bildirilmez: Apple işletim sistemi değildir.
        #if !canImport(Darwin)
        XCTAssertNil(FeralinInstallSource.osVersion)
        #endif
    }

    func testJailbreakHeuristic() {
        XCTAssertTrue(FeralinInstallSource.looksJailbroken { $0 == "/var/jb" })
        XCTAssertFalse(FeralinInstallSource.looksJailbroken { _ in false })
        // Linux ve macOS'ta denetim yapılmaz: /usr/sbin/sshd gibi yollar orada sıradandır.
        #if !os(iOS)
        XCTAssertFalse(FeralinInstallSource.isJailbroken)
        #endif
    }

    func testInstallSourceOnThisPlatform() async {
        // Linux ve macOS'ta Apple kurulum kaynağını bildirmez: değer uydurulmaz. Simülatör yalnız simülatör derlemesinde true olur.
        #if !targetEnvironment(simulator) && !os(iOS)
        let source = await FeralinInstallSource.current()
        XCTAssertNil(source)
        XCTAssertFalse(FeralinInstallSource.isSimulator)
        #endif
    }
}

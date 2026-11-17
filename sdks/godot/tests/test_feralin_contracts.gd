extends SceneTree

## v0.2.0 sözleşme testleri: Unity çıktılarından üretilmiş vektörler (tests/vectors/sdk_vectors.json), NIST AES-GCM ve SHA-256, kalıcı şifreli kuyruk,
## gelir, reklam geliri, oyun olayları, fr_error, oturum, atıf. Çalıştırma: godot --headless --path sdks/godot -s tests/test_feralin_contracts.gd
## Çıkış kodu kalan denetim sayısıdır. BU MAKİNEDE GODOT YOK: bu testler yazıldı, ÇALIŞTIRILMADI. AES-GCM, GHASH ve düzenli ifade hattının
## algoritması Python eşiyle aynı vektörlere karşı doğrulandı; GDScript söz dizimi ve motor API'si doğrulanmadı.

const FeralinCore := preload("res://addons/feralin/feralin_core.gd")
const FeralinCrypto := preload("res://addons/feralin/feralin_crypto.gd")
const FeralinRules := preload("res://addons/feralin/feralin_rules.gd")
const FeralinStore := preload("res://addons/feralin/feralin_store.gd")
const KEY := "pk_test_godot_key_0001"

var _failures := 0
var _checks := 0
var _clock := 1793700000.0
var _counter := 1
var _warnings: Array[String] = []


func _init() -> void:
	_test_primitives()
	_test_vectors()
	_test_persistence()
	_test_store_edges()
	_test_contracts()
	_test_game_events()
	_test_errors_and_session()
	_test_attribution()
	_test_bind_install()
	print("feralin_contracts: %d denetim, %d kaldı" % [_checks, _failures])
	quit(_failures)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("KALDI: " + label)


func _bytes(hex: String) -> PackedByteArray:
	return hex.hex_decode()


func _make(store: Variant = null, options: Dictionary = {}) -> FeralinCore:
	var core := FeralinCore.new()
	core.now_unix = func() -> float: return _clock
	core.random_unit = func() -> float: return 0.0
	core.random_bytes = func(count: int) -> PackedByteArray:
		var out := PackedByteArray()
		for _i in range(count):
			out.append((_counter * 37) & 0xFF)
			_counter += 1
		return out
	core.log_warning = func(message: String) -> void: _warnings.append(message)
	var opts := options.duplicate()
	if store != null:
		opts["store"] = store
		opts["queue_protection"] = "local_file"
	core.configure(KEY, "https://collect.example.test/", opts)
	return core


func _fresh_store(name: String) -> RefCounted:
	var store := _fresh_store_reopen(name)
	store.clear()
	for marker in ["install_id", "first_open_event_id", "first_open_at_ms", "referrer_checked", "deferred_deep_link"]:
		store.remove_marker(marker)
	return store


func _repeat(value: int, count: int) -> PackedByteArray:
	var out := PackedByteArray()
	for _i in range(count):
		out.append(value)
	return out


func _events(core: FeralinCore) -> Array:
	var request := core.next_request()
	return JSON.parse_string(request["body"].get_string_from_utf8())["events"] if not request.is_empty() else []


func _same(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _same(a[key], b[key]):
				return false
		return true
	if (a is float or a is int) and (b is float or b is int):
		return float(a) == float(b)
	return a == b


func _test_primitives() -> void:
	_check(FeralinCrypto.sha256_hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 abc")
	_check(FeralinCrypto.sha256_hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 boş")
	var zero_key := _repeat(0, 32)
	var zero_iv := _repeat(0, 12)
	_check(FeralinCrypto.seal(zero_key, zero_iv, _repeat(0, 16), PackedByteArray()).hex_encode() == "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919", "NIST AES-256-GCM sıfır anahtar")
	_check(FeralinCrypto.seal(zero_key, zero_iv, PackedByteArray(), PackedByteArray()).hex_encode() == "530f8afbc74536b9a963b4f1c4cb738b", "NIST AES-256-GCM boş düz metin")
	var key := _bytes("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
	var iv := _bytes("cafebabefacedbaddecaf888")
	var plain := _bytes("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255")
	var sealed := FeralinCrypto.seal(key, iv, plain, PackedByteArray())
	_check(sealed.hex_encode() == "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015adb094dac5d93471bdec1a502270e3cc6c", "NIST AES-256-GCM dört blok")
	_check(FeralinCrypto.open(key, iv, sealed, PackedByteArray()) == plain, "açma")
	var tampered := sealed.duplicate()
	tampered[3] ^= 1
	_check(FeralinCrypto.open(key, iv, tampered, PackedByteArray()).is_empty(), "kurcalanmış satır açılmaz")


func _load_vectors() -> Dictionary:
	var file := FileAccess.open("res://tests/vectors/sdk_vectors.json", FileAccess.READ)
	if file == null:
		return {}
	return JSON.parse_string(file.get_as_text())


func _test_vectors() -> void:
	var vectors := _load_vectors()
	_check(not vectors.is_empty(), "vektör dosyası okunur")
	for c in vectors.get("scrub", []):
		_check(FeralinRules.scrub(c["in"], int(c["max"])) == c["out"], "scrub: " + str(c["in"]).substr(0, 40))
	for c in vectors.get("frames", []):
		var frames := FeralinRules.normalize_frames(c["in"], int(c["max"]))
		_check(Array(frames) == c["frames"], "çerçeve: " + str(c["in"]).substr(0, 30))
		_check(FeralinRules.fingerprint(c["type"], frames) == c["fingerprint"], "parmak izi")
	for c in vectors.get("aes", []):
		var aes_key := _bytes(c["key"])
		var aes_iv := _bytes(c["iv"])
		_check(FeralinCrypto.encrypt_line(aes_key, aes_iv, c["plain"], c["aad"]) == c["line"], "Unity ile aynı enc1 satırı")
		var opened := FeralinCrypto.decrypt_line(aes_key, c["line"], c["aad"])
		if String(c["plain"]).is_empty():
			_check(not opened["ok"], "boş gövde Unity'de de açılmaz")
		else:
			_check(opened["ok"] and opened["text"] == c["plain"], "enc1 satırı açılır")
		_check(not FeralinCrypto.decrypt_line(aes_key, c["line"], "BASKA")["ok"], "AAD başka kimliğe taşınırsa açılmaz")
	for c in vectors.get("revenue", []):
		var input: Dictionary = c["input"].duplicate()
		var rev := {"transaction_id": input["transaction_id"], "amount_minor": input["amount_minor"], "currency": input["currency"], "quantity": input["quantity"], "purchase_type": input["purchase_type"], "properties": input.get("properties")}
		if input.get("product_id") != null:
			rev["product_id"] = input["product_id"]
		if input.get("receipt_provider") != null:
			rev["receipt"] = {"provider": input["receipt_provider"], "token": input["receipt_token"]}
		_check(_same(FeralinRules.revenue_properties(rev), c["props"]), "gelir vektörü " + str(input["transaction_id"]).substr(0, 12))
	for c in vectors.get("adrevenue", []):
		var ad: Dictionary = c["input"].duplicate()
		for key in ["ad_unit", "placement", "impression_id"]:
			if ad.get(key) == null:
				ad.erase(key)
		_check(_same(FeralinRules.ad_revenue_properties(ad), c["props"]), "reklam geliri vektörü " + str(ad["network"]))


func _test_persistence() -> void:
	var store := _fresh_store("persist")
	var core := _make(store)
	core.set_consent({"analytics": true})
	var ids: Array = []
	for i in range(3):
		ids.append(core.track("level_started", {"n": i})["event_id"])
	var disk := FileAccess.get_file_as_string("user://feralin_test_persist/events.log")
	_check(disk.contains("enc1:") and not disk.contains("level_started") and disk.begins_with(ids[0]), "kuyruk diskte şifreli")
	# Yeniden başlatma: aynı event_id'ler aynı sırayla, izin verilince geri yüklenir.
	var again := _make(_fresh_store_reopen("persist"))
	_check(again.queued() == 0, "izin kararı gelene kadar yüklenmez")
	again.set_consent({"analytics": true})
	_check(again.queued() == 3, "üç olay geri yüklendi")
	var request := again.next_request()
	var restored: Array = JSON.parse_string(request["body"].get_string_from_utf8())["events"]
	_check(restored[0]["event_id"] == ids[0] and restored[2]["event_id"] == ids[2], "event_id korunur")
	_check(request["headers"].has("Idempotency-Key: " + FeralinCore.idempotency_key_for(ids)), "aynı Idempotency-Key")
	again.on_response(202, PackedStringArray(), "{}")
	_check(FileAccess.get_file_as_string("user://feralin_test_persist/events.log").is_empty(), "kabul edilince diskten silinir")
	# Geçici hatada kalır, 401'de temizlenir.
	var third := _make(_fresh_store_reopen("persist"))
	third.set_consent({"analytics": true})
	third.track("a")
	third.next_request()
	third.on_response(503, PackedStringArray(), "")
	_check(not FileAccess.get_file_as_string("user://feralin_test_persist/events.log").is_empty() and third.queued() == 1, "geçici hatada diskte kalır")
	third.on_response(401, PackedStringArray(), "")
	_check(FileAccess.get_file_as_string("user://feralin_test_persist/events.log").is_empty() and third.queued() == 0, "401 kuyruğu ve diski temizler")


func _fresh_store_reopen(name: String) -> RefCounted:
	var store: RefCounted = FeralinStore.new("user://feralin_test_" + name, _repeat(7, 32))
	store.random_bytes = func(count: int) -> PackedByteArray:
		var out := PackedByteArray()
		for _i in range(count):
			out.append((_counter * 91) & 0xFF)
			_counter += 1
		return out
	return store


func _test_store_edges() -> void:
	var store := _fresh_store("edge")
	var core := _make(store)
	core.set_consent({"analytics": true})
	core.track("x")
	# Yanlış anahtar: satır açılmaz ve atılır; düz metne düşülmez.
	var wrong := FeralinStore.new("user://feralin_test_edge", _repeat(9, 32))
	_check(wrong.load_events().is_empty() and FileAccess.get_file_as_string("user://feralin_test_edge/events.log").is_empty(), "yanlış anahtarla açılamayan satırlar atılır")
	# İzin reddi diskteki olayı siler.
	var again := _make(_fresh_store_reopen("edge"))
	again.set_consent({"analytics": true})
	again.track("y")
	again.set_consent({"analytics": false})
	_check(FileAccess.get_file_as_string("user://feralin_test_edge/events.log").is_empty(), "izin reddi diski siler")
	# Kuyruk sınırı diske de uygulanır.
	var limited := _make(_fresh_store_reopen("edge"), {"queue_limit": 3})
	limited.set_consent({"analytics": true})
	var ids: Array = []
	for i in range(5):
		ids.append(limited.track("e", {"i": i})["event_id"])
	var reopened := _make(_fresh_store_reopen("edge"), {"queue_limit": 3})
	reopened.set_consent({"analytics": true})
	var events := _events(reopened)
	_check(events.size() == 3 and events[0]["event_id"] == ids[2] and events[2]["event_id"] == ids[4], "sınır sonrası en yeni üç olay diskte")
	# Kalıcı depo yoksa bellekte çalışır.
	var memory := _make(null)
	memory.set_consent({"analytics": true})
	_check(not memory.track("m").is_empty() and memory.store == null, "depo yoksa bellek kuyruğu")


func _test_contracts() -> void:
	var core := _make(null)
	core.set_consent({"analytics": true, "advertising": true})
	var purchase := core.track_revenue({"transaction_id": "tx1", "amount_minor": 4999, "currency": "TRY", "product_id": "gold", "properties": {"verified": true, "note": "x"}})
	_check(not purchase.is_empty() and not purchase["properties"].has("verified") and purchase["properties"]["amount_minor"] == 4999, "gelir: verified gönderilmez")
	_check(core.track_revenue({"transaction_id": "tx2", "amount_minor": -1, "currency": "TRY"}).is_empty(), "gelir: negatif tutar reddedilir")
	_check(core.track_revenue({"transaction_id": "tx3", "amount_minor": 5, "currency": "TRY", "purchase_type": "subscription_cancel"}).is_empty(), "gelir: iptal tutar taşımaz")
	_check(not core.track_iap_purchase("p", 4.99, "USD", "tx4").is_empty() and core.track_iap_purchase("p", 4.99, "USD", "").is_empty(), "iap_purchase eşlemesi")
	_check(core.track_iap_purchase("p", 500.0, "JPY", "tx5")["properties"]["amount_minor"] == 500, "JPY ondalıksız")
	_check(not core.track_ad_revenue({"network": "admob", "ad_format": "rewarded", "revenue_micros": 12500, "currency": "USD"}).is_empty(), "reklam geliri")
	_check(core.track_ad_revenue({"network": "AdMob", "revenue_micros": 1, "currency": "USD"}).is_empty(), "reklam ağı küçük harf olmalı")
	_check(not core.group("clan_1", {"size": 5}).is_empty() and core.group("").is_empty(), "fr_group")
	_check(not core.set_user_properties({"tier": "gold"}).is_empty() and core.set_user_properties({"bad key": 1}).is_empty(), "fr_user_properties")
	var events := _events(core)
	_check(events[0]["event_name"] == "feralin_purchase" and events[3]["event_name"] == "fr_ad_revenue", "olay adları")


func _test_game_events() -> void:
	_check(FeralinRules.level_properties("l1", 2) != null and FeralinRules.level_properties("") == null and FeralinRules.level_properties("l", 0) == null, "level_start kuralları")
	_check(FeralinRules.level_properties("l", null, -1) == null and FeralinRules.level_properties("l", null, 0, 86400000, "boss") != null, "score ve süre sınırı")
	_check(FeralinRules.level_properties("l", null, null, 86400001) == null and FeralinRules.level_properties("l", null, null, null, "r".repeat(65)) == null, "süre ve fail_reason üst sınırı")
	_check(FeralinRules.economy_properties("gem", 1) != null and FeralinRules.economy_properties("gem", 1000000000000) != null, "economy sınırları")
	_check(FeralinRules.economy_properties("gem", 0) == null and FeralinRules.economy_properties("gem", 1000000000001) == null and FeralinRules.economy_properties("", 5) == null, "economy reddi")
	_check(FeralinRules.rewarded_shown_properties("p", "admob") != null and FeralinRules.rewarded_shown_properties("") == null, "rewarded_ad_shown")
	_check(FeralinRules.rewarded_complete_properties("p", null, 0, "gem") != null and FeralinRules.rewarded_complete_properties("p", null, -1) == null, "rewarded_ad_complete")
	_check(FeralinRules.iap_offer_properties("sku") != null and FeralinRules.iap_offer_properties("s".repeat(129)) == null, "iap_offer_shown")
	_check(FeralinRules.iap_initiated_properties("sku", null, "tx") != null and FeralinRules.iap_initiated_properties("sku", null, "t".repeat(129)) == null, "iap_initiated")


func _test_errors_and_session() -> void:
	var core := _make(null, {"errors": {"max_per_minute": 3, "max_per_fingerprint_per_minute": 2}, "app_version": "1.2.3"})
	_check(core.capture_error("Boom", "x").is_empty(), "izin yokken fr_error yok")
	core.set_consent({"analytics": true})
	var first := core.capture_error("NullReference ali@example.com", "kullanıcı ali@example.com token=abc /Users/ali/x", "A.B (at /Users/ali/a.cs:10)\nC.D () (at b.cs:2)", false, "unhandled_exception")
	_check(not first.is_empty(), "fr_error üretildi")
	var event: Dictionary = _events(core)[0]
	var props: Dictionary = event["properties"]
	_check(event["event_name"] == "fr_error" and props["fingerprint"].length() == 16 and props["frame_count"] == 2 and props["fatal"] == true and props["handled"] == false, "fr_error alanları")
	_check(props["origin"] == "uncaught_exception" and props["app_version"] == "1.2.3", "fr_error origin ve sürüm")
	var flat: String = str(props.get("message", "")) + str(props["error_type"]) + str(props.get("top_frame", ""))
	_check(not flat.contains("ali") and not flat.contains("example.com") and not flat.contains("abc"), "kişisel veri sızmaz")
	for key in props:
		_check(["error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin"].has(key), "şema dışı alan yok: " + key)
	core = _make(null, {"errors": {"max_per_minute": 3, "max_per_fingerprint_per_minute": 2}})
	core.set_consent({"analytics": true})
	_check(not core.capture_error("Same", "m", "S.T ()").is_empty() and not core.capture_error("Same", "m", "S.T ()").is_empty(), "parmak izi başına iki")
	_check(core.capture_error("Same", "m", "S.T ()").is_empty() and core.errors_suppressed == 1, "üçüncüsü bastırılır")
	_clock += 61.0
	_check(not core.capture_error("Same", "m", "S.T ()").is_empty(), "pencere geçince tekrar alınır")
	# Genel sınır parmak izinden bağımsızdır (Unity ErrorGlobalLimitAppliesAcrossFingerprints ile aynı senaryo).
	var limited := _make(null, {"errors": {"max_per_minute": 3, "max_per_fingerprint_per_minute": 10}})
	limited.set_consent({"analytics": true})
	for i in range(6):
		limited.capture_error("Hata%d" % i, "m", "X.Y%d ()" % i)
	_check(_events(limited).size() == 3 and limited.errors_suppressed == 3, "genel dakikalık sınır")
	var none := _make(null, {"errors": {"sample_rate": 0.0}})
	none.set_consent({"analytics": true})
	_check(none.capture_error("Boom", "m").is_empty(), "örnekleme sıfır")
	# Oturum
	var session := _make(null)
	session.set_consent({"analytics": true})
	var first_session := session.current_session_id()
	_check(first_session.length() == 26, "oturum üretildi")
	session.notify_background()
	_clock += 29.0 * 60.0
	session.notify_foreground()
	_check(session.current_session_id() == first_session, "29 dakikada aynı oturum")
	session.notify_background()
	_clock += 30.0 * 60.0
	session.notify_foreground()
	_check(session.current_session_id() != first_session, "30 dakikada yeni oturum")
	session.track("a")
	_check(_events(session)[0]["session_id"] == session.current_session_id(), "olay oturum kimliğini taşır")


func _referrer(raw: String, calls: Array) -> Callable:
	return func(done: Callable) -> void:
		calls.append(1)
		done.call(true, raw)


func _test_attribution() -> void:
	var store := _fresh_store("attr")
	store.clear()
	var core := _make(store)
	var calls: Array = []
	core.start_attribution(_referrer("utm_source=google&utm_medium=cpc&fr_click=clk_abc&fr_dl=%2Fpromo%2F1&evil=1", calls))
	_check(calls.is_empty(), "izin kararı yokken referrer okunmaz")
	core.set_consent({"analytics": true, "advertising": true})
	_check(calls.size() == 1, "referrer bir kez okunur")
	var events := _events(core)
	_check(events.size() == 1 and events[0]["event_name"] == "app_first_open", "app_first_open")
	var props: Dictionary = events[0]["properties"]
	_check(props["attribution_source"] == "play_install_referrer" and props["fr_click"] == "clk_abc" and props["utm_source"] == "google", "referrer kanıtı")
	_check(not props.has("evil") and not props.has("fr_dl"), "izin listesi dışı parametre yok")
	_check(core.consume_deferred_deep_link() == "/promo/1" and core.consume_deferred_deep_link() == "", "ertelenmiş yol bir kez")
	# Organik varsayılan kanıt sayılmaz; reklam izni yoksa referrer okunmaz.
	var organic_store := _fresh_store("attr2")
	organic_store.clear()
	var organic := _make(organic_store)
	organic.start_attribution(_referrer("utm_source=google-play&utm_medium=organic", []))
	organic.set_consent({"analytics": true, "advertising": true})
	_check(_events(organic)[0]["properties"]["attribution_source"] == "none", "organik varsayılan kanıt değildir")
	var plain_store := _fresh_store("attr3")
	plain_store.clear()
	var plain := _make(plain_store)
	var plain_calls: Array = []
	plain.start_attribution(_referrer("fr_click=zzz", plain_calls))
	plain.set_consent({"analytics": true})
	_check(plain_calls.is_empty() and _events(plain)[0]["properties"]["attribution_source"] == "none", "reklam izni yok: kanıtsız ve okunmaz")
	plain.set_consent({"analytics": true, "advertising": true})
	_check(plain_calls.size() == 1, "sonradan gelen reklam izni referrer'ı bir kez okur")
	# Derin bağlantı
	var link_core := _make(null)
	link_core.handle_deep_link("myapp://open?fr_click=x")
	link_core.handle_deep_link("https://Shop.Example.com:443/p/1?fr_click=clk9&utm_campaign=c&email=a@b.com&token=1#frag")
	link_core.set_consent({"analytics": true, "advertising": true})
	var links := _events(link_core)
	_check(links.size() == 1 and links[0]["event_name"] == "deep_link_opened", "bekleyen bağlantı izinden sonra teslim edilir")
	var lp: Dictionary = links[0]["properties"]
	_check(lp["attribution_source"] == "app_link" and lp["fr_click"] == "clk9" and lp["utm_campaign"] == "c" and not lp.has("email") and not lp.has("token"), "bağlantı kanıtı süzülür")
	_check(links[0]["context"]["page_url"] == "https://shop.example.com/p/1", "ham URL değil temiz adres")
	_check(FeralinRules.parse_deep_link("ftp://x/y").is_empty() and FeralinRules.parse_deep_link("not a url").is_empty(), "http(s) dışı reddedilir")
	_check(FeralinRules.valid_deep_link_path("/a/b?x=1") and not FeralinRules.valid_deep_link_path("//evil") and not FeralinRules.valid_deep_link_path("/%2e%2e/x") and not FeralinRules.valid_deep_link_path("/../x") and not FeralinRules.valid_deep_link_path("x"), "derin bağlantı yolu kuralları")


func _test_bind_install() -> void:
	var store := _fresh_store("bind")
	var core := _make(store, {"attribution_api_url": "https://api.feralin.test/", "project_id": "proj_1"})
	var result := {}
	# GDScript lambda'sı yerel değişkeni değerle yakalar; atama dışarı yansımaz, bu yüzden aynı sözlük yerinde güncellenir.
	var done := func(r: Dictionary) -> void:
		result.clear()
		result.merge(r)
	var reader := func(cb: Callable) -> void: cb.call({"status": "token", "token": "TOKEN123"})
	var sent := {"url": "", "body": "", "headers": PackedStringArray()}
	var responding := [202]
	var post := func(url: String, headers: PackedStringArray, body: String, cb: Callable) -> void:
		sent["url"] = url
		sent["body"] = body
		sent["headers"] = headers
		cb.call(responding[0])
	core.set_consent({"analytics": true})
	core.bind_install(reader, post, done)
	_check(result["status"] == "skipped_no_consent" and result["install_id"] == "" and sent["url"] == "", "reklam izni yokken token alınmaz")
	core.set_consent({"analytics": true, "advertising": true})
	core.bind_install(reader, post, done)
	_check(result["status"] == "received" and result["install_id"].length() == 26, "token iletildi")
	_check(sent["url"] == "https://api.feralin.test/v1/projects/proj_1/attribution/apple-adservices/tokens", "uç adresi")
	_check(sent["body"].contains("TOKEN123") and sent["headers"].has("Authorization: Bearer " + KEY), "gövde ve yetki başlığı")
	var install: String = result["install_id"]
	responding[0] = 503
	core.bind_install(reader, post, done)
	_check(result["status"] == "temporary_failure" and result["install_id"] == install, "geçici hatada kimlik kalıcı")
	responding[0] = 400
	core.bind_install(reader, post, done)
	_check(result["status"] == "rejected", "kalıcı ret")
	core.bind_install(func(cb: Callable) -> void: cb.call({"status": "unsupported", "token": ""}), post, done)
	_check(result["status"] == "unsupported", "desteklenmiyor")
	core.bind_install(func(cb: Callable) -> void: cb.call({"status": "failed", "token": ""}), post, done)
	_check(result["status"] == "token_unavailable", "token alınamadı")
	var unconfigured := _make(null)
	unconfigured.set_consent({"analytics": true, "advertising": true})
	unconfigured.bind_install(reader, post, done)
	_check(result["status"] == "not_configured", "yapılandırma yok")
	var denied := _make(null, {"attribution_api_url": "https://api.feralin.test", "project_id": "p"})
	denied.tracking_status = func() -> int: return 2
	denied.set_consent({"analytics": true, "advertising": true})
	denied.bind_install(reader, post, done)
	_check(result["status"] == "skipped_no_consent", "ATT reddi reklam kanıtını kapatır")
	for line in _warnings:
		_check(not line.contains("TOKEN123"), "günlükte token yok")

extends SceneTree

## Çekirdek birim testleri. Çalıştırma: godot --headless --path sdks/godot -s tests/test_feralin_core.gd
## Çıkış kodu kalan test sayısıdır. Beklenen idempotency değerleri Python SDK'sından alınmıştır.

const FeralinCore := preload("res://addons/feralin/feralin_core.gd")
const FeralinNode := preload("res://addons/feralin/feralin.gd")
const KEY := "pk_test_godot_key_0001"

var _failures := 0
var _checks := 0
var _warnings: Array[String] = []
var _clock := 1793700000.0


func _init() -> void:
	_test_configure()
	_test_no_consent()
	_test_wire_event()
	_test_fr_click()
	_test_context()
	_test_server_only()
	_test_invalid_input()
	_test_idempotency_vectors()
	_test_ack()
	_test_auth_failure()
	_test_client_error()
	_test_retry_same_key()
	_test_backoff()
	_test_retry_after()
	_test_queue_limit()
	_test_consent_withdrawal()
	_test_key_not_logged()
	_test_control_characters()
	_test_reset_rotates_stored_id()
	_test_install_code()
	print("feralin_core: %d denetim, %d kaldı" % [_checks, _failures])
	quit(_failures)


func _make(consent: Dictionary = {"analytics": true}) -> FeralinCore:
	var core := FeralinCore.new()
	core.now_unix = func() -> float: return _clock
	core.random_unit = func() -> float: return 1.0
	core.log_warning = func(message: String) -> void: _warnings.append(message)
	core.configure(KEY, "https://collect.example.test/")
	core.set_consent(consent)
	return core


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("KALDI: " + label)


func _header(request: Dictionary, name: String) -> String:
	for line in request["headers"]:
		if line.begins_with(name + ": "):
			return line.substr(name.length() + 2)
	return ""


func _events(request: Dictionary) -> Array:
	return JSON.parse_string(request["body"].get_string_from_utf8())["events"]


## Bu makinede Godot yok: bu testler yazıldı, ÇALIŞTIRILMADI.
func _test_control_characters() -> void:
	var core := _make()
	_check(core.track("a", {"t": "satır\nsekme\ttırnak\""}).size() > 0, "json_escape'in kaçırdığı metin geçmeli")
	for bad in ["x\u0001y", "x\u000By", "x\u001Fy"]:
		_check(core.track("a", {"t": bad}).is_empty(), "denetim karakterli değer elenmeli")
		_check(core.track("a", {"nested": {"k": [bad]}}).is_empty(), "iç içe denetim karakteri elenmeli")
		_check(core.track("a", {}, {"user_id": bad}).is_empty(), "kimlikte denetim karakteri elenmeli")
		_check(core.track("a", {}, {"context": {"locale": bad}}).is_empty(), "bağlamda denetim karakteri elenmeli")
	_check(core.track("a", {"nested": {"k\u0001": 1}}).is_empty(), "iç içe anahtarda denetim karakteri elenmeli")
	_check(core.queued() == 1, "yalnız geçerli olay kuyrukta")
	var body: String = core.next_request()["body"].get_string_from_utf8()
	var parser := JSON.new()
	_check(parser.parse(body) == OK, "gövde geçerli JSON olmalı")


func _test_reset_rotates_stored_id() -> void:
	var node := FeralinNode.new()
	node.core.configure(KEY, "https://collect.example.test/")
	node.set_consent({"analytics": true})
	var first := _stored_anonymous_id()
	_check(first.length() == 26, "izinle kimlik saklanmalı")
	_check(_stored_anonymous_id() == first, "kimlik okunurken değişmemeli")

	node.reset()
	var second := _stored_anonymous_id()
	_check(second.length() == 26 and second != first, "reset saklı kimliği yenilemeli")
	var tracked_body := JSON.stringify(_track_wire(node))
	_check(tracked_body.contains(second) and not tracked_body.contains(first), "yeni olay yeni kimliği taşımalı")

	node.set_consent({"analytics": false})
	_check(not FileAccess.file_exists(FeralinNode.ANONYMOUS_ID_PATH), "izin geri çekilince kimlik silinmeli")
	node.reset()
	_check(not FileAccess.file_exists(FeralinNode.ANONYMOUS_ID_PATH), "izin yokken reset kimlik üretmemeli")
	node.set_consent({"analytics": true})
	var third := _stored_anonymous_id()
	_check(third != second and third != first, "yeniden izinde yeni kimlik")
	node.set_consent({"analytics": false})
	node.free()


func _stored_anonymous_id() -> String:
	var config := ConfigFile.new()
	if config.load(FeralinNode.ANONYMOUS_ID_PATH) != OK:
		return ""
	return str(config.get_value("feralin", "anonymous_id", ""))


func _track_wire(node) -> Array:
	node.core.track("a")
	return _events(node.core.next_request())


func _test_configure() -> void:
	var core := FeralinCore.new()
	_check(not core.configure("sk_live_secret_0001", "https://c.example.test"), "sk_ reddedilmeli")
	_check(not core.config_error.contains("sk_live_secret_0001"), "anahtar hata metnine yazılmamalı")
	_check(not core.configure("nope", "https://c.example.test"), "pk_ zorunlu")
	_check(not core.configure(KEY, "ftp://c.example.test"), "şema denetimi")
	_check(not core.configure(KEY, "goreli/yol"), "göreli adres reddedilmeli")
	_check(core.configure(KEY, "https://c.example.test/"), "geçerli yapılandırma")
	_check(core.endpoint == "https://c.example.test/v1/batch", "uç nokta")


func _test_no_consent() -> void:
	var core := _make({})
	_check(core.track("level_start").is_empty(), "izinsiz olay üretilmemeli")
	_check(core.queued() == 0, "izinsiz kuyruk boş")
	_check(core.next_request().is_empty(), "izinsiz istek yok")


func _test_wire_event() -> void:
	var core := _make({"analytics": true, "advertising": true})
	core.identify("player_1")
	var tracked: Dictionary = core.track("level_start", {"level_id": "w1"})
	_check(String(tracked["event_id"]).length() == 26, "ULID uzunluğu")
	var request: Dictionary = core.next_request()
	_check(_header(request, "X-Feralin-Project-Key") == KEY, "anahtar başlığı")
	_check(_header(request, "Idempotency-Key") == FeralinCore.idempotency_key_for([tracked["event_id"]]), "idempotency başlığı")
	var event: Dictionary = _events(request)[0]
	_check(event["platform"] == "godot", "platform")
	_check(int(event["schema_version"]) == 1, "schema_version")
	_check(event["user_id"] == "player_1", "user_id")
	_check(event["consent"]["analytics"] == true, "consent")
	_check(event["properties"]["level_id"] == "w1", "özellik")
	_check(not event.has("verified"), "verified gönderilmemeli")


func _test_fr_click() -> void:
	var without := _make({"analytics": true})
	_check(not without.track("a", {"fr_click": "clk"})["properties"].has("fr_click"), "reklam izni yokken fr_click çıkarılmalı")
	var granted := _make({"analytics": true, "advertising": true})
	_check(granted.track("a", {"fr_click": "clk"})["properties"]["fr_click"] == "clk", "reklam izniyle fr_click kalmalı")


func _test_context() -> void:
	var core := _make()
	core.track("a", {}, {"context": {"locale": "tr-TR", "screen": {"width": 1}, "app": {"version": "1.0", "x": 1}}})
	var context: Dictionary = _events(core.next_request())[0]["context"]
	_check(context == {"locale": "tr-TR", "app": {"version": "1.0"}}, "bağlam yalnız izinli alanları taşır")


func _test_server_only() -> void:
	var core := _make()
	var props: Dictionary = core.track("iap_purchase", {"verified": true, "Tenant_Id": "x", "a": 1})["properties"]
	_check(props.size() == 1 and props.has("a"), "sunucu alanları çıkarılmalı")


func _test_invalid_input() -> void:
	var core := _make()
	_check(core.track("LevelStart").is_empty(), "olay adı deseni")
	_check(core.track("").is_empty(), "boş olay adı")
	_check(core.track("a", {"nan": NAN}).is_empty(), "NaN reddedilmeli")
	_check(core.track("a", {"v": Vector2.ZERO}).is_empty(), "JSON dışı tür reddedilmeli")
	_check(core.track("a", {}, {"user_id": "u".repeat(129)}).is_empty(), "uzun kimlik reddedilmeli")
	_check(core.track("a", {"bad-key": 1, "ok": 1})["properties"].size() == 1, "geçersiz anahtar çıkarılmalı")


func _test_idempotency_vectors() -> void:
	_check(FeralinCore.idempotency_key_for(["01ARZ3NDEKTSV4RRFFQ69G5FAV"]) == "4b321ae683d5ab40-1", "tek olay vektörü")
	_check(FeralinCore.idempotency_key_for(["01ARZ3NDEKTSV4RRFFQ69G5FAW", "01ARZ3NDEKTSV4RRFFQ69G5FAV"]) == "de0c7683bd7be052-2", "iki olay vektörü")


func _test_ack() -> void:
	var core := _make()
	core.track("a")
	core.next_request()
	var outcome: Dictionary = core.on_response(202, PackedStringArray(), "{\"batch_id\":\"b1\",\"accepted\":1,\"rejected\":0}")
	_check(outcome["accepted"] == 1 and outcome["batch_id"] == "b1" and outcome["more"], "202 sonucu")
	_check(core.queued() == 0, "202 kuyruğu boşaltır")


func _test_auth_failure() -> void:
	for status in [401, 403]:
		var core := _make()
		core.batch_size = 1
		core.track("a")
		core.track("b")
		core.next_request()
		var outcome: Dictionary = core.on_response(status, PackedStringArray(), "")
		_check(outcome["rejected"] == 2 and not outcome["more"], "%d kuyruğu atar" % status)
		_check(core.queued() == 0, "%d sonrası kuyruk boş" % status)


func _test_client_error() -> void:
	var core := _make()
	core.batch_size = 1
	core.track("a")
	core.track("b")
	core.next_request()
	var outcome: Dictionary = core.on_response(400, PackedStringArray(), "")
	_check(outcome["rejected"] == 1 and outcome["more"], "400 yalnız batch'i atar")
	_check(core.queued() == 1, "400 sonrası diğer olay kalır")


func _test_retry_same_key() -> void:
	var core := _make()
	var first: Dictionary = core.track("a")
	var attempt: Dictionary = core.next_request()
	var outcome: Dictionary = core.on_response(0, PackedStringArray(), "")
	_check(not outcome["more"] and core.queued() == 1, "ağ hatası kuyrukta tutar")
	core.track("b")
	var retry: Dictionary = core.next_request()
	_check(_header(attempt, "Idempotency-Key") == _header(retry, "Idempotency-Key"), "aynı anahtar")
	_check(_events(retry).size() == 1 and _events(retry)[0]["event_id"] == first["event_id"], "aynı içerik")


func _test_backoff() -> void:
	var core := _make()
	core.track("a")
	core.next_request()
	for expected in [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0]:
		core.on_response(500, PackedStringArray(), "")
		_check(is_equal_approx(core.backoff_remaining(), expected), "geri çekilme %s" % expected)
	_check(core.backoff_active(), "geri çekilme etkin")


func _test_retry_after() -> void:
	var core := _make()
	core.track("a")
	core.next_request()
	core.on_response(429, PackedStringArray(["Retry-After: 60"]), "")
	_check(is_equal_approx(core.backoff_remaining(), 60.0), "Retry-After")
	_check(core.server_wait_active(), "açık flush da bekler")
	core.on_response(503, PackedStringArray(["retry-after: 86400"]), "")
	_check(is_equal_approx(core.backoff_remaining(), 300.0), "Retry-After üst sınırı")


func _test_queue_limit() -> void:
	var core := _make()
	core.queue_limit = 2
	core.track("a")
	var second: Dictionary = core.track("b")
	core.track("c")
	_check(core.queued() == 2 and core.dropped == 1, "kuyruk sınırı")
	_check(_events(core.next_request())[0]["event_id"] == second["event_id"], "en eski atılır")


func _test_consent_withdrawal() -> void:
	var core := _make()
	core.track("a")
	core.next_request()
	core.track("b")
	core.set_consent({"analytics": false})
	_check(core.queued() == 0, "izin geri çekilince kuyruk silinir")
	_check(core.track("c").is_empty(), "izin geri çekilince olay yok")


func _test_key_not_logged() -> void:
	_warnings = []
	var core := _make()
	core.track("GECERSIZ")
	core.track("a")
	core.next_request()
	core.on_response(401, PackedStringArray(), "")
	_check(not _warnings.is_empty(), "uyarı beklenir")
	for line in _warnings:
		_check(not line.contains(KEY), "anahtar loga yazılmamalı")


func _test_install_code() -> void:
	var core := FeralinCore.new()
	core.now_unix = func() -> float: return _clock
	core.random_unit = func() -> float: return 1.0
	core.log_warning = func(message: String) -> void: _warnings.append(message)
	core.configure(KEY, "https://collect.example.test/", {"install_code": " K7M2-Q9XR4 "})
	_check(core.track("level_start").is_empty(), "izin yokken olay ve kod gitmemeli")
	core.set_consent({"analytics": true})
	var first: Dictionary = core.track("level_start", {"level_id": "w1"})
	_check(first["properties"].get("fr_install_code", "") == "K7M2-Q9XR4", "eşleştirme kodu ilk olaya eklenmeli")
	_check(first["properties"]["level_id"] == "w1", "olayın kendi özelliği korunmalı")
	var second: Dictionary = core.track("level_complete")
	_check(not second["properties"].has("fr_install_code"), "eşleştirme kodu yalnız ilk olayda olmalı")
	var bad := FeralinCore.new()
	bad.now_unix = func() -> float: return _clock
	bad.configure(KEY, "https://collect.example.test/", {"install_code": "x;DROP"})
	bad.set_consent({"analytics": true})
	_check(not bad.track("a")["properties"].has("fr_install_code"), "biçimi geçersiz kod yok sayılmalı")

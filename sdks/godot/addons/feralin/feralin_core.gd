extends RefCounted

## Ağ bilmeyen çekirdek: kuyruk, izin, doğrulama ve yanıt kuralları. Düğüm ve sahne ağacı gerektirmez, bu yüzden tek başına sınanır.
## HTTP isteğini feralin.gd atar; burası yalnız isteği üretir ve yanıtı yorumlar.

const SDK_NAME := "feralin-godot"
const SDK_VERSION := "0.2.0"
const PLATFORM := "godot"
const SCHEMA_VERSION := 1

const MAX_BATCH_EVENTS := 500
const MAX_EVENT_NAME_LENGTH := 100
const MAX_PROPERTIES := 100
const MAX_IDENTIFIER_LENGTH := 128
const MAX_DEPTH := 16
## Toplayıcı gövdeyi 1 MiB ile sınırlar; zarf için pay bırakılır.
const MAX_BODY_BYTES := 900 * 1024
const CLICK_PROPERTY := "fr_click"
## Kurulum eşleştirme kodu özelliği (toplayıcı `installcode.go` ve Android SDK ile aynı).
const INSTALL_CODE_PROPERTY := "fr_install_code"
## Bu alanları yalnız sunucu üretir; istemci özelliği olarak da taşınmaz.
const SERVER_ONLY_PROPERTIES := ["verified", "tenant_id", "project_id"]

const MIN_BACKOFF_SEC := 1.0
const MAX_BACKOFF_SEC := 30.0
const MAX_RETRY_AFTER_SEC := 300.0
## String.json_escape yalnız bu denetim karakterlerini geçerli biçimde kaçırır (\b \t \n \f \r). Geri kalanı ham yazılır, \v ise
## geçersiz "\v" olur; tek bozuk metin tüm batch'i geçersiz JSON yaparak toplayıcıda düşürür.
const JSON_SAFE_CONTROLS := [0x08, 0x09, 0x0A, 0x0C, 0x0D]

const CROCKFORD := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const FNV_OFFSET_HI := 0xcbf29ce4
const FNV_OFFSET_LO := 0x84222325
const MASK_32 := 0xFFFFFFFF

var project_key := ""
var endpoint := ""
var batch_size := 100
var queue_limit := 1000
var config_error := ""

## Saat ve rastgele kaynak testte değiştirilir.
var now_unix: Callable = func() -> float: return Time.get_unix_time_from_system()
var random_unit: Callable = func() -> float: return randf()
var random_bytes: Callable = func(count: int) -> PackedByteArray: return Crypto.new().generate_random_bytes(count)
var log_warning: Callable = func(message: String) -> void: push_warning("[Feralin] " + message)

var dropped := 0

const FeralinRules := preload("res://addons/feralin/feralin_rules.gd")
const MAX_EVENT_CHARS := 256 * 1024
const MARKER_FIRST_OPEN := "first_open_event_id"
const MARKER_FIRST_OPEN_AT := "first_open_at_ms"
const MARKER_REFERRER_CHECKED := "referrer_checked"
const MARKER_DEFERRED_DEEP_LINK := "deferred_deep_link"
const MARKER_INSTALL_ID := "install_id"

## Kalıcı şifreli kuyruk (feralin_store.gd); null ise kuyruk yalnız bellektedir. Koruma düzeyi: local_file, android_keystore, ios_keychain, none.
var store = null
var queue_protection := "none"
## Arka planda bu kadar kalınca yeni session_id üretilir (saniye); 0 oturumu kapatır.
var session_timeout_sec := 1800.0
var attribution_api_url := ""
var project_id := ""
var app_version := ""
## iOS ATT durumu için Callable: 0 belirsiz, 1 kısıtlı, 2 reddedildi, 3 izinli, 4 yok; geçersizse yalnız reklam izni sayılır.
var tracking_status: Callable = Callable()
var error_options := {"sample_rate": 1.0, "max_per_minute": 10, "max_per_fingerprint_per_minute": 2, "max_message_length": 200, "max_frames": 12}
var errors_suppressed := 0

var _order: Array = []
var _store_loaded := false
var _consent_decided := false
var _last_background := -1.0
var _error_times: Array = []
var _error_times_by_fp := {}
var _referrer_reader: Callable = Callable()
var _first_open_started := false
var _follow_up_started := false
var _pending_link: Dictionary = {}
var _pending_link_at := 0.0
var _link_evidence: Dictionary = {}
var _install_id := ""

var _consent := {"analytics": false, "advertising": false, "personalization": false, "session_replay": false}
var _user_id := ""
var _anonymous_id := ""
var _session_id := ""
var _queue: Array = []
## Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda kaybolduysa araya giren
## yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
var _pinned: Array = []
var _failures := 0
var _not_before := 0.0
var _server_not_before := 0.0
var _event_name_re: RegEx = RegEx.create_from_string("^[a-z][a-z0-9_]*$")
var _install_code_re: RegEx = RegEx.create_from_string("^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$")
## Kurulum eşleştirme kodu: izin verildikten sonra kuyruğa giren ilk olaya eklenir, sonra boşalır.
var _pending_install_code := ""
var _property_key_re: RegEx = RegEx.create_from_string("^[a-zA-Z][a-zA-Z0-9_]{0,63}$")


## Yapılandırır. Başarısızsa false döner, neden config_error içindedir. Anahtar hata metnine yazılmaz.
func configure(key: String, collect_url: String, options: Dictionary = {}) -> bool:
	config_error = ""
	project_key = ""
	endpoint = ""
	var clean_key := key.strip_edges()
	if clean_key.begins_with("sk_"):
		config_error = "gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin"
		return false
	if not clean_key.begins_with("pk_") or clean_key.length() < 8:
		config_error = "proje anahtarı pk_ ile başlamalı"
		return false
	var url := collect_url.strip_edges()
	var scheme_end := url.find("://")
	var scheme: String = url.substr(0, scheme_end) if scheme_end > 0 else ""
	if (scheme != "http" and scheme != "https") or url.length() <= scheme_end + 3:
		config_error = "collect_url http veya https şemalı mutlak adres olmalı"
		return false
	project_key = clean_key
	endpoint = url.rstrip("/") + "/v1/batch"
	batch_size = clampi(int(options.get("batch_size", 100)), 1, MAX_BATCH_EVENTS)
	queue_limit = maxi(1, int(options.get("queue_limit", 1000)))
	session_timeout_sec = float(options.get("session_timeout_sec", 1800.0))
	attribution_api_url = String(options.get("attribution_api_url", "")).strip_edges().rstrip("/")
	project_id = String(options.get("project_id", "")).strip_edges()
	app_version = String(options.get("app_version", ""))
	# Kurulum eşleştirme kodu (panel "Kurulumu doğrula"): biçimi geçersizse yok sayılır.
	var install_code := String(options.get("install_code", "")).strip_edges()
	_pending_install_code = install_code if _install_code_re.search(install_code) != null else ""
	store = options.get("store")
	queue_protection = String(options.get("queue_protection", "none")) if store != null else "none"
	var errors: Variant = options.get("errors")
	if errors is Dictionary:
		for field in errors:
			error_options[field] = errors[field]
	_session_id = new_ulid() if session_timeout_sec > 0.0 else ""
	return true


func is_configured() -> bool:
	return not project_key.is_empty()


## Reklam kanıtı kullanılabilir mi: reklam izni var ve (varsa) iOS ATT durumu reddetmemiş.
func _effective_advertising() -> bool:
	if not _consent["advertising"]:
		return false
	if not tracking_status.is_valid():
		return true
	var status: Variant = tracking_status.call()
	return typeof(status) == TYPE_INT and status != 1 and status != 2


func _advertising_allowed_now() -> bool:
	return _consent["analytics"] and _effective_advertising()


## İzni günceller. analytics false ise bekleyen olaylar ve diskteki kuyruk silinir, yeni olay üretilmez; izin verilince diskteki
## olaylar event_id'leri korunarak geri yüklenir. Reklam izni yoksa fr_click, kurulum kimliği ve ertelenmiş yol taşınmaz.
func set_consent(consent: Dictionary) -> void:
	for field in _consent:
		var given: Variant = consent.get(field, false)
		_consent[field] = given is bool and given
	_consent_decided = true
	if not _consent["analytics"]:
		_clear_queue()
		_order = []
		if store != null:
			store.clear()
			store.remove_marker(MARKER_INSTALL_ID)
			store.remove_marker(MARKER_DEFERRED_DEEP_LINK)
		_store_loaded = false
		_link_evidence = {}
		_first_open_started = false
		_follow_up_started = false
		_install_id = ""
	else:
		_load_persisted()
	_on_consent_applied()


func get_consent() -> Dictionary:
	return _consent.duplicate()


## Varsayılan user_id; boş değer varsayılanı kaldırır. E-posta veya telefon vermeyin.
func identify(user_id: String) -> void:
	if user_id.length() > MAX_IDENTIFIER_LENGTH:
		log_warning.call("geçersiz user_id yok sayıldı")
		return
	_user_id = user_id


func set_anonymous_id(anonymous_id: String) -> void:
	if anonymous_id.length() > MAX_IDENTIFIER_LENGTH:
		log_warning.call("geçersiz anonymous_id yok sayıldı")
		return
	_anonymous_id = anonymous_id


func set_session_id(session_id: String) -> void:
	if session_id.length() > MAX_IDENTIFIER_LENGTH:
		log_warning.call("geçersiz session_id yok sayıldı")
		return
	_session_id = session_id


## Çıkış: varsayılan kimlikler ve kuyruk silinir.
func reset() -> void:
	_user_id = ""
	_anonymous_id = ""
	# Çıkışta oturum da yenilenir: sonraki hesap önceki oturumla bağlanmaz.
	_session_id = new_ulid() if session_timeout_sec > 0.0 else ""
	_last_background = -1.0
	_clear_queue()
	_order = []
	if store != null:
		store.clear()
		store.remove_marker(MARKER_INSTALL_ID)
	_install_id = ""


func queued() -> int:
	return _queue.size() + _pinned.size()


func unsent_is_full() -> bool:
	return _queue.size() >= batch_size


## Olayı doğrular ve kuyruğa ekler; ağ çağrısı yapmaz. İzin yoksa veya girdi geçersizse boş sözlük döner, oyunu düşürmez.
## fr_click yalnız reklam izniyle gönderilir; verified hiçbir zaman gönderilmez.
func track(event_name: String, properties: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	if not is_configured():
		log_warning.call("yapılandırılmadı, olay üretilmedi")
		return {}
	if not _consent["analytics"]:
		return {}
	if event_name.is_empty() or event_name.length() > MAX_EVENT_NAME_LENGTH or _event_name_re.search(event_name) == null:
		log_warning.call("geçersiz olay adı")
		return {}

	var user_id: String = str(options.get("user_id", _user_id))
	var anonymous_id: String = str(options.get("anonymous_id", _anonymous_id))
	var session_id: String = str(options.get("session_id", _session_id))
	if user_id.length() > MAX_IDENTIFIER_LENGTH or anonymous_id.length() > MAX_IDENTIFIER_LENGTH or session_id.length() > MAX_IDENTIFIER_LENGTH:
		log_warning.call("geçersiz kimlik alanı, olay üretilmedi")
		return {}

	var props := _sanitize_properties(properties)
	if not _effective_advertising():
		props.erase(CLICK_PROPERTY)
	# Kod yalnız kuyruğa giren ilk olaya eklenir; olay erken reddedilirse bir sonrakine kalır.
	var install_code := _pending_install_code
	if not install_code.is_empty():
		props[INSTALL_CODE_PROPERTY] = install_code

	var now: float = now_unix.call()
	var event_id := new_ulid()
	var wire := {
		"event_id": event_id,
		"event_name": event_name,
		"occurred_at": format_time(float(options.get("occurred_at", now))),
		"platform": PLATFORM,
		"schema_version": SCHEMA_VERSION,
		"sdk": {"name": SDK_NAME, "version": SDK_VERSION},
		"consent": _consent.duplicate(),
	}
	if not anonymous_id.is_empty():
		wire["anonymous_id"] = anonymous_id
	if not user_id.is_empty():
		wire["user_id"] = user_id
	if not session_id.is_empty():
		wire["session_id"] = session_id
	if not props.is_empty():
		wire["properties"] = props
	var context := _clean_context(options.get("context"))
	if not context.is_empty():
		wire["context"] = context

	# JSON.stringify bilinmeyen türleri metne çevirir, NaN ve denetim karakteri için geçersiz JSON yazar; bozuk olay kuyruğa girmeden
	# elenir. Kimlik ve bağlam metinleri de aynı JSON'a girdiğinden denetim tüm olay üzerindedir. Başlangıç -1: özellikler derinlik 0.
	if not _is_json_safe(wire, -1):
		log_warning.call("JSON'a dönüştürülemeyen değer, olay üretilmedi")
		return {}

	var json := JSON.stringify(wire)
	var size := json.to_utf8_buffer().size()
	if size > MAX_BODY_BYTES:
		log_warning.call("olay boyut sınırını aşıyor, atıldı: %d bayt" % size)
		return {}

	_queue.append({"id": event_id, "json": json, "size": size})
	_order.append(event_id)
	if not install_code.is_empty():
		_pending_install_code = ""
	if store != null and json.length() <= MAX_EVENT_CHARS:
		store.add(event_id, json)
	var over := queued() - queue_limit
	if over > 0:
		var removed := mini(over, _queue.size())
		var dropped_ids: Array = []
		for _i in range(removed):
			dropped_ids.append(_queue.pop_front()["id"])
		dropped += removed
		_forget(dropped_ids)
		log_warning.call("kuyruk sınırı aşıldı, en eski %d olay atıldı" % removed)
	return {"event_id": event_id, "event_name": event_name, "properties": props}


## Üstel geri çekilme veya Retry-After otomatik gönderimi engelliyor mu.
func backoff_active() -> bool:
	var now: float = now_unix.call()
	return now < _not_before or now < _server_not_before


## Sunucunun Retry-After süresi sürüyor mu; açık flush da bunu bekler.
func server_wait_active() -> bool:
	return now_unix.call() < _server_not_before


## Gönderilecek sonraki isteği üretir: {url, headers, body, size}; yoksa boş sözlük. Yanıt gelene kadar batch sabit kalır.
func next_request() -> Dictionary:
	if _pinned.is_empty():
		var count := 0
		var bytes := 0
		for item in _queue:
			if count >= batch_size or (count > 0 and bytes + int(item["size"]) > MAX_BODY_BYTES):
				break
			count += 1
			bytes += int(item["size"]) + 1
		if count == 0:
			return {}
		_pinned = _queue.slice(0, count)
		_queue = _queue.slice(count)

	var ids: Array = []
	var events: PackedStringArray = []
	for item in _pinned:
		ids.append(item["id"])
		events.append(item["json"])
	var body := "{\"sent_at\":\"%s\",\"events\":[%s]}" % [format_time(now_unix.call()), ",".join(events)]
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json, application/problem+json",
		"X-Feralin-Project-Key: " + project_key,
		"Idempotency-Key: " + idempotency_key_for(ids),
		"User-Agent: %s/%s" % [SDK_NAME, SDK_VERSION],
	])
	return {"url": endpoint, "headers": headers, "body": body.to_utf8_buffer(), "size": _pinned.size()}


## Yanıtı işler. status 0: ağ hatası. Dönen sözlük: sent, accepted, rejected, status, batch_id, more (aynı turda devam edilsin mi).
func on_response(status: int, response_headers: PackedStringArray, body_text: String) -> Dictionary:
	var size := _pinned.size()
	var result := {"sent": size, "accepted": 0, "rejected": 0, "status": status, "batch_id": "", "more": false}
	if status == 202:
		# JSON.new().parse okunamayan gövdede hata günlüğü üretmez; kabul edilen batch yine gönderilmiş sayılır.
		var parser := JSON.new()
		var values: Dictionary = parser.data if parser.parse(body_text) == OK and parser.data is Dictionary else {}
		var accepted: Variant = values.get("accepted")
		var rejected: Variant = values.get("rejected")
		var batch_id: Variant = values.get("batch_id")
		result["accepted"] = int(accepted) if accepted is float or accepted is int else size
		result["rejected"] = int(rejected) if rejected is float or rejected is int else 0
		result["batch_id"] = batch_id if batch_id is String else ""
		result["more"] = true
		_forget_items(_pinned)
		_pinned = []
		_failures = 0
		_not_before = 0.0
		_server_not_before = 0.0
		return result
	if status == 401 or status == 403:
		# Anahtar geçersizse sıradaki olaylar da aynı yanıtı alır; kuyruk atılır, oyun etkilenmez.
		result["rejected"] = size + _queue.size()
		_pinned = []
		_queue = []
		_order = []
		if store != null:
			store.clear()
		log_warning.call("anahtar reddedildi: HTTP %d, %d olay atıldı" % [status, result["rejected"]])
		return result
	if status >= 400 and status < 500 and status != 429:
		result["rejected"] = size
		result["more"] = true
		_forget_items(_pinned)
		_pinned = []
		log_warning.call("batch kalıcı olarak reddedildi: HTTP %d, %d olay atıldı" % [status, size])
		return result
	_note_failure(_retry_after(response_headers))
	return result


## Kaç saniye beklenecek (tanı amaçlı).
func backoff_remaining() -> float:
	return maxf(0.0, maxf(_not_before, _server_not_before) - float(now_unix.call()))


## 26 karakter Crockford base32: 48 bit zaman, 80 bit güvenli rastgele.
func new_ulid() -> String:
	var chars := PackedStringArray()
	chars.resize(26)
	var time_ms := maxi(0, int(float(now_unix.call()) * 1000.0))
	for i in range(9, -1, -1):
		chars[i] = CROCKFORD[time_ms % 32]
		time_ms = time_ms / 32
	var random: PackedByteArray = random_bytes.call(16)
	for i in range(16):
		chars[10 + i] = CROCKFORD[random[i] % 32]
	return "".join(chars)


## Diğer Feralin SDK'larıyla aynı anahtar: sıralı tüm event_id'lerin UTF-8 FNV-1a 64 özeti ve olay sayısı.
## GDScript tamsayısı işaretli 64 bittir; taşma tanımsız kalmasın diye çarpım 32 bitlik parçalarla yapılır.
static func idempotency_key_for(event_ids: Array) -> String:
	var ordered := event_ids.duplicate()
	ordered.sort()
	var joined := ",".join(PackedStringArray(ordered))
	var hi := FNV_OFFSET_HI
	var lo := FNV_OFFSET_LO
	for value in joined.to_utf8_buffer():
		lo = lo ^ value
		# Asal 2^40 + 0x1B3: h * asal = (h << 40) + h * 0x1B3 (mod 2^64).
		var low_product := lo * 0x1B3
		var high_product := hi * 0x1B3 + (lo << 8) + (low_product >> 32)
		lo = low_product & MASK_32
		hi = high_product & MASK_32
	return "%08x%08x-%d" % [hi, lo, ordered.size()]


## UTC RFC3339, milisaniye hassasiyeti.
static func format_time(unix_seconds: float) -> String:
	var whole := int(floor(unix_seconds))
	var millis := clampi(int((unix_seconds - whole) * 1000.0), 0, 999)
	return "%s.%03dZ" % [Time.get_datetime_string_from_unix_time(whole), millis]


## Kuyruktan atılan olayların kimliklerini sıra listesinden ve diskten siler.
func _forget(ids: Array) -> void:
	if ids.is_empty():
		return
	var gone := {}
	for id in ids:
		gone[String(id)] = true
	_order = _order.filter(func(id: Variant) -> bool: return not gone.has(String(id)))
	if store != null:
		store.remove(ids)


func _forget_items(items: Array) -> void:
	var ids: Array = []
	for item in items:
		ids.append(item["id"])
	_forget(ids)


## İzin verilince diskteki olaylar event_id'leri korunarak belleğe alınır (aynı event_id ile tekrar gönderim). Bir kez yapılır.
func _load_persisted() -> void:
	if store == null or _store_loaded:
		return
	_store_loaded = true
	var known := {}
	for item in _queue:
		known[item["id"]] = true
	for item in _pinned:
		known[item["id"]] = true
	var restored: Array = []
	var invalid: Array = []
	for row in store.load_events():
		var payload: String = row["payload"]
		if payload.length() > MAX_EVENT_CHARS:
			invalid.append(row["id"])
		elif not known.has(row["id"]):
			known[row["id"]] = true
			restored.append({"id": row["id"], "json": payload, "size": payload.to_utf8_buffer().size()})
	var ordered: Array = []
	for item in restored:
		ordered.append(item["id"])
	_order = ordered + _order
	_queue = restored + _queue
	var over := queued() - queue_limit
	if over > 0:
		var drop := mini(over, _queue.size())
		for _i in range(drop):
			invalid.append(_queue.pop_front()["id"])
		dropped += drop
	_forget(invalid)


# ---------------------------------------------------------------- oturum

## Oyun arka plana geçti; ön plana dönüşte süre dolmuşsa yeni oturum başlar.
func notify_background() -> void:
	# Duraklama ve odak kaybı art arda gelebilir; ilk arka plan anı korunur.
	if _last_background < 0.0:
		_last_background = float(now_unix.call())


func notify_foreground() -> void:
	var now: float = now_unix.call()
	if session_timeout_sec > 0.0 and _last_background >= 0.0 and now - _last_background >= session_timeout_sec:
		_session_id = new_ulid()
	_last_background = -1.0


func current_session_id() -> String:
	return _session_id


# ---------------------------------------------------------------- sözleşmeli olaylar

func _reject(event_name: String) -> Dictionary:
	log_warning.call("%s: girdi sözleşmeye uymuyor, olay üretilmedi" % event_name)
	return {}


## Satın alma ya da abonelik beyanı (feralin_purchase). İstemci beyanıdır; verified hiçbir zaman gönderilmez.
func track_revenue(input: Dictionary) -> Dictionary:
	var props: Variant = FeralinRules.revenue_properties(input)
	return _reject("feralin_purchase") if props == null else track("feralin_purchase", props)


## Reklam geliri (fr_ad_revenue): satın alma gelirinden ayrıdır, deftere feralin_purchase olarak girmez.
func track_ad_revenue(input: Dictionary) -> Dictionary:
	var props: Variant = FeralinRules.ad_revenue_properties(input)
	return _reject("fr_ad_revenue") if props == null else track("fr_ad_revenue", props)


## Eski iap_purchase yardımcısı: ondalık tutarı küçük birime çevirip feralin_purchase gönderir; işlem kimliği zorunludur.
func track_iap_purchase(product_id: String, price: float, currency: String, transaction_id: String, properties: Dictionary = {}) -> Dictionary:
	var minor: Variant = FeralinRules.to_minor(price, currency) if FeralinRules.valid_currency(currency) else null
	if product_id.is_empty() or transaction_id.is_empty() or minor == null:
		return _reject("iap_purchase")
	return track_revenue({"transaction_id": transaction_id, "amount_minor": minor, "currency": currency, "product_id": product_id, "properties": properties})


## Kullanıcıyı gruba bağlar (fr_group). Grup kimliği kişisel veri taşımamalıdır.
func group(group_id: String, traits: Dictionary = {}) -> Dictionary:
	if not FeralinRules.text_in(group_id, MAX_IDENTIFIER_LENGTH):
		return _reject("fr_group")
	var props := FeralinRules.sanitize_properties(traits)
	props["group_id"] = group_id
	return track("fr_group", props)


## Kullanıcı özellikleri (fr_user_properties). Geçerli özellik yoksa olay üretilmez.
func set_user_properties(properties: Dictionary) -> Dictionary:
	var props := FeralinRules.sanitize_properties(properties)
	if props.is_empty():
		return _reject("fr_user_properties")
	return track("fr_user_properties", props)


## Oyun olayı: props null ise (sözleşme dışı) üretilmez. Kurallar feralin_rules.gd içindedir.
func track_game(event_name: String, props: Variant) -> Dictionary:
	return _reject(event_name) if props == null else track(event_name, props)


# ---------------------------------------------------------------- hata (fr_error)

## fr_error: ileti ve yığın kişisel veriden arındırılır, çerçeveler normalleştirilir, parmak izi üretilir; örnekleme ve dakikalık hız sınırı
## uygulanır. Alan adları packages/schemas/utp/v1/event.schema.json ile aynıdır. Gönderilmeyen hata için boş sözlük.
## source: manual | unhandled_exception | log_error | log_fatal.
func capture_error(error_type: String, message: String, stack_trace: String = "", handled: bool = true, source: String = "manual") -> Dictionary:
	if not _consent["analytics"]:
		return {}
	var sample_rate := float(error_options["sample_rate"])
	if sample_rate <= 0.0 or (sample_rate < 1.0 and float(random_unit.call()) >= sample_rate):
		return {}
	var type := FeralinRules.scrub("Error" if error_type.is_empty() else error_type, 64)
	if type.is_empty():
		type = "Error"
	var frames := FeralinRules.normalize_frames(stack_trace, maxi(1, int(error_options["max_frames"])))
	var fingerprint := FeralinRules.fingerprint(type, frames)
	if not _admit_error(fingerprint):
		errors_suppressed += 1
		return {}
	var fatal := source == "unhandled_exception" or source == "log_fatal"
	var origin := "uncaught_exception" if fatal else ("handled" if source == "log_error" else ("manual" if handled else "uncaught_exception"))
	var props := {
		"error_type": type,
		"fingerprint": fingerprint,
		"frame_count": frames.size(),
		"handled": handled,
		"fatal": fatal,
		"origin": origin,
	}
	var clean := FeralinRules.scrub(message, mini(200, maxi(16, int(error_options["max_message_length"]))))
	if not clean.is_empty():
		props["message"] = clean
	if frames.size() > 0:
		props["top_frame"] = frames[0].substr(0, 160)
	if not app_version.is_empty() and app_version.length() <= 32:
		props["app_version"] = app_version
	return track("fr_error", props)


func _admit_error(fingerprint: String) -> bool:
	var max_total := int(error_options["max_per_minute"])
	var max_each := int(error_options["max_per_fingerprint_per_minute"])
	if max_total <= 0 or max_each <= 0:
		return false
	var now: float = now_unix.call()
	_error_times = _error_times.filter(func(t: float) -> bool: return t > now - 60.0)
	if _error_times.size() >= max_total:
		return false
	if not _error_times_by_fp.has(fingerprint) and _error_times_by_fp.size() >= 64:
		for key in _error_times_by_fp.keys():
			_error_times_by_fp[key] = _error_times_by_fp[key].filter(func(t: float) -> bool: return t > now - 60.0)
			if _error_times_by_fp[key].is_empty():
				_error_times_by_fp.erase(key)
		if _error_times_by_fp.size() >= 64:
			_error_times_by_fp.clear()
	var own: Array = _error_times_by_fp.get(fingerprint, []).filter(func(t: float) -> bool: return t > now - 60.0)
	if own.size() >= max_each:
		_error_times_by_fp[fingerprint] = own
		return false
	_error_times.append(now)
	own.append(now)
	_error_times_by_fp[fingerprint] = own
	return true


# ---------------------------------------------------------------- atıf

func _marker(key: String) -> Dictionary:
	return store.get_marker(key) if store != null else {"found": false, "value": ""}


## Android: Play Install Referrer'ı kurulumda bir kez okur ve app_first_open üretir. reader: done(has_value: bool, raw: String) çağıran Callable.
## Referrer yalnız analitik ve reklam izniyle okunur; izin yoksa ilk açılış kanıtsız (attribution_source=none) üretilir, reklam izni
## sonradan gelirse referrer o zaman bir kez okunur ve işaretli deep_link_opened ile taşınır. Kalıcı depo yoksa hiçbir şey yapılmaz.
func start_attribution(reader: Callable) -> void:
	if not reader.is_valid():
		return
	if store == null:
		log_warning.call("atıf: kalıcı depo yok, ilk açılış tekrarlanabileceğinden başlatılmadı")
		return
	_referrer_reader = reader
	_process_attribution()


## Uygulama bağlantısı: yalnız http(s). Sorgudan yalnız fr_click, fr_dl ve utm_* okunur, ham URL saklanmaz. İzin kararı verilmeden
## gelen bağlantı bellekte bekletilir.
func handle_deep_link(url: String) -> void:
	var link := FeralinRules.parse_deep_link(url)
	if link.is_empty():
		return
	var at: float = now_unix.call()
	if not _consent_decided:
		_pending_link = link
		_pending_link_at = at
		return
	if not _consent["analytics"]:
		return
	_emit_deep_link(link, at)


## Ertelenmiş derin bağlantı yolunu bir kez teslim eder (yalnız fr_click ile gelen uygulama içi yol); yoksa boş metin.
func consume_deferred_deep_link() -> String:
	if store == null or not _consent["analytics"] or not _effective_advertising():
		return ""
	var marker := _marker(MARKER_DEFERRED_DEEP_LINK)
	if not marker["found"]:
		return ""
	store.remove_marker(MARKER_DEFERRED_DEEP_LINK)
	return marker["value"]


## iOS: AdServices token'ını kurulum kimliğiyle sunucuya iletir (ADR-0007). Reklam izni (analitik, reklam ve ATT) yoksa token alınmaz.
## token_reader: done({"status": "token"|"unsupported"|"failed", "token": String}) çağıran Callable.
## http_post: (url: String, headers: PackedStringArray, body: String, done: Callable(status: int)). on_done: ({"status", "install_id"}).
## Kesin tekil atıf iddia edilmez: sunucu bugün Apple'a sormaz, token yalnız saklanır.
func bind_install(token_reader: Callable, http_post: Callable, on_done: Callable) -> void:
	if not on_done.is_valid():
		return
	if attribution_api_url.is_empty() or project_id.is_empty():
		on_done.call({"status": "not_configured", "install_id": ""})
		return
	if not _advertising_allowed_now():
		on_done.call({"status": "skipped_no_consent", "install_id": ""})
		return
	if not token_reader.is_valid() or not http_post.is_valid():
		on_done.call({"status": "unsupported", "install_id": ""})
		return
	var answered := [false]
	token_reader.call(func(result: Dictionary) -> void:
		if answered[0]:
			return
		answered[0] = true
		_complete_bind(result, http_post, on_done))


func _bind_finish(on_done: Callable, status: String) -> void:
	on_done.call({"status": status, "install_id": _ensure_install_id() if _advertising_allowed_now() else ""})


func _complete_bind(result: Dictionary, http_post: Callable, on_done: Callable) -> void:
	# Sonuç, gönderim sırasında izin geri çekildiyse kimlik içermez.
	if not _advertising_allowed_now():
		on_done.call({"status": "skipped_no_consent", "install_id": ""})
		return
	var token_status: String = result.get("status", "failed")
	if token_status == "failed" or token_status.is_empty():
		_bind_finish(on_done, "token_unavailable")
		return
	if token_status == "unsupported":
		_bind_finish(on_done, "unsupported")
		return
	var install_id := _ensure_install_id()
	var body := JSON.stringify({"token": result.get("token", ""), "install_id": install_id})
	var url := attribution_api_url + "/v1/projects/" + project_id.uri_encode() + "/attribution/apple-adservices/tokens"
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json, application/problem+json",
		"Authorization: Bearer " + project_key,
		"User-Agent: %s/%s" % [SDK_NAME, SDK_VERSION],
	])
	var responded := [false]
	http_post.call(url, headers, body, func(status: int) -> void:
		if responded[0]:
			return
		responded[0] = true
		if status == 202:
			_bind_finish(on_done, "received")
		elif status == 0 or status == 429 or status >= 500:
			_bind_finish(on_done, "temporary_failure")
		else:
			log_warning.call("AdServices token reddedildi: HTTP %d" % status)
			_bind_finish(on_done, "rejected"))


## Kurulum kimliği rastgele ULID'dir, cihazdan türetilmez; yalnız reklam izniyle üretilir ve kalıcı depoda tutulur.
func _ensure_install_id() -> String:
	if not _install_id.is_empty():
		return _install_id
	var stored := _marker(MARKER_INSTALL_ID)
	_install_id = stored["value"] if stored["found"] and String(stored["value"]).length() == 26 else new_ulid()
	if store != null:
		store.put_marker(MARKER_INSTALL_ID, _install_id)
	return _install_id


## set_consent sonrası: bekleyen bağlantı, ilk açılış ve izin geri çekildiyse atıf durumunun temizliği.
func _on_consent_applied() -> void:
	var pending := {}
	var pending_at := 0.0
	var analytics: bool = _consent["analytics"]
	if analytics:
		pending = _pending_link
		pending_at = _pending_link_at
	_pending_link = {}
	if analytics and not _effective_advertising():
		# Reklam izni yoksa kanıt, kurulum kimliği ve ertelenmiş yol taşınmaz.
		_link_evidence = {}
		_install_id = ""
		if store != null:
			store.remove_marker(MARKER_INSTALL_ID)
			store.remove_marker(MARKER_DEFERRED_DEEP_LINK)
	if not analytics:
		return
	if not pending.is_empty():
		_emit_deep_link(pending, pending_at)
	_process_attribution()


func _emit_deep_link(link: Dictionary, at: float) -> void:
	var advertising := _effective_advertising()
	var params: Dictionary = link["params"]
	if advertising and not FeralinRules.attribution_is_empty(params):
		_link_evidence = params
	var props := {}
	if advertising:
		props["attribution_source"] = "app_link"
		FeralinRules.attribution_write(params, props)
	else:
		# İzin yoksa atıf yoktur: açılış sayılır, kanıt gönderilmez.
		props["attribution_source"] = "none"
	track("deep_link_opened", props, {"occurred_at": at, "context": {"page_url": link["clean_url"]}})


func _process_attribution() -> void:
	if not _referrer_reader.is_valid() or store == null or not _consent_decided or not _consent["analytics"]:
		return
	var advertising := _effective_advertising()
	var first_open := _marker(MARKER_FIRST_OPEN)
	var checked := _marker(MARKER_REFERRER_CHECKED)
	var start_first := false
	var start_follow := false
	if not first_open["found"]:
		if _first_open_started:
			return
		_first_open_started = true
		start_first = true
	elif advertising and not checked["found"] and not _follow_up_started:
		_follow_up_started = true
		start_follow = true
	if start_first:
		var at: float = now_unix.call()
		if advertising:
			_read_referrer(func(has: bool, raw: String) -> void: _complete_first_open(at, has, raw))
		else:
			_complete_first_open(at, false, "")
	elif start_follow:
		_read_referrer(func(has: bool, raw: String) -> void: _complete_follow_up(has, raw))


func _read_referrer(on_result: Callable) -> void:
	var settled := [false]
	_referrer_reader.call(func(has: bool, raw: String) -> void:
		if settled[0]:
			return
		settled[0] = true
		on_result.call(has, raw))


func _complete_first_open(at: float, has: bool, raw: String) -> void:
	if not _consent["analytics"]:
		# İzin okuma sırasında geri çekildi: işaret yazılmadı, sonraki onayda yeniden denenir.
		_first_open_started = false
		return
	var advertising := _effective_advertising()
	var referrer := FeralinRules.parse_attribution_query(raw) if advertising and has else {}
	var props := {}
	if advertising and not referrer.is_empty() and not FeralinRules.attribution_is_empty(referrer) and not FeralinRules.attribution_is_play_organic(referrer):
		props["attribution_source"] = "play_install_referrer"
		FeralinRules.attribution_write(referrer, props)
	elif advertising and not _link_evidence.is_empty():
		props["attribution_source"] = "app_link"
		FeralinRules.attribution_write(_link_evidence, props)
	else:
		props["attribution_source"] = "none"
	var tracked := track("app_first_open", props, {"occurred_at": at})
	if tracked.is_empty():
		_first_open_started = false
		return
	store.put_marker(MARKER_FIRST_OPEN, tracked["event_id"])
	# Sonradan gelen izinde bakış penceresi gerçek ilk açılışa göre işlesin: izin anı kanıtın yaşını değiştirmemeli.
	store.put_marker(MARKER_FIRST_OPEN_AT, str(int(at * 1000.0)))
	if advertising:
		store.put_marker(MARKER_REFERRER_CHECKED, "1")
		if not referrer.is_empty() and not String(referrer["deep_link_path"]).is_empty():
			store.put_marker(MARKER_DEFERRED_DEEP_LINK, referrer["deep_link_path"])


func _complete_follow_up(has: bool, raw: String) -> void:
	_follow_up_started = false
	if not _consent["analytics"] or not _effective_advertising():
		return
	var referrer := FeralinRules.parse_attribution_query(raw) if has else {}
	if referrer.is_empty() or FeralinRules.attribution_is_empty(referrer) or FeralinRules.attribution_is_play_organic(referrer):
		store.put_marker(MARKER_REFERRER_CHECKED, "1")
		return
	var props := {"attribution_source": "play_install_referrer", "consent_followup": true}
	var first_open_at := _marker(MARKER_FIRST_OPEN_AT)
	if first_open_at["found"] and String(first_open_at["value"]).is_valid_int():
		props["first_open_at"] = format_time(float(int(first_open_at["value"])) / 1000.0)
	FeralinRules.attribution_write(referrer, props)
	var tracked := track("deep_link_opened", props)
	if tracked.is_empty():
		return
	store.put_marker(MARKER_REFERRER_CHECKED, "1")
	if not String(referrer["deep_link_path"]).is_empty():
		store.put_marker(MARKER_DEFERRED_DEEP_LINK, referrer["deep_link_path"])


func _clear_queue() -> void:
	_queue = []
	_pinned = []
	_failures = 0
	_not_before = 0.0
	_server_not_before = 0.0


func _sanitize_properties(properties: Dictionary) -> Dictionary:
	var result := {}
	var removed := 0
	for key in properties:
		var name := str(key)
		if not (key is String or key is StringName) or _property_key_re.search(name) == null or SERVER_ONLY_PROPERTIES.has(name.to_lower()) or result.size() >= MAX_PROPERTIES:
			removed += 1
			continue
		result[name] = properties[key]
	if removed > 0:
		log_warning.call("geçersiz veya sunucuya ait %d özellik çıkarıldı" % removed)
	return result


## Şema dışı bağlam alanı toplayıcıda tüm batch'i 400 ile düşürür; yalnız parmak izi üretmeyen izinli alanlar geçer.
func _clean_context(context: Variant) -> Dictionary:
	var result := {}
	if not context is Dictionary:
		return result
	for field in ["locale", "timezone"]:
		var value: Variant = context.get(field)
		if value is String and not value.is_empty():
			result[field] = value.substr(0, 16 if field == "locale" else 64)
	# Derin bağlantı olayı temizlenmiş (sorgusuz) sayfa adresini taşır; ham URL değildir.
	var page_url: Variant = context.get("page_url")
	if page_url is String and not page_url.is_empty() and page_url.length() <= 2048:
		result["page_url"] = page_url
	var app: Variant = context.get("app")
	if app is Dictionary:
		var clean_app := {}
		for field in ["version", "build"]:
			var value: Variant = app.get(field)
			if value is String and not value.is_empty():
				clean_app[field] = value.substr(0, 32)
		if not clean_app.is_empty():
			result["app"] = clean_app
	return result


func _is_json_safe(value: Variant, depth: int) -> bool:
	if depth > MAX_DEPTH:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return true
		TYPE_STRING, TYPE_STRING_NAME:
			return not _has_unsafe_control(String(value))
		TYPE_FLOAT:
			return not (is_nan(value) or is_inf(value))
		TYPE_ARRAY:
			for item in value:
				if not _is_json_safe(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if not (key is String or key is StringName) or _has_unsafe_control(String(key)) or not _is_json_safe(value[key], depth + 1):
					return false
			return true
	return false


func _has_unsafe_control(text: String) -> bool:
	for i in range(text.length()):
		var code := text.unicode_at(i)
		if code < 0x20 and not JSON_SAFE_CONTROLS.has(code):
			return true
	return false


func _retry_after(response_headers: PackedStringArray) -> float:
	for line in response_headers:
		if line.to_lower().begins_with("retry-after:"):
			var value := line.substr(line.find(":") + 1).strip_edges()
			if value.is_valid_int():
				return float(value.to_int())
	return 0.0


func _note_failure(retry_after: float) -> void:
	_failures += 1
	var now: float = now_unix.call()
	var ceiling := minf(MAX_BACKOFF_SEC, MIN_BACKOFF_SEC * pow(2.0, mini(_failures - 1, 10)))
	# Yarım jitter: aynı anda yeniden başlayan oyunlar toplayıcıya birlikte yüklenmez.
	_not_before = now + ceiling * (0.5 + float(random_unit.call()) * 0.5)
	if retry_after > 0.0:
		_server_not_before = now + minf(retry_after, MAX_RETRY_AFTER_SEC)

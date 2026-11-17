extends Node

## "Feralin" autoload'u. HTTPRequest ile gönderir, Timer ile otomatik gönderimi sürer, arka plana geçişte kuyruğu dener.
## Anahtar ve adres Proje Ayarları'ndan (feralin/project_key, feralin/collect_url) veya configure() ile gelir.
## İzin kaydedilmez: oyun her açılışta kendi kararını set_consent ile bildirir; karar verilene kadar olay üretilmez.

## Bir gönderim turu bitince yayılır. Sözlük: sent, accepted, rejected, status, retained, batch_id.
signal flushed(result: Dictionary)

const FeralinCore := preload("res://addons/feralin/feralin_core.gd")
const FeralinStore := preload("res://addons/feralin/feralin_store.gd")
const FeralinRules := preload("res://addons/feralin/feralin_rules.gd")
const ANONYMOUS_ID_PATH := "user://feralin.cfg"
const QUEUE_DIRECTORY := "user://feralin"
## Toplayıcı yanıtı küçük bir onaydır; bozuk veya kötü niyetli sunucu oyunun belleğini dolduramaz.
## Sınır aşılırsa HTTPRequest sonucu başarısız olur ve istek ağ hatası gibi işlenir: batch aynı anahtarla yeniden denenir.
const MAX_RESPONSE_BYTES := 64 * 1024

var core := FeralinCore.new()

var flush_interval_sec := 2.0
var timeout_sec := 10.0

var _http: HTTPRequest
var _timer: Timer
var _busy := false
var _flush_again := false
var _result := {}
var _rounds := 0


func _ready() -> void:
	# Oyun duraklatıldığında (get_tree().paused) da gönderim sürer.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.timeout = timeout_sec
	_http.body_size_limit = MAX_RESPONSE_BYTES
	# Yönlendirme izlenmez: proje anahtarı başka adrese gitmesin.
	_http.max_redirects = 0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_timer = Timer.new()
	_timer.wait_time = flush_interval_sec
	_timer.timeout.connect(_on_timer)
	add_child(_timer)
	_timer.start()
	var key := str(ProjectSettings.get_setting("feralin/project_key", ""))
	if not key.is_empty():
		configure(key, str(ProjectSettings.get_setting("feralin/collect_url", "")))


## Yapılandırır. Geçersiz anahtar veya adres oyunu düşürmez: hata yazılır, false döner, olay üretilmez.
func configure(project_key: String, collect_url: String, options: Dictionary = {}) -> bool:
	var core_options := options.duplicate()
	# Kalıcı şifreli kuyruk (varsayılan açık, options["persist_queue"] = false ile kapanır). Anahtar alınamazsa düz metne düşülmez,
	# kuyruk bellekte kalır. Koruma düzeyi Android'de Keystore, iOS'ta Keychain (yerel eklenti varsa), aksi halde local_file.
	if bool(options.get("persist_queue", true)):
		var directory := str(options.get("queue_directory", QUEUE_DIRECTORY))
		var opened: Dictionary = FeralinStore.open_key(directory, _key_protector())
		if opened["key"].size() == 32:
			core_options["store"] = FeralinStore.new(directory, opened["key"])
			core_options["queue_protection"] = opened["protection"]
		else:
			push_warning("[Feralin] kuyruk anahtarı alınamadı: kalıcı kuyruk kapalı, olaylar yalnız bellekte tutulur")
	if not core.configure(project_key, collect_url, core_options):
		push_error("[Feralin] " + core.config_error)
		return false
	core.tracking_status = _tracking_status_reader()
	if bool(options.get("start_attribution", true)):
		_start_platform_attribution()
	flush_interval_sec = float(options.get("flush_interval_sec", flush_interval_sec))
	timeout_sec = float(options.get("timeout_sec", timeout_sec))
	if _http != null:
		_http.timeout = timeout_sec
	if _timer != null and flush_interval_sec > 0.0:
		_timer.wait_time = flush_interval_sec
	return true


## Olay üretir. İzin yoksa veya girdi geçersizse boş sözlük döner. Sözlük: event_id, event_name, properties.
## options: user_id, anonymous_id, session_id, occurred_at (unix saniye), context.
func track(event_name: String, properties: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	var tracked: Dictionary = core.track(event_name, properties, options)
	if not tracked.is_empty() and core.unsent_is_full() and not core.backoff_active():
		flush()
	return tracked


## Varsayılan user_id; boş metin kaldırır. E-posta veya telefon vermeyin.
func identify(user_id: String) -> void:
	core.identify(user_id)


## İzni günceller: {"analytics": true, "advertising": false}. Verilmeyen alan false sayılır.
## Analitik izniyle rastgele bir anonymous_id üretilip user:// altında tutulur (cihaz kimliği değildir); izin geri çekilince silinir.
func set_consent(consent: Dictionary) -> void:
	core.set_consent(consent)
	if core.get_consent()["analytics"]:
		core.set_anonymous_id(_load_or_create_anonymous_id())
	else:
		core.set_anonymous_id("")
		_delete_anonymous_id()


## Çıkış: kimlikler ve kuyruk silinir, saklı anonymous_id de silinir; analitik izni sürüyorsa yenisi üretilir.
## Ortak cihazda iki hesap aynı kimlikle bağlanmaz.
func reset() -> void:
	core.reset()
	_delete_anonymous_id()
	if core.get_consent()["analytics"]:
		core.set_anonymous_id(_load_or_create_anonymous_id())


## BindInstall sonucu: {"status": String, "install_id": String}. Status: received, skipped_no_consent, not_configured, unsupported,
## token_unavailable, rejected, temporary_failure. install_id rastgele kurulum kimliğidir (cihaz kimliği değildir); reklam izni yoksa boş.
signal install_bound(result: Dictionary)


## Satın alma ya da abonelik beyanı (feralin_purchase). Sözlük: transaction_id, amount_minor (küçük birim, tam sayı), currency (ISO 4217),
## product_id?, quantity?, purchase_type? (purchase|subscription_start|subscription_renew|subscription_cancel), receipt? {provider, token}, properties?.
## İstemci beyanıdır: verified gönderilmez; sunucu yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar. Sözleşme dışında boş sözlük döner.
func track_revenue(input: Dictionary) -> Dictionary:
	return _after(core.track_revenue(input))


## Reklam geliri (fr_ad_revenue): network, ad_format, revenue_micros (para biriminin milyonda biri, tam sayı), currency, ad_unit?, precision?,
## placement?, impression_id?, properties?. Satın alma gelirinden ayrıdır.
func track_ad_revenue(input: Dictionary) -> Dictionary:
	return _after(core.track_ad_revenue(input))


## Eski iap_purchase yardımcısı: feralin_purchase gönderir; transaction_id zorunludur.
func track_iap_purchase(product_id: String, price: float, currency: String, transaction_id: String, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_iap_purchase(product_id, price, currency, transaction_id, properties))


## Kullanıcıyı gruba bağlar (fr_group) ve kullanıcı özelliklerini bildirir (fr_user_properties). Kişisel veri vermeyin.
func group(group_id: String, traits: Dictionary = {}) -> Dictionary:
	return _after(core.group(group_id, traits))


func set_user_properties(properties: Dictionary) -> Dictionary:
	return _after(core.set_user_properties(properties))


## Oyun olayları (packages/schemas/utp/v1/game-events.md). Verilmeyen isteğe bağlı değer için null verin.
func track_level_start(level_id: String, attempt: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("level_start", FeralinRules.level_properties(level_id, attempt, null, null, null, properties)))


func track_level_complete(level_id: String, attempt: Variant = null, score: Variant = null, duration_ms: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("level_complete", FeralinRules.level_properties(level_id, attempt, score, duration_ms, null, properties)))


func track_level_fail(level_id: String, attempt: Variant = null, score: Variant = null, duration_ms: Variant = null, fail_reason: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("level_fail", FeralinRules.level_properties(level_id, attempt, score, duration_ms, fail_reason, properties)))


## Oyun içi sanal para girişi ve harcaması (gerçek para değildir; gerçek gelir için track_revenue). amount 1..10^12.
func track_economy_source(currency_name: String, amount: int, reason: Variant = null, item_id: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("economy_source", FeralinRules.economy_properties(currency_name, amount, reason, item_id, properties)))


func track_economy_sink(currency_name: String, amount: int, reason: Variant = null, item_id: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("economy_sink", FeralinRules.economy_properties(currency_name, amount, reason, item_id, properties)))


func track_rewarded_ad_shown(placement: String, network: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("rewarded_ad_shown", FeralinRules.rewarded_shown_properties(placement, network, properties)))


func track_rewarded_ad_complete(placement: String, network: Variant = null, reward_amount: Variant = null, reward_currency: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("rewarded_ad_complete", FeralinRules.rewarded_complete_properties(placement, network, reward_amount, reward_currency, properties)))


func track_iap_offer_shown(product_id: String, placement: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("iap_offer_shown", FeralinRules.iap_offer_properties(product_id, placement, properties)))


func track_iap_initiated(product_id: String, placement: Variant = null, transaction_id: Variant = null, properties: Dictionary = {}) -> Dictionary:
	return _after(core.track_game("iap_initiated", FeralinRules.iap_initiated_properties(product_id, placement, transaction_id, properties)))


## Hata olayı (fr_error). İleti ve yığın kişisel veriden arındırılır; örnekleme ve dakikalık hız sınırı uygulanır. GDScript hatalarını
## yakalayan kanca yalnız Godot 4.5+ içindir (Logger); native çökme yakalanmaz.
func capture_error(error_type: String, message: String, stack_trace: String = "", handled: bool = true) -> Dictionary:
	var tracked: Dictionary = core.capture_error(error_type, message, stack_trace, handled, "manual" if handled else "unhandled_exception")
	return _after(tracked)


## Uygulama bağlantısı (App Link, Universal Link): deep_link_opened. Yalnız http(s); ham URL saklanmaz, yalnız fr_click ve utm_* okunur.
func handle_deep_link(url: String) -> void:
	core.handle_deep_link(url)


## Play Install Referrer'dan gelen ertelenmiş uygulama içi yolu bir kez verir; yoksa boş metin.
func consume_deferred_deep_link() -> String:
	return core.consume_deferred_deep_link()


## iOS: AdServices token'ını kurulum kimliğiyle sunucuya iletir; sonuç install_bound sinyaliyle gelir. Kesin tekil atıf değildir.
func bind_install() -> void:
	var post := func(url: String, headers: PackedStringArray, body: String, done: Callable) -> void:
		var request := HTTPRequest.new()
		request.timeout = timeout_sec
		request.max_redirects = 0
		add_child(request)
		request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
			request.queue_free()
			done.call(code if result == HTTPRequest.RESULT_SUCCESS else 0))
		if request.request(url, headers, HTTPClient.METHOD_POST, body) != OK:
			request.queue_free()
			done.call(0)
	core.bind_install(_token_reader(), post, func(result: Dictionary) -> void: install_bound.emit(result))


func current_session_id() -> String:
	return core.current_session_id()


func _after(tracked: Dictionary) -> Dictionary:
	if not tracked.is_empty() and core.unsent_is_full() and not core.backoff_active():
		flush()
	return tracked


# ---------------------------------------------------------------- platform köprüleri (Godot yerel eklentileri; yoksa devre dışı)
# Android: "FeralinAndroid" tekil nesnesi (native/android). iOS: "FeralinIOS" (native/ios). İkisi de bu depoda derlenmedi.

func _android() -> Object:
	return Engine.get_singleton("FeralinAndroid") if OS.get_name() == "Android" and Engine.has_singleton("FeralinAndroid") else null


func _ios() -> Object:
	return Engine.get_singleton("FeralinIOS") if OS.get_name() == "iOS" and Engine.has_singleton("FeralinIOS") else null


func _key_protector() -> Dictionary:
	var android := _android()
	if android != null:
		return {"name": "android_keystore", "protect": func(data: PackedByteArray) -> PackedByteArray: return android.wrap(data), "unprotect": func(data: PackedByteArray) -> PackedByteArray: return android.unwrap(data)}
	var ios := _ios()
	if ios != null:
		# Keychain anahtarın kendisini tutar; dosya yalnız bir işaretçidir.
		return {"name": "ios_keychain", "protect": func(data: PackedByteArray) -> PackedByteArray: return PackedByteArray([1]) if int(ios.keychain_save("queue_key", data)) == 0 else PackedByteArray(), "unprotect": func(_data: PackedByteArray) -> PackedByteArray: return ios.keychain_load("queue_key")}
	return {}


func _tracking_status_reader() -> Callable:
	var ios := _ios()
	if ios == null:
		return Callable()
	return func() -> int: return int(ios.att_status())


func _token_reader() -> Callable:
	var ios := _ios()
	if ios == null:
		return Callable()
	return func(done: Callable) -> void:
		var token := str(ios.adservices_token())
		if token == "":
			done.call({"status": "unsupported", "token": ""})
		elif token == "!error":
			done.call({"status": "failed", "token": ""})
		else:
			done.call({"status": "token", "token": token})


## Android: Play Install Referrer yerel eklenti sinyaliyle gelir; ilk açılış ve ertelenmiş yol çekirdekte işlenir.
func _start_platform_attribution() -> void:
	var android := _android()
	if android == null:
		return
	core.start_attribution(func(done: Callable) -> void:
		android.install_referrer.connect(func(has: bool, raw: String) -> void: done.call(has, raw), CONNECT_ONE_SHOT)
		android.readInstallReferrer())


## Godot 4.5+ Logger sınıfı varsa GDScript ve motor hatalarını fr_error olarak gönderir (feralin_logger.gd ayrı yüklenir; eski sürümde ayrıştırma hatası vermez).
func enable_log_error_capture() -> bool:
	if not ClassDB.class_exists("Logger"):
		push_warning("[Feralin] Logger sınıfı bu Godot sürümünde yok (4.5+ gerekir): günlük hatası yakalama kapalı")
		return false
	var script: Script = load("res://addons/feralin/feralin_logger.gd")
	if script == null:
		return false
	_logger = script.new(self)
	OS.add_logger(_logger)
	return true


func _on_log_error(source: String, message: String, fatal: bool) -> void:
	_after(core.capture_error(source, message, "", not fatal, "log_fatal" if fatal else "log_error"))


var _logger: Object = null


## Kuyruğu gönderir; sonucu flushed sinyali verir. Boş kuyrukta da sinyal gelir: var r = await Feralin.flushed
## Üstel geri çekilmeyi beklemez (açık çağrı niyet sayılır), ama sunucunun Retry-After süresi dolmadan istek yapmaz.
func flush() -> void:
	if _busy:
		_flush_again = true
		return
	_busy = true
	_result = {"sent": 0, "accepted": 0, "rejected": 0, "status": 0, "retained": 0, "batch_id": ""}
	_rounds = core.queue_limit / core.batch_size + 2
	if core.server_wait_active():
		_finish.call_deferred()
		return
	_send_next()


func _on_timer() -> void:
	if flush_interval_sec > 0.0 and core.queued() > 0 and not _busy and not core.backoff_active():
		flush()


func _send_next() -> void:
	_rounds -= 1
	var request: Dictionary = core.next_request() if _rounds >= 0 else {}
	if request.is_empty():
		_finish.call_deferred()
		return
	var error := _http.request_raw(request["url"], request["headers"], HTTPClient.METHOD_POST, request["body"])
	if error != OK:
		# İstek hiç başlamadı; ağ hatası gibi işlenir, batch aynı anahtarla sonra denenir.
		_absorb(core.on_response(0, PackedStringArray(), ""))
		_finish.call_deferred()


func _on_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	var status := response_code if result == HTTPRequest.RESULT_SUCCESS else 0
	var outcome: Dictionary = core.on_response(status, headers, body.get_string_from_utf8())
	_absorb(outcome)
	if outcome["more"]:
		_send_next()
	else:
		_finish.call_deferred()


func _absorb(outcome: Dictionary) -> void:
	_result["sent"] += outcome["sent"]
	_result["accepted"] += outcome["accepted"]
	_result["rejected"] += outcome["rejected"]
	_result["status"] = outcome["status"]
	if not String(outcome["batch_id"]).is_empty():
		_result["batch_id"] = outcome["batch_id"]


func _finish() -> void:
	_busy = false
	_result["retained"] = core.queued()
	flushed.emit(_result)
	if _flush_again:
		_flush_again = false
		flush()


# Mobilde arka plana geçişte, masaüstünde kapanış isteğinde gönderim denenir; kuyruk bellektedir ve süreç her an durabilir.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_CLOSE_REQUEST:
			# 30 dakikalık otomatik oturum: arka plana geçiş anı kaydedilir, dönüşte süre dolmuşsa yeni session_id üretilir.
			if what != NOTIFICATION_WM_CLOSE_REQUEST:
				core.notify_background()
			if _http != null and core.queued() > 0:
				flush()
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			core.notify_foreground()


func _delete_anonymous_id() -> void:
	if FileAccess.file_exists(ANONYMOUS_ID_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ANONYMOUS_ID_PATH))


func _load_or_create_anonymous_id() -> String:
	var config := ConfigFile.new()
	if config.load(ANONYMOUS_ID_PATH) == OK:
		var stored := str(config.get_value("feralin", "anonymous_id", ""))
		if not stored.is_empty():
			return stored
	var fresh: String = core.new_ulid()
	config.set_value("feralin", "anonymous_id", fresh)
	var error := config.save(ANONYMOUS_ID_PATH)
	if error != OK:
		push_warning("[Feralin] anonim kimlik kaydedilemedi: %d" % error)
	return fresh

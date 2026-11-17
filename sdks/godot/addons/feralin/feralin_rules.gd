extends RefCounted

## Olay sözleşmeleri: feralin_purchase, fr_ad_revenue, oyun olayları, fr_error temizliği, atıf ayrıştırma. Düğüm ve ağ bilmez.
## Kaynak Unity SDK 0.2.0'dır (sdks/unity/Runtime/Core): aynı kurallar, aynı sonuç. Geçersiz girdide null döner (olay üretilmez).
## Düzenli ifadelerde " ve ' karakterleri \x22 ve \x27 ile yazılır (ham metin sınırlayıcısı). Bu dosya hiç çalıştırılmadı (Godot yok);
## desenler ve sıra Python re ile Unity çıktılarına karşı doğrulandı (tests/README).

const FeralinCrypto := preload("res://addons/feralin/feralin_crypto.gd")

const MAX_SAFE := 9007199254740991
const MAX_IDENTIFIER := 128
const MAX_QUANTITY := 100000
const MAX_TOKEN_LENGTH := 8192
const MAX_DURATION_MS := 86400000
const MAX_ECONOMY_AMOUNT := 1000000000000
const RESERVED_KEYS := ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"]
const SERVER_ONLY := ["verified", "tenant_id", "project_id"]
const PURCHASE_TYPES := ["purchase", "subscription_start", "subscription_renew", "subscription_cancel"]
const RECEIPT_PROVIDERS := ["apple", "google", "stripe"]
const AD_FORMATS := ["banner", "interstitial", "rewarded", "rewarded_interstitial", "native", "app_open", "other"]
const AD_PRECISIONS := ["estimated", "publisher_provided", "precise", "unknown"]

# ErrorSanitizer.Scrub adımları (sıra önemlidir).
const P_URL_QUERY := r"(?i)(https?://[^\s?#\x22\x27<>]+)[?#][^\s\x22\x27<>]*"
const P_JWT := r"eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]*"
const P_SECRET := r"(?i)\b(password|passwd|pwd|secret|token|api[_\-]?key|authorization)\b\s*[=:]\s*[^\s,;\x22\x27]+"
const P_BEARER := r"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+"
const P_EMAIL := r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"
const P_WIN_USER := r"(?i)([A-Za-z]:\\Users\\)[^\\\s]+"
const P_UNIX_USER := r"(/(?:Users|home)/)[^/\s]+"
const P_IPV4 := r"\b(?:\d{1,3}\.){3}\d{1,3}\b"
const P_IPV6 := r"\b(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b"
const P_LONG_HEX := r"\b[0-9a-fA-F]{32,}\b"
const P_LONG_TOKEN := r"\b[A-Za-z0-9_\-]{40,}\b"
const P_PHONE := r"\+?\d[\d\s().\-]{8,}\d"
# Çerçeve normalleştirme.
const P_FRAME_LOCATION := r"\s*\(at [^)]*\)|\s+in\s+<[^>]*>:\d+|\s+in\s+\S+:\d+|\s*\[0x[0-9a-fA-F]+\]|\s+\[at [^\]]*\]"
const P_FRAME_PREFIX := r"^\s*(?:at\s+)?"
const P_FRAME_ARGS := r"\([^()]*\)"
const P_HEX := r"0x[0-9a-fA-F]+"
const P_DIGITS := r"\d+"

static var _cache := {}


static func _re(pattern: String) -> RegEx:
	if not _cache.has(pattern):
		_cache[pattern] = RegEx.create_from_string(pattern)
	return _cache[pattern]


static func _sub(text: String, pattern: String, replacement: String) -> String:
	return _re(pattern).sub(text, replacement, true)


# ---------------------------------------------------------------- ortak

static func to_int(value: Variant) -> Variant:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT and is_finite(value) and floor(value) == value and absf(value) <= float(MAX_SAFE):
		return int(value)
	return null


static func text_in(value: Variant, max_length: int) -> bool:
	return (typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME) and not String(value).is_empty() and String(value).length() <= max_length


## Şemaya uymayan, sunucuya ait ya da 100'ü aşan anahtar düşer: tek geçersiz alan toplayıcıda tüm batch'i düşürürdü.
static func sanitize_properties(properties: Variant) -> Dictionary:
	var result := {}
	if not properties is Dictionary:
		return result
	var key_re := _re(r"^[a-zA-Z][a-zA-Z0-9_]{0,63}$")
	for key in properties:
		if not (key is String or key is StringName):
			continue
		var name := String(key)
		if key_re.search(name) == null or SERVER_ONLY.has(name.to_lower()) or result.size() >= 100:
			continue
		result[name] = properties[key]
	return result


static func valid_currency(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and _re(r"^[A-Z]{3}$").search(value) != null


# ---------------------------------------------------------------- gelir

## input: transaction_id, amount_minor, currency, product_id?, quantity?, purchase_type?, receipt? {provider, token}, properties?.
## İstemci beyanıdır: verified hiçbir zaman gönderilmez; sunucu yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar.
static func revenue_properties(input: Dictionary) -> Variant:
	var transaction_id: Variant = input.get("transaction_id")
	if not text_in(transaction_id, MAX_IDENTIFIER):
		return null
	var amount: Variant = to_int(input.get("amount_minor"))
	if amount == null or amount < 0 or amount > MAX_SAFE:
		return null
	var currency: Variant = input.get("currency")
	if not valid_currency(currency):
		return null
	var product_id: Variant = input.get("product_id")
	if product_id != null and not text_in(product_id, MAX_IDENTIFIER):
		return null
	var quantity: Variant = to_int(input.get("quantity", 1))
	if quantity == null or quantity < 0 or quantity > MAX_QUANTITY:
		return null
	var purchase_type: Variant = input.get("purchase_type", "purchase")
	if not PURCHASE_TYPES.has(purchase_type):
		return null
	# Abonelik iptali para taşımaz; defter tutarsız iptali reddeder.
	if purchase_type == "subscription_cancel" and amount != 0:
		return null
	var receipt: Variant = input.get("receipt")
	if receipt != null:
		if not receipt is Dictionary or not RECEIPT_PROVIDERS.has(receipt.get("provider")):
			return null
		var token: Variant = receipt.get("token")
		if typeof(token) != TYPE_STRING or token.is_empty() or token.length() > MAX_TOKEN_LENGTH:
			return null
	var props := sanitize_properties(input.get("properties"))
	for key in RESERVED_KEYS:
		props.erase(key)
	props["transaction_id"] = transaction_id
	props["amount_minor"] = amount
	props["currency"] = currency
	props["quantity"] = quantity
	props["purchase_type"] = purchase_type
	if product_id != null:
		props["product_id"] = product_id
	if receipt != null:
		props["receipt"] = {"provider": receipt["provider"], "token": receipt["token"]}
	return props


## ISO 4217 küçük birim üssü: ondalık tutarı tam sayı küçük birime çevirir (yarım değer yukarı); aralık dışıysa null.
static func to_minor(amount: float, currency: String) -> Variant:
	if not (amount >= 0.0):
		return null
	var exponent := 2
	if ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"].has(currency):
		exponent = 0
	elif ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"].has(currency):
		exponent = 3
	var minor := floorf(amount * pow(10.0, exponent) + 0.5)
	if minor > float(MAX_SAFE):
		return null
	return int(minor)


## input: network, ad_format, revenue_micros, currency, ad_unit?, precision?, placement?, impression_id?, properties?.
static func ad_revenue_properties(input: Dictionary) -> Variant:
	var network: Variant = input.get("network")
	if typeof(network) != TYPE_STRING or _re(r"^[a-z][a-z0-9_]{0,63}$").search(network) == null:
		return null
	var format: Variant = input.get("ad_format", "other")
	var precision: Variant = input.get("precision", "unknown")
	if not AD_FORMATS.has(format) or not AD_PRECISIONS.has(precision):
		return null
	var micros: Variant = to_int(input.get("revenue_micros"))
	if micros == null or micros < 0 or micros > MAX_SAFE:
		return null
	if not valid_currency(input.get("currency")):
		return null
	for pair in [["ad_unit", 128], ["placement", 64], ["impression_id", 128]]:
		var value: Variant = input.get(pair[0])
		if value != null and not text_in(value, pair[1]):
			return null
	var props := sanitize_properties(input.get("properties"))
	for key in RESERVED_KEYS:
		props.erase(key)
	props["network"] = network
	props["ad_format"] = format
	props["revenue_micros"] = micros
	props["currency"] = input["currency"]
	props["precision"] = precision
	for key in ["ad_unit", "placement", "impression_id"]:
		if input.get(key) != null:
			props[key] = input[key]
	return props


# ---------------------------------------------------------------- oyun olayları

static func _put_text(props: Dictionary, key: String, value: Variant, max_length: int) -> bool:
	if value == null:
		return true
	if not text_in(value, max_length):
		return false
	props[key] = value
	return true


static func _put_number(props: Dictionary, key: String, value: Variant, min_value: int, max_value: int) -> bool:
	if value == null:
		return true
	var number: Variant = to_int(value)
	if number == null or number < min_value or number > max_value:
		return false
	props[key] = number
	return true


## level_start, level_complete, level_fail (game-events.md). Ek alanlar: attempt, score, duration_ms, fail_reason.
static func level_properties(level_id: Variant, attempt: Variant = null, score: Variant = null, duration_ms: Variant = null, fail_reason: Variant = null, extra: Variant = null) -> Variant:
	var props := sanitize_properties(extra)
	if not text_in(level_id, 64):
		return null
	props["level_id"] = level_id
	if not (_put_number(props, "attempt", attempt, 1, MAX_SAFE) and _put_number(props, "score", score, 0, MAX_SAFE)
			and _put_number(props, "duration_ms", duration_ms, 0, MAX_DURATION_MS) and _put_text(props, "fail_reason", fail_reason, 64)):
		return null
	return props


## economy_source ve economy_sink: oyun içi sanal para (gerçek para değildir). amount 1..10^12.
static func economy_properties(currency_name: Variant, amount: Variant, reason: Variant = null, item_id: Variant = null, extra: Variant = null) -> Variant:
	var props := sanitize_properties(extra)
	var number: Variant = to_int(amount)
	if not text_in(currency_name, 64) or number == null or number < 1 or number > MAX_ECONOMY_AMOUNT:
		return null
	props["currency_name"] = currency_name
	props["amount"] = number
	if not (_put_text(props, "reason", reason, 64) and _put_text(props, "item_id", item_id, 64)):
		return null
	return props


static func rewarded_shown_properties(placement: Variant, network: Variant = null, extra: Variant = null) -> Variant:
	var props := sanitize_properties(extra)
	if not text_in(placement, 64):
		return null
	props["placement"] = placement
	return props if _put_text(props, "network", network, 64) else null


static func rewarded_complete_properties(placement: Variant, network: Variant = null, reward_amount: Variant = null, reward_currency: Variant = null, extra: Variant = null) -> Variant:
	var props := sanitize_properties(extra)
	if not text_in(placement, 64):
		return null
	props["placement"] = placement
	if not (_put_text(props, "network", network, 64) and _put_number(props, "reward_amount", reward_amount, 0, MAX_SAFE) and _put_text(props, "reward_currency", reward_currency, 64)):
		return null
	return props


static func iap_offer_properties(product_id: Variant, placement: Variant = null, extra: Variant = null) -> Variant:
	var props := sanitize_properties(extra)
	if not text_in(product_id, 128):
		return null
	props["product_id"] = product_id
	return props if _put_text(props, "placement", placement, 64) else null


static func iap_initiated_properties(product_id: Variant, placement: Variant = null, transaction_id: Variant = null, extra: Variant = null) -> Variant:
	var props := sanitize_properties(extra)
	if not text_in(product_id, 128):
		return null
	props["product_id"] = product_id
	if not (_put_text(props, "placement", placement, 64) and _put_text(props, "transaction_id", transaction_id, 128)):
		return null
	return props


# ---------------------------------------------------------------- hata: kişisel veri ayıklama

## Kişisel veri ve gizli değer ayıklanmış, sınırlandırılmış metin (ErrorSanitizer.Scrub).
static func scrub(text: String, max_length: int) -> String:
	if text.is_empty():
		return ""
	var s := text.substr(0, max_length * 4) if text.length() > max_length * 4 else text
	s = _sub(s, P_URL_QUERY, "$1?[redacted]")
	s = _sub(s, P_JWT, "[token]")
	s = _sub(s, P_SECRET, "$1=[redacted]")
	s = _sub(s, P_BEARER, "Bearer [token]")
	s = _sub(s, P_EMAIL, "[email]")
	s = _sub(s, P_WIN_USER, "$1[user]")
	s = _sub(s, P_UNIX_USER, "$1[user]")
	s = _sub(s, P_IPV4, "[ip]")
	s = _sub(s, P_IPV6, "[ip]")
	s = _sub(s, P_LONG_HEX, "[token]")
	s = _sub(s, P_LONG_TOKEN, "[token]")
	s = _sub(s, P_PHONE, "[number]")
	s = s.replace("\r", " ").replace("\n", " ").strip_edges()
	return s.substr(0, max_length) if s.length() > max_length else s


## Yığın izini normalleştirilmiş çerçeve listesine çevirir (dosya yolu, satır, adres ve bağımsız değişken yok).
static func normalize_frames(stack_trace: String, max_frames: int) -> PackedStringArray:
	var frames := PackedStringArray()
	if stack_trace.is_empty():
		return frames
	for raw in stack_trace.split("\n"):
		var line := _trim_chars(String(raw))
		if line.is_empty():
			continue
		line = _sub(line, P_FRAME_LOCATION, "")
		line = _re(P_FRAME_PREFIX).sub(line, "", false)
		for _i in range(3):
			var next := _sub(line, P_FRAME_ARGS, "")
			if next == line:
				break
			line = next
		line = _sub(line, P_HEX, "0x")
		line = _sub(line, P_DIGITS, "#")
		line = scrub(line, 200)
		if line.is_empty():
			continue
		frames.append(line)
		if frames.size() >= max_frames:
			break
	return frames


## C#'taki Trim('\r', ' ', '\t'): yalnız bu üç karakter baştan ve sondan kırpılır.
static func _trim_chars(text: String) -> String:
	var begin := 0
	var end := text.length()
	while begin < end and (text[begin] == "\r" or text[begin] == " " or text[begin] == "\t"):
		begin += 1
	while end > begin and (text[end - 1] == "\r" or text[end - 1] == " " or text[end - 1] == "\t"):
		end -= 1
	return text.substr(begin, end - begin)


## Hata türü ve ilk altı normalleştirilmiş çerçevenin SHA-256 özetinin ilk 16 onaltılık karakteri.
static func fingerprint(error_type: String, frames: PackedStringArray) -> String:
	var joined := error_type
	for i in range(mini(frames.size(), 6)):
		joined += "\n" + frames[i]
	return FeralinCrypto.sha256_hex(joined).substr(0, 16)


# ---------------------------------------------------------------- atıf

## Katı çözümleme: '+' boşluktur, bozuk %XX ya da geçersiz UTF-8 null döndürür (parça yok sayılır).
static func percent_decode(text: String) -> Variant:
	var source := text.to_utf8_buffer()
	var bytes := PackedByteArray()
	var i := 0
	while i < source.size():
		var c := source[i]
		if c == 0x2B:
			bytes.append(0x20)
		elif c == 0x25:
			if i + 2 >= source.size():
				return null
			var hi := _hex_value(source[i + 1])
			var lo := _hex_value(source[i + 2])
			if hi < 0 or lo < 0:
				return null
			bytes.append((hi << 4) | lo)
			i += 2
		else:
			bytes.append(c)
		i += 1
	var decoded := bytes.get_string_from_utf8()
	# Geçersiz UTF-8 yok sayılır: yeniden kodlanan bayt dizisi özgün diziyle aynı olmalı.
	return decoded if decoded.to_utf8_buffer() == bytes else null


static func _hex_value(c: int) -> int:
	if c >= 0x30 and c <= 0x39:
		return c - 0x30
	if c >= 0x61 and c <= 0x66:
		return c - 0x61 + 10
	if c >= 0x41 and c <= 0x46:
		return c - 0x41 + 10
	return -1


## Link-router ve saas-api ile aynı kural: şema ve host taşıyamaz, yalnız uygulama içi yol.
static func valid_deep_link_path(path: String) -> bool:
	if path.length() > 200 or not path.begins_with("/") or path.begins_with("//"):
		return false
	if _re(r"^/[A-Za-z0-9._~!$'()*+,;=:@%/?&-]*$").search(path) == null:
		return false
	# Kodlanmış nokta, bölü, ters bölü, kontrol karakteri ya da bozuk kaçış: %2e%2e birleştirmede üst dizine çıkar.
	if _re(r"(?i)%(?:2e|2f|5c|0[0-9a-f]|1[0-9a-f]|7f|[^0-9a-f]|[0-9a-f](?:[^0-9a-f]|$)|$)").search(path) != null:
		return false
	var question := path.find("?")
	var only := path.substr(0, question) if question >= 0 else path
	return not Array(only.split("/")).has("..")


## a=b&c=d dizgisini izin listesiyle ayrıştırır: yalnız fr_click, fr_dl ve standart utm_*. Dönüş: {fr_click, utm (Dictionary), deep_link_path}.
static func parse_attribution_query(raw: String) -> Dictionary:
	var result := {"fr_click": "", "utm": {}, "deep_link_path": ""}
	if raw.strip_edges().is_empty():
		return result
	var text := raw
	# Bazı kampanya araçları referrer'ın tamamını bir kez daha kodlar.
	if not text.contains("=") and text.to_upper().contains("%3D"):
		var once: Variant = percent_decode(text)
		if once != null:
			text = once
	var utm_keys := ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]
	var fr_click := ""
	var deep_link := ""
	for pair in text.split("&"):
		var eq := String(pair).find("=")
		if eq <= 0:
			continue
		var key: Variant = percent_decode(String(pair).substr(0, eq))
		if key == null or (key != "fr_click" and key != "fr_dl" and not utm_keys.has(key)):
			continue
		var decoded: Variant = percent_decode(String(pair).substr(eq + 1))
		var value: String = String(decoded).strip_edges() if decoded != null else ""
		if value.is_empty():
			continue
		if key == "fr_click":
			if fr_click.is_empty() and _re(r"^[A-Za-z0-9._~-]{1,256}$").search(value) != null:
				fr_click = value
		elif key == "fr_dl":
			if deep_link.is_empty() and valid_deep_link_path(value):
				deep_link = value
		elif not result["utm"].has(key):
			result["utm"][key] = value.substr(0, 256)
	result["fr_click"] = fr_click
	# Yol tıklama kimliğiyle birlikte gelir; kimliksiz değer Feralin linkinden gelmemiştir.
	result["deep_link_path"] = deep_link if not fr_click.is_empty() else ""
	return result


static func attribution_is_empty(params: Dictionary) -> bool:
	return String(params.get("fr_click", "")).is_empty() and params.get("utm", {}).is_empty()


## Play'in tıklama yokken döndürdüğü varsayılan (organic / (not set)) kanıt sayılmaz.
static func attribution_is_play_organic(params: Dictionary) -> bool:
	if not String(params.get("fr_click", "")).is_empty():
		return false
	var utm: Dictionary = params.get("utm", {})
	return String(utm.get("utm_medium", "")).to_lower() == "organic" or utm.get("utm_source", "") == "(not set)"


static func attribution_write(params: Dictionary, target: Dictionary) -> void:
	if not String(params.get("fr_click", "")).is_empty():
		target["fr_click"] = params["fr_click"]
	for key in params.get("utm", {}):
		target[key] = params["utm"][key]


## Yalnız http(s) kabul edilir; özel şemalar kanıt sayılmaz. Dönüş: {clean_url, params} ya da boş sözlük.
static func parse_deep_link(raw: String) -> Dictionary:
	var url := raw.strip_edges()
	var scheme_end := url.find("://")
	if scheme_end <= 0:
		return {}
	var scheme := url.substr(0, scheme_end).to_lower()
	if scheme != "http" and scheme != "https":
		return {}
	var authority_start := scheme_end + 3
	var authority_end := url.length()
	for marker in ["/", "?", "#"]:
		var at := url.find(marker, authority_start)
		if at >= 0:
			authority_end = mini(authority_end, at)
	var authority := url.substr(authority_start, authority_end - authority_start)
	var at_sign := authority.rfind("@")
	if at_sign >= 0:
		authority = authority.substr(at_sign + 1)
	var host := authority
	var port := ""
	var colon := authority.rfind(":")
	if colon >= 0 and not authority.contains("]"):
		host = authority.substr(0, colon)
		port = authority.substr(colon + 1)
		if not port.is_empty() and not port.is_valid_int():
			return {}
	if host.is_empty():
		return {}
	host = host.to_lower()
	if (scheme == "https" and port == "443") or (scheme == "http" and port == "80"):
		port = ""
	var rest := url.substr(authority_end)
	var hash := rest.find("#")
	if hash >= 0:
		rest = rest.substr(0, hash)
	var question := rest.find("?")
	var path := rest.substr(0, question) if question >= 0 else rest
	var query := rest.substr(question + 1) if question >= 0 else ""
	var clean := scheme + "://" + host + (":" + port if not port.is_empty() else "") + (path if not path.is_empty() else "/")
	if clean.length() > 2048:
		return {}
	return {"clean_url": clean, "params": parse_attribution_query(query)}

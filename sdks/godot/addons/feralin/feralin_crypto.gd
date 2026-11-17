extends RefCounted

## Kalıcı kuyruk şifrelemesi: AES-256-GCM, Android EncryptedEventStore ve Unity ile aynı satır biçimi.
## Satır: "enc1:" + hex(iv(12) || şifreli metin || etiket(16)); ilişkilendirilmiş veri (AAD) olay kimliğidir.
## Godot'nun AESContext sınıfı yalnız ECB ve CBC verir; GCM, ECB üstünde elle kurulur (CTR anahtar akışı ve GHASH).
## GHASH 4 adet 32 bitlik parçayla yapılır: GDScript tamsayısı işaretli 64 bittir, 32 bitlik işaretsiz değerler taşma olmadan sığar.
## Bu dosya hiç çalıştırılmadı (Godot yok); aynı algoritmanın Python eşi NIST ve Unity vektörleriyle karşılaştırıldı (tests/README).

const PREFIX := "enc1:"
const IV_BYTES := 12
const TAG_BYTES := 16
const MASK_32 := 0xFFFFFFFF
const REDUCTION := 0xE1000000


## SHA-256 özeti, 64 karakterlik küçük harf onaltılık metin.
static func sha256_hex(text: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	# HashingContext.update boş tamponu reddeder; boş metnin özeti yalnız start + finish ile alınır.
	if not text.is_empty():
		context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()


static func _ecb(key: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	var aes := AESContext.new()
	aes.start(AESContext.MODE_ECB_ENCRYPT, key)
	var out := aes.update(data)
	aes.finish()
	return out


static func _limbs(bytes: PackedByteArray, offset: int) -> Array:
	return [
		(bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3],
		(bytes[offset + 4] << 24) | (bytes[offset + 5] << 16) | (bytes[offset + 6] << 8) | bytes[offset + 7],
		(bytes[offset + 8] << 24) | (bytes[offset + 9] << 16) | (bytes[offset + 10] << 8) | bytes[offset + 11],
		(bytes[offset + 12] << 24) | (bytes[offset + 13] << 16) | (bytes[offset + 14] << 8) | bytes[offset + 15],
	]


## GF(2^128) çarpımı (NIST SP 800-38D, algoritma 1).
static func _gf_mul(x: Array, h: Array) -> Array:
	var z0 := 0
	var z1 := 0
	var z2 := 0
	var z3 := 0
	var v0: int = h[0]
	var v1: int = h[1]
	var v2: int = h[2]
	var v3: int = h[3]
	for i in range(128):
		var bit: int = (int(x[i >> 5]) >> (31 - (i & 31))) & 1
		if bit == 1:
			z0 ^= v0
			z1 ^= v1
			z2 ^= v2
			z3 ^= v3
		var lsb := v3 & 1
		v3 = ((v3 >> 1) | ((v2 & 1) << 31)) & MASK_32
		v2 = ((v2 >> 1) | ((v1 & 1) << 31)) & MASK_32
		v1 = ((v1 >> 1) | ((v0 & 1) << 31)) & MASK_32
		v0 = v0 >> 1
		if lsb == 1:
			v0 ^= REDUCTION
	return [z0, z1, z2, z3]


static func _ghash_update(state: Array, h: Array, data: PackedByteArray) -> Array:
	var offset := 0
	while offset < data.size():
		var block := PackedByteArray()
		block.resize(16)
		var count := mini(16, data.size() - offset)
		for k in range(count):
			block[k] = data[offset + k]
		var b := _limbs(block, 0)
		state = _gf_mul([state[0] ^ b[0], state[1] ^ b[1], state[2] ^ b[2], state[3] ^ b[3]], h)
		offset += 16
	return state


## Etiket (16 bayt): GHASH(AAD, şifreli metin, uzunluklar) XOR E(K, IV || 1).
static func _tag(key: PackedByteArray, iv: PackedByteArray, aad: PackedByteArray, cipher_text: PackedByteArray) -> PackedByteArray:
	var zero := PackedByteArray()
	zero.resize(16)
	var h := _limbs(_ecb(key, zero), 0)
	var state: Array = [0, 0, 0, 0]
	state = _ghash_update(state, h, aad)
	state = _ghash_update(state, h, cipher_text)
	# Uzunluk bloğu: bit cinsinden AAD ve şifreli metin uzunluğu (her biri 64 bit).
	var aad_bits := aad.size() * 8
	var text_bits := cipher_text.size() * 8
	state = _gf_mul([state[0] ^ ((aad_bits >> 32) & MASK_32), state[1] ^ (aad_bits & MASK_32), state[2] ^ ((text_bits >> 32) & MASK_32), state[3] ^ (text_bits & MASK_32)], h)
	var j0 := PackedByteArray()
	j0.append_array(iv)
	j0.append_array(PackedByteArray([0, 0, 0, 1]))
	var mask := _ecb(key, j0)
	var tag := PackedByteArray()
	tag.resize(16)
	for i in range(4):
		var word: int = state[i]
		for b in range(4):
			tag[i * 4 + b] = ((word >> (24 - 8 * b)) & 0xFF) ^ mask[i * 4 + b]
	return tag


## CTR (sayaç 2'den): ECB ile sayaç blokları şifrelenir, veriyle XOR'lanır.
static func _ctr(key: PackedByteArray, iv: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	if data.is_empty():
		return PackedByteArray()
	var blocks := (data.size() + 15) / 16
	var counters := PackedByteArray()
	counters.resize(blocks * 16)
	for n in range(blocks):
		for k in range(IV_BYTES):
			counters[n * 16 + k] = iv[k]
		var counter := n + 2
		counters[n * 16 + 12] = (counter >> 24) & 0xFF
		counters[n * 16 + 13] = (counter >> 16) & 0xFF
		counters[n * 16 + 14] = (counter >> 8) & 0xFF
		counters[n * 16 + 15] = counter & 0xFF
	var stream := _ecb(key, counters)
	var out := PackedByteArray()
	out.resize(data.size())
	for i in range(data.size()):
		out[i] = data[i] ^ stream[i]
	return out


## Çıktı: şifreli metin || 16 baytlık etiket.
static func seal(key: PackedByteArray, iv: PackedByteArray, plain: PackedByteArray, aad: PackedByteArray) -> PackedByteArray:
	var body := _ctr(key, iv, plain)
	var out := PackedByteArray()
	out.append_array(body)
	out.append_array(_tag(key, iv, aad, body))
	return out


## Etiket tutmazsa boş dizi (açılamadı) döner; boş düz metin de boş döner, bu yüzden çağıran önce uzunluğa bakar.
static func open(key: PackedByteArray, iv: PackedByteArray, sealed: PackedByteArray, aad: PackedByteArray) -> PackedByteArray:
	if sealed.size() <= TAG_BYTES:
		return PackedByteArray()
	var body := sealed.slice(0, sealed.size() - TAG_BYTES)
	var tag := sealed.slice(sealed.size() - TAG_BYTES)
	var expected := _tag(key, iv, aad, body)
	var diff := 0
	for i in range(TAG_BYTES):
		diff |= tag[i] ^ expected[i]
	if diff != 0:
		return PackedByteArray()
	return _ctr(key, iv, body)


## enc1: satırı üretir. iv 12 bayt olmalı (çağıran rastgele verir).
static func encrypt_line(key: PackedByteArray, iv: PackedByteArray, plain: String, aad: String) -> String:
	var sealed := seal(key, iv, plain.to_utf8_buffer(), aad.to_utf8_buffer())
	var all := PackedByteArray()
	all.append_array(iv)
	all.append_array(sealed)
	return PREFIX + all.hex_encode()


## Açılamazsa (bozuk, kurcalanmış, anahtar kayıp, düz metin) false ve boş metin; fırlatmaz.
static func decrypt_line(key: PackedByteArray, stored: String, aad: String) -> Dictionary:
	if not stored.begins_with(PREFIX):
		return {"ok": false, "text": ""}
	var hex := stored.substr(PREFIX.length())
	if hex.length() % 2 != 0 or not hex.is_valid_hex_number(false):
		return {"ok": false, "text": ""}
	var raw := hex.hex_decode()
	if raw.size() <= IV_BYTES + TAG_BYTES:
		return {"ok": false, "text": ""}
	var plain := open(key, raw.slice(0, IV_BYTES), raw.slice(IV_BYTES), aad.to_utf8_buffer())
	if plain.is_empty():
		return {"ok": false, "text": ""}
	return {"ok": true, "text": plain.get_string_from_utf8()}

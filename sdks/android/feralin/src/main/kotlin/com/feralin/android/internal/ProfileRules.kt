package com.feralin.android.internal

/**
 * UTP §8.2 kimlik yöntemlerinin ortak kuralı: `group` → `fr_group`, `setUserProperties` → `fr_user_properties`, `setGlobalProperties`.
 * Kurallar öteki SDK'larla (`packages/sdk-web/src/profile.ts`) ve toplayıcıyla (`services/collect/internal/httpapi/profile_filter.go`)
 * birebir aynıdır; toplayıcı ayrıca projenin izin listesini uygular (liste boşsa hiçbir kullanıcı özelliği saklanmaz).
 */
internal object ProfileRules {
    /** Çağrı başına ve global haritada en çok bu kadar özellik. */
    const val MAX_PROPERTIES = 50

    /** Dizge değerin en çok karakter (kod noktası) sayısı. */
    const val MAX_VALUE_LENGTH = 256
    const val MAX_GROUP_ID_LENGTH = 128

    private val KEY = Regex("^[a-zA-Z][a-zA-Z0-9_]{0,63}$")
    private val EMAIL = Regex("[^\\s@]+@[^\\s@]+\\.[^\\s@]+")

    /** İstemci gelir doğrulaması beyan edemez: sunucu alanları düşer. */
    val RESERVED = setOf("verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt")

    // Kişisel veri anahtar kuralı (toplayıcıdaki piiTokens, piiFragments, piiExact ile aynı listeler).
    private val PII_TOKENS = setOf(
        "email", "mail", "phone", "tel", "telephone", "mobile", "msisdn", "gsm",
        "ip", "ipv4", "ipv6", "ssn", "tckn", "passport", "password", "iban",
        "address", "adres", "eposta", "telefon", "soyad", "surname", "firstname",
        "lastname", "fullname", "birthdate", "birthday", "dob",
    )
    private val PII_FRAGMENTS = listOf("email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname", "surname", "soyad", "eposta", "telefon", "password", "birthdate")
    private val PII_EXACT = setOf("name", "username", "displayname", "isim", "ad")

    /** Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırıcıdır. */
    fun keyTokens(key: String): List<String> {
        val out = StringBuilder()
        var index = 0
        var previous = -1
        while (index < key.length) {
            val cp = key.codePointAt(index)
            if (index > 0 && Character.isUpperCase(cp) && previous >= 0 && (Character.isLowerCase(previous) || Character.isDigit(previous))) out.append('_')
            out.appendCodePoint(Character.toLowerCase(cp))
            previous = cp
            index += Character.charCount(cp)
        }
        return out.split('_').filter { it.isNotEmpty() }
    }

    /** Anahtar kişisel veriye (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) benziyor mu. */
    fun isPiiLikeKey(key: String): Boolean {
        val tokens = keyTokens(key)
        if (tokens.any { it in PII_TOKENS }) return true
        val joined = tokens.joinToString("")
        if (joined in PII_EXACT) return true
        return PII_FRAGMENTS.any { joined.contains(it) }
    }

    private fun hasControl(text: String): Boolean = text.codePoints().anyMatch { Character.getType(it) == Character.CONTROL.toInt() }

    /** Değer dizge (≤256 karakter, e-posta biçimli ve kontrol karakterli değil), sonlu sayı ya da mantıksal olmalı. */
    fun validValue(value: Any?): Boolean = when (value) {
        is Boolean -> true
        is Double -> !value.isNaN() && !value.isInfinite()
        is Float -> !value.isNaN() && !value.isInfinite()
        is Number -> true
        is String -> value.codePointCount(0, value.length) <= MAX_VALUE_LENGTH && !EMAIL.containsMatchIn(value) && !hasControl(value)
        else -> false
    }

    /**
     * Özellikleri kimlik sözleşmesine indirger. [allowNull] yalnız global özellikte açıktır: `null` o anahtarı siler. Düşen anahtar sayısı
     * döner (değer döndürülmez).
     */
    fun sanitize(input: Map<String, Any?>?, allowNull: Boolean = false): Pair<LinkedHashMap<String, Any?>, Int> {
        val out = LinkedHashMap<String, Any?>()
        var dropped = 0
        if (input.isNullOrEmpty()) return out to 0
        var count = 0
        for ((key, value) in input) {
            if (!KEY.matches(key) || key in RESERVED || isPiiLikeKey(key)) {
                dropped++
                continue
            }
            if (value == null && allowNull) {
                out[key] = null
            } else if (validValue(value)) {
                if (count >= MAX_PROPERTIES) {
                    dropped++
                    continue
                }
                out[key] = if (value is Float) value.toDouble() else value
                count++
            } else {
                dropped++
            }
        }
        return out to dropped
    }

    /** Grup kimliği: 1-128 karakter, yalnız boşluk değil, `@` ve kontrol karakteri yok (kişisel veri taşımamalı). */
    fun validGroupId(groupId: String?): Boolean {
        if (groupId == null || groupId.isBlank()) return false
        if (groupId.codePointCount(0, groupId.length) > MAX_GROUP_ID_LENGTH) return false
        return !groupId.contains('@') && !hasControl(groupId)
    }

    /** Global özellikler `fr_` sistem olaylarına eklenmez: toplayıcı bu gövdelerde izin listesi dışı alanı düşürür ya da reddeder. */
    fun acceptsGlobalProperties(eventName: String): Boolean = !eventName.startsWith("fr_")
}

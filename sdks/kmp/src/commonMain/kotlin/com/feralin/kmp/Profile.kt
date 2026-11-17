package com.feralin.kmp

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/** Grup olayı adı; React Native, Unity ve Android ile aynı. */
const val GROUP_EVENT_NAME: String = "fr_group"

/** Kullanıcı özellikleri olayı adı. */
const val USER_PROPERTIES_EVENT_NAME: String = "fr_user_properties"

/** Çağrı başına ve global haritada en çok özellik sayısı. */
const val MAX_PROFILE_PROPERTIES: Int = 50

private const val MAX_PROFILE_VALUE_LENGTH = 256
private const val MAX_GROUP_ID_LENGTH = 128

private val PROFILE_KEY = Regex("^[a-zA-Z][a-zA-Z0-9_]{0,63}$")
private val EMAIL_LIKE = Regex("[^\\s@]+@[^\\s@]+\\.[^\\s@]+")

// İstemci doğrulama beyan edemez: bu anahtarlar düşer, toplayıcı da düşürür.
private val RESERVED_KEYS = setOf("verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt")

// Kişisel veri anahtar kuralı (toplayıcıdaki piiTokens, piiFragments, piiExact ile aynı listeler).
private val PII_TOKENS = setOf(
    "email", "mail", "phone", "tel", "telephone", "mobile", "msisdn", "gsm",
    "ip", "ipv4", "ipv6", "ssn", "tckn", "passport", "password", "iban",
    "address", "adres", "eposta", "telefon", "soyad", "surname", "firstname",
    "lastname", "fullname", "birthdate", "birthday", "dob",
)
private val PII_FRAGMENTS = listOf(
    "email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname", "surname", "soyad", "eposta", "telefon", "password", "birthdate",
)
private val PII_EXACT = setOf("name", "username", "displayname", "isim", "ad")

/**
 * UTP §8.2 kimlik yöntemlerinin istemci kuralları (`group`, `setUserProperties`, `setGlobalProperties`). Bütün SDK'larda ve toplayıcıda
 * (`services/collect/internal/httpapi/profile_filter.go`) birebir aynıdır; toplayıcı ayrıca projenin izin listesini uygular.
 */
object ProfileRules {
    /** Sistem olayı (`fr_` önekli) mı; global özellikler bunlara eklenmez. */
    fun isSystemEvent(eventName: String): Boolean = eventName.startsWith("fr_")

    /** Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırır. */
    fun keyTokens(key: String): List<String> {
        val builder = StringBuilder(key.length + 4)
        key.forEachIndexed { index, char ->
            if (index > 0 && char.isUpperCase() && (key[index - 1].isLowerCase() || key[index - 1].isDigit())) builder.append('_')
            builder.append(char.lowercaseChar())
        }
        return builder.split('_').filter { it.isNotEmpty() }
    }

    /** Anahtar kişisel veriye (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) benziyor mu. */
    fun isPiiLikeKey(key: String): Boolean {
        val tokens = keyTokens(key)
        if (tokens.any { it in PII_TOKENS }) return true
        val joined = tokens.joinToString("")
        if (joined in PII_EXACT) return true
        return PII_FRAGMENTS.any { joined.contains(it) }
    }

    /** Grup kimliği kuralı: 1-128 karakter, yalnız boşluk değil, `@` ve kontrol karakteri yok. */
    fun isValidGroupId(groupId: String?): Boolean =
        !groupId.isNullOrBlank() && codePoints(groupId) <= MAX_GROUP_ID_LENGTH && '@' !in groupId && groupId.none { it.isISOControl() }

    /** Kod noktası sayısı (Web/Node ve toplayıcı gibi): vekil çifti tek karakter sayılır. */
    private fun codePoints(text: String): Int = text.length - text.count { it.isLowSurrogate() }

    private fun validKey(key: String): Boolean = PROFILE_KEY.matches(key) && key !in RESERVED_KEYS && !isPiiLikeKey(key)

    private fun cleanValue(value: Any?): JsonElement? = when (value) {
        is String -> if (codePoints(value) > MAX_PROFILE_VALUE_LENGTH || EMAIL_LIKE.containsMatchIn(value) || value.any { it.isISOControl() }) null else JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Double -> if (value.isNaN() || value.isInfinite()) null else JsonPrimitive(value)
        is Float -> if (value.isNaN() || value.isInfinite()) null else JsonPrimitive(value)
        is Int, is Long, is Short, is Byte -> JsonPrimitive(value as Number)
        else -> null
    }

    /** Temizleme sonucu: kalan özellikler (global haritada `null` silme isteğidir) ve düşen anahtar sayısı. */
    class Sanitized internal constructor(val properties: Map<String, JsonElement?>, val dropped: Int)

    /** Özellikleri sözleşmeye indirger; çağrı başına en çok 50 özellik tutulur. [allowNull] yalnız global haritada kullanılır. */
    fun sanitize(properties: Map<String, Any?>?, allowNull: Boolean = false): Sanitized {
        val out = LinkedHashMap<String, JsonElement?>()
        var dropped = 0
        // Sınır yalnız değer taşıyan anahtarları sayar; global haritadaki silme isteği (null) sınıra girmez (Web/Node ile aynı).
        var count = 0
        if (properties == null) return Sanitized(out, 0)
        for ((key, value) in properties) {
            if (!validKey(key)) {
                dropped++
                continue
            }
            if (allowNull && value == null) {
                out[key] = null
                continue
            }
            val clean = cleanValue(value)
            if (clean == null || count >= MAX_PROFILE_PROPERTIES) {
                dropped++
                continue
            }
            out[key] = clean
            count++
        }
        return Sanitized(out, dropped)
    }
}

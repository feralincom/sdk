' Feralin Roku SDK çekirdeği: yapılandırma, izin, olay üretimi, kalıcı kuyruk, oturum ve yeniden deneme kararları. Ağ ve iş parçacığı
' yoktur; FeralinTask.brs bu işlevleri Task iş parçacığında kullanır, testler (tests/) aynı işlevleri brs yorumlayıcısında sahte cihaz,
' kayıt bölümü ve saatle koşar. Olay sözleşmesi: packages/schemas/utp/v1/event.schema.json (UTP v1).
'
' Kullanılan Roku API'leri ve kaynakları:
'   roRegistrySection Read/Write/Delete/Exists/Flush: https://developer.roku.com/dev/docs/ifregistrysection
'   Registry boyutu (uygulama başına sıkıştırılmış 32 KB): https://developer.roku.com/dev/docs/roregistry
'   roDeviceInfo GetRandomUUID, GetRIDA, IsRIDADisabled, GetCurrentLocale, GetTimeZone, GetDisplaySize, GetModel, GetOSVersion:
'     https://developer.roku.com/dev/docs/ifdeviceinfo
'   roDateTime Mark, GetYear ... GetMilliseconds, AsSeconds: https://developer.roku.com/dev/docs/ifdatetime
'   roRegex IsMatch: https://developer.roku.com/dev/docs/ifregex

function Feralin_SdkName() as String
    return "feralin-roku"
end function

function Feralin_SdkVersion() as String
    return "0.1.0"
end function

' Kayıt bölümü adı; bölüm adları büyük-küçük harfe duyarlıdır.
function Feralin_RegistrySection() as String
    return "Feralin"
end function

' --- Tür yardımcıları ---

function Feralin__IsString(value as Dynamic) as Boolean
    t = type(value)
    return t = "String" or t = "roString"
end function

function Feralin__IsBool(value as Dynamic) as Boolean
    t = type(value)
    return t = "Boolean" or t = "roBoolean"
end function

function Feralin__IsNumber(value as Dynamic) as Boolean
    t = type(value)
    return t = "Integer" or t = "roInt" or t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble" or t = "LongInteger" or t = "roLongInteger"
end function

function Feralin__IsAA(value as Dynamic) as Boolean
    return type(value) = "roAssociativeArray"
end function

function Feralin__IsArray(value as Dynamic) as Boolean
    return type(value) = "roArray"
end function

function Feralin__Int(value as Dynamic, fallback as Integer, minimum as Integer, maximum as Integer) as Integer
    if not Feralin__IsNumber(value) then return fallback
    n = Int(value)
    if n < minimum or n > maximum then return fallback
    return n
end function

function Feralin__Pad(value as Integer, width as Integer) as String
    text = value.ToStr()
    while Len(text) < width
        text = "0" + text
    end while
    return text
end function

' --- Yapılandırma ve izin ---

' Yalnız analytics boolean ise geçerlidir; öteki alanlar verilmediyse gönderilmez (varsayılan olarak verilmiş sayılmaz).
function Feralin_NormalizeConsent(consent as Dynamic) as Dynamic
    if not Feralin__IsAA(consent) then return invalid
    if not Feralin__IsBool(consent.analytics) then return invalid
    out = { analytics: consent.analytics }
    if Feralin__IsBool(consent.advertising) then out.advertising = consent.advertising
    if Feralin__IsBool(consent.personalization) then out.personalization = consent.personalization
    if Feralin__IsBool(consent.session_replay) then out.session_replay = consent.session_replay
    return out
end function

' Yapılandırmayı doğrular. Yalnız public anahtar (pk_) kabul edilir; gizli anahtar (sk_) ya da bozuk adres invalid döner ve SDK kapalı kalır.
'   collectAdvertisingId: Roku reklam kimliği (RIDA) yalnız true verilirse ve yalnız Feralin_AdvertisingId koşullarıyla okunur.
'   platform: "roku" (varsayılan; toplayıcı 19 Kasım 2026'dan beri kabul eder). Eski toplayıcıya gönderen kanal "other" verebilir.
function Feralin_NormalizeConfig(config as Dynamic) as Dynamic
    if not Feralin__IsAA(config) then return invalid
    if not Feralin__IsString(config.projectKey) or not Feralin__IsString(config.collectUrl) then return invalid
    key = config.projectKey.Trim()
    if LCase(Left(key, 3)) = "sk_" or Left(key, 3) <> "pk_" or Len(key) < 8 then return invalid
    url = config.collectUrl.Trim()
    if Left(url, 8) <> "https://" and Left(url, 7) <> "http://" then return invalid
    while Right(url, 1) = "/"
        url = Left(url, Len(url) - 1)
    end while
    platform = "roku"
    if Feralin__IsString(config.platform) and config.platform = "other" then platform = "other"
    out = {
        projectKey: key
        collectUrl: url
        platform: platform
        batchSize: Feralin__Int(config.batchSize, 20, 1, 100)
        flushIntervalMs: Feralin__Int(config.flushIntervalMs, 10000, 1000, 300000)
        queueLimit: Feralin__Int(config.queueLimit, 100, 1, 200)
        ' Kayıt bölümü uygulama başına sıkıştırılmış 32 KB ile sınırlı ve uygulamanın kendi verisiyle paylaşılır: kuyruk JSON metni bu sınırı aşmaz.
        maxQueueChars: Feralin__Int(config.maxQueueChars, 16000, 2000, 24000)
        sessionTimeoutSeconds: Feralin__Int(config.sessionTimeoutSeconds, 1800, 60, 86400)
        requestTimeoutMs: Feralin__Int(config.requestTimeoutMs, 15000, 1000, 60000)
        collectAdvertisingId: config.collectAdvertisingId = true
        debug: config.debug = true
        consent: Feralin_NormalizeConsent(config.consent)
        installCode: invalid
        appVersion: invalid
    }
    if Feralin__IsString(config.installCode)
        code = config.installCode.Trim()
        if CreateObject("roRegex", "^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$", "").IsMatch(code) then out.installCode = code
    end if
    if Feralin__IsString(config.appVersion) and Len(config.appVersion) > 0 and Len(config.appVersion) <= 32 then out.appVersion = config.appVersion
    return out
end function

' --- Olay adı ve özellikler ---

function Feralin_ValidEventName(name as Dynamic) as Boolean
    if not Feralin__IsString(name) then return false
    if Len(name) < 1 or Len(name) > 100 then return false
    return CreateObject("roRegex", "^[a-z][a-z0-9_]*$", "").IsMatch(name)
end function

function Feralin__IsJsonValue(value as Dynamic, depth as Integer) as Boolean
    if value = invalid then return true
    if Feralin__IsString(value) or Feralin__IsBool(value) or Feralin__IsNumber(value) then return true
    if depth > 8 then return false
    if Feralin__IsArray(value)
        for each item in value
            if not Feralin__IsJsonValue(item, depth + 1) then return false
        end for
        return true
    end if
    if Feralin__IsAA(value)
        for each key in value
            if not Feralin__IsJsonValue(value[key], depth + 1) then return false
        end for
        return true
    end if
    return false
end function

' Özellik anahtarlarını şema desenine göre süzer; en çok 100 özellik. JSON'a dönüşmeyen değer (düğüm, işlev) düşer. Boşsa invalid.
function Feralin_SanitizeProperties(properties as Dynamic) as Dynamic
    if not Feralin__IsAA(properties) then return invalid
    pattern = CreateObject("roRegex", "^[a-zA-Z][a-zA-Z0-9_]{0,63}$", "")
    out = {}
    count = 0
    for each key in properties
        if count >= 100 then exit for
        value = properties[key]
        if pattern.IsMatch(key) and Feralin__IsJsonValue(value, 0)
            out[key] = value
            count = count + 1
        end if
    end for
    if count = 0 then return invalid
    return out
end function

' Gelir olayı (`feralin_purchase`) özellikleri; Web, Android ve Swift SDK'larıyla aynı kurallar. Sözleşme dışı girdide invalid.
function Feralin_BuildRevenueProperties(input as Dynamic) as Dynamic
    if not Feralin__IsAA(input) then return invalid
    if not Feralin__IsString(input.transactionId) or Len(input.transactionId) < 1 or Len(input.transactionId) > 128 then return invalid
    if not Feralin__IsNumber(input.amountMinor) then return invalid
    if input.amountMinor < 0 or input.amountMinor <> Int(input.amountMinor) then return invalid
    if not Feralin__IsString(input.currency) or not CreateObject("roRegex", "^[A-Z]{3}$", "").IsMatch(input.currency) then return invalid
    quantity = 1
    if input.quantity <> invalid
        if not Feralin__IsNumber(input.quantity) then return invalid
        if input.quantity < 0 or input.quantity > 100000 or input.quantity <> Int(input.quantity) then return invalid
        quantity = Int(input.quantity)
    end if
    purchaseType = "purchase"
    if input.purchaseType <> invalid then purchaseType = input.purchaseType
    allowed = { purchase: true, subscription_start: true, subscription_renew: true, subscription_cancel: true }
    if not Feralin__IsString(purchaseType) or not allowed.DoesExist(purchaseType) then return invalid
    ' Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
    if purchaseType = "subscription_cancel" and input.amountMinor <> 0 then return invalid
    props = Feralin_SanitizeProperties(input.properties)
    if props = invalid then props = {}
    ' İstemci doğrulama beyan edemez: bu anahtarlar düşürülür, toplayıcı da düşürür.
    for each reserved in ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"]
        props.Delete(reserved)
    end for
    props.transaction_id = input.transactionId
    props.amount_minor = input.amountMinor
    props.currency = input.currency
    props.quantity = quantity
    props.purchase_type = purchaseType
    if input.productId <> invalid
        if not Feralin__IsString(input.productId) or Len(input.productId) < 1 or Len(input.productId) > 128 then return invalid
        props.product_id = input.productId
    end if
    return props
end function

' --- Zaman ---

' RFC 3339 UTC zamanı (ör. 2026-11-19T08:30:05.123Z). roDateTime.ToISOString() "+0000" biçimi verir; toplayıcının date-time biçimiyle
' tutarlı olmak için alanlar elle birleştirilir. Mark() sonrası alanlar UTC'dir (ToLocalTime çağrılmaz).
function Feralin_IsoTime(dt as Object) as String
    text = Feralin__Pad(dt.GetYear(), 4) + "-" + Feralin__Pad(dt.GetMonth(), 2) + "-" + Feralin__Pad(dt.GetDayOfMonth(), 2)
    text = text + "T" + Feralin__Pad(dt.GetHours(), 2) + ":" + Feralin__Pad(dt.GetMinutes(), 2) + ":" + Feralin__Pad(dt.GetSeconds(), 2)
    return text + "." + Feralin__Pad(dt.GetMilliseconds(), 3) + "Z"
end function

' --- Reklam kimliği (RIDA) ---

' RIDA yalnız üç koşul birlikte sağlanırsa döner: uygulama collectAdvertisingId=true ile açıkça istedi, kullanıcı reklam ölçümü iznini
' verdi (consent.advertising=true) ve cihazda "Limit ad tracking" kapalı (IsRIDADisabled()=false). Aksi hâlde GetRIDA hiç çağrılmaz.
' Toplayıcı kimliği yalnız app_first_open olayında ve küçük harfli UUID biçiminde kabul eder.
function Feralin_AdvertisingId(config as Object, consent as Dynamic, device as Object) as Dynamic
    if config.collectAdvertisingId <> true then return invalid
    if consent = invalid then return invalid
    if consent.advertising <> true then return invalid
    if device.IsRIDADisabled() then return invalid
    rida = LCase(device.GetRIDA())
    uuid = CreateObject("roRegex", "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", "")
    if not uuid.IsMatch(rida) or rida = "00000000-0000-0000-0000-000000000000" then return invalid
    return rida
end function

' --- Gönderim kararları ---

' HTTP sonucunu sınıflar: 2xx kabul; ağ hatası (0 ve negatif cURL kodları), 408, 429 ve 5xx yeniden denenir; öteki 4xx atılır.
function Feralin_Classify(code as Integer) as String
    if code >= 200 and code < 300 then return "accepted"
    if code <= 0 or code = 408 or code = 429 or code >= 500 then return "retry"
    return "dropped"
end function

' Üstel geri çekilme: 1 sn, 2 sn, 4 sn ... en çok 30 sn; %20'ye kadar rastgele ek (jitter 0..1).
function Feralin_Backoff(attempt as Integer, jitter as Float) as Integer
    exponent = attempt - 1
    if exponent < 0 then exponent = 0
    if exponent > 5 then exponent = 5
    delay = 1000 * (2 ^ exponent)
    if delay > 30000 then delay = 30000
    return Int(delay + delay * 0.2 * jitter)
end function

' Retry-After başlığı (saniye); yoksa ya da bozuksa 0. Üst sınır 5 dakika.
function Feralin_RetryAfterMs(headers as Dynamic) as Integer
    if not Feralin__IsAA(headers) then return 0
    raw = headers["retry-after"]
    if not Feralin__IsString(raw) then return 0
    if not CreateObject("roRegex", "^[0-9]{1,6}$", "").IsMatch(raw.Trim()) then return 0
    ms = raw.Trim().ToInt() * 1000
    if ms > 300000 then ms = 300000
    return ms
end function

' --- Motor ---

' env: { device (roDeviceInfo yüzü), registry (roRegistrySection yüzü), uuid(), nowIso(), nowSeconds(), random(), appVersion }
function Feralin_NewEngine(config as Object, env as Object) as Object
    engine = {
        config: config
        env: env
        consent: config.consent
        anonymousId: invalid
        sessionId: invalid
        userId: invalid
        lastActivity: 0
        firstOpenSent: false
        installCodePending: config.installCode <> invalid
        queue: []
        inflight: invalid
        attempt: 0
        notBefore: 0
        dirty: false
        context: invalid
        lastResult: ""
        Start: Feralin__EngineStart
        SetConsent: Feralin__EngineSetConsent
        Track: Feralin__EngineTrack
        TrackRevenue: Feralin__EngineTrackRevenue
        Identify: Feralin__EngineIdentify
        Reset: Feralin__EngineReset
        TakeBatch: Feralin__EngineTakeBatch
        BatchBody: Feralin__EngineBatchBody
        OnResponse: Feralin__EngineOnResponse
        Persist: Feralin__EnginePersist
        Status: Feralin__EngineStatus
        Activate: Feralin__EngineActivate
        Enqueue: Feralin__EngineEnqueue
        TouchSession: Feralin__EngineTouchSession
        BuildEvent: Feralin__EngineBuildEvent
        ClearStored: Feralin__EngineClearStored
    }
    engine.context = Feralin__Context(env)
    return engine
end function

function Feralin__Context(env as Object) as Object
    context = {}
    device = env.device
    locale = device.GetCurrentLocale()
    if Feralin__IsString(locale) and Len(locale) > 0 and Len(locale) <= 16 then context.locale = locale
    zone = device.GetTimeZone()
    if Feralin__IsString(zone) and Len(zone) > 0 and Len(zone) <= 64 then context.timezone = zone
    size = device.GetDisplaySize()
    if Feralin__IsAA(size) and Feralin__IsNumber(size.w) and Feralin__IsNumber(size.h) then context.screen = { width: Int(size.w), height: Int(size.h) }
    if Feralin__IsString(env.appVersion) and Len(env.appVersion) > 0 and Len(env.appVersion) <= 32 then context.app = { version: env.appVersion }
    return context
end function

' Kayıtlı durumu yükler. Açık analytics=false kararıyla açılışta kayıtlı kuyruk ve kimlikler silinir; karar yoksa (bekleniyor) kuyruk
' korunur ama olay üretilmez.
sub Feralin__EngineStart()
    registry = m.env.registry
    m.firstOpenSent = registry.Exists("first_open")
    if m.consent <> invalid and m.consent.analytics = false
        m.ClearStored()
        return
    end if
    if registry.Exists("queue")
        stored = ParseJson(registry.Read("queue"))
        if Feralin__IsArray(stored) then m.queue = stored
    end if
    if registry.Exists("inflight")
        stored = ParseJson(registry.Read("inflight"))
        if Feralin__IsAA(stored) and Feralin__IsString(stored.key) and Feralin__IsArray(stored.events) then m.inflight = stored
    end if
    if registry.Exists("anon_id") then m.anonymousId = registry.Read("anon_id")
    if registry.Exists("user_id") then m.userId = registry.Read("user_id")
    if registry.Exists("session_id") then m.sessionId = registry.Read("session_id")
    if registry.Exists("last_activity") then m.lastActivity = registry.Read("last_activity").ToInt()
    if m.consent <> invalid and m.consent.analytics = true then m.Activate()
end sub

' Analitik izni varken: anonim kimlik, oturum ve kurulum başına tek ilk açılış.
sub Feralin__EngineActivate()
    if m.anonymousId = invalid or m.anonymousId = ""
        m.anonymousId = m.env.uuid()
        m.dirty = true
    end if
    m.TouchSession()
    if not m.firstOpenSent
        props = {}
        os = m.env.device.GetOSVersion()
        ' GetOSVersion alanları metindir (major, minor, revision, build).
        if Feralin__IsAA(os) and Feralin__IsString(os.major) and Feralin__IsString(os.minor) then props.os_version = os.major + "." + os.minor
        model = m.env.device.GetModel()
        if Feralin__IsString(model) and Len(model) > 0 and Len(model) <= 32 then props.device_model = model
        rida = Feralin_AdvertisingId(m.config, m.consent, m.env.device)
        if rida <> invalid then props.advertising_id = rida
        m.Enqueue(m.BuildEvent("app_first_open", props))
        m.firstOpenSent = true
        m.env.registry.Write("first_open", "1")
        m.dirty = true
    end if
end sub

' Son etkinlikten sessionTimeoutSeconds geçtiyse yeni oturum açılır ve session_start olayı üretilir.
sub Feralin__EngineTouchSession()
    now = m.env.nowSeconds()
    expired = m.sessionId = invalid or m.sessionId = "" or (now - m.lastActivity) > m.config.sessionTimeoutSeconds
    m.lastActivity = now
    m.dirty = true
    if expired
        m.sessionId = m.env.uuid()
        m.Enqueue(m.BuildEvent("session_start", invalid))
    end if
end sub

function Feralin__EngineBuildEvent(name as String, properties as Dynamic) as Object
    event = {
        event_id: m.env.uuid()
        event_name: name
        occurred_at: m.env.nowIso()
        platform: m.config.platform
        schema_version: 1
        sdk: { name: Feralin_SdkName(), version: Feralin_SdkVersion() }
        anonymous_id: m.anonymousId
        session_id: m.sessionId
        consent: Feralin__Copy(m.consent)
    }
    if m.userId <> invalid and m.userId <> "" then event.user_id = m.userId
    props = properties
    if m.installCodePending
        if props = invalid then props = {}
        props.fr_install_code = m.config.installCode
        m.installCodePending = false
    end if
    if props <> invalid and props.Count() > 0 then event.properties = props
    if m.context.Count() > 0 then event.context = Feralin__Copy(m.context)
    return event
end function

' Derin kopya: her olay kendi izin ve bağlam nesnesini taşır; aynı nesnenin kuyrukta birden çok olayda yer alması FormatJson'u
' bozabilir ve sonradan yapılan izin değişikliği eski olayları etkilemez.
function Feralin__Copy(value as Dynamic) as Dynamic
    if Feralin__IsAA(value)
        out = {}
        for each key in value
            out[key] = Feralin__Copy(value[key])
        end for
        return out
    end if
    if Feralin__IsArray(value)
        list = []
        for each item in value
            list.Push(Feralin__Copy(item))
        end for
        return list
    end if
    return value
end function

' Kuyruğa ekler; sayı ya da JSON boyutu sınırı aşılırsa en eski olay düşer.
sub Feralin__EngineEnqueue(event as Object)
    m.queue.Push(event)
    while m.queue.Count() > m.config.queueLimit
        m.queue.Shift()
    end while
    while m.queue.Count() > 1 and Len(FormatJson(m.queue)) > m.config.maxQueueChars
        m.queue.Shift()
    end while
    m.dirty = true
end sub

' Olay üretir; olay kimliği döner. İzin yoksa (bekleniyor ya da analytics=false) ya da ad geçersizse invalid.
function Feralin__EngineTrack(name as Dynamic, properties as Dynamic) as Dynamic
    if m.consent = invalid then return invalid
    if m.consent.analytics <> true then return invalid
    if not Feralin_ValidEventName(name) then return invalid
    props = Feralin_SanitizeProperties(properties)
    if props <> invalid
        ' Reklam kimliği yalnız SDK'nın ilk açılış olayında gider; tıklama kimliği reklam izni ister.
        props.Delete("advertising_id")
        if m.consent.advertising <> true then props.Delete("fr_click")
    end if
    m.TouchSession()
    event = m.BuildEvent(name, props)
    m.Enqueue(event)
    return event.event_id
end function

function Feralin__EngineTrackRevenue(input as Dynamic) as Dynamic
    props = Feralin_BuildRevenueProperties(input)
    if props = invalid then return invalid
    if m.consent = invalid then return invalid
    if m.consent.analytics <> true then return invalid
    m.TouchSession()
    event = m.BuildEvent("feralin_purchase", props)
    m.Enqueue(event)
    return event.event_id
end function

' Uygulamanın kendi opak kullanıcı kimliği (1-128 karakter). E-posta ya da telefon vermeyin.
function Feralin__EngineIdentify(userId as Dynamic) as Boolean
    if not Feralin__IsString(userId) then return false
    if Len(userId) < 1 or Len(userId) > 128 then return false
    m.userId = userId
    m.dirty = true
    return true
end function

' Çıkış: kullanıcı kimliği silinir, anonim kimlik ve oturum yenilenir, bekleyen kuyruk silinir.
sub Feralin__EngineReset()
    m.userId = invalid
    m.queue = []
    m.inflight = invalid
    m.anonymousId = invalid
    m.sessionId = invalid
    m.env.registry.Delete("user_id")
    m.dirty = true
    if m.consent <> invalid and m.consent.analytics = true then m.Activate()
end sub

sub Feralin__EngineClearStored()
    m.queue = []
    m.inflight = invalid
    m.anonymousId = invalid
    m.sessionId = invalid
    m.userId = invalid
    registry = m.env.registry
    for each key in ["queue", "inflight", "anon_id", "session_id", "user_id", "last_activity"]
        registry.Delete(key)
    end for
    registry.Flush()
    m.dirty = false
end sub

' İzin kararı. analytics=false: kuyruk ve kimlikler silinir. Reklam izni kalkarsa bekleyen olaylardan reklam kimliği ve tıklama kimliği
' çıkarılır, izin bloğu güncellenir; değişen bekleyen batch yeni Idempotency-Key alır (toplayıcı event_id ile tekrarı ayıklar).
function Feralin__EngineSetConsent(consent as Dynamic) as Boolean
    normalized = Feralin_NormalizeConsent(consent)
    if normalized = invalid then return false
    m.consent = normalized
    if normalized.analytics <> true
        m.ClearStored()
        return true
    end if
    if normalized.advertising <> true
        Feralin__StripAdvertising(m.queue, normalized)
        if m.inflight <> invalid
            if Feralin__StripAdvertising(m.inflight.events, normalized) then m.inflight.key = "roku-" + m.env.uuid()
        end if
    end if
    m.dirty = true
    m.Activate()
    return true
end function

function Feralin__StripAdvertising(events as Object, consent as Object) as Boolean
    changed = false
    for each event in events
        props = event.properties
        if Feralin__IsAA(props)
            if props.DoesExist("advertising_id") or props.DoesExist("fr_click")
                props.Delete("advertising_id")
                props.Delete("fr_click")
                event.consent = Feralin__Copy(consent)
                changed = true
            end if
        end if
    end for
    return changed
end function

' Gönderilecek batch: bekleyen (yeniden denenen) batch varsa aynısı ve aynı Idempotency-Key ile, yoksa kuyruğun başından yenisi.
function Feralin__EngineTakeBatch() as Dynamic
    if m.inflight <> invalid then return m.inflight
    if m.queue.Count() = 0 then return invalid
    events = []
    while m.queue.Count() > 0 and events.Count() < m.config.batchSize
        events.Push(m.queue.Shift())
    end while
    m.inflight = { key: "roku-" + m.env.uuid(), events: events }
    m.dirty = true
    return m.inflight
end function

function Feralin__EngineBatchBody(batch as Object) as String
    return FormatJson({ sent_at: m.env.nowIso(), events: batch.events })
end function

' Yanıta göre karar: kabul ya da atılan batch silinir; yeniden denenecek batch bekler ve sonraki deneme geri çekilmeyle ertelenir.
function Feralin__EngineOnResponse(code as Integer, retryAfterMs as Integer, nowMs as Integer) as String
    result = Feralin_Classify(code)
    if result = "retry"
        m.attempt = m.attempt + 1
        delay = Feralin_Backoff(m.attempt, m.env.random())
        if retryAfterMs > delay then delay = retryAfterMs
        m.notBefore = nowMs + delay
    else
        m.inflight = invalid
        m.attempt = 0
        m.notBefore = 0
    end if
    m.lastResult = result + ":" + code.ToStr()
    m.dirty = true
    return result
end function

' Değişen durumu kayıt bölümüne yazar ve diske işler (Flush). Analitik izni yoksa kimlik yazılmaz.
sub Feralin__EnginePersist()
    if not m.dirty then return
    registry = m.env.registry
    registry.Write("queue", FormatJson(m.queue))
    if m.inflight <> invalid
        registry.Write("inflight", FormatJson(m.inflight))
    else
        registry.Delete("inflight")
    end if
    if m.consent <> invalid and m.consent.analytics = true
        if m.anonymousId <> invalid then registry.Write("anon_id", m.anonymousId)
        if m.sessionId <> invalid then registry.Write("session_id", m.sessionId)
        registry.Write("last_activity", m.lastActivity.ToStr())
        if m.userId <> invalid then registry.Write("user_id", m.userId)
    end if
    registry.Flush()
    m.dirty = false
end sub

function Feralin__EngineStatus() as Object
    pending = 0
    if m.inflight <> invalid then pending = m.inflight.events.Count()
    return {
        initialized: true
        sdk: Feralin_SdkName()
        version: Feralin_SdkVersion()
        queued: m.queue.Count() + pending
        consent: m.consent
        sessionId: m.sessionId
        lastResult: m.lastResult
    }
end function

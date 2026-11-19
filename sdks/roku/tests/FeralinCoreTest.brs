' FeralinCore.brs birim testleri. Roku cihazı gerekmez: brs yorumlayıcısıyla koşar (node sdks/roku/tests/run.mjs). Cihaz, kayıt bölümü
' ve saat sahte nesnelerdir; Task iş parçacığı (roUrlTransfer, roSGNode) burada sınanmaz, cihaz ister.
' Her satır "ok <ad>" ya da "FAIL <ad>: <ayrıntı>" yazar; sonda özet ve toplayıcı şemasıyla denetlenecek batch gövdeleri ("BATCH_JSON ").

sub main()
    t = { passed: 0, failed: 0 }
    Test_Config(t)
    Test_EventNameAndProperties(t)
    Test_AdvertisingIdGate(t)
    Test_Decisions(t)
    Test_IsoTime(t)
    Test_PendingConsent(t)
    Test_FirstOpenOncePerInstall(t)
    Test_AdvertisingIdOnlyOnFirstOpen(t)
    Test_ConsentWithdrawal(t)
    Test_BatchLifecycle(t)
    Test_QueueLimits(t)
    Test_SessionTimeout(t)
    Test_RevenueAndInstallCode(t)
    Test_SchemaBodies(t)
    print "SUMMARY passed=" + t.passed.ToStr() + " failed=" + t.failed.ToStr()
end sub

sub Check(t as Object, name as String, condition as Boolean, detail = "" as String)
    if condition
        t.passed = t.passed + 1
        print "ok " + name
    else
        t.failed = t.failed + 1
        print "FAIL " + name + ": " + detail
    end if
end sub

' --- Sahte ortam ---

function FakeRegistry() as Object
    return {
        data: {}
        flushes: 0
        Read: function(key as String) as String
            if m.data.DoesExist(key) then return m.data[key]
            return ""
        end function
        Write: function(key as String, value as String) as Boolean
            m.data[key] = value
            return true
        end function
        Delete: function(key as String) as Boolean
            return m.data.Delete(key)
        end function
        Exists: function(key as String) as Boolean
            return m.data.DoesExist(key)
        end function
        Flush: function() as Boolean
            m.flushes = m.flushes + 1
            return true
        end function
    }
end function

function FakeDevice() as Object
    return {
        counter: 0
        ridaDisabled: false
        rida: "AB12CD34-0000-4000-8000-1234567890AB"
        ridaCalls: 0
        GetRandomUUID: function() as String
            m.counter = m.counter + 1
            return "00000000-0000-4000-8000-" + Feralin__Pad(m.counter, 12)
        end function
        GetRIDA: function() as String
            m.ridaCalls = m.ridaCalls + 1
            return m.rida
        end function
        IsRIDADisabled: function() as Boolean
            return m.ridaDisabled
        end function
        GetCurrentLocale: function() as String
            return "tr_TR"
        end function
        GetTimeZone: function() as String
            return "Europe/Istanbul"
        end function
        GetDisplaySize: function() as Object
            return { w: 1920, h: 1080 }
        end function
        GetModel: function() as String
            return "3930X"
        end function
        GetOSVersion: function() as Object
            return { major: "15", minor: "1", revision: "4", build: "4130" }
        end function
    }
end function

function FakeEnv(registry = invalid as Dynamic) as Object
    if registry = invalid then registry = FakeRegistry()
    return {
        device: FakeDevice()
        registry: registry
        appVersion: "2.3.1"
        ' brs toplama sonucunu tek duyarlıklı kayan sayıya çevirebilir; tam kalması için küçük bir başlangıç değeri kullanılır.
        seconds: 1000000
        uuid: function() as String
            return m.device.GetRandomUUID()
        end function
        nowIso: function() as String
            return "2026-11-19T10:00:00.000Z"
        end function
        nowSeconds: function() as Integer
            ' brs büyük sayı sabitini Double okur; cihazdaki roDateTime.AsSeconds() Integer döndürür.
            return Int(m.seconds)
        end function
        random: function() as Float
            return 0.5
        end function
    }
end function

function BaseConfig(extra = invalid as Dynamic) as Object
    config = { projectKey: "pk_test_roku_123", collectUrl: "https://collect.example.com/" }
    if extra <> invalid
        for each key in extra
            config[key] = extra[key]
        end for
    end if
    return Feralin_NormalizeConfig(config)
end function

function EventNames(events as Object) as String
    names = ""
    for each event in events
        if names <> "" then names = names + ","
        names = names + event.event_name
    end for
    return names
end function

' --- Testler ---

sub Test_Config(t as Object)
    Check(t, "config: gizli anahtar reddedilir", Feralin_NormalizeConfig({ projectKey: "sk_live_123456", collectUrl: "https://c.example.com" }) = invalid)
    Check(t, "config: büyük harfli gizli anahtar reddedilir", Feralin_NormalizeConfig({ projectKey: "SK_live_123456", collectUrl: "https://c.example.com" }) = invalid)
    Check(t, "config: pk_ olmayan anahtar reddedilir", Feralin_NormalizeConfig({ projectKey: "dev_key_1234", collectUrl: "https://c.example.com" }) = invalid)
    Check(t, "config: http(s) olmayan adres reddedilir", Feralin_NormalizeConfig({ projectKey: "pk_test_123456", collectUrl: "ftp://c.example.com" }) = invalid)
    Check(t, "config: eksik alan reddedilir", Feralin_NormalizeConfig({ projectKey: "pk_test_123456" }) = invalid)
    c = BaseConfig({ batchSize: 500, flushIntervalMs: 5000, platform: "android" })
    Check(t, "config: sondaki eğik çizgi kırpılır", c.collectUrl = "https://collect.example.com", c.collectUrl)
    Check(t, "config: sınır dışı batchSize varsayılana döner", c.batchSize = 20, c.batchSize.ToStr())
    Check(t, "config: geçerli flushIntervalMs korunur", c.flushIntervalMs = 5000)
    Check(t, "config: bilinmeyen platform roku olur", c.platform = "roku", c.platform)
    Check(t, "config: reklam kimliği varsayılan kapalı", c.collectAdvertisingId = false)
    Check(t, "config: izin verilmediyse bekleniyor", c.consent = invalid)
    Check(t, "config: geçici other platformu", BaseConfig({ platform: "other" }).platform = "other")
    c2 = BaseConfig({ consent: { analytics: true, advertising: "evet" }, installCode: "ABCDE-FGHJK" })
    Check(t, "config: izin süzülür", FormatJson(c2.consent) = "{""analytics"":true}", FormatJson(c2.consent))
    Check(t, "config: kurulum kodu", c2.installCode = "ABCDE-FGHJK")
    Check(t, "config: bozuk kurulum kodu yok sayılır", BaseConfig({ installCode: "abc" }).installCode = invalid)
end sub

sub Test_EventNameAndProperties(t as Object)
    Check(t, "ad: snake_case geçer", Feralin_ValidEventName("level_up"))
    Check(t, "ad: büyük harf geçmez", not Feralin_ValidEventName("LevelUp"))
    Check(t, "ad: boşluk geçmez", not Feralin_ValidEventName("level up"))
    Check(t, "ad: boş geçmez", not Feralin_ValidEventName(""))
    Check(t, "ad: dizgi olmayan geçmez", not Feralin_ValidEventName(42))
    props = Feralin_SanitizeProperties({ level: 3, ok: true, "bad key": 1, "9x": 2, nested: { a: [1, 2] }, fn: Feralin_SdkName })
    Check(t, "özellik: geçersiz anahtar ve işlev düşer", props.Count() = 3, FormatJson(props))
    Check(t, "özellik: iç içe değer korunur", props.nested.a.Count() = 2)
    Check(t, "özellik: boşsa invalid", Feralin_SanitizeProperties({ "bad key": 1 }) = invalid)
    many = {}
    for i = 1 to 150
        many["k" + i.ToStr()] = i
    end for
    Check(t, "özellik: en çok 100", Feralin_SanitizeProperties(many).Count() = 100)
end sub

sub Test_AdvertisingIdGate(t as Object)
    device = FakeDevice()
    optIn = BaseConfig({ collectAdvertisingId: true })
    optOut = BaseConfig()
    granted = { analytics: true, advertising: true }
    Check(t, "rida: uygulama istemediyse okunmaz", Feralin_AdvertisingId(optOut, granted, device) = invalid and device.ridaCalls = 0)
    Check(t, "rida: reklam izni yoksa okunmaz", Feralin_AdvertisingId(optIn, { analytics: true }, device) = invalid and device.ridaCalls = 0)
    Check(t, "rida: izin bekleniyorsa okunmaz", Feralin_AdvertisingId(optIn, invalid, device) = invalid and device.ridaCalls = 0)
    device.ridaDisabled = true
    Check(t, "rida: Limit ad tracking açıksa okunmaz", Feralin_AdvertisingId(optIn, granted, device) = invalid and device.ridaCalls = 0)
    device.ridaDisabled = false
    rida = Feralin_AdvertisingId(optIn, granted, device)
    Check(t, "rida: üç koşulda küçük harfli UUID", rida = "ab12cd34-0000-4000-8000-1234567890ab", Feralin__Text(rida))
    device.rida = "00000000-0000-0000-0000-000000000000"
    Check(t, "rida: sıfır kimlik gönderilmez", Feralin_AdvertisingId(optIn, granted, device) = invalid)
    device.rida = "not-a-uuid"
    Check(t, "rida: bozuk kimlik gönderilmez", Feralin_AdvertisingId(optIn, granted, device) = invalid)
end sub

function Feralin__Text(value as Dynamic) as String
    if value = invalid then return "invalid"
    if Feralin__IsString(value) then return value
    return FormatJson(value)
end function

sub Test_Decisions(t as Object)
    Check(t, "karar: 202 kabul", Feralin_Classify(202) = "accepted")
    Check(t, "karar: 429 yeniden", Feralin_Classify(429) = "retry")
    Check(t, "karar: 503 yeniden", Feralin_Classify(503) = "retry")
    Check(t, "karar: ağ hatası yeniden", Feralin_Classify(-6) = "retry")
    Check(t, "karar: 0 yeniden", Feralin_Classify(0) = "retry")
    Check(t, "karar: 400 atılır", Feralin_Classify(400) = "dropped")
    Check(t, "karar: 401 atılır", Feralin_Classify(401) = "dropped")
    Check(t, "geri çekilme: ilk deneme 1 sn", Feralin_Backoff(1, 0) = 1000)
    Check(t, "geri çekilme: üstel", Feralin_Backoff(3, 0) = 4000)
    Check(t, "geri çekilme: üst sınır 30 sn", Feralin_Backoff(12, 0) = 30000)
    Check(t, "geri çekilme: jitter en çok %20", Feralin_Backoff(1, 1) = 1200)
    Check(t, "Retry-After saniye", Feralin_RetryAfterMs({ "retry-after": "7" }) = 7000)
    Check(t, "Retry-After üst sınır", Feralin_RetryAfterMs({ "retry-after": "9999" }) = 300000)
    Check(t, "Retry-After bozuk", Feralin_RetryAfterMs({ "retry-after": "Wed, 21 Oct" }) = 0)
    Check(t, "Retry-After yok", Feralin_RetryAfterMs(invalid) = 0)
end sub

sub Test_IsoTime(t as Object)
    dt = {
        GetYear: function() as Integer : return 2026 : end function
        GetMonth: function() as Integer : return 3 : end function
        GetDayOfMonth: function() as Integer : return 5 : end function
        GetHours: function() as Integer : return 7 : end function
        GetMinutes: function() as Integer : return 8 : end function
        GetSeconds: function() as Integer : return 9 : end function
        GetMilliseconds: function() as Integer : return 45 : end function
    }
    Check(t, "zaman: RFC 3339 UTC", Feralin_IsoTime(dt) = "2026-03-05T07:08:09.045Z", Feralin_IsoTime(dt))
    real = Feralin_IsoTime(CreateObject("roDateTime"))
    Check(t, "zaman: gerçek roDateTime biçimi", CreateObject("roRegex", "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", "").IsMatch(real), real)
end sub

sub Test_PendingConsent(t as Object)
    env = FakeEnv()
    env.registry.Write("queue", "[{""event_id"":""eski"",""event_name"":""eski""}]")
    engine = Feralin_NewEngine(BaseConfig(), env)
    engine.Start()
    Check(t, "bekleyen izin: kayıtlı kuyruk korunur", engine.queue.Count() = 1)
    Check(t, "bekleyen izin: olay üretilmez", engine.Track("level_up", invalid) = invalid)
    Check(t, "bekleyen izin: ilk açılış yok", not env.registry.Exists("first_open"))
    Check(t, "bekleyen izin: anonim kimlik yok", engine.anonymousId = invalid)
    Check(t, "izin: analytics olmayan karar reddedilir", not engine.SetConsent({ advertising: true }))
    Check(t, "izin: verilince ilk açılış üretilir", engine.SetConsent({ analytics: true }) and EventNames(engine.queue) = "eski,session_start,app_first_open", EventNames(engine.queue))
end sub

sub Test_FirstOpenOncePerInstall(t as Object)
    registry = FakeRegistry()
    env = FakeEnv(registry)
    engine = Feralin_NewEngine(BaseConfig({ consent: { analytics: true } }), env)
    engine.Start()
    Check(t, "ilk açılış: oturum ve ilk açılış", EventNames(engine.queue) = "session_start,app_first_open", EventNames(engine.queue))
    first = engine.queue[1]
    Check(t, "ilk açılış: platform roku", first.platform = "roku")
    Check(t, "ilk açılış: işletim sistemi ve model", first.properties.os_version = "15.1" and first.properties.device_model = "3930X", FormatJson(first.properties))
    Check(t, "ilk açılış: reklam kimliği istenmediyse yok", not first.properties.DoesExist("advertising_id"))
    Check(t, "ilk açılış: bağlam", first.context.locale = "tr_TR" and first.context.screen.width = 1920 and first.context.app.version = "2.3.1", FormatJson(first.context))
    Check(t, "ilk açılış: oturum kimliği olayda", first.session_id = engine.sessionId and first.anonymous_id = engine.anonymousId)
    engine.Persist()
    restarted = Feralin_NewEngine(BaseConfig({ consent: { analytics: true } }), FakeEnv(registry))
    restarted.Start()
    Check(t, "ilk açılış: yeniden açılışta tekrar yok", EventNames(restarted.queue) = "session_start,app_first_open", EventNames(restarted.queue))
    Check(t, "kalıcılık: anonim kimlik korunur", restarted.anonymousId = engine.anonymousId)
    Check(t, "kalıcılık: oturum süresi dolmadıysa aynı oturum", restarted.sessionId = engine.sessionId)
end sub

sub Test_AdvertisingIdOnlyOnFirstOpen(t as Object)
    env = FakeEnv()
    engine = Feralin_NewEngine(BaseConfig({ collectAdvertisingId: true, consent: { analytics: true, advertising: true } }), env)
    engine.Start()
    first = engine.queue[1]
    Check(t, "rida: ilk açılışta gider", first.properties.advertising_id = "ab12cd34-0000-4000-8000-1234567890ab", FormatJson(first.properties))
    id = engine.Track("video_start", { advertising_id: "ab12cd34-0000-4000-8000-1234567890ab", fr_click: "c1", title_id: "t1" })
    last = engine.queue[engine.queue.Count() - 1]
    Check(t, "rida: uygulama olayına eklenemez", id <> invalid and not last.properties.DoesExist("advertising_id"), FormatJson(last.properties))
    Check(t, "tıklama: reklam izniyle kalır", last.properties.fr_click = "c1")
    disabledEnv = FakeEnv()
    disabledEnv.device.ridaDisabled = true
    disabled = Feralin_NewEngine(BaseConfig({ collectAdvertisingId: true, consent: { analytics: true, advertising: true } }), disabledEnv)
    disabled.Start()
    Check(t, "rida: Limit ad tracking açıkken ilk açılışta yok", not disabled.queue[1].properties.DoesExist("advertising_id") and disabledEnv.device.ridaCalls = 0)
end sub

sub Test_ConsentWithdrawal(t as Object)
    env = FakeEnv()
    engine = Feralin_NewEngine(BaseConfig({ collectAdvertisingId: true, consent: { analytics: true, advertising: true } }), env)
    engine.Start()
    engine.Track("video_start", { fr_click: "c1" })
    engine.SetConsent({ analytics: true, advertising: false })
    stripped = true
    for each event in engine.queue
        if Feralin__IsAA(event.properties)
            if event.properties.DoesExist("advertising_id") or event.properties.DoesExist("fr_click") then stripped = false
        end if
    end for
    Check(t, "izin geri çekme: reklam ve tıklama kimliği bekleyen olaylardan çıkar", stripped)
    Check(t, "izin geri çekme: izin bloğu güncellenir", engine.queue[1].consent.advertising = false)
    engine.Persist()
    engine.SetConsent({ analytics: false })
    Check(t, "opt-out: kuyruk silinir", engine.queue.Count() = 0)
    Check(t, "opt-out: kayıtlı kimlik silinir", not env.registry.Exists("anon_id") and not env.registry.Exists("queue"))
    Check(t, "opt-out: olay üretilmez", engine.Track("level_up", invalid) = invalid)
    Check(t, "opt-out: ilk açılış kaydı korunur", env.registry.Exists("first_open"))
end sub

sub Test_BatchLifecycle(t as Object)
    env = FakeEnv()
    engine = Feralin_NewEngine(BaseConfig({ batchSize: 2, consent: { analytics: true } }), env)
    engine.Start()
    engine.Track("level_up", { level: 1 })
    batch = engine.TakeBatch()
    Check(t, "batch: boyut sınırı", batch.events.Count() = 2 and engine.queue.Count() = 1)
    key = batch.key
    Check(t, "batch: Idempotency-Key biçimi", CreateObject("roRegex", "^[\x21-\x7E]{8,128}$", "").IsMatch(key), key)
    Check(t, "batch: yeniden deneme", engine.OnResponse(503, 0, 1000) = "retry")
    Check(t, "batch: geri çekilme süresi", engine.notBefore = 1000 + 1100, engine.notBefore.ToStr())
    again = engine.TakeBatch()
    Check(t, "batch: aynı batch aynı anahtarla", again.key = key and again.events.Count() = 2)
    engine.OnResponse(429, 7000, 2000)
    Check(t, "batch: Retry-After geri çekilmeden uzunsa uygulanır", engine.notBefore = 9000, engine.notBefore.ToStr())
    engine.Persist()
    restored = Feralin_NewEngine(BaseConfig({ batchSize: 2, consent: { analytics: true } }), FakeEnv(env.registry))
    restored.Start()
    Check(t, "kalıcılık: bekleyen batch yeniden açılışta aynı anahtarla", restored.inflight <> invalid and restored.inflight.key = key)
    Check(t, "kalıcılık: kuyruk geri yüklenir", restored.queue.Count() >= 1)
    Check(t, "batch: kabul", engine.OnResponse(202, 0, 3000) = "accepted" and engine.inflight = invalid and engine.attempt = 0)
    nextBatch = engine.TakeBatch()
    Check(t, "batch: kabulden sonra yeni anahtar", nextBatch <> invalid and nextBatch.key <> key)
    Check(t, "batch: 400 atılır", engine.OnResponse(400, 0, 4000) = "dropped" and engine.inflight = invalid)
    Check(t, "batch: kuyruk boşsa batch yok", engine.TakeBatch() = invalid)
end sub

sub Test_QueueLimits(t as Object)
    engine = Feralin_NewEngine(BaseConfig({ queueLimit: 5, consent: { analytics: true } }), FakeEnv())
    engine.Start()
    for i = 1 to 10
        engine.Track("tick", { n: i })
    end for
    Check(t, "kuyruk: sayı sınırı, en eski düşer", engine.queue.Count() = 5 and engine.queue[4].properties.n = 10)
    small = Feralin_NewEngine(BaseConfig({ maxQueueChars: 2000, consent: { analytics: true } }), FakeEnv())
    small.Start()
    for i = 1 to 40
        small.Track("tick", { n: i, label: "uzun bir etiket metni" })
    end for
    Check(t, "kuyruk: kayıt bölümü boyut sınırı", Len(FormatJson(small.queue)) <= 2000 and small.queue.Count() > 0, Len(FormatJson(small.queue)).ToStr())
end sub

sub Test_SessionTimeout(t as Object)
    env = FakeEnv()
    engine = Feralin_NewEngine(BaseConfig({ consent: { analytics: true } }), env)
    engine.Start()
    firstSession = engine.sessionId
    env.seconds = env.seconds + 600
    engine.Track("level_up", invalid)
    Check(t, "oturum: zaman aşımı dolmadan aynı", engine.sessionId = firstSession)
    env.seconds = env.seconds + 1801
    engine.Track("level_up", invalid)
    names = EventNames(engine.queue)
    Check(t, "oturum: zaman aşımında yeni session_start", engine.sessionId <> firstSession and Right(names, 22) = "session_start,level_up", names)
    engine.Identify("kullanici_42")
    engine.Track("level_up", invalid)
    Check(t, "kimlik: user_id olayda", engine.queue[engine.queue.Count() - 1].user_id = "kullanici_42")
    Check(t, "kimlik: uzun kimlik reddedilir", not engine.Identify(String(129, "a")))
    anon = engine.anonymousId
    engine.Reset()
    Check(t, "reset: kimlikler yenilenir, kuyruk silinir", engine.anonymousId <> anon and engine.userId = invalid and EventNames(engine.queue) = "session_start", EventNames(engine.queue))
end sub

sub Test_RevenueAndInstallCode(t as Object)
    Check(t, "gelir: kesirli tutar reddedilir", Feralin_BuildRevenueProperties({ transactionId: "t1", amountMinor: 49.99, currency: "TRY" }) = invalid)
    Check(t, "gelir: küçük harfli para birimi reddedilir", Feralin_BuildRevenueProperties({ transactionId: "t1", amountMinor: 4999, currency: "try" }) = invalid)
    Check(t, "gelir: tutarlı iptal reddedilir", Feralin_BuildRevenueProperties({ transactionId: "t1", amountMinor: 10, currency: "TRY", purchaseType: "subscription_cancel" }) = invalid)
    props = Feralin_BuildRevenueProperties({ transactionId: "t1", amountMinor: 4999, currency: "TRY", productId: "pro", properties: { verified: true, plan: "aylik" } })
    Check(t, "gelir: doğrulama beyanı düşer", props <> invalid and not props.DoesExist("verified") and props.plan = "aylik" and props.purchase_type = "purchase" and props.quantity = 1, Feralin__Text(props))
    engine = Feralin_NewEngine(BaseConfig({ installCode: "ABCDE-FGHJK", consent: { analytics: true } }), FakeEnv())
    engine.Start()
    Check(t, "kurulum kodu: ilk olayda bir kez", engine.queue[0].properties.fr_install_code = "ABCDE-FGHJK" and not engine.queue[1].properties.DoesExist("fr_install_code"))
    Check(t, "gelir: olay üretilir", engine.TrackRevenue({ transactionId: "t1", amountMinor: 4999, currency: "TRY" }) <> invalid)
end sub

' Toplayıcı şemasıyla denetlenecek gövdeler: tests/run.mjs bunları packages/schemas/utp/v1 şemasıyla doğrular.
sub Test_SchemaBodies(t as Object)
    for each platform in ["roku", "other"]
        engine = Feralin_NewEngine(BaseConfig({ platform: platform, collectAdvertisingId: true, consent: { analytics: true, advertising: true }, installCode: "ABCDE-FGHJK" }), FakeEnv())
        engine.Start()
        engine.Track("video_start", { title_id: "t1", position_s: 12.5 })
        engine.TrackRevenue({ transactionId: "order_1", amountMinor: 4999, currency: "TRY" })
        engine.Identify("kullanici_42")
        engine.Track("level_up", invalid)
        batch = engine.TakeBatch()
        print "BATCH_JSON " + platform + " " + engine.BatchBody(batch)
    end for
    Check(t, "şema gövdeleri üretildi", true)
end sub

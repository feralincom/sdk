' Feralin Task iş parçacığı: komutları işler, kuyruğu kayıt bölümünde tutar ve batch'leri toplayıcıya gönderir.
'
' Kullanılan Roku API'leri ve kaynakları:
'   Task düğümü, functionName, control="RUN": https://developer.roku.com/dev/docs/task
'   İş parçacığı kuralları (roUrlTransfer yalnız Task'ta): https://developer.roku.com/dev/docs/brightscript-support
'   SceneGraph iş parçacıkları ve rendezvous: https://developer.roku.com/dev/docs/threads
'   observeField(field, port): değer iki kez değişse de kaçmaz: https://developer.roku.com/dev/docs/ifsgnodefield
'   roSGNodeEvent getField/getData: https://developer.roku.com/dev/docs/rosgnodeevent
'   roUrlTransfer SetUrl, AsyncPostFromString, AsyncCancel, RetainBodyOnError, GetIdentity:
'     https://developer.roku.com/dev/docs/ifurltransfer  (nesne aktarım bitene kadar referansta kalmalıdır)
'   HTTPS için common:/certs/ca-bundle.crt ve SetCertificatesFile, AddHeader: https://developer.roku.com/dev/docs/rourltransfer,
'     https://developer.roku.com/dev/docs/ifhttpagent
'   SetMessagePort: https://developer.roku.com/dev/docs/ifsetmessageport
'   roUrlEvent GetInt (1 = aktarım bitti), GetResponseCode (negatif = cURL hatası), GetSourceIdentity, GetResponseHeaders:
'     https://developer.roku.com/dev/docs/rourlevent
'   roTimespan TotalMilliseconds: https://developer.roku.com/dev/docs/iftimespan
'   roAppInfo GetVersion: https://developer.roku.com/dev/docs/ifappinfo

sub init()
    m.top.functionName = "Feralin_TaskMain"
end sub

' Gerçek cihaz ortamı; testler aynı yüzü sahte nesnelerle verir.
function Feralin_DeviceEnv(appVersion as Dynamic) as Object
    return {
        device: CreateObject("roDeviceInfo")
        registry: CreateObject("roRegistrySection", Feralin_RegistrySection())
        appVersion: appVersion
        uuid: function() as String
            return m.device.GetRandomUUID()
        end function
        nowIso: function() as String
            dt = CreateObject("roDateTime")
            return Feralin_IsoTime(dt)
        end function
        nowSeconds: function() as Integer
            dt = CreateObject("roDateTime")
            return dt.AsSeconds()
        end function
        random: function() as Float
            return Rnd(0)
        end function
    }
end function

sub Feralin_TaskMain()
    config = Feralin_NormalizeConfig(m.top.config)
    if config = invalid
        ' Anahtar ve adres değeri loglanmaz.
        print "[feralin] yapılandırma geçersiz: SDK kapalı"
        m.top.status = { initialized: false, reason: "invalid_config" }
        return
    end if
    appVersion = config.appVersion
    if appVersion = invalid then appVersion = CreateObject("roAppInfo").GetVersion()
    env = Feralin_DeviceEnv(appVersion)
    engine = Feralin_NewEngine(config, env)
    engine.Start()
    engine.Persist()

    port = CreateObject("roMessagePort")
    m.top.observeField("command", port)
    clock = CreateObject("roTimespan")
    clock.Mark()
    transfer = invalid
    transferStartedMs = 0
    nextFlushMs = 0
    lastPersistMs = 0
    m.top.status = engine.Status()

    while true
        msg = wait(250, port)
        kind = type(msg)
        if kind = "roSGNodeEvent"
            if msg.getField() = "command"
                if Feralin__HandleCommand(engine, msg.getData()) then nextFlushMs = 0
                m.top.status = engine.Status()
            end if
        else if kind = "roUrlEvent" and transfer <> invalid
            if msg.GetSourceIdentity() = transfer.GetIdentity() and msg.GetInt() = 1
                code = msg.GetResponseCode()
                result = engine.OnResponse(code, Feralin_RetryAfterMs(msg.GetResponseHeaders()), clock.TotalMilliseconds())
                if config.debug then print "[feralin] batch "; result; " "; code
                transfer = invalid
                m.top.status = engine.Status()
            end if
        end if

        now = clock.TotalMilliseconds()
        if transfer <> invalid and now - transferStartedMs > config.requestTimeoutMs
            ' Yanıt gelmeyen istek iptal edilir ve ağ hatası sayılır; batch aynı Idempotency-Key ile yeniden denenir.
            transfer.AsyncCancel()
            transfer = invalid
            engine.OnResponse(0, 0, now)
        end if
        if transfer = invalid and now >= engine.notBefore and (now >= nextFlushMs or engine.queue.Count() >= config.batchSize or engine.inflight <> invalid)
            batch = engine.TakeBatch()
            if batch <> invalid
                transfer = Feralin__Post(config, batch.key, engine.BatchBody(batch), port)
                transferStartedMs = now
                if transfer = invalid then engine.OnResponse(0, 0, now)
            end if
            nextFlushMs = now + config.flushIntervalMs
        end if
        ' Kayıt bölümüne yazım sıklığı sınırlı tutulur (Roku önerisi); en geç 2 saniyede bir.
        if engine.dirty and now - lastPersistMs >= 2000
            engine.Persist()
            lastPersistMs = now
        end if
    end while
end sub

' Komutu işler; true dönerse kuyruk hemen gönderilmeye çalışılır.
function Feralin__HandleCommand(engine as Object, command as Dynamic) as Boolean
    if type(command) <> "roAssociativeArray" then return false
    kind = command.type
    if kind = "track"
        engine.Track(command.name, command.properties)
    else if kind = "screen"
        props = Feralin_SanitizeProperties(command.properties)
        if props = invalid then props = {}
        if type(command.name) = "String" or type(command.name) = "roString" then props.screen_name = command.name
        engine.Track("screen_view", props)
    else if kind = "trackRevenue"
        engine.TrackRevenue(command.input)
    else if kind = "identify"
        engine.Identify(command.userId)
    else if kind = "consent"
        engine.SetConsent(command.consent)
        engine.Persist()
    else if kind = "reset"
        engine.Reset()
        engine.Persist()
    else if kind = "flush"
        engine.Persist()
        return true
    end if
    return false
end function

' Batch'i eşzamansız gönderir; dönen nesne aktarım bitene kadar referansta tutulmalıdır. İstek kurulamazsa invalid.
function Feralin__Post(config as Object, idempotencyKey as String, body as String, port as Object) as Dynamic
    transfer = CreateObject("roUrlTransfer")
    transfer.SetUrl(config.collectUrl + "/v1/batch")
    if Left(config.collectUrl, 8) = "https://" then transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.AddHeader("Content-Type", "application/json")
    ' Yalnız public proje anahtarı; değer loglanmaz.
    transfer.AddHeader("X-Feralin-Project-Key", config.projectKey)
    transfer.AddHeader("Idempotency-Key", idempotencyKey)
    transfer.RetainBodyOnError(true)
    transfer.SetMessagePort(port)
    if not transfer.AsyncPostFromString(body) then return invalid
    return transfer
end function

' Feralin Roku SDK uygulama yüzü (render iş parçacığı). Sahne bileşeninizin XML dosyasına ekleyin:
'   <script type="text/brightscript" uri="pkg:/components/feralin/FeralinApi.brs" />
' Bu işlevler yalnız FeralinTask düğümünün alanlarına yazar; ağ ve kayıt bölümü Task iş parçacığındadır. Task düğümü genel düğümde
' (m.global.feralinTask) tutulur; böylece her bileşen aynı örneği kullanır.
'
' Kaynaklar:
'   Task düğümü ve control="RUN": https://developer.roku.com/dev/docs/task
'   Genel düğüm (m.global) ve addFields/setField: https://developer.roku.com/dev/docs/ifsgnodefield

' SDK'yı başlatır ve Task düğümünü döndürür. İkinci çağrı mevcut düğümü döndürür. Yapılandırma geçersizse Task çalışır ama
' status.initialized=false yazar ve olay üretmez.
function Feralin_Init(config as Object) as Object
    existing = Feralin__Task()
    if existing <> invalid then return existing
    task = CreateObject("roSGNode", "FeralinTask")
    task.config = config
    if m.global <> invalid
        if m.global.hasField("feralinTask")
            m.global.setField("feralinTask", task)
        else
            m.global.addFields({ feralinTask: task })
        end if
    end if
    m.feralinTask = task
    task.control = "RUN"
    return task
end function

function Feralin__Task() as Dynamic
    if m.feralinTask <> invalid then return m.feralinTask
    if m.global <> invalid
        if m.global.hasField("feralinTask")
            task = m.global.getField("feralinTask")
            if task <> invalid
                m.feralinTask = task
                return task
            end if
        end if
    end if
    return invalid
end function

sub Feralin__Send(command as Object)
    task = Feralin__Task()
    if task = invalid then return
    task.command = command
end sub

' Olay: ad snake_case (^[a-z][a-z0-9_]*$), özellik anahtarları ^[a-zA-Z][a-zA-Z0-9_]{0,63}$. Kişisel veri vermeyin.
sub Feralin_Track(name as String, properties = invalid as Dynamic)
    Feralin__Send({ type: "track", name: name, properties: properties })
end sub

' `screen_view` olayı; ekran adı `screen_name` özelliğindedir.
sub Feralin_Screen(name as String, properties = invalid as Dynamic)
    Feralin__Send({ type: "screen", name: name, properties: properties })
end sub

' `feralin_purchase` istemci beyanı: { transactionId, amountMinor (küçük birimde tam sayı), currency (ISO 4217), productId?, quantity?,
' purchaseType? }. Doğrulama yalnız sunucudadır.
sub Feralin_TrackRevenue(input as Object)
    Feralin__Send({ type: "trackRevenue", input: input })
end sub

' Uygulamanın kendi opak kullanıcı kimliği (1-128 karakter). E-posta ya da telefon vermeyin.
sub Feralin_Identify(userId as String)
    Feralin__Send({ type: "identify", userId: userId })
end sub

' İzin kararı: { analytics, advertising?, personalization?, session_replay? }. analytics=false kuyruğu ve kimlikleri siler.
sub Feralin_SetConsent(consent as Object)
    Feralin__Send({ type: "consent", consent: consent })
end sub

sub Feralin_OptOut()
    Feralin__Send({ type: "consent", consent: { analytics: false } })
end sub

' Çıkış: kullanıcı kimliği silinir, anonim kimlik ve oturum yenilenir.
sub Feralin_Reset()
    Feralin__Send({ type: "reset" })
end sub

' Kuyruğu hemen göndermeyi dener.
sub Feralin_Flush()
    Feralin__Send({ type: "flush" })
end sub

' Son durum: { initialized, sdk, version, queued, consent, sessionId, lastResult } ya da invalid.
function Feralin_Status() as Dynamic
    task = Feralin__Task()
    if task = invalid then return invalid
    return task.status
end function

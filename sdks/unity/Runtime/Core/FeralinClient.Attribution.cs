using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading;

namespace Feralin.Unity
{
    // Kurulum atfı: Android Play Install Referrer, bağlantı (App Link, Universal Link) ve iOS AdServices token'ı ile kurulum kimliği.
    // Kurallar Android ve Swift SDK'larla aynıdır. Parmak izi yoktur; iOS'ta kesin tekil atıf iddia edilmez.
    public sealed partial class FeralinClient
    {
        /// <summary>İlk açılış olayı adı (<c>app_first_open</c>).</summary>
        public const string FirstOpenEventName = "app_first_open";
        /// <summary>Bağlantıyla açılış olayı adı (<c>deep_link_opened</c>).</summary>
        public const string DeepLinkEventName = "deep_link_opened";

        internal const string MarkerFirstOpen = "first_open_event_id";
        internal const string MarkerFirstOpenAt = "first_open_at_ms";
        internal const string MarkerReferrerChecked = "referrer_checked";
        internal const string MarkerDeferredDeepLink = "deferred_deep_link";
        internal const string MarkerInstallId = "install_id";

        private IInstallReferrerSource _referrerSource;
        private bool _firstOpenStarted;
        private bool _followUpStarted;
        private DeepLink _pendingLink;
        private DateTimeOffset _pendingLinkAt;
        private AttributionParams _linkEvidence;
        private string _installId;

        /// <summary>
        /// Android'de Google Play Install Referrer'ı kurulumda bir kez okur ve <c>app_first_open</c> olayını üretir. Referrer yalnız
        /// analitik ve reklam izniyle okunur; izin yoksa ilk açılış kanıtsız (<c>attribution_source=none</c>) üretilir, reklam izni sonradan
        /// gelirse referrer o zaman bir kez okunur ve kanıt işaretli <c>deep_link_opened</c> ile taşınır. İşaretler kalıcı depoda tutulur;
        /// <see cref="FeralinOptions.Store"/> yoksa ilk açılış her başlatmada tekrarlanabileceğinden hiçbir şey yapılmaz.
        /// </summary>
        public void StartAttribution(IInstallReferrerSource source)
        {
            if (source == null)
            {
                return;
            }
            if (_store == null)
            {
                Warn("atıf: kalıcı depo yok, ilk açılış tekrarlanabileceğinden başlatılmadı");
                return;
            }
            lock (_gate)
            {
                _referrerSource = source;
            }
            ProcessAttribution();
        }

        /// <summary>
        /// Uygulama bağlantısını işler (<c>Application.deepLinkActivated</c>). Yalnız http(s) bağlantılar kanıt sayılır; sorgudan yalnız
        /// <c>fr_click</c>, <c>fr_dl</c> ve standart <c>utm_*</c> okunur, ham URL saklanmaz. Reklam izni yoksa olay kanıtsız (<c>none</c>) gider.
        /// İzin kararı verilmeden gelen bağlantı bellekte bekletilir.
        /// </summary>
        public void HandleDeepLink(string url)
        {
            var link = DeepLink.Parse(url);
            if (link == null)
            {
                return;
            }
            var at = _now();
            lock (_gate)
            {
                if (_closed)
                {
                    return;
                }
                if (!_consentDecided)
                {
                    _pendingLink = link;
                    _pendingLinkAt = at;
                    return;
                }
                if (!_consent.Analytics)
                {
                    return;
                }
            }
            EmitDeepLink(link, at);
        }

        /// <summary>
        /// Play Install Referrer'dan gelen ertelenmiş derin bağlantı yolunu bir kez teslim eder (yalnız <c>fr_click</c> ile birlikte gelen
        /// uygulama içi yol). Reklam izni yoksa ya da yol yoksa <c>null</c>.
        /// </summary>
        public string ConsumeDeferredDeepLink()
        {
            string path = null;
            lock (_gate)
            {
                if (_store == null || !_consent.Analytics || !EffectiveAdvertising(_consent))
                {
                    return null;
                }
                StoreCall(() => path = _store.GetMarker(MarkerDeferredDeepLink));
                if (path != null)
                {
                    StoreCall(() => _store.RemoveMarker(MarkerDeferredDeepLink));
                }
            }
            return string.IsNullOrEmpty(path) ? null : path;
        }

        /// <summary>
        /// iOS: AdServices token'ını kurulum kimliğiyle sunucuya iletir ve kimliği döndürür (ADR-0007). Reklam izni (analitik, reklam ve ATT)
        /// yoksa token alınmaz, kimlik üretilmez. Kimlik müşterinin kendi sunucusuna iletilir; hesap bağı yalnız oradan kurulur. Sunucu bugün
        /// Apple'a sormaz, token saklanır: sonuç kesin atıf değildir.
        /// </summary>
        public void BindInstall(IAdServicesTokenSource source, Action<InstallBinding> onComplete)
        {
            if (onComplete == null)
            {
                return;
            }
            if (_attributionApi == null || _projectId == null)
            {
                onComplete(new InstallBinding(InstallBindingStatus.NotConfigured, null));
                return;
            }
            if (!AdvertisingAllowedNow())
            {
                onComplete(new InstallBinding(InstallBindingStatus.SkippedNoConsent, null));
                return;
            }
            if (source == null)
            {
                onComplete(new InstallBinding(InstallBindingStatus.Unsupported, null));
                return;
            }
            var answered = 0;
            Action<AdServicesTokenResult> received = result =>
            {
                if (Interlocked.Exchange(ref answered, 1) != 0)
                {
                    return;
                }
                CompleteBind(result, onComplete);
            };
            try
            {
                source.GetToken(received);
            }
            catch (Exception ex)
            {
                Warn("AdServices token kaynağı hata verdi: " + ex.GetType().Name);
                received(AdServicesTokenResult.Failed());
            }
        }

        private bool AdvertisingAllowedNow()
        {
            lock (_gate)
            {
                return !_closed && _consent.Analytics && EffectiveAdvertising(_consent);
            }
        }

        private void CompleteBind(AdServicesTokenResult result, Action<InstallBinding> onComplete)
        {
            // Sonuç, gönderim sırasında izin geri çekildiyse kimlik içermez.
            Action<string> finish = status => SafeBind(onComplete, status, AdvertisingAllowedNow() ? ReadInstallId() : null);
            if (!AdvertisingAllowedNow())
            {
                SafeBind(onComplete, InstallBindingStatus.SkippedNoConsent, null);
                return;
            }
            if (result == null || result.Status == "failed")
            {
                finish(InstallBindingStatus.TokenUnavailable);
                return;
            }
            if (result.Status == "unsupported")
            {
                finish(InstallBindingStatus.Unsupported);
                return;
            }
            var installId = EnsureInstallId();
            var body = MiniJson.Write(new Dictionary<string, object>(StringComparer.Ordinal) { ["token"] = result.Token, ["install_id"] = installId });
            var url = _attributionApi + "/v1/projects/" + Uri.EscapeDataString(_projectId) + "/attribution/apple-adservices/tokens";
            var headers = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json, application/problem+json",
                ["Authorization"] = "Bearer " + _projectKey,
                ["User-Agent"] = SdkName + "/" + SdkVersion,
            };
            var responded = 0;
            Action<TransportResponse> onResponse = response =>
            {
                if (Interlocked.Exchange(ref responded, 1) != 0)
                {
                    return;
                }
                var status = response?.Status ?? 0;
                if (status == 202)
                {
                    finish(InstallBindingStatus.Received);
                }
                else if (status == 0 || status == 429 || status >= 500)
                {
                    finish(InstallBindingStatus.TemporaryFailure);
                }
                else
                {
                    Warn("AdServices token reddedildi: HTTP " + status.ToString(CultureInfo.InvariantCulture));
                    finish(InstallBindingStatus.Rejected);
                }
            };
            try
            {
                _transport.Send(new TransportRequest(url, Encoding.UTF8.GetBytes(body), headers, _timeout), onResponse);
            }
            catch (Exception ex)
            {
                WriteDebug("taşıyıcı hatası: " + ex.GetType().Name);
                onResponse(TransportResponse.NetworkError);
            }
        }

        private void SafeBind(Action<InstallBinding> onComplete, string status, string installId)
        {
            try
            {
                onComplete(new InstallBinding(status, installId));
            }
            catch (Exception ex)
            {
                Warn("geri çağrı hatası: " + ex.GetType().Name);
            }
        }

        // Kurulum kimliği rastgele ULID'dir, cihazdan türetilmez; yalnız reklam izniyle üretilir ve kalıcı depoda tutulur.
        private string EnsureInstallId()
        {
            lock (_gate)
            {
                if (_installId != null)
                {
                    return _installId;
                }
                string stored = null;
                if (_store != null)
                {
                    StoreCall(() => stored = _store.GetMarker(MarkerInstallId));
                }
                _installId = !string.IsNullOrEmpty(stored) && stored.Length == 26 ? stored : Ulid.New(_now());
                if (_store != null)
                {
                    var id = _installId;
                    StoreCall(() => _store.PutMarker(MarkerInstallId, id));
                }
                return _installId;
            }
        }

        private string ReadInstallId() => EnsureInstallId();

        // SetConsent sonrası: bekleyen bağlantı, ilk açılış ve izin geri çekildiyse atıf durumunun temizliği.
        private void OnConsentApplied()
        {
            DeepLink pending = null;
            var pendingAt = default(DateTimeOffset);
            bool analytics;
            lock (_gate)
            {
                analytics = _consent.Analytics;
                if (analytics)
                {
                    pending = _pendingLink;
                    pendingAt = _pendingLinkAt;
                }
                _pendingLink = null;
                if (!analytics)
                {
                    _linkEvidence = null;
                    _firstOpenStarted = false;
                    _followUpStarted = false;
                    _installId = null;
                }
                else if (!EffectiveAdvertising(_consent))
                {
                    // Reklam izni yoksa kanıt, kurulum kimliği ve ertelenmiş yol taşınmaz.
                    _linkEvidence = null;
                    _installId = null;
                    if (_store != null)
                    {
                        StoreCall(() => _store.RemoveMarker(MarkerInstallId));
                        StoreCall(() => _store.RemoveMarker(MarkerDeferredDeepLink));
                    }
                }
            }
            if (!analytics)
            {
                return;
            }
            if (pending != null)
            {
                EmitDeepLink(pending, pendingAt);
            }
            ProcessAttribution();
        }

        private void EmitDeepLink(DeepLink link, DateTimeOffset at)
        {
            bool advertising;
            lock (_gate)
            {
                advertising = EffectiveAdvertising(_consent);
                if (advertising && !link.Params.IsEmpty)
                {
                    _linkEvidence = link.Params;
                }
            }
            var props = new Dictionary<string, object>(StringComparer.Ordinal);
            if (advertising)
            {
                props["attribution_source"] = AttributionSource.AppLink;
                link.Params.WriteTo(props);
            }
            else
            {
                // İzin yoksa atıf yoktur: açılış sayılır, kanıt gönderilmez.
                props["attribution_source"] = AttributionSource.None;
            }
            TrackWithPage(DeepLinkEventName, props, new TrackOptions { OccurredAt = at }, link.CleanUrl);
        }

        private TrackedEvent TrackWithPage(string eventName, IEnumerable<KeyValuePair<string, object>> props, TrackOptions options, string pageUrl)
        {
            try
            {
                return BuildAndEnqueue(eventName, props, options, pageUrl);
            }
            catch (Exception ex)
            {
                Warn("olay üretilemedi: " + ex.GetType().Name);
                return null;
            }
        }

        private void ProcessAttribution()
        {
            IInstallReferrerSource source;
            bool advertising;
            var startFirstOpen = false;
            var startFollowUp = false;
            lock (_gate)
            {
                source = _referrerSource;
                if (source == null || _store == null || _closed || !_consentDecided || !_consent.Analytics)
                {
                    return;
                }
                advertising = EffectiveAdvertising(_consent);
                string firstOpen = null;
                string checkedMarker = null;
                StoreCall(() =>
                {
                    firstOpen = _store.GetMarker(MarkerFirstOpen);
                    checkedMarker = _store.GetMarker(MarkerReferrerChecked);
                });
                if (firstOpen == null)
                {
                    if (_firstOpenStarted)
                    {
                        return;
                    }
                    _firstOpenStarted = true;
                    startFirstOpen = true;
                }
                else if (advertising && checkedMarker == null && !_followUpStarted)
                {
                    _followUpStarted = true;
                    startFollowUp = true;
                }
            }
            if (startFirstOpen)
            {
                var at = _now();
                if (advertising)
                {
                    ReadReferrer(source, raw => CompleteFirstOpen(at, raw));
                }
                else
                {
                    CompleteFirstOpen(at, null);
                }
            }
            else if (startFollowUp)
            {
                ReadReferrer(source, CompleteFollowUp);
            }
        }

        private void ReadReferrer(IInstallReferrerSource source, Action<string> onResult)
        {
            var settled = 0;
            Action<string> once = raw =>
            {
                if (Interlocked.Exchange(ref settled, 1) == 0)
                {
                    onResult(raw);
                }
            };
            try
            {
                source.Read(once);
            }
            catch (Exception ex)
            {
                // Referrer kütüphanesi uygulamadan çıkarılmışsa ya da servis yoksa kanıt yoktur.
                WriteDebug("referrer okunamadı: " + ex.GetType().Name);
                once(null);
            }
        }

        private void CompleteFirstOpen(DateTimeOffset at, string raw)
        {
            bool advertising;
            AttributionParams link;
            lock (_gate)
            {
                if (_closed || !_consent.Analytics)
                {
                    // İzin okuma sırasında geri çekildi: işaret yazılmadı, sonraki onayda yeniden denenir.
                    _firstOpenStarted = false;
                    return;
                }
                advertising = EffectiveAdvertising(_consent);
                link = _linkEvidence;
            }
            var referrer = advertising && raw != null ? AttributionParams.ParseQuery(raw) : null;
            var props = new Dictionary<string, object>(StringComparer.Ordinal);
            if (advertising && referrer != null && !referrer.IsEmpty && !referrer.IsPlayOrganicDefault)
            {
                props["attribution_source"] = AttributionSource.PlayInstallReferrer;
                referrer.WriteTo(props);
            }
            else if (advertising && link != null)
            {
                props["attribution_source"] = AttributionSource.AppLink;
                link.WriteTo(props);
            }
            else
            {
                props["attribution_source"] = AttributionSource.None;
            }
            var tracked = TrackWithPage(FirstOpenEventName, props, new TrackOptions { OccurredAt = at }, null);
            if (tracked == null)
            {
                lock (_gate)
                {
                    _firstOpenStarted = false;
                }
                return;
            }
            lock (_gate)
            {
                StoreCall(() =>
                {
                    _store.PutMarker(MarkerFirstOpen, tracked.EventId);
                    // Sonradan gelen izinde bakış penceresi gerçek ilk açılışa göre işlesin: izin anı kanıtın yaşını değiştirmemeli.
                    _store.PutMarker(MarkerFirstOpenAt, Millis(at));
                    if (advertising)
                    {
                        _store.PutMarker(MarkerReferrerChecked, "1");
                        if (referrer?.DeepLinkPath != null)
                        {
                            _store.PutMarker(MarkerDeferredDeepLink, referrer.DeepLinkPath);
                        }
                    }
                });
            }
        }

        private void CompleteFollowUp(string raw)
        {
            lock (_gate)
            {
                _followUpStarted = false;
                if (_closed || !_consent.Analytics || !EffectiveAdvertising(_consent))
                {
                    return;
                }
            }
            var referrer = raw == null ? null : AttributionParams.ParseQuery(raw);
            if (referrer == null || referrer.IsEmpty || referrer.IsPlayOrganicDefault)
            {
                StoreCall(() => _store.PutMarker(MarkerReferrerChecked, "1"));
                return;
            }
            var props = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["attribution_source"] = AttributionSource.PlayInstallReferrer,
                ["consent_followup"] = true,
            };
            string firstOpenAt = null;
            StoreCall(() => firstOpenAt = _store.GetMarker(MarkerFirstOpenAt));
            if (long.TryParse(firstOpenAt, NumberStyles.Integer, CultureInfo.InvariantCulture, out var millis))
            {
                props["first_open_at"] = FormatMillis(millis);
            }
            referrer.WriteTo(props);
            var tracked = TrackWithPage(DeepLinkEventName, props, null, null);
            if (tracked == null)
            {
                return;
            }
            StoreCall(() =>
            {
                _store.PutMarker(MarkerReferrerChecked, "1");
                if (referrer.DeepLinkPath != null)
                {
                    _store.PutMarker(MarkerDeferredDeepLink, referrer.DeepLinkPath);
                }
            });
        }
    }
}

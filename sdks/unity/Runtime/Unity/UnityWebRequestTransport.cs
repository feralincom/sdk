#if UNITY_5_3_OR_NEWER
using System;
using System.IO;
using System.Text;
using UnityEngine.Networking;

namespace Feralin.Unity
{
    /// <summary>
    /// UnityWebRequest taşıyıcısı. Unity bu API'yi yalnız ana iş parçacığında kabul eder; <see cref="FeralinBehaviour"/> Tick ve
    /// Flush'ı ana iş parçacığından çağırır. Başka iş parçacığından çağrı ağ hatası sayılır, olay kuyrukta kalır.
    /// </summary>
    public sealed class UnityWebRequestTransport : IFeralinTransport
    {
        // Toplayıcı yanıtı küçük bir onaydır; bozuk veya kötü niyetli sunucu oyunun belleğini dolduramaz.
        private const int MaxResponseBytes = 64 * 1024;

#if !UNITY_WEBGL || UNITY_EDITOR
        /// <summary>Sınır aşılınca indirmeyi keser. Yanıt sonucu bilinmeyen sayılır, batch aynı anahtarla yeniden denenir.</summary>
        private sealed class LimitedDownloadHandler : DownloadHandlerScript
        {
            private readonly MemoryStream _body = new MemoryStream();

            public LimitedDownloadHandler()
                : base(new byte[4096])
            {
            }

            public bool Exceeded { get; private set; }

            // DownloadHandlerScript'in temel text özelliği bu sınıfla boş dönüyor (Unity 6000.0 PlayMode testi); gövde buradan okunur.
            public string Body => Encoding.UTF8.GetString(_body.GetBuffer(), 0, (int)_body.Length);

            protected override bool ReceiveData(byte[] data, int dataLength)
            {
                if (_body.Length + dataLength > MaxResponseBytes)
                {
                    Exceeded = true;
                    return false;
                }
                _body.Write(data, 0, dataLength);
                return true;
            }

            protected override byte[] GetData() => _body.ToArray();
        }
#endif

        /// <inheritdoc />
        public void Send(TransportRequest request, Action<TransportResponse> onComplete)
        {
            // Kısa link çözümlemesi gövdesiz GET'tir; diğer bütün istekler POST.
            var get = request.Method == "GET";
            var web = new UnityWebRequest(request.Url, get ? UnityWebRequest.kHttpVerbGET : UnityWebRequest.kHttpVerbPOST)
            {
                // Yönlendirme izlenmez: proje anahtarı başka adrese gitmesin.
                redirectLimit = 0,
                uploadHandler = get ? null : new UploadHandlerRaw(request.Body),
#if UNITY_WEBGL && !UNITY_EDITOR
                // Tarayıcıda akış okunamaz, yanıt alındıktan sonra boyutuna bakılır.
                downloadHandler = new DownloadHandlerBuffer(),
#else
                downloadHandler = new LimitedDownloadHandler(),
#endif
                timeout = Math.Max(1, (int)Math.Ceiling(request.Timeout.TotalSeconds)),
            };
            foreach (var header in request.Headers)
            {
#if UNITY_WEBGL && !UNITY_EDITOR
                // Tarayıcı User-Agent başlığının değiştirilmesine izin vermez.
                if (header.Key == "User-Agent")
                {
                    continue;
                }
#endif
                web.SetRequestHeader(header.Key, header.Value);
            }
            web.SendWebRequest().completed += _ =>
            {
                TransportResponse response;
                if (web.result == UnityWebRequest.Result.ConnectionError || web.result == UnityWebRequest.Result.DataProcessingError || ExceededLimit(web))
                {
                    // Sonuç bilinmiyor: batch aynı anahtarla yeniden denenir.
                    response = TransportResponse.NetworkError;
                }
                else
                {
                    response = new TransportResponse((int)web.responseCode, ResponseBody(web), web.GetResponseHeader("Retry-After"));
                }
                web.Dispose();
                onComplete(response);
            };
        }

        private static string ResponseBody(UnityWebRequest web)
        {
#if UNITY_WEBGL && !UNITY_EDITOR
            return web.downloadHandler?.text;
#else
            return (web.downloadHandler as LimitedDownloadHandler)?.Body;
#endif
        }

        private static bool ExceededLimit(UnityWebRequest web)
        {
#if UNITY_WEBGL && !UNITY_EDITOR
            return web.downloadedBytes > MaxResponseBytes;
#else
            return web.downloadHandler is LimitedDownloadHandler limited && limited.Exceeded;
#endif
        }
    }
}
#endif

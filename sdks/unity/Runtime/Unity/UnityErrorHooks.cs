#if UNITY_5_3_OR_NEWER
using System;
using System.Threading.Tasks;
using UnityEngine;

namespace Feralin.Unity
{
    /// <summary>
    /// Unity hata kancaları: <c>Application.logMessageReceivedThreaded</c> (istisna kayıtları; isteğe bağlı hata ve assert kayıtları),
    /// <c>AppDomain.UnhandledException</c> ve <c>TaskScheduler.UnobservedTaskException</c>. Hepsi <see cref="FeralinClient.CaptureError"/> üzerinden
    /// geçer: kişisel veri temizliği, parmak izi özeti, örnekleme ve hız sınırı çekirdektedir. Kancalar oyuna istisna fırlatmaz.
    /// </summary>
    public sealed class UnityErrorHooks : IDisposable
    {
        private readonly FeralinClient _client;
        private readonly bool _captureErrorLogs;
        private bool _disposed;

        /// <summary>Kancaları bağlar. <paramref name="captureErrorLogs"/> <c>true</c> ise <c>Debug.LogError</c> ve assert kayıtları da alınır.</summary>
        public UnityErrorHooks(FeralinClient client, bool captureErrorLogs = false)
        {
            _client = client ?? throw new ArgumentNullException(nameof(client));
            _captureErrorLogs = captureErrorLogs;
            Application.logMessageReceivedThreaded += OnLog;
            AppDomain.CurrentDomain.UnhandledException += OnUnhandled;
            TaskScheduler.UnobservedTaskException += OnUnobserved;
        }

        /// <summary>Kancaları söker.</summary>
        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            Application.logMessageReceivedThreaded -= OnLog;
            AppDomain.CurrentDomain.UnhandledException -= OnUnhandled;
            TaskScheduler.UnobservedTaskException -= OnUnobserved;
        }

        private void OnLog(string condition, string stackTrace, LogType type)
        {
            try
            {
                // SDK'nın kendi günlükleri hata sayılmaz (döngü olmasın).
                if (condition != null && condition.StartsWith("[Feralin]", StringComparison.Ordinal))
                {
                    return;
                }
                if (type == LogType.Exception)
                {
                    SplitException(condition, out var errorType, out var message);
                    _client.CaptureError(errorType, message, stackTrace, false, ErrorSource.LogException);
                }
                else if (_captureErrorLogs && (type == LogType.Error || type == LogType.Assert))
                {
                    _client.CaptureError(type.ToString(), condition, stackTrace, true, ErrorSource.LogError);
                }
            }
            catch (Exception)
            {
                // Günlük kancası oyunu düşürmez.
            }
        }

        private void OnUnhandled(object sender, UnhandledExceptionEventArgs args)
        {
            if (args.ExceptionObject is Exception exception)
            {
                Capture(exception, ErrorSource.UnhandledException);
            }
        }

        private void OnUnobserved(object sender, UnobservedTaskExceptionEventArgs args)
        {
            Capture(args.Exception, ErrorSource.UnobservedTask);
        }

        private void Capture(Exception exception, string source)
        {
            try
            {
                var root = exception is AggregateException aggregate ? aggregate.GetBaseException() : exception;
                // Unity istisna kayıtlarındaki kısa tür adıyla aynı parmak izi çıksın.
                _client.CaptureError(root.GetType().Name, root.Message, root.StackTrace, false, source);
            }
            catch (Exception)
            {
                // Kanca oyunu düşürmez.
            }
        }

        // Unity istisna kaydı: "NullReferenceException: ileti". Türü ve iletiyi ayırır.
        internal static void SplitException(string condition, out string errorType, out string message)
        {
            errorType = "Exception";
            message = condition ?? "";
            var colon = message.IndexOf(": ", StringComparison.Ordinal);
            if (colon > 0 && colon <= 120 && message.IndexOf(' ', 0, colon) < 0)
            {
                errorType = message.Substring(0, colon);
                message = message.Substring(colon + 2);
            }
        }
    }
}
#endif

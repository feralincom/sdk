using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Feralin.AspNetCore;

/// <summary>ASP.NET Core kaydı: tekil <see cref="FeralinClient"/> ve kapanışta gönderim.</summary>
public static class FeralinServiceCollectionExtensions
{
    /// <summary>
    /// <see cref="FeralinClient"/> tekil olarak eklenir; <c>ILogger</c> günlüğe bağlanır, uygulama kapanırken kuyruk gönderilir.
    /// Anahtarı yapılandırmadan okuyun, kaynak koda yazmayın.
    /// </summary>
    public static IServiceCollection AddFeralin(this IServiceCollection services, Action<FeralinOptions> configure)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configure);
        services.TryAddSingleton(provider =>
        {
            var options = new FeralinOptions();
            configure(options);
            if (options.Log is null)
            {
                var logger = provider.GetService<ILoggerFactory>()?.CreateLogger("Feralin");
                if (logger is not null)
                {
                    options.Log = (level, message) => logger.Log(level == FeralinLogLevel.Warning ? LogLevel.Warning : LogLevel.Debug, "{FeralinMessage}", message);
                }
            }
            return new FeralinClient(options);
        });
        services.AddHostedService<FeralinShutdownService>();
        return services;
    }

    private sealed class FeralinShutdownService : IHostedService
    {
        private readonly FeralinClient _client;

        public FeralinShutdownService(FeralinClient client) => _client = client;

        public Task StartAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task StopAsync(CancellationToken cancellationToken) => _client.CloseAsync();
    }
}

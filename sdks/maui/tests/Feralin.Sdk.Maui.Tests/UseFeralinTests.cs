using System.Net;
using System.Text;
using Feralin.Maui;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Maui.Hosting;
using Xunit;

namespace Feralin.Maui.Tests;

internal sealed class RecordingHandler : HttpMessageHandler
{
    private readonly object _gate = new();
    private readonly TaskCompletionSource _first = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public List<string> Keys { get; } = new();
    public List<string> Bodies { get; } = new();
    public Task FirstRequest => _first.Task;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = await request.Content!.ReadAsStringAsync(cancellationToken);
        lock (_gate)
        {
            Keys.Add(request.Headers.GetValues("x-feralin-project-key").Single());
            Bodies.Add(body);
        }
        _first.TrySetResult();
        return new HttpResponseMessage(HttpStatusCode.Accepted)
        {
            Content = new StringContent("{\"batch_id\":\"b1\",\"accepted\":1,\"rejected\":0}", Encoding.UTF8, "application/json"),
        };
    }
}

internal sealed class CapturingLoggerProvider : ILoggerProvider, ILogger
{
    public List<string> Lines { get; } = new();
    public ILogger CreateLogger(string categoryName) => this;
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(LogLevel logLevel) => true;
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter) => Lines.Add(formatter(state, exception));
    public void Dispose()
    {
    }
}

public class UseFeralinTests
{
    private const string Key = "pk_test_maui_key_0001";
    private readonly RecordingHandler _handler = new();

    private MauiApp Build(bool consented = true, Action<MauiAppBuilder>? edit = null, string key = Key, Action<FeralinOptions>? configure = null)
    {
        var builder = MauiApp.CreateBuilder(useDefaults: false);
        builder.UseFeralin(options =>
        {
            options.ProjectKey = key;
            options.CollectUrl = "https://collect.example.test";
            options.Consent = consented ? new Consent(true) : null;
            options.FlushInterval = TimeSpan.Zero;
            options.HttpHandler = _handler;
            configure?.Invoke(options);
        });
        edit?.Invoke(builder);
        return builder.Build();
    }

    [Fact]
    public async Task RegistersSingletonThatSendsWithProjectKey()
    {
        using var app = Build();
        var client = app.Services.GetRequiredService<FeralinClient>();
        Assert.Same(client, app.Services.GetRequiredService<FeralinClient>());
        Assert.NotNull(client.Track("screen_view"));
        var result = await client.FlushAsync();
        Assert.Equal(202, result.Status);
        Assert.Equal(Key, Assert.Single(_handler.Keys));
    }

    [Theory]
    [InlineData("sk_live_secret_0001")]
    [InlineData("gecersiz")]
    public void InvalidKeyFailsDuringBuildNotLater(string key)
    {
        var error = Assert.Throws<ArgumentException>(() => Build(key: key));
        Assert.DoesNotContain(key, error.Message);
    }

    [Fact]
    public void WithoutConsentNoEventIsProduced()
    {
        using var app = Build(consented: false);
        Assert.Null(app.Services.GetRequiredService<FeralinClient>().Track("screen_view"));
    }

    [Fact]
    public async Task BackgroundFlushesQueueWithoutCaller()
    {
        using var app = Build();
        app.Services.GetRequiredService<FeralinClient>().Track("screen_view");
        app.Services.GetRequiredService<FeralinLifecycle>().OnBackground();
        await _handler.FirstRequest.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Single(_handler.Bodies);
    }

    [Fact]
    public async Task ForegroundFlushesQueueWithoutCaller()
    {
        using var app = Build();
        app.Services.GetRequiredService<FeralinClient>().Track("screen_view");
        app.Services.GetRequiredService<FeralinLifecycle>().OnForeground();
        await _handler.FirstRequest.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Single(_handler.Bodies);
    }

    [Fact]
    public void LifecycleAfterDisposeDoesNotThrow()
    {
        var app = Build();
        var lifecycle = app.Services.GetRequiredService<FeralinLifecycle>();
        app.Dispose();
        lifecycle.OnBackground();
        lifecycle.OnForeground();
    }

    [Fact]
    public void DisposingAppSendsRemainingEvents()
    {
        var app = Build();
        app.Services.GetRequiredService<FeralinClient>().Track("screen_view");
        app.Dispose();
        Assert.Single(_handler.Bodies);
    }

    [Fact]
    public void SecondUseFeralinKeepsFirstRegistration()
    {
        var other = new RecordingHandler();
        using var app = Build(edit: builder => builder.UseFeralin(options =>
        {
            options.ProjectKey = "pk_test_other_key_002";
            options.CollectUrl = "https://other.example.test";
            options.HttpHandler = other;
        }));
        var status = app.Services.GetRequiredService<FeralinClient>().GetStatus();
        Assert.StartsWith("https://collect.example.test", status.Endpoint);
        Assert.Single(app.Services.GetServices<FeralinClient>());
    }

    [Fact]
    public void LogsGoThroughILoggerWithoutKey()
    {
        var provider = new CapturingLoggerProvider();
        using var app = Build(edit: builder => builder.Logging.AddProvider(provider));
        Assert.Null(app.Services.GetRequiredService<FeralinClient>().Track("GECERSIZ AD"));
        Assert.Contains(provider.Lines, line => line.Contains("geçersiz olay adı"));
        Assert.All(provider.Lines, line => Assert.DoesNotContain(Key, line));
    }

    [Fact]
    public void AppSuppliedLogIsNotReplaced()
    {
        var lines = new List<string>();
        var builder = MauiApp.CreateBuilder(useDefaults: false);
        builder.UseFeralin(options =>
        {
            options.ProjectKey = Key;
            options.CollectUrl = "https://collect.example.test";
            options.FlushInterval = TimeSpan.Zero;
            options.Consent = new Consent(true);
            options.Log = (_, message) => lines.Add(message);
        });
        using var app = builder.Build();
        app.Services.GetRequiredService<FeralinClient>().Track("GECERSIZ AD");
        Assert.NotEmpty(lines);
    }

    [Fact]
    public async Task IdentityRevenueAndErrorMethodsReachCollector()
    {
        using var app = Build(configure: options => options.AppVersion = "3.1.0");
        var client = app.Services.GetRequiredService<FeralinClient>();
        Assert.NotNull(client.Group("acme-team", new Dictionary<string, object?> { ["plan"] = "team" }));
        Assert.NotNull(client.SetUserProperties(new Dictionary<string, object?> { ["plan"] = "pro", ["email"] = "a@b.co" }));
        Assert.NotNull(client.TrackRevenue(new RevenueInput("ord_1", 4999, "TRY") { Properties = new Dictionary<string, object?> { ["verified"] = true } }));
        TrackedEvent? error = null;
        try
        {
            throw new InvalidOperationException("ödeme ekranı açılamadı");
        }
        catch (Exception ex)
        {
            error = client.CaptureError(ex);
        }
        Assert.NotNull(error);
        await client.FlushAsync();
        using var body = System.Text.Json.JsonDocument.Parse(Assert.Single(_handler.Bodies));
        var events = body.RootElement.GetProperty("events").EnumerateArray().ToArray();
        Assert.Equal(new[] { "fr_group", "fr_user_properties", "feralin_purchase", "fr_error" }, events.Select(e => e.GetProperty("event_name").GetString()));
        Assert.False(events[1].GetProperty("properties").TryGetProperty("email", out _));
        Assert.False(events[2].GetProperty("properties").TryGetProperty("verified", out _));
        var errorProps = events[3].GetProperty("properties");
        Assert.Equal("InvalidOperationException", errorProps.GetProperty("error_type").GetString());
        Assert.Equal("3.1.0", errorProps.GetProperty("app_version").GetString());
        Assert.Equal("dotnet", events[3].GetProperty("platform").GetString());
    }

    [Fact]
    public async Task InstallCodeGoesOnFirstEventOnly()
    {
        using var app = Build(configure: options => options.InstallCode = "7K3M-9QX2-PR");
        var client = app.Services.GetRequiredService<FeralinClient>();
        client.Track("app_open");
        client.Track("screen_view");
        await client.FlushAsync();
        using var body = System.Text.Json.JsonDocument.Parse(Assert.Single(_handler.Bodies));
        var events = body.RootElement.GetProperty("events");
        Assert.Equal("7K3M-9QX2-PR", events[0].GetProperty("properties").GetProperty("fr_install_code").GetString());
        Assert.False(events[1].TryGetProperty("properties", out var second) && second.TryGetProperty("fr_install_code", out _));
    }

    [Fact]
    public void NullArgumentsAreRejected()
    {
        Assert.Throws<ArgumentNullException>(() => FeralinMauiExtensions.UseFeralin(null!, _ => { }));
        Assert.Throws<ArgumentNullException>(() => MauiApp.CreateBuilder(useDefaults: false).UseFeralin(null!));
        Assert.Throws<ArgumentNullException>(() => new FeralinLifecycle(null!));
    }
}

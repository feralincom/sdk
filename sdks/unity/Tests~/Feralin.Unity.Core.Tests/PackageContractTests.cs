using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using Xunit;

namespace Feralin.Unity.Core.Tests;

/// <summary>UPM paketinin Unity olmadan denetlenebilen kuralları: Unity .meta dosyası olmayan varlığı salt okunur pakette yok sayar.</summary>
public class PackageContractTests
{
    private static string Root([CallerFilePath] string self = "") => Path.GetFullPath(Path.Combine(Path.GetDirectoryName(self)!, "..", ".."));

    private static IEnumerable<string> Assets()
    {
        var root = Root();
        foreach (var top in new[] { "Runtime", "Tests", "Editor" })
        {
            var folder = Path.Combine(root, top);
            yield return folder;
            foreach (var entry in Directory.EnumerateFileSystemEntries(folder, "*", SearchOption.AllDirectories))
            {
                if (!entry.EndsWith(".meta", StringComparison.Ordinal))
                {
                    yield return entry;
                }
            }
        }
        foreach (var file in new[] { "package.json", "README.md", "CHANGELOG.md", "LICENSE.md" })
        {
            yield return Path.Combine(root, file);
        }
    }

    [Fact]
    public void EveryAssetHasMetaWithUniqueGuid()
    {
        var seen = new HashSet<string>();
        foreach (var asset in Assets())
        {
            var meta = asset + ".meta";
            Assert.True(File.Exists(meta), $".meta yok: {asset}");
            var guid = Regex.Match(File.ReadAllText(meta), "^guid: ([0-9a-f]{32})$", RegexOptions.Multiline);
            Assert.True(guid.Success, $"guid yok: {meta}");
            Assert.True(seen.Add(guid.Groups[1].Value), $"guid tekrarı: {meta}");
        }
    }

    [Fact]
    public void NoOrphanMeta()
    {
        foreach (var meta in Directory.EnumerateFiles(Root(), "*.meta", SearchOption.AllDirectories))
        {
            if (meta.Contains("Tests~"))
            {
                continue;
            }
            var asset = meta[..^".meta".Length];
            Assert.True(File.Exists(asset) || Directory.Exists(asset), $"sahipsiz .meta: {meta}");
        }
    }

    [Fact]
    public void ManifestAndAsmdefAreValid()
    {
        var root = Root();
        var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "package.json"))).RootElement;
        Assert.Equal("com.feralin.unity", manifest.GetProperty("name").GetString());
        Assert.Equal(FeralinClient.SdkVersion, manifest.GetProperty("version").GetString());
        Assert.Equal("1.0.0", manifest.GetProperty("dependencies").GetProperty("com.unity.modules.unitywebrequest").GetString());
        var asmdef = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "Runtime", "Feralin.Unity.asmdef"))).RootElement;
        Assert.Equal("Feralin.Unity", asmdef.GetProperty("name").GetString());
    }

    [Fact]
    public void CoreHasNoEngineOrUnavailableDependencies()
    {
        foreach (var file in Directory.EnumerateFiles(Path.Combine(Root(), "Runtime", "Core"), "*.cs"))
        {
            var text = File.ReadAllText(file);
            Assert.DoesNotContain("using UnityEngine", text);
            Assert.DoesNotContain("using System.Text.Json", text);
            Assert.DoesNotContain("new Thread", text);
            Assert.DoesNotContain("deviceUniqueIdentifier", text);
        }
    }

    [Fact]
    public void EngineFilesAreGuarded()
    {
        foreach (var file in Directory.EnumerateFiles(Path.Combine(Root(), "Runtime", "Unity"), "*.cs"))
        {
            Assert.StartsWith("#if UNITY_5_3_OR_NEWER", File.ReadAllText(file));
            Assert.DoesNotContain("deviceUniqueIdentifier", File.ReadAllText(file));
        }
    }

    [Fact]
    public void NativePluginsAreImportedOnlyForTheirPlatform()
    {
        var plugins = Path.Combine(Root(), "Runtime", "Plugins");
        var android = File.ReadAllText(Path.Combine(plugins, "Android", "FeralinKeystore.java.meta"));
        var ios = File.ReadAllText(Path.Combine(plugins, "iOS", "FeralinNative.mm.meta"));
        Assert.Contains("PluginImporter:", android);
        Assert.Matches(@"(?s)Android: Android\s+second:\s+enabled: 1", android);
        Assert.Matches(@"(?s)Editor: Editor\s+second:\s+enabled: 0", android);
        Assert.DoesNotContain("iPhone:", android);
        Assert.Contains("PluginImporter:", ios);
        Assert.Matches(@"(?s)iPhone: iOS\s+second:\s+enabled: 1", ios);
        Assert.Matches(@"(?s)Editor: Editor\s+second:\s+enabled: 0", ios);
        Assert.DoesNotContain("Android:", ios);
    }

    [Fact]
    public void ManifestShipsEditorDependenciesAndNativePlugins()
    {
        var root = Root();
        var files = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "package.json"))).RootElement.GetProperty("files").EnumerateArray().Select(f => f.GetString()).ToArray();
        Assert.Contains("Editor", files);
        Assert.Contains("Editor.meta", files);
        Assert.Contains("Runtime", files);
        var dependencies = File.ReadAllText(Path.Combine(root, "Editor", "FeralinDependencies.xml"));
        Assert.Contains("com.android.installreferrer:installreferrer:2.2", dependencies);
    }

    [Fact]
    public void NativeBridgesNeverReadDeviceIdentifiers()
    {
        var plugins = Path.Combine(Root(), "Runtime", "Plugins");
        foreach (var file in Directory.EnumerateFiles(plugins, "*", SearchOption.AllDirectories).Where(f => !f.EndsWith(".meta", StringComparison.Ordinal)))
        {
            var text = File.ReadAllText(file);
            Assert.DoesNotContain("advertisingIdentifier", text);
            Assert.DoesNotContain("identifierForVendor", text);
            Assert.DoesNotContain("ANDROID_ID", text);
            Assert.DoesNotContain("getAdvertisingIdInfo", text);
        }
    }
}

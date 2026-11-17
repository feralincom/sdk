using UnrealBuildTool;

public class Feralin : ModuleRules
{
	public Feralin(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"DeveloperSettings",
			"HTTP"
		});

		if (Target.Platform == UnrealTargetPlatform.Android)
		{
			// JNI (FAndroidApplication) Launch modülündedir; Keystore ve Install Referrer köprüsü Feralin_UPL.xml ile gradle'a eklenir.
			PrivateDependencyModuleNames.Add("Launch");
			string PluginPath = Utils.MakePathRelativeTo(ModuleDirectory, Target.RelativeEnginePath);
			AdditionalPropertiesForReceipt.Add("AndroidPlugin", System.IO.Path.Combine(PluginPath, "Private/Android/Feralin_UPL.xml"));
		}
		else if (Target.Platform == UnrealTargetPlatform.IOS)
		{
			// FeralinNative.mm: Keychain için Security; AdServices ve AppTrackingTransparency çalışma zamanında yüklenir.
			PublicFrameworks.Add("Security");
		}
	}
}

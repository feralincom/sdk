// Paketleme öncesi yerel çekirdekleri eklentiye kopyalar; hiçbir registry'ye yükleme yapmaz.
//   iOS:     sdks/swift/Sources/Feralin → ios/Sources/Feralin (Package.swift `Feralin` hedefi, podspec kaynakları)
//   Android: sdks/android `:feralin:publishReleasePublicationToLocalVendorRepository` → android/maven-repo (build.gradle yerel depo)
// Ortak iOS köprüsü (FeralinBridge.swift) sdks/cordova ile birebir aynı olmalıdır; farklıysa betik durur.
// Kullanım: node scripts/vendor.mjs [--ios-only | --android-only]
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const sdks = join(root, "..");
const args = new Set(process.argv.slice(2));

function fail(message) {
  console.error(`HATA: ${message}`);
  process.exit(1);
}

function checkSharedBridge() {
  const own = readFileSync(join(root, "ios/Sources/FeralinCapacitorPlugin/FeralinBridge.swift"), "utf8");
  const cordova = readFileSync(join(sdks, "cordova/src/ios/Plugin/FeralinBridge.swift"), "utf8");
  if (own !== cordova) fail("FeralinBridge.swift sdks/cordova kopyasıyla aynı değil");
}

function vendorSwift() {
  const source = join(sdks, "swift/Sources/Feralin");
  const target = join(root, "ios/Sources/Feralin");
  if (!existsSync(source)) fail(`Swift çekirdeği bulunamadı: ${source}`);
  rmSync(target, { recursive: true, force: true });
  cpSync(source, target, { recursive: true });
  if (!existsSync(join(target, "Resources/PrivacyInfo.xcprivacy"))) fail("PrivacyInfo.xcprivacy kopyalanmadı");
  const files = readdirSync(target).filter((name) => name.endsWith(".swift"));
  console.log(`iOS çekirdeği kopyalandı: ${files.length} Swift dosyası → ${target}`);
}

function vendorAndroid() {
  const android = join(sdks, "android");
  const repo = join(root, "android/maven-repo");
  const env = { ...process.env };
  // local.properties depoda yoktur; ANDROID_HOME verilmediyse Android Studio'nun varsayılan SDK dizini denenir.
  const studioSdk = process.env.LOCALAPPDATA ? join(process.env.LOCALAPPDATA, "Android", "Sdk") : join(process.env.HOME ?? "", "Android", "Sdk");
  if (!env.ANDROID_HOME && !env.ANDROID_SDK_ROOT && existsSync(studioSdk)) env.ANDROID_HOME = studioSdk;
  rmSync(repo, { recursive: true, force: true });
  const gradlew = process.platform === "win32" ? "cmd.exe" : "./gradlew";
  // cmd.exe geçerli dizini aramayabilir (NoDefaultCurrentDirectoryInExePath); tam yol verilir.
  const prefix = process.platform === "win32" ? ["/d", "/c", join(android, "gradlew.bat")] : [];
  const result = spawnSync(gradlew, [...prefix, ":feralin:publishReleasePublicationToLocalVendorRepository", `-PferalinVendorRepo=${repo}`, "--console=plain", "-q"], {
    cwd: android,
    stdio: "inherit",
    env,
  });
  if (result.status !== 0) fail("Android çekirdeği yerel depoya yazılamadı");
  const props = readFileSync(join(android, "gradle.properties"), "utf8");
  const version = /^feralinVersion=(.+)$/m.exec(props)?.[1]?.trim();
  const gradle = readFileSync(join(root, "android/build.gradle"), "utf8");
  if (!gradle.includes(`def feralinCoreVersion = "${version}"`)) fail(`android/build.gradle çekirdek sürümü ${version} değil`);
  if (!existsSync(join(repo, `com/feralin/android/${version}/android-${version}.aar`))) fail("yerel depoda AAR yok");
  console.log(`Android çekirdeği yerel depoda: ${repo}`);
}

checkSharedBridge();
if (!args.has("--android-only")) vendorSwift();
if (!args.has("--ios-only")) vendorAndroid();

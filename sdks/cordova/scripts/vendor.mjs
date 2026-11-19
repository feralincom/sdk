// Paketleme öncesi yerel çekirdekleri eklentiye kopyalar; hiçbir registry'ye yükleme yapmaz.
//   iOS:     sdks/swift/Sources/Feralin → src/ios/Feralin (Package.swift içindeki `Feralin` hedefi)
//   Android: sdks/android `:feralin:assembleRelease` → src/android/libs/feralin-android-<sürüm>.aar (plugin.xml lib-file)
// Kullanım: node scripts/vendor.mjs [--ios-only | --android-only]
import { spawnSync } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const sdks = join(root, "..");
const args = new Set(process.argv.slice(2));

function fail(message) {
  console.error(`HATA: ${message}`);
  process.exit(1);
}

function vendorSwift() {
  const source = join(sdks, "swift/Sources/Feralin");
  const target = join(root, "src/ios/Feralin");
  if (!existsSync(source)) fail(`Swift çekirdeği bulunamadı: ${source}`);
  rmSync(target, { recursive: true, force: true });
  cpSync(source, target, { recursive: true });
  const files = readdirSync(target).filter((name) => name.endsWith(".swift"));
  if (!existsSync(join(target, "Resources/PrivacyInfo.xcprivacy"))) fail("PrivacyInfo.xcprivacy kopyalanmadı");
  console.log(`iOS çekirdeği kopyalandı: ${files.length} Swift dosyası → ${target}`);
}

function vendorAndroid() {
  const android = join(sdks, "android");
  const props = readFileSync(join(android, "gradle.properties"), "utf8");
  const version = /^feralinVersion=(.+)$/m.exec(props)?.[1]?.trim();
  if (!version) fail("sdks/android/gradle.properties içinde feralinVersion yok");
  const xml = readFileSync(join(root, "plugin.xml"), "utf8");
  const expected = `feralin-android-${version}.aar`;
  if (!xml.includes(`src/android/libs/${expected}`)) fail(`plugin.xml lib-file ${expected} değil; sürümü güncelleyin`);
  const gradlew = process.platform === "win32" ? "cmd.exe" : "./gradlew";
  // cmd.exe geçerli dizini aramayabilir (NoDefaultCurrentDirectoryInExePath); tam yol verilir.
  const prefix = process.platform === "win32" ? ["/d", "/c", join(android, "gradlew.bat")] : [];
  const env = { ...process.env };
  // local.properties depoda yoktur; ANDROID_HOME verilmediyse Android Studio'nun varsayılan SDK dizini denenir.
  const studioSdk = process.env.LOCALAPPDATA ? join(process.env.LOCALAPPDATA, "Android", "Sdk") : join(process.env.HOME ?? "", "Android", "Sdk");
  if (!env.ANDROID_HOME && !env.ANDROID_SDK_ROOT && existsSync(studioSdk)) env.ANDROID_HOME = studioSdk;
  const result = spawnSync(gradlew, [...prefix, ":feralin:assembleRelease", "--console=plain", "-q"], { cwd: android, stdio: "inherit", env });
  if (result.status !== 0) fail("Android çekirdeği derlenemedi (:feralin:assembleRelease)");
  const aar = join(android, "feralin/build/outputs/aar/feralin-release.aar");
  if (!existsSync(aar)) fail(`AAR bulunamadı: ${aar}`);
  const libs = join(root, "src/android/libs");
  rmSync(libs, { recursive: true, force: true });
  mkdirSync(libs, { recursive: true });
  copyFileSync(aar, join(libs, expected));
  console.log(`Android çekirdeği kopyalandı: ${join(libs, expected)}`);
}

if (!args.has("--android-only")) vendorSwift();
if (!args.has("--ios-only")) vendorAndroid();

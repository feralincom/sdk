#!/usr/bin/env node
// Unreal olmadan yapılabilen denetimler. Gerçek UE derlemesinin yerini TUTMAZ.
//   1. FeralinWire.hpp, sdks/cpp/include/feralin/wire.hpp ile aynı mı
//   2. .uplugin, Build.cs, modül ve sürüm tutarlı mı
//   3. Saf tel biçimi: sdks/cpp ile aynı vektörler, UE gibi exception ve RTTI kapalı, C++17 ve C++20
//   4. UFeralinSubsystem akışı: UE taklit başlıklarıyla (tests/ue_stub/ue_stub.h)
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const unreal = join(here, "..");
const repo = join(unreal, "../..");
const plugin = join(unreal, "Feralin");
const module = join(plugin, "Source/Feralin");
const suffix = process.platform === "win32" ? ".exe" : "";
const work = mkdtempSync(join(tmpdir(), "feralin-unreal-test-"));

const STRICT = ["-Wall", "-Wextra", "-Wshadow", "-Wconversion", "-Wsign-conversion", "-Werror"];
// MinGW çalışma zamanı DLL'i PATH'teki başka bir araç zincirinden yüklenmesin.
const LINK = process.platform === "win32" ? ["-static"] : [];

function exec(command, args) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.status !== 0) throw new Error(`komut başarısız (${result.status ?? result.error}): ${command}`);
}

function normalized(path) {
  return readFileSync(path, "utf8").replaceAll("\r\n", "\n");
}

function checkWireCopy() {
  const source = normalized(join(repo, "sdks/cpp/include/feralin/wire.hpp"));
  const copy = normalized(join(module, "Private/FeralinWire.hpp"));
  if (source !== copy) throw new Error("FeralinWire.hpp sdks/cpp ile aynı değil: wire.hpp dosyasını kopyalayın");
  console.log("OK    FeralinWire.hpp sdks/cpp ile aynı");
}

function checkPlugin() {
  const descriptor = JSON.parse(readFileSync(join(plugin, "Feralin.uplugin"), "utf8"));
  const names = descriptor.Modules.map((item) => item.Name);
  if (names.join() !== "Feralin") throw new Error(`beklenmeyen modüller: ${names.join()}`);
  if (!existsSync(join(module, "Feralin.Build.cs"))) throw new Error("Feralin.Build.cs yok");
  const build = readFileSync(join(module, "Feralin.Build.cs"), "utf8");
  for (const dependency of ["Core", "CoreUObject", "Engine", "DeveloperSettings", "HTTP"]) {
    if (!build.includes(`"${dependency}"`)) throw new Error(`Build.cs bağımlılığı eksik: ${dependency}`);
  }
  const subsystem = readFileSync(join(module, "Private/FeralinSubsystem.cpp"), "utf8");
  const version = /SdkVersion = "([^"]+)"/.exec(subsystem)?.[1];
  if (descriptor.VersionName !== version) throw new Error(`sürüm uyuşmuyor: uplugin ${descriptor.VersionName}, kod ${version}`);
  const header = readFileSync(join(module, "Public/FeralinSubsystem.h"), "utf8");
  for (const method of ["bool Track(", "void SetConsent(", "void Flush("]) {
    const index = header.indexOf(method);
    if (index < 0 || !header.slice(Math.max(0, index - 200), index).includes("BlueprintCallable")) throw new Error(`Blueprint çağrılabilir değil: ${method}`);
  }
  console.log(`OK    eklenti tanımı tutarlı (sürüm ${version})`);
}

function runWire() {
  const include = [`-I${join(module, "Private")}`, `-I${join(repo, "sdks/cpp/tests")}`];
  for (const standard of ["c++17", "c++20"]) {
    const binary = join(work, `wire_test_${standard.replace("+", "p").replace("+", "p")}${suffix}`);
    exec("g++", [`-std=${standard}`, "-fno-exceptions", "-fno-rtti", ...STRICT, ...include, join(here, "wire_test.cpp"), "-o", binary, ...LINK]);
    exec(binary, []);
  }
}

// Oyun sözleşmeleri (FeralinGame.hpp): Unity çıktılarından üretilmiş tests/vectors/sdk_vectors.json ile birebir karşılaştırma, NIST AES-GCM ve
// SHA-256 vektörleri, kalıcı şifreli kuyruk, hata, oturum, atıf. Yalnız standart kütüphane; UE gibi exception ve RTTI kapalı.
function runGame() {
  const include = [`-I${join(module, "Private")}`];
  for (const name of ["crypto_test", "game_test"]) {
    const binary = join(work, `${name}${suffix}`);
    exec("g++", ["-std=c++17", "-fno-exceptions", "-fno-rtti", ...STRICT, ...include, join(here, `${name}.cpp`), "-o", binary, ...LINK]);
    exec(binary, [here]);
  }
}

// UE başlıklarının yerine ue_stub.h'a yönlenen dosyalar geçici dizinde üretilir; depoya taklit başlık ağacı girmez.
function writeForwarders() {
  const stubs = join(work, "ue_headers");
  const forward = `#pragma once\n#include "${join(here, "ue_stub/ue_stub.h").replaceAll("\\", "/")}"\n`;
  for (const header of [
    "CoreMinimal.h",
    "HttpModule.h",
    "Containers/Ticker.h",
    "Engine/DeveloperSettings.h",
    "HAL/PlatformTime.h",
    "Interfaces/IHttpRequest.h",
    "Interfaces/IHttpResponse.h",
    "Misc/DateTime.h",
    "Misc/Guid.h",
    "Async/Async.h",
    "HAL/FileManager.h",
    "Misc/CoreDelegates.h",
    "Misc/OutputDevice.h",
    "Misc/Paths.h",
    "Modules/ModuleInterface.h",
    "Modules/ModuleManager.h",
    "Subsystems/GameInstanceSubsystem.h",
    "FeralinSettings.generated.h",
    "FeralinSubsystem.generated.h",
  ]) {
    const path = join(stubs, header);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, forward);
  }
  return stubs;
}

function runGlue() {
  const stubs = writeForwarders();
  const binary = join(work, `glue_test${suffix}`);
  exec("g++", [
    "-std=c++17",
    "-Wall",
    "-Wextra",
    "-Wshadow",
    "-Werror",
    "-Wno-unused-parameter", // OnTick imzası motor delegesinden gelir
    `-I${stubs}`,
    `-I${join(module, "Public")}`,
    `-I${join(module, "Private")}`,
    join(here, "glue_test.cpp"),
    join(module, "Private/FeralinSubsystem.cpp"),
    join(module, "Private/FeralinModule.cpp"),
    join(module, "Private/FeralinPlatform.cpp"),
    "-o",
    binary,
    ...LINK,
  ]);
  exec(binary, []);
}

let code = 0;
try {
  checkWireCopy();
  checkPlugin();
  runWire();
  runGame();
  runGlue();
  console.log("Unreal dışı denetimler GEÇTİ. Gerçek UE derlemesi ve çalıştırması YAPILMADI.");
} catch (error) {
  code = 1;
  console.error(`KALDI: ${error instanceof Error ? error.message : String(error)}`);
} finally {
  rmSync(work, { recursive: true, force: true, maxRetries: 3 });
}
process.exit(code);

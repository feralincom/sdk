// Roku SDK birim testleri: FeralinCore.brs, brs yorumlayıcısıyla (npm "brs", Roku cihazı gerekmez) koşar. brs depoya bağımlılık olarak
// eklenmez; `npx --yes brs@0.45.0` ile indirilir ya da BRS_BIN ile verilir. Testlerin ürettiği batch gövdeleri toplayıcının UTP v1
// şemasıyla (packages/schemas/utp/v1) doğrulanır; ajv, packages/sdk-web geliştirme bağımlılığından çözülür.
// brs girdi akışı açık kalırsa beklemede kalır; stdin kapalı başlatılır.
// Kullanım: node sdks/roku/tests/run.mjs
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(root, "../..");
const files = [join(root, "components/feralin/FeralinCore.brs"), join(root, "tests/FeralinCoreTest.brs")];

// brs açılışta kök dizindeki (varsayılan: çalışma dizini) XML bileşenlerini tarar; depo kökünden çalışırsa bütün depoyu tarayıp
// beklemede kalır. Kök ve çalışma dizini yalnız tests/ klasörüdür; sınanan dosyalar mutlak yolla verilir.
const testsDir = join(root, "tests");
const brsArgs = ["--root", testsDir, ...files];
const options = { cwd: testsDir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 120000, shell: process.platform === "win32" };
const quote = (value) => (process.platform === "win32" ? `"${value}"` : value);
const runBrs = (args) => process.env.BRS_BIN
  ? spawnSync(quote(process.env.BRS_BIN), args.map(quote), options)
  : spawnSync(process.platform === "win32" ? "npx.cmd" : "npx", ["--yes", "brs@0.45.0", ...args.map(quote)], options);
const brs = runBrs(brsArgs);
// Task ve uygulama yüzü dosyaları da yorumlayıcıda ayrıştırılır (yalnız sözdizimi ve cihaz ortamı kurulumu).
const parse = runBrs(["--root", testsDir, files[0], join(root, "components/feralin/FeralinTask.brs"), join(root, "components/feralin/FeralinApi.brs"), join(testsDir, "ParseCheck.brs")]);
const parseOk = /PARSE ok/.test(`${parse.stdout ?? ""}`);
console.log(parseOk ? "PARSE ok FeralinTask.brs ve FeralinApi.brs" : `PARSE FAIL ${(parse.stdout ?? "") + (parse.stderr ?? "")}`.slice(0, 2000));

const output = `${brs.stdout ?? ""}${brs.stderr ?? ""}`;
const lines = output.split(/\r?\n/);
for (const line of lines) {
  if (line.startsWith("ok ") || line.startsWith("FAIL ") || line.startsWith("SUMMARY")) console.log(line);
}
const summary = lines.find((line) => line.startsWith("SUMMARY"));
if (!summary) {
  console.error("HATA: brs testleri tamamlanmadı");
  console.error(output.slice(-2000));
  process.exit(1);
}
let failed = Number(/failed=(\d+)/.exec(summary)[1]);

// Şema denetimi: platform "roku" (varsayılan) ve "other" gövdeleri ayrı ayrı doğrulanır; ikisi de geçmelidir.
let Ajv2020;
let addFormats;
try {
  const req = createRequire(join(repo, "packages/sdk-web/package.json"));
  Ajv2020 = req("ajv/dist/2020").default;
  addFormats = req("ajv-formats").default;
} catch {
  console.log("SCHEMA atlandı: ajv bulunamadı (pnpm install sonrası packages/sdk-web geliştirme bağımlılığıdır)");
}
if (Ajv2020) {
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  ajv.addSchema(JSON.parse(readFileSync(join(repo, "packages/schemas/utp/v1/event.schema.json"), "utf8")));
  const validate = ajv.compile(JSON.parse(readFileSync(join(repo, "packages/schemas/utp/v1/batch.schema.json"), "utf8")));
  for (const line of lines.filter((l) => l.startsWith("BATCH_JSON "))) {
    const [, platform, ...rest] = line.split(" ");
    const body = JSON.parse(rest.join(" "));
    const ok = validate(body);
    const errors = (validate.errors ?? []).map((e) => `${e.instancePath} ${e.message}${e.params?.allowedValues ? ` (${e.params.allowedValues.join("|")})` : ""}`);
    if (ok) {
      console.log(`SCHEMA ok platform=${platform}: ${body.events.length} olay toplayıcı şemasına uyuyor`);
    } else {
      failed++;
      console.log(`SCHEMA FAIL platform=${platform}: ${errors.slice(0, 8).join("; ")}`);
    }
  }
}

process.exit(failed === 0 ? 0 : 1);

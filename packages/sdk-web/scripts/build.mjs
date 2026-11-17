// esbuild ile üç çıktı: ESM, CJS ve tarayıcı snippet'i (IIFE, window.feralin). Boyut bütçesi: IIFE ≤ 8 KB gzip.
import { build } from "esbuild";
import { readFileSync, statSync, mkdirSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
mkdirSync(join(root, "dist"), { recursive: true });
const common = { entryPoints: [join(root, "src/index.ts")], bundle: true, sourcemap: true, target: ["es2020"], define: { __SDK_VERSION__: JSON.stringify(version) }, legalComments: "none" };
await build({ ...common, format: "esm", outfile: join(root, "dist/feralin.mjs") });
await build({ ...common, format: "cjs", outfile: join(root, "dist/feralin.cjs") });
await build({ ...common, format: "iife", globalName: "feralin", minify: true, outfile: join(root, "dist/feralin.iife.js"), footer: { js: "window.feralin=feralin;" } });
const iife = readFileSync(join(root, "dist/feralin.iife.js"));
const gz = gzipSync(iife).length;
console.log(`sdk-web v${version}: iife ${statSync(join(root, "dist/feralin.iife.js")).size} B, gzip ${gz} B`);
if (gz > 8 * 1024) { console.error("HATA: IIFE gzip boyutu 8 KB bütçesini aşıyor"); process.exit(1); }

// App Banner ayrı bir betiktir: ölçüm SDK'sını yüklemez, ondan bağımsız çalışır. ESM çıktısı testler içindir.
const banner = { entryPoints: [join(root, "src/banner.ts")], bundle: true, sourcemap: true, target: ["es2020"], legalComments: "none" };
await build({ ...banner, format: "esm", outfile: join(root, "dist/feralin-banner.mjs") });
await build({ ...banner, format: "iife", globalName: "feralinBanner", minify: true, outfile: join(root, "dist/feralin-banner.iife.js"), footer: { js: "window.feralinBanner={mount:feralinBanner.mountBanner,resolve:feralinBanner.resolveBannerOptions};" } });
const bannerGz = gzipSync(readFileSync(join(root, "dist/feralin-banner.iife.js"))).length;
console.log(`sdk-web banner: iife ${statSync(join(root, "dist/feralin-banner.iife.js")).size} B, gzip ${bannerGz} B`);
if (bannerGz > 3 * 1024) { console.error("HATA: banner gzip boyutu 3 KB bütçesini aşıyor"); process.exit(1); }

// Replay/heatmap ve bayrak modülleri ayrı betiklerdir: çekirdek bütçesine girmez, yalnız isteyen sayfa yükler (şartname §40.1:
// replay ve ağır özellikler varsayılan açılmaz). Her birinin kendi gzip bütçesi vardır.
for (const [name, globalName, footer, budget] of [
  ["replay", "feralinReplay", "window.feralinReplay=feralinReplay;", 3 * 1024],
  ["flags", "feralinFlags", "window.feralinFlags=feralinFlags;", 3 * 1024],
  ["auto", "feralinAuto", "window.feralinAuto=feralinAuto;", 3 * 1024],
  ["errors", "feralinErrors", "window.feralinErrors=feralinErrors;", 3 * 1024],
  ["vitals", "feralinVitals", "window.feralinVitals=feralinVitals;", 2 * 1024],
]) {
  const mod = { entryPoints: [join(root, `src/${name}.ts`)], bundle: true, sourcemap: true, target: ["es2020"], legalComments: "none" };
  await build({ ...mod, format: "esm", outfile: join(root, `dist/feralin-${name}.mjs`) });
  await build({ ...mod, format: "iife", globalName, minify: true, outfile: join(root, `dist/feralin-${name}.iife.js`), footer: { js: footer } });
  const gz = gzipSync(readFileSync(join(root, `dist/feralin-${name}.iife.js`))).length;
  console.log(`sdk-web ${name}: iife ${statSync(join(root, `dist/feralin-${name}.iife.js`)).size} B, gzip ${gz} B`);
  if (gz > budget) { console.error(`HATA: ${name} gzip boyutu ${budget / 1024} KB bütçesini aşıyor`); process.exit(1); }
}

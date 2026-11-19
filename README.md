# Feralin SDKs

Feralin is a privacy-first analytics and attribution platform for websites, mobile apps, games and servers: <https://feralin.com>

This repository holds the client SDKs, their documentation and the public API contract. It is a snapshot exported from the Feralin source tree (commit `5be5fcb4ce30`); the product itself (API, panel, collectors) is not in this repository.

- User guide: <https://feralin.com/en/docs/guide>
- API guide: <https://feralin.com/en/developers/guide>
- SDK downloads with SHA-256 checksums: <https://feralin.com/en/sdk-registry>
- Security contact: see [SECURITY.md](SECURITY.md)

## Türkçe

Feralin; web siteleri, mobil uygulamalar, oyunlar ve sunucular için izin öncelikli analitik ve attribution platformudur: <https://feralin.com>

Bu depo istemci SDK'larını, belgelerini ve herkese açık API sözleşmesini içerir. Feralin kaynak ağacından dışa aktarılmış bir kopyadır; ürünün kendisi (API, panel, toplayıcılar) bu depoda değildir. SDK belgeleri ve kod içi açıklamalar Türkçedir.

- Kullanım kılavuzu: <https://feralin.com/tr/docs/guide>
- API kılavuzu: <https://feralin.com/tr/developers/guide>
- SHA-256 özetli SDK indirmeleri: <https://feralin.com/tr/sdk-registry>

## SDKs

Status values are the project's own evidence levels: `INTEGRATION_TESTED` means the SDK delivered events to the real collector in a clean install; platform and registry verification are tracked separately in [docs/sdk/capability-matrix.md](docs/sdk/capability-matrix.md). An SDK that has not been verified on its real platform says so in its README.

| SDK | Package | Version | Status | Source |
|---|---|---|---|---|
| Web JS/TS | `@feralin/web` | 0.1.0 | INSTALL_VERIFIED | [packages/sdk-web](packages/sdk-web) |
| React / Next.js | `@feralin/react` | 0.1.0 | INSTALL_VERIFIED | [sdks/web-react](sdks/web-react) |
| Vue / Nuxt | `@feralin/vue` | 0.1.0 | INSTALL_VERIFIED | [sdks/web-vue](sdks/web-vue) |
| Angular | `@feralin/angular` | 0.1.0 | INSTALL_VERIFIED | [sdks/web-angular](sdks/web-angular) |
| WordPress / WooCommerce | `feralin` | 0.1.0 | IMPLEMENTING | [sdks/wordpress](sdks/wordpress) |
| PHP | `feralin/feralin-php` | 0.1.0 | INTEGRATION_TESTED | [sdks/php](sdks/php) |
| Laravel | `feralin/feralin-laravel` | 0.1.0 | INTEGRATION_TESTED | [sdks/php-laravel](sdks/php-laravel) |
| Symfony | `feralin/feralin-symfony` | 0.1.0 | INTEGRATION_TESTED | [sdks/php-symfony](sdks/php-symfony) |
| Go | `github.com/feralincom/sdk/sdks/go` | 0.1.0 | INSTALL_VERIFIED | [sdks/go](sdks/go) |
| C# / .NET / ASP.NET | `Feralin.Sdk, Feralin.Sdk.AspNetCore` | 0.1.0 | INTEGRATION_TESTED | [sdks/dotnet](sdks/dotnet) |
| Node.js | `@feralin/node` | 0.1.0 | INSTALL_VERIFIED | [sdks/node](sdks/node) |
| Express | `@feralin/express` | 0.1.0 | INSTALL_VERIFIED | [sdks/node-express](sdks/node-express) |
| NestJS | `@feralin/nest` | 0.1.0 | INSTALL_VERIFIED | [sdks/node-nest](sdks/node-nest) |
| Python | `feralin` | 0.1.0 | INTEGRATION_TESTED | [sdks/python](sdks/python) |
| Django | `feralin-django` | 0.1.0 | INTEGRATION_TESTED | [sdks/python-django](sdks/python-django) |
| FastAPI | `feralin-fastapi` | 0.1.0 | INTEGRATION_TESTED | [sdks/python-fastapi](sdks/python-fastapi) |
| Dart / Flutter | `feralin_flutter` | 0.3.0 | INTEGRATION_TESTED | [sdks/flutter](sdks/flutter) |
| Kotlin / Android | `com.feralin:android` | 0.1.0 | INTEGRATION_TESTED | [sdks/android](sdks/android) |
| Swift / iOS / macOS | `Feralin` | 0.3.0 | INTEGRATION_TESTED | [sdks/swift](sdks/swift) |
| Java / Spring | `com.feralin:java, com.feralin:feralin-spring-boot-starter` | 0.1.0 | INTEGRATION_TESTED | [sdks/java](sdks/java) |
| React Native | `@feralin/react-native` | 0.3.0 | INSTALL_VERIFIED | [sdks/react-native](sdks/react-native) |
| Unity C# | `com.feralin.unity` | 0.3.0 | INTEGRATION_TESTED | [sdks/unity](sdks/unity) |
| Unreal C++ | `Feralin` | 0.2.0 | IMPLEMENTING | [sdks/unreal](sdks/unreal) |
| Godot GDScript | `feralin` | 0.2.0 | INTEGRATION_TESTED | [sdks/godot](sdks/godot) |
| Rust | `feralin, tauri-plugin-feralin` | 0.1.0 | INTEGRATION_TESTED | [sdks/rust](sdks/rust) |
| Ruby / Rails | `feralin` | 0.1.0 | INTEGRATION_TESTED | [sdks/ruby](sdks/ruby) |
| C / C++ native | `feralin` | 0.1.0 | INTEGRATION_TESTED | [sdks/cpp](sdks/cpp) |
| Objective-C | `FeralinObjC` | 0.1.0 | IMPLEMENTING | [sdks/objc](sdks/objc) |
| Kotlin Multiplatform | `com.feralin:feralin-kmp` | 0.1.0 | INTEGRATION_TESTED | [sdks/kmp](sdks/kmp) |
| Electron | `@feralin/electron` | 0.1.0 | INSTALL_VERIFIED | [sdks/electron](sdks/electron) |
| Tauri | `@feralin/tauri` | 0.1.0 | INTEGRATION_TESTED | [sdks/tauri](sdks/tauri) |
| .NET MAUI | `Feralin.Sdk.Maui` | 0.1.0 | INTEGRATION_TESTED | [sdks/maui](sdks/maui) |
| Shopify | `-` | - | INTEGRATION_TESTED | [docs/sdk/no-code.md](docs/sdk/no-code.md) |
| Wix / Webflow / Bubble / no-code | `-` | - | INTEGRATION_TESTED | [docs/sdk/no-code.md](docs/sdk/no-code.md) |
| MCP stdio köprüsü | `@feralin/mcp-server` | 0.1.0 | REGISTRY_VERIFIED | [packages/mcp-server](packages/mcp-server) |
| Cordova | `cordova-plugin-feralin` | 0.1.0 | UNIT_TESTED | [sdks/cordova](sdks/cordova) |
| Capacitor | `@feralin/capacitor` | 0.1.0 | UNIT_TESTED | [sdks/capacitor](sdks/capacitor) |
| Roku (BrightScript) | `-` | 0.1.0 | UNIT_TESTED | [sdks/roku](sdks/roku) |

## Install from this repository

Some SDKs install straight from a Git tag of this repository instead of a package registry. A tag exists only after it is published; the list is at <https://github.com/feralincom/sdk/tags>.

| SDK | How | Tag |
|---|---|---|
| Go | `go get github.com/feralincom/sdk/sdks/go@v0.1.0` | `sdks/go/v0.1.0` |
| Swift / iOS / macOS | `.package(url: "https://github.com/feralincom/sdk.git", exact: "0.3.0")`, product `Feralin` (root `Package.swift`) | `0.3.0` |
| Unity C# | `https://github.com/feralincom/sdk.git?path=sdks/unity#sdks/unity/v0.3.0` in Package Manager → Add package from git URL | `sdks/unity/v0.3.0` |
| C / C++ native | `FetchContent_Declare` with `GIT_TAG sdks/cpp/v0.1.0` and `SOURCE_SUBDIR sdks/cpp` | `sdks/cpp/v0.1.0` |
| Godot GDScript | copy `sdks/godot/addons/feralin` from the tag into your project's `addons/` | `sdks/godot/v0.2.0` |
| Dart / Flutter | pubspec.yaml: `feralin_flutter: { git: { url: https://github.com/feralincom/sdk.git, path: sdks/flutter, ref: sdks/flutter/v0.3.0 } }` | `sdks/flutter/v0.3.0` |

Each SDK README has the full steps.

## Layout

- `sdks/`, `packages/`: SDK sources, each with its own README, CHANGELOG and LICENSE.
- `Package.swift`: Swift Package Manager manifest for the Swift SDK in `sdks/swift`.
- `docs/sdk/`: per-SDK documentation, the capability matrix, the upgrade guide and the support policy.
- `api/`: OpenAPI 3.1 contract and a Postman collection for the public REST API.

## License

MIT. See [LICENSE](LICENSE); each SDK directory carries the same license file.

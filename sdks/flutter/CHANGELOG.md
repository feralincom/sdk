# Changelog

## Unreleased

## 0.3.0 (19 November 2026)

- Fera Fly short links: when the app is opened directly by `https://fera.fly/<code>` or `https://<brand>.fera.fly/<code>`, the engine resolves the link with `Accept: application/vnd.feralin.link+json` (no redirects, 5 s, 16 KB) and feeds the deep path, UTM and click id (advertising consent only) into `deep_link_opened`. New `Feralin.handleShortLink(uri)` → `ShortLinkOpen`, `Feralin.lastShortLink`, `FeralinConfig.shortLinkHosts` (default `['fera.fly']`). No request without analytics consent; `Feralin-Attribution: off` without advertising consent. Unit tested and checked against the live router; not run on a real device (19 November 2026).
- SDK signature: `FeralinConfig(signingKey: SigningKey(id, secret))` signs `app_first_open` and `deep_link_opened` only, as `fr_sig` (`v1.<id>.<unix seconds>.<hex hmac-sha256>`, same string and test vector as the Android SDK and the server). An invalid key is a configuration error; the secret never reaches logs or `toString`. HMAC-SHA256 is pure Dart, no new dependency. Unit tested; not run against a real device (18 November 2026).
- Emulator flag (Android): `app_first_open` carries `device_emulator: true` when the native plugin's `Build` heuristic matches; the field is absent otherwise and a read failure does not block the first open. Unit tested; not run against a real device.
- Huawei AppGallery install referrer (Android): read when Play gives no evidence and advertising consent is on; sent as `attribution_source=huawei_install_referrer` through the same allow-list. The plugin manifest now declares `<queries>` for `com.huawei.appmarket`. Unit tested; not run on a Huawei device.
- Install store (Android): `app_first_open` carries `install_store`, a closed-list class derived from the installer package (`google_play`, `samsung_galaxy_store`, `huawei_appgallery`, `amazon_appstore`, `xiaomi_getapps`, `oppo_app_market`, `vivo_app_store`, `honor_app_market`, `sideload`, `unknown`, `other`). Added regardless of advertising consent; an unlisted installer's package name is never sent; a read failure does not block the first open. Unit tested; not run against a real device.
- Install pairing code: `FeralinConfig(installCode: ...)` attaches the single-use code generated on the panel's "Verify install" screen to the first queued event as `fr_install_code`; the server strips it from event data and links the install to the project. A malformed code is ignored.
- UTP §8.2 identity methods: `group` (`fr_group`), `setUserProperties` (`fr_user_properties`), `setGlobalProperties` and `clearGlobalProperties`. PII-like keys, verification fields and off-contract values are dropped on the client; global properties are added to every non-`fr_` event and cleared by `reset`. Unit tested; not run against a real device.

## 0.2.0

- Queue encryption: event bodies in the on-disk queue are AES-256-GCM encrypted (`enc1:` rows, event id as associated data, compatible with the Android core `EncryptedEventStore` row format). The key lives in Android Keystore / iOS Keychain and never reaches Dart. If the key is unavailable the SDK keeps events in memory only; it never falls back to plain text. Plain-text rows from 0.1.0 are encrypted on first read.
- iOS: a small native plugin now holds the Keychain key (not compiled on this machine: no macOS or Xcode).

## 0.1.0

- First implementation: consent-first events, durable file queue, batching, exponential backoff, session lifecycle.
- Android: Play Install Referrer and App Link capture through the platform channel.
- iOS: Dart-only; universal links are passed by the app, and there is no native attribution bridge yet.
- Not published to pub.dev yet.

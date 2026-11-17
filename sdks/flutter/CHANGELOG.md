# Changelog

## Unreleased

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

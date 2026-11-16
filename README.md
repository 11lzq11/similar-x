# Similar-X

**One app for every social network — 一个应用，刷遍所有社交网络。**

Similar-X is a modular, multi-platform social media aggregator. Each
social network lives behind a small adapter; the app merges them into
one unified timeline. Login is optional per platform — guests can
browse public content, and logging in unlocks your own timeline,
posting, likes, comments, DMs and notifications.

Similar-X 是一个模块化的全端社交聚合器：每个社交平台对应一个小
适配器，应用把它们汇成一条统一时间线。每个平台都可登录、可不登录
——游客能看公开内容，登录后解锁自己的时间线、发帖、点赞、评论、
私信和通知。

> **Status: v0.1.0 scaffold.** The app shell, Chinese/English locales
> and the adapter registry compile and run. Every adapter is a stub
> until its real API client lands — this is the foundation, not the
> finished app.
>
> **状态：v0.1.0 脚手架。** 应用外壳、中英文语言、适配器注册表已
> 能编译运行。每个适配器目前还是占位实现，等各自的 API 客户端接
> 入——这是地基，不是成品。

## Platform status / 平台接入状态

Based on `research/third-party-feasibility.md` (2026-11-16). Reality
first: only the open platforms can be done completely; closed
platforms get a WebView fallback or are cut.

| Platform / 平台 | Status / 状态 | Shape / 形态 |
|---|---|---|
| Telegram | ✅ Fully feasible / 完全可行 | Full client via MTProto + TDLib (free, no approval) |
| Mastodon | ✅ Fully feasible / 完全可行 | Full client, open REST + Streaming API |
| Bluesky | ✅ Fully feasible / 完全可行 | Full client, AT Protocol, public read without login |
| YouTube | ⚠️ Limited / 有限 | Official Data API (10k units/day) + InnerTube fallback |
| Reddit | ⚠️ Limited / 有限 | Free tier 100/min OAuth; manual approval required |
| Threads | ⚠️ Limited / 有限 | Own account only — post + manage, no public timeline |
| X | 🔴 WebView only / 仅网页版 | Pay-per-read API + ToS bans replacement clients |
| Instagram | 🔴 WebView only / 仅网页版 | No personal-account API (Basic Display closed 2024) |
| Facebook | 🔴 WebView only / 仅网页版 | Graph API covers Pages only |
| Discord | ❌ Cut / 砍掉 | User-token automation is banned by ToS |
| TikTok | ❌ Cut / 砍掉 | No public feed API |

## Architecture / 架构

```
lib/
  main.dart                 # App shell, locales (zh/en), provider wiring
  core/
    platform_adapter.dart   # The contract every adapter implements
    account_store.dart      # Encrypted on-device token storage
    app_localizations.dart  # Chinese + English strings (no codegen)
    app_state.dart          # Adapter registry + locale state
  adapters/
    registry.dart           # Launch-priority adapter list
    telegram_adapter.dart   # Tier 1: MTProto + TDLib (FFI, future)
    mastodon_adapter.dart   # Tier 1: REST + Streaming API
    bluesky_adapter.dart    # Tier 1: AT Protocol
    youtube_adapter.dart    # Tier 2: Data API v3
    reddit_adapter.dart     # Tier 2: Data API (OAuth per user)
    threads_adapter.dart    # Tier 2: Threads API (own account)
    webview_adapter.dart    # Tier 3: X / Instagram / Facebook
  screens/
    home_screen.dart        # Platform list (unified timeline lands later)
```

Design rules:

- **Modular / 模块化** — one adapter per platform, loaded lazily, so
  the app only pays for the platforms the user enables (keeps the
  install small).
- **Your accounts, your quota / 各自的账号和配额** — each user logs in
  with their own account on each platform; the app never pools one
  central API key for all traffic.
- **Tokens stay on-device / Token 只存本地** — OAuth tokens live in
  encrypted secure storage and are only ever sent to the platform's
  own API. Similar-X has no backend server.
- **Free-tier backends only / 只用免费后端** — no paid servers, no
  paid data services in v1.

## Clients / 客户端

Flutter, five platforms: **Android, Windows, iOS, macOS, Linux**
(no Web — the user asked to skip it). CI builds unsigned
IPA/DMG/APK/AppImage/Windows packages on every tag (see
`.github/workflows/build.yml`).

## Build / 构建

```sh
flutter pub get
flutter analyze
flutter test
flutter run

# Release builds (CI does these on tags v*):
flutter build apk --release
flutter build windows --release
flutter build linux --release
flutter build macos --release
flutter build ipa --no-codesign   # unsigned IPA
```

Requires Flutter 3.50.0 (stable) or newer.

## Roadmap / 路线图

- [x] v0.1.0 — scaffold: app shell, locales, adapter registry, CI
- [ ] v0.2.0 — Mastodon + Bluesky timelines (REST, guest-first)
- [ ] v0.3.0 — Telegram via TDLib (FFI), login + chat list
- [ ] v0.4.0 — unified timeline, posting, likes, comments
- [ ] v0.5.0 — YouTube / Reddit / Threads (limited tiers), WebView tab

## Contributing / 参与

Issues and PRs are welcome. Please keep adapters small and
single-purpose, and never add a central server or a pooled API key.

## License / 协议

MIT — see [LICENSE](LICENSE).

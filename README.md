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
| Telegram | ✅ Implemented / 已实现 | Full client via MTProto + TDLib (free, no approval) |
| Mastodon | ✅ Implemented / 已实现 | Full client, open REST + OAuth (PKCE) |
| Bluesky | ✅ Implemented / 已实现 | Full client, AT Protocol, App Password login, public read without login |
| YouTube | ⚠️ Limited / 有限 | Official Data API (10k units/day) + InnerTube fallback |
| Reddit | ⚠️ Limited / 有限 | Implemented — Data API OAuth (own installed app); free tier 100/min; manual approval needed since Nov 2025 |
| Threads | ⚠️ Limited / 有限 | Implemented — Threads API OAuth (own Meta app); own threads, post/reply/quote/repost, mentions, keyword search (500/7 days), insights. No public timeline; the official API has no like endpoint |
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
    telegram_adapter.dart   # Tier 1: MTProto + TDLib (FFI, implemented)
    mastodon_adapter.dart   # Tier 1: REST + Streaming API
    bluesky_adapter.dart    # Tier 1: AT Protocol
    youtube_adapter.dart    # Tier 2: Data API v3
    reddit_adapter.dart     # Tier 2: Data API (OAuth per user)
    reddit/
      reddit_client.dart    # Data API: OAuth PKCE + app-only guest token
      reddit_models.dart    # Post / Comment / Subreddit / Message
    threads_adapter.dart    # Tier 2: Threads API (own account)
    threads/
      threads_client.dart   # Threads API: OAuth, container + publish, repost, insights
      threads_models.dart   # Post / User / Tokens / Insights / PublishingLimit
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

## Telegram setup / Telegram 接入说明

Telegram is the first fully implemented adapter. It uses
[TDLib](https://github.com/tdlib/td) (the official Telegram client
library) through a thin Dart FFI layer — no third-party TDLib package
(the ones on pub.dev don't cover all five platforms).

**Native library / 原生库** — the prebuilt `libtdjson` (~13–22 MB per
platform, TDLib 1.8.69) is **not** committed to this repo. Fetch it
before building a platform target; CI does this automatically:

```sh
python3 scripts/fetch_tdlib.py --platform android   # all 3 ABIs
python3 scripts/fetch_tdlib.py --platform ios       # XCFramework
python3 scripts/fetch_tdlib.py --platform macos     # .dylib
python3 scripts/fetch_tdlib.py --platform windows   # .dll
python3 scripts/fetch_tdlib.py --platform linux     # .so
```

Downloads are SHA-256 verified against `scripts/tdjson-manifest.json`
(pinned Mithka `mithka-tdjson` release). Already-correct targets are
skipped, so re-running is cheap.

**API credentials / API 凭证** — TDLib needs an `api_id` and
`api_hash`, which identify the *application* (one per Similar-X
install). Get them free from
[my.telegram.org](https://my.telegram.org) (log in with your phone
number → **API development tools** → create an app; the values are
yours, never shared). Enter them in the app's Telegram settings — the
app never ships a pooled key, and the credentials are stored encrypted
on-device (flutter_secure_storage). Then log in with your phone number
+ the code Telegram sends you; the session is kept in TDLib's local
database, encrypted with a per-install random key.

## Bluesky setup / Bluesky 接入说明

Bluesky uses the open [AT Protocol](https://atproto.com) — no app
registration, no approval, no quota. Public content is readable
without login (the Discover feed); writes need a session.

**Login / 登录** — enter your handle (e.g. `alice.bsky.social`)
and an **App Password**, made at Bluesky Settings > Privacy and
security > App passwords. Never use your account password here.
The session (access + refresh JWT) is stored encrypted on-device;
the access token is refreshed automatically when it expires
(about two hours). Most accounts live on `bsky.social`; users on
another PDS can change the service host in settings.

## Roadmap / 路线图

- [x] v0.1.0 — scaffold: app shell, locales, adapter registry, CI
- [x] v0.2.0 — Mastodon (REST + OAuth) + Bluesky (AT Protocol + App Password): timelines, post, like, repost, notifications, guest-first
- [x] v0.3.0 — Telegram via TDLib (FFI), login + chat list + messages
- [ ] v0.4.0 — unified timeline, posting, likes, comments
- [ ] v0.5.0 — YouTube ✅ / Reddit ✅ / Threads (limited tiers), WebView tab

## Contributing / 参与

Issues and PRs are welcome. Please keep adapters small and
single-purpose, and never add a central server or a pooled API key.

## License / 协议

MIT — see [LICENSE](LICENSE).

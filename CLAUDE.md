# CLAUDE.md

Guidance for Claude Code working in this repo (a fork of LocalSend).

## Project

LocalSend — cross-platform file sharing (Flutter + Rust). Monorepo:

- `app/` — the Flutter app (UI, providers, platform code). Rust bridge in `app/rust/`.
- `common/` — shared Dart models, DTOs, discovery/upload tasks.
- `cli/`, `server/` — secondary entry points.

State management: **Refena** (redux-style providers). Serialization: **dart_mappable**
(`*.mapper.dart`) and **freezed** (`*.freezed.dart`) — generated, never hand-edit.
i18n: **slang** (`app/lib/gen/strings*.g.dart`).

## Fork direction: Tailscale-direct

Making device discovery device-based (identity = fingerprint, not IP) with Tailscale
as an always-reachable transport backbone. A device keeps a **list of known addresses**
(LAN IP, Tailscale 100.x, MagicDNS name, hotspot IP); on send, all are probed in
parallel and the first reachable wins. Names are enrichment only (LocalSend's own
`/info` handshake; a desktop running `tailscale status --json` can distribute the
IP↔name map to peers). Tailscale identity details: see the project memory.

## Build / run

Flutter is **not pinned to the latest stable** by upstream (`.fvmrc` says 3.38.10),
but this fork resolves on the current stable too (dev-deps were adjusted: direct
`test` removed in favour of `flutter_test`, `mockito` constrained for SDK analyzer/meta).

```bash
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # after editing any @MappableClass / freezed / i18n
flutter run -d linux        # or: -d <android-device-id>
flutter analyze             # lib/ and test/ must be 0 errors
```

Note: ~43 analyze errors under `rust_builder/cargokit/build_tool/` are pre-existing
noise from a vendored isolated package (own pubspec, resolved at Rust build time) —
ignore them.

## Conventions

- Match surrounding code style; keep generated files generated (run build_runner, don't hand-edit).
- **Commit + push when a unit of work is done.** Conventional Commits, concise. Work on a
  feature branch off `main` (e.g. `feat/tailscale-direct`). Remote: `origin`
  (github.com/chukfinley/localsend). Only commit code that analyzes/builds.

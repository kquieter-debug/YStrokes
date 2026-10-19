<div align="right">
  <a href="README.md">简体中文</a> · <b>English</b>
</div>

### A personal simple project with AI🤓
# YStrokes

A vector-stroke drawing app for Android, built around how a stroke actually feels. The UI is Flutter; geometry and the on-disk document format are handled in Rust, connected through `flutter_rust_bridge`.

> **Status**: MVP. The core loop (draw → autosave → leave and come back) works end to end, but it has not yet been fully verified on a physical Android device.

## Features

- **Vector storage**: strokes are stored in normalized coordinates, decoupled from resolution, so proportions survive device changes and export.
- **Incremental smoothing**: smoothing happens as samples arrive. The point list committed on pen-up is bit-for-bit what was on screen — no flicker, no shape shift.
- **Durable writes**: atomic write (temp file + rename) means a process kill never leaves a truncated document; damaged documents recover partially instead of failing outright.
- **Undoable**: both adding a stroke and clearing the canvas can be undone.

## Tech stack

| Layer | Technology |
| --- | --- |
| Frontend | Flutter / Dart 3.12+, Material 3 |
| Geometry & document format | Rust 2021 (crate `ystrokes_rust`) |
| Bridge | flutter_rust_bridge 2.12.0 (versions must match exactly) |
| Android build | NDK + `cargo-ndk` + cargokit |

## Project structure

```
ystrokes/
├─ lib/                      # Flutter frontend
│  ├─ main.dart              # Entry point: initializes FRB
│  └─ src/
│     ├─ app.dart            # Root widget and theme
│     ├─ models/             # DrawingProject / Stroke
│     ├─ screens/            # welcome / home / canvas
│     ├─ services/           # StrokeSmoother / DrawingEngine
│     │                      # DocumentStore / ProjectStore / SettingsService
│     ├─ widgets/            # ProjectTile
│     └─ rust/               # FRB generated code (do not edit)
├─ rust/                     # Rust backend
│  ├─ Cargo.toml
│  └─ src/
│     ├─ lib.rs
│     ├─ api/mod.rs          # Public API + document codec
│     └─ frb_generated.rs    # Generated code (do not edit)
├─ rust_builder/             # cargokit: Rust → Android .so
├─ android/                  # Android project
├─ assets/                   # App icons
├─ test/                     # Unit and widget tests
├─ windows/                  # Windows project (rendering checks only, not a target)
├─ flutter_rust_bridge.yaml  # codegen configuration
└─ pubspec.yaml
```

## Requirements

- Flutter SDK (stable, Dart 3.12+)
- Android SDK and **NDK**
- Rust toolchain (`rustc` / `cargo`) and `cargo-ndk`
- Android cross-compilation targets

## Getting started

```powershell
flutter pub get
cargo install cargo-ndk                    # if not installed yet
flutter_rust_bridge_codegen generate       # generate Rust → Flutter bindings
flutter run                                # or: flutter build apk
```

## Development conventions

### After changing the Rust API

1. Edit `rust/src/api/mod.rs`.
2. Regenerate bindings: `flutter_rust_bridge_codegen generate`.
3. Run Rust tests: `cargo test --manifest-path rust/Cargo.toml`.

### Generated code

Everything under `lib/src/rust/**` and `rust/src/frb_generated.rs` is produced by codegen. **Do not edit it by hand** — the next run will overwrite your changes.

### Version alignment

The versions in `pubspec.yaml`, `rust/Cargo.toml`, and your local `flutter_rust_bridge_codegen` must match (currently 2.12.0). A mismatch between generated code and runtime surfaces as hard-to-diagnose failures.

## Design notes

### Data storage

| Content | Location | Notes |
| --- | --- | --- |
| Project metadata | `shared_preferences` (key `projects`) | Lightweight index; the list screen reads only this |
| Stroke data | `<appDocuments>/projects/<projectId>/strokes.bin` | Binary, encoded/decoded by Rust |

- **Metadata and strokes are separated**: stroke data is large and changes often, so it lives in its own file instead of rewriting one big JSON blob on every save.
- **Atomic writes**: writes go to `strokes.bin.tmp` first, then rename over the target, so a kill mid-write cannot corrupt existing artwork.
- **Save timing**: throttled 0.8s after pen-up; flushed immediately when the app goes to background or the canvas is left.
- **Fault tolerance**: a damaged document keeps whatever strokes parsed cleanly and shows the reason in the canvas.

Document format (all little-endian):

```
header : "YSTK"(4) | version u16 | stroke_count u32
stroke : id u32 | color u32 | width f32 | point_count u32
point  : x f32 | y f32 | pressure f32 | timestamp_ms u32
```

Coordinates are stored as f32: normalized values live in 0–1, absolute precision is about 6e-8 — far below visible error — and the payload is half the size.

### Stroke processing

- **Smoothing is incremental, during capture** (`StrokeSmoother`): point `i` has window `[i-2, i+2]`, so its value is fixed once two more samples arrive. What you see while drawing is exactly what gets committed and persisted.
- **The input hot path never crosses FFI**: pen-up commits synchronously, so there is no gap frame waiting on an async round trip.
- Rust's `smooth_stroke` / `simplify_stroke` remain for batch work (export simplification, reprocessing legacy documents) and are not used per point.

### Coordinate and width contracts

- Coordinates: normalized to `0.0 ~ 1.0` relative to canvas size.
- Stroke width: normalized to the canvas **short edge** (e.g. `0.01` = 1%), converted to pixels at render time.

Both are dimensionless, so zoom, export, and cross-device previews can reuse the same data. **Any change that bakes zoom into coordinates breaks this contract.**

## Tests

```powershell
cargo test --manifest-path rust/Cargo.toml   # geometry and document codec
flutter test                                 # smoother, storage, UI flow
flutter analyze                              # static analysis
```

> If `flutter test` runs behind an HTTP proxy, add `localhost` / `127.0.0.1` to `NO_PROXY`; otherwise the proxy intercepts flutter_tester's local WebSocket.

## Known limitations

- Android only; the `windows/` project exists to debug rendering, not as a delivery target.
- The canvas toolbar is a single non-scrolling row and overflows on narrow screens (< 425dp); a redesign is pending.
- No eraser, zoom/pan, export, or layers yet.
- `applicationId` is still `com.example.ystrokes` and must be changed before release.

## License

[WTFPL v2](LICENSE)

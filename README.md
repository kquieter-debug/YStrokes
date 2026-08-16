# YStrokes

# 专注于笔触的绘画应用：**Flutter 负责渲染与交互，Rust 负责计算密集的几何处理**
是我个人

## 目录结构

```
ystrokes/
├─ lib/                      # Flutter 源码
│  ├─ main.dart              # 入口
│  └─ src/
│     ├─ app.dart            # 根组件
│     ├─ models/             # Stroke / DrawingProject 数据模型
│     ├─ screens/            # welcome / home / canvas 三个界面
│     ├─ services/           # DrawingEngine / ProjectStore / SettingsService
│     ├─ widgets/            # 复用组件
│     └─ rust/               # flutter_rust_bridge 生成的绑定
├─ rust/                     # Rust 后端 crate
│  ├─ Cargo.toml
│  └─ src/
│     ├─ lib.rs
│     ├─ api/mod.rs          # 暴露给 Flutter 的 API（业务逻辑）
│     └─ frb_generated.rs    # 生成的胶水代码
├─ rust_builder/             # cargokit 构建胶水（Rust → Android .so）
├─ android/                  # Android 工程
├─ flutter_rust_bridge.yaml  # codegen 配置
└─ test/                     # Flutter widget 测试
```

## 前置条件

- Flutter SDK（stable，Dart 3.x）
- Android SDK + **NDK**（cargokit 交叉编译 Rust 需要，`flutter doctor` 检查）
- Rust 工具链（`rustc` / `cargo`）+ `cargo-ndk`
- Android 交叉编译目标（cargokit 会按需调用 cargo-ndk，通常无需手动安装 target）

## 首次构建

```powershell
flutter pub get
cargo install cargo-ndk            # 若尚未安装
flutter_rust_bridge_codegen generate   # 生成 Dart 绑定（修改 Rust API 后重跑）
flutter run                        # 或 flutter build apk
```

## 修改 Rust API 后

1. 编辑 `rust/src/api/mod.rs`。
2. 重新生成绑定：`flutter_rust_bridge_codegen generate`。
3. 运行 Rust 单测：`cargo test --manifest-path rust/Cargo.toml`。

## 测试

```powershell
cargo test --manifest-path rust/Cargo.toml   # Rust 单元测试
flutter test                                  # Flutter widget 测试
flutter analyze                               # Dart 静态分析
```
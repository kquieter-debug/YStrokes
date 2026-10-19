<div align="right">
  <b>简体中文</b> · <a href="README.en.md">English</a>
</div>

### 用 AI 写的一个小东西🤓
# YStrokes

面向 Android 的矢量笔画绘画应用，专注于笔触手感。前端使用 Flutter，几何计算与文档格式由 Rust 承担，两者通过 `flutter_rust_bridge` 连接。

> **状态**：MVP。核心链路（绘制 → 自动保存 → 退出重进）已打通，但尚未在 Android 真机上完成全量验证。

## 特性

- **矢量存储**：笔画以归一化坐标保存，与分辨率解耦，更换设备或导出时比例不变。
- **增量平滑**：平滑在采集阶段完成，抬手提交的点列与屏幕显示逐位相同——不闪烁、不形变。
- **可靠落盘**：原子写入（临时文件 + 重命名），进程被系统回收也不会留下半截文档；文档损坏时按「部分恢复」处理。
- **可撤销**：新增笔画与清空画布均可撤销。

## 技术栈

| 层 | 技术 |
| --- | --- |
| 前端 | Flutter / Dart 3.12+，Material 3 |
| 几何与文档格式 | Rust 2021（crate `ystrokes_rust`） |
| 桥接 | flutter_rust_bridge 2.12.0（前后端版本需严格对齐） |
| Android 构建 | NDK + `cargo-ndk` + cargokit |

## 目录结构

```
ystrokes/
├─ lib/                      # Flutter 前端
│  ├─ main.dart              # 入口：初始化 FRB
│  └─ src/
│     ├─ app.dart            # 根组件与主题
│     ├─ models/             # DrawingProject / Stroke
│     ├─ screens/            # welcome / home / canvas
│     ├─ services/           # StrokeSmoother / DrawingEngine
│     │                      # DocumentStore / ProjectStore / SettingsService
│     ├─ widgets/            # ProjectTile
│     └─ rust/               # FRB 生成代码（勿手改）
├─ rust/                     # Rust 后端
│  ├─ Cargo.toml
│  └─ src/
│     ├─ lib.rs
│     ├─ api/mod.rs          # 对外 API + 文档编解码
│     └─ frb_generated.rs    # 生成代码（勿手改）
├─ rust_builder/             # cargokit：Rust → Android .so
├─ android/                  # Android 工程
├─ assets/                   # 应用图标
├─ test/                     # 单元与 widget 测试
├─ windows/                  # Windows 工程（仅用于快速验证渲染，非交付目标）
├─ flutter_rust_bridge.yaml  # codegen 配置
└─ pubspec.yaml
```

## 环境要求

- Flutter SDK（stable，Dart 3.12+）
- Android SDK 与 **NDK**
- Rust 工具链（`rustc` / `cargo`）与 `cargo-ndk`
- Android 交叉编译目标

## 快速开始

```powershell
flutter pub get
cargo install cargo-ndk                    # 如未安装
flutter_rust_bridge_codegen generate       # 生成 Rust → Flutter 绑定
flutter run                                # 或 flutter build apk
```

## 开发约定

### 修改 Rust API 后

1. 编辑 `rust/src/api/mod.rs`。
2. 重新生成绑定：`flutter_rust_bridge_codegen generate`。
3. 运行 Rust 测试：`cargo test --manifest-path rust/Cargo.toml`。

### 生成代码

`lib/src/rust/**` 与 `rust/src/frb_generated.rs` 均由 codegen 产出，**不要手工修改**——下次生成会被覆盖。

### 版本对齐

`pubspec.yaml`、`rust/Cargo.toml` 与本机 `flutter_rust_bridge_codegen` 三者的版本必须一致（当前 2.12.0）。生成代码与运行时版本错位会产生难以定位的故障。

## 设计要点

### 数据存储

| 内容 | 位置 | 说明 |
| --- | --- | --- |
| 工程元数据 | `shared_preferences`（键 `projects`） | 轻量索引，列表页只读这里 |
| 笔画数据 | `<appDocuments>/projects/<projectId>/strokes.bin` | 二进制，由 Rust 编解码 |

- **元数据与笔画分离**：笔画体量大、变化频繁，独立成文件，避免每次保存全量重写。
- **原子写入**：先写 `strokes.bin.tmp` 再重命名覆盖，写入中途被杀不会损坏既有文档。
- **保存时机**：抬笔后 0.8s 节流保存；退到后台或离开画布立即落盘。
- **容错**：文档损坏时保留已解析的完整笔画，并在画布顶部提示原因。

文档格式（全部小端序）：

```
header : "YSTK"(4) | version u16 | stroke_count u32
stroke : id u32 | color u32 | width f32 | point_count u32
point  : x f32 | y f32 | pressure f32 | timestamp_ms u32
```

坐标以 f32 落盘：归一化值域固定在 0~1，绝对精度约 6e-8，远小于可见误差，存储体积减半。

### 笔迹处理

- **平滑在采集阶段增量完成**（`StrokeSmoother`）：点 `i` 的窗口为 `[i-2, i+2]`，再收到 2 个采样点后取值即固定。因此「绘制中看到的形状」与「提交并持久化的形状」完全一致。
- **输入热路径不跨 FFI**：抬手时同步提交，不存在等待异步返回的空窗帧。
- Rust 侧的 `smooth_stroke` / `simplify_stroke` 保留用于批量处理（导出简化、历史文档重算），不参与逐点绘制。

### 坐标与笔宽契约

- 坐标：相对画布尺寸归一化到 `0.0 ~ 1.0`。
- 笔宽：相对画布**短边**的归一化比例（如 `0.01` 表示 1%），渲染时换算为像素。

两者同为无量纲量，因此缩放、导出与跨设备预览都能复用同一份数据。**任何将缩放烘焙进坐标的改动都会破坏这一契约。**

## 测试

```powershell
cargo test --manifest-path rust/Cargo.toml   # 几何算法与文档编解码
flutter test                                 # 平滑器、存储层、界面流程
flutter analyze                              # 静态检查
```

> 若在设置了 HTTP 代理的环境中运行 `flutter test`，需将 `localhost` / `127.0.0.1` 加入 `NO_PROXY`，否则 flutter_tester 的本地 WebSocket 会被代理拦截。

## 已知限制

- 仅面向 Android；`windows/` 工程用于调试渲染，不作为交付目标。
- 画布工具栏为单行布局，在窄屏（< 425dp）下会溢出，待重构。
- 尚无橡皮擦、缩放/平移、导出与图层面板。
- `applicationId` 仍为 `com.example.ystrokes`，发布前需替换。

## 许可证

[WTFPL v2](LICENSE)

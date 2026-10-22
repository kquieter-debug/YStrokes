<div align="right">
  <b>简体中文</b> · <a href="README.en.md">English</a>
</div>

### 用 AI 写的一个小东西🤓
# YStrokes

面向 Android 的矢量笔画绘画应用，专注于笔触手感。前端使用 Flutter，几何计算与文档格式由 Rust 承担，两者通过 `flutter_rust_bridge` 连接。

> **状态**：MVP。核心链路（绘制 → 自动保存 → 退出重进）已打通，但尚未在 Android 真机上完成全量验证。

## 特性

- **矢量存储**：笔画以归一化坐标保存，与分辨率解耦，更换设备或导出时比例不变。
- **画布规格**：新建时指定尺寸、分辨率与底色（内置 A4 / A5 / 手机 / 正方形等模板），参数随工程保存，不受设备影响。
- **增量平滑**：平滑在采集阶段完成，抬手提交的点列与屏幕显示逐位相同——不闪烁、不形变。
- **压感驱动笔宽**：压力经 gamma 映射为宽度（最细 25%），按点生成左右轮廓后一次填充；画布、缩略图、PNG 与 SVG 四处一致。画笔默认开启、橡皮默认关闭；**开关只影响之后画的笔**，已画内容保持画下时的样子。
- **工具设置气泡**：长按工具（或再次点按已选中的工具）在悬浮工具栏旁弹出设置面板，改完直接点外部关闭，没有确认按钮。
- **图层气泡**：图层面板固定停靠在屏幕右侧、自顶栏向下展开，改完即生效；同样没有确认按钮，点外部即收起。
- **选区与自由变换**：套索圈住要调整的内容，拖框内移动、拖角等比缩放、拖顶部圆点旋转，确认后一次撤销即可回退；还支持加选 / 减选 / 反向 / 切分到选区 / 翻转与数值输入；图层面板里还能对整层做同样的变换。
- **位图图层**：图层面板可新建位图图层，或把矢量图层**显式**栅格化为像素；像素笔与像素橡皮直接涂在瓦片上（256×256 惰性分配），像素以 PNG 独立落盘、抬笔即存。矢量与位图按图层共存，互不干扰，两者都支持水平/垂直翻转。
- **像素选区**：位图图层上用套索圈出一块像素，拖动即可整体移动，松手即提交、一次撤销可回退。选区边界是**流动虚线**，选区之外会**淡黑压暗**（可在设置里关掉）；边界带抗锯齿，移动后不留硬边。
- **吸管**：点按画面即可取色（取的是合成后的颜色），取完自动回到上一个绘画工具。
- **复制图层**：图层面板一键复制，副本叠在源层上方并自动选中。
- **不丢作品**：删除工程先进回收站，可恢复；矢量笔画抬笔即写增量日志，像素内容抬笔即落盘，进程被杀也不丢最后一笔。
- **可靠落盘**：原子写入（临时文件 + 重命名），进程被系统回收也不会留下半截文档；文档损坏时按「部分恢复」处理。
- **可撤销**：新增笔画、擦除、清空画布、图层增删改、选区删除与变换、像素笔画与栅格化均可撤销，按「步数 + 内存」双上限保留历史。
- **工具**：画笔、橡皮、吸管、选区。矢量图层上的橡皮以「擦除笔画」的形式记录，因此撤销天然成立；位图图层上的橡皮直接改像素。
- **图层**：每层独立不透明度、显隐与混合模式（12 种，与 Photoshop 同名）；支持重命名、拖拽排序、向下合并（仅矢量）。每层单独合成，橡皮只作用于本层。
- **视口**：双指缩放 / 旋转 / 平移，带「适配画布」复位；落笔坐标经视口反算，缩放后不偏移。
- **双指双击撤销**：两指快速点两下即撤销上一笔，不必抬手去点顶栏；缩放/旋转不会误触发。
- **工具栏**：悬浮面板可按住顶部「三个小点」拖动，位置按比例记忆，横屏、平板、分屏都不会挡住手写区。
- **导出**：PNG / JPG（1x·2x·3x·自定义，可透明）与纯矢量 SVG（保留图层组、橡皮转蒙版；**含位图图层时改用 PNG**）；Android 经 MediaStore 写入系统「下载/YStrokes」，桌面写入「下载/YStrokes」；保存位置可用系统文件管理器改选，导出后提示位置，不弹出分享面板。

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
│     ├─ models/             # DrawingProject / Stroke / DrawingLayer
│     │                      # DocumentSpec / CanvasPreset / ToolSettings
│     ├─ screens/            # welcome / home / canvas / new_document
│     │                      # sections：工程区 / 设置 / 关于
│     ├─ models/             # DrawingProject / Stroke / DrawingLayer / DocumentSpec
│     │                      # CanvasPreset / ToolSettings / StrokeRenderOptions
│     ├─ services/           # StrokeSmoother / DrawingEngine / stroke_outline
│     │                      # canvas_geometry / canvas_viewport / document_painter
│     │                      # DocumentStore / ProjectStore / DocumentExporter
│     │                      # SvgExporter / SettingsService / AppTheme
│     ├─ widgets/            # ProjectTile / AppIcon / SectionCard
│     │                      # HsvColorPicker / ToolSettingsSheet / LayersSheet
│     └─ rust/               # FRB 生成代码（勿手改）
├─ rust/                     # Rust 后端
│  ├─ Cargo.toml
│  └─ src/
│     ├─ lib.rs
│     └─ api/
│        ├─ mod.rs           # 对外 API 入口（ping / rust_version）
│        ├─ stroke.rs        # 笔画模型 + 批量几何
│        ├─ document.rs      # 文档 v4 编解码 + 混合模式
│        └─ tools/           # 画笔 / 橡皮，每工具一个子模块
├─ rust_builder/             # cargokit：Rust → Android .so
├─ android/                  # Android 工程
├─ assets/                   # 应用图标
│  └─ icons/                 # 界面 SVG 图标（替换文件即可换图）
├─ test/                     # 单元与 widget 测试（18 个文件）
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
header : "YSTK"(4) | version u16 | layer_count u32
layer  : name_len u16 | name utf8 | opacity f32 | visible u8 | blend u8 | stroke_count u32
stroke : id u32 | color u32 | width f32 | point_count u32 | tool u8
point  : x f32 | y f32 | pressure f32 | timestamp_ms u32
```

坐标以 f32 落盘：归一化值域固定在 0~1，绝对精度约 6e-8，远小于可见误差，存储体积减半。
格式版本为 v4（图层 + 不透明度 + 可见性 + 混合模式）。解码只接受当前版本：项目尚未发布，
不做旧格式兼容，版本号不匹配会明确报错而不是猜测结构。

### 笔迹处理

- **平滑在采集阶段增量完成**（`StrokeSmoother`）：点 `i` 的窗口为 `[i-2, i+2]`，再收到 2 个采样点后取值即固定。因此「绘制中看到的形状」与「提交并持久化的形状」完全一致。
- **输入热路径不跨 FFI**：抬手时同步提交，不存在等待异步返回的空窗帧。
- Rust 侧的 `smooth_stroke` / `simplify_stroke` 保留用于批量处理（导出简化、历史文档重算），不参与逐点绘制。

### 画布与工具面板

画板由三层构成，自下而上：

1. **工作台**：文档之外的底色区域。
2. **文档**：按工程固有宽高比居中的纸面，笔画只绘制在这里。
3. **工具面板**：贴左缘悬浮，分「工具 / 颜色 / 尺寸」三区，统一两列排版，尺寸随屏幕短边自适应。

面板是覆盖层而非布局元素，因此它变宽或变窄都不会挤压、缩放文档；文档矩形只由
「文档比例」与「可用区域」决定。文档比例来自新建时设定的画布规格（`DocumentSpec`），
随工程保存，因此旋转屏幕或更换设备都不会改变文档形状。

工具面板的尺寸随屏幕短边在 34~48dp 之间自适应，取短边而非宽度是为了让竖屏与横屏
获得一致的触控密度。

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
- 工具面板固定两列、暂不支持折叠；工具目前只有画笔与橡皮，配色与笔宽为固定档位。
- 尚无图层组与蒙版；向下合并会丢弃上方图层的不透明度与混合模式（合并前会提示）。
- 导出暂不支持逐层批量；工程含位图内容时不可导出 SVG。

## 许可证

[WTFPL v2](LICENSE)

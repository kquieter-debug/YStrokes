//! 文档二进制编解码。
//!
//! 磁盘格式（全部小端序）：
//!
//! ```text
//! header : magic "YSTK"(4) | version u16 | layer_count u32
//! layer  : name_len u16 | name utf8 | opacity f32 | visible u8 | blend u8 | kind u8 | payload
//!   kind 0 (vector) : stroke_count u32 | stroke...
//!   kind 1 (raster) : width u32 | height u32 | tile_size u16 | tile_count u32 | tile...
//! stroke : id u32 | color u32 | width f32 | point_count u32 | tool u8 | uses_pressure u8
//! point  : x f32 | y f32 | pressure f32 | timestamp_ms u32
//! tile   : x u16 | y u16
//! ```
//!
//! `kind` 放在图层头、payload 按类型分支，而不是「统一成通用属性包」：分支只有两支，
//! 矢量分支的字节与 v5 的笔画段逐位一致，便于对照测试；通用属性包会让解码器
//! 必须理解所有类型的字段组合，出错面更大。
//!
//! 位图图层的**像素不进文档**：这里只记「哪些瓦片存在」，像素落在
//! `<project>/tiles/<layerOrdinal>/<x>_<y>.png`。理由是 Rust 侧目前没有任何压缩依赖，
//! 引入 `flate2` 会牵动构建与 ABI；而 PNG 在 Dart 侧已有（`image` 包），
//! 且它可以直接用看图软件打开，排查「导出与屏幕不一致」时省事。
//!
//! 当前版本 v6。**只接受当前版本**（ADR-020）：第一版 release 尚未发布，
//! 没有需要照顾的旧文件，因此不留迁移分支。迁移代码一旦写下来就永久背负两套结构，
//! 而它保护的用户群体目前为零——这类代码应当在真有历史包袱时再加。
//!
//! 坐标用 f32 而非 f64：归一化值域固定在 0~1，绝对精度约 6e-8，
//! 远小于简化容差（1e-3 量级），体积却减半。

use super::stroke::{Stroke, StrokePoint};
use super::tools::ToolKind;

/// 文档魔数，用于快速识别非本应用文件。
const DOC_MAGIC: [u8; 4] = *b"YSTK";

/// 当前文档版本。解码只接受这一版。
pub const DOC_VERSION: u16 = 6;

/// 头部长度：magic(4) + version(2) + layer_count(4)。
const DOC_HEADER_LEN: usize = 10;

/// 单条笔画头部：id + color + width + point_count + tool + uses_pressure。
const STROKE_HEADER: usize = 18;

/// 图层头部：name_len(2) + opacity(4) + visible(1) + blend(1) + kind(1)。
const LAYER_HEADER_FIXED: usize = 9;

/// 矢量 payload 的固定部分：stroke_count(4)。
const VECTOR_PAYLOAD_HEADER: usize = 4;

/// 位图 payload 的固定部分：width(4) + height(4) + tile_size(2) + tile_count(4)。
const RASTER_PAYLOAD_HEADER: usize = 14;

/// 单个瓦片引用：x(2) + y(2)。
const TILE_REF_LEN: usize = 4;

/// 单个采样点长度：x + y + pressure + timestamp。
const POINT_LEN: usize = 16;

/// 图层名长度上限，防止损坏文件把它解释成一个巨大的分配。
const MAX_LAYER_NAME_LEN: usize = 512;

/// 位图单边上限。超过它的宽高声明视为损坏——否则一个坏整数就能触发巨型分配。
const MAX_RASTER_SIDE: u32 = 8192;

/// 瓦片边长上限。取值过大等于退回「整层一张图」，会让惰性分配失去意义。
const MAX_TILE_SIZE: u16 = 512;

/// 图层混合模式。
///
/// 只收录与 Photoshop 同名同义、且 Skia 有直接对应实现的一组。
/// **存储编码一经发布不可重排**，新增模式只能追加在末尾。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerBlendMode {
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    ColorDodge,
    ColorBurn,
    SoftLight,
    HardLight,
    Difference,
    Exclusion,
}

impl LayerBlendMode {
    pub fn to_code(self) -> u8 {
        match self {
            LayerBlendMode::Normal => 0,
            LayerBlendMode::Multiply => 1,
            LayerBlendMode::Screen => 2,
            LayerBlendMode::Overlay => 3,
            LayerBlendMode::Darken => 4,
            LayerBlendMode::Lighten => 5,
            LayerBlendMode::ColorDodge => 6,
            LayerBlendMode::ColorBurn => 7,
            LayerBlendMode::SoftLight => 8,
            LayerBlendMode::HardLight => 9,
            LayerBlendMode::Difference => 10,
            LayerBlendMode::Exclusion => 11,
        }
    }

    /// 未知编码按「正常」处理：这是针对单字节损坏的容错，
    /// 与版本兼容无关——文档版本号在解码入口已校验。
    pub fn from_code(code: u8) -> Self {
        match code {
            1 => LayerBlendMode::Multiply,
            2 => LayerBlendMode::Screen,
            3 => LayerBlendMode::Overlay,
            4 => LayerBlendMode::Darken,
            5 => LayerBlendMode::Lighten,
            6 => LayerBlendMode::ColorDodge,
            7 => LayerBlendMode::ColorBurn,
            8 => LayerBlendMode::SoftLight,
            9 => LayerBlendMode::HardLight,
            10 => LayerBlendMode::Difference,
            11 => LayerBlendMode::Exclusion,
            _ => LayerBlendMode::Normal,
        }
    }
}

/// 图层内容的类型。
///
/// 不落成图层上的独立字段，而是由 `Layer::raster` 是否为空推导——
/// 两个字段表达同一件事时，总会出现「声明的类型与载荷不一致」的中间态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerKind {
    Vector,
    Raster,
}

impl LayerKind {
    pub fn to_code(self) -> u8 {
        match self {
            LayerKind::Vector => 0,
            LayerKind::Raster => 1,
        }
    }

    /// 未知编码按矢量处理：与混合模式一样，只针对单字节损坏做容错。
    pub fn from_code(code: u8) -> Self {
        match code {
            1 => LayerKind::Raster,
            _ => LayerKind::Vector,
        }
    }
}

/// 一个已分配的瓦片坐标。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TileRef {
    pub x: u16,
    pub y: u16,
}

/// 位图图层的尺寸与瓦片清单。
///
/// 位图尺寸恒等于文档尺寸（D1：不做超采样），`tile_size` 决定网格划分，
/// `tiles` 只列「真的写过像素」的那些瓦片——空白瓦片不占磁盘也不占内存。
#[derive(Debug, Clone, PartialEq)]
pub struct RasterInfo {
    pub width: u32,
    pub height: u32,
    pub tile_size: u16,
    pub tiles: Vec<TileRef>,
}

impl RasterInfo {
    pub fn new(width: u32, height: u32, tile_size: u16) -> Self {
        Self {
            width,
            height,
            tile_size,
            tiles: Vec::new(),
        }
    }

    /// 横向/纵向各需要多少块瓦片（至少 1）。
    pub fn grid(&self) -> (u32, u32) {
        let size = self.tile_size.max(1) as u32;
        (self.width.div_ceil(size).max(1), self.height.div_ceil(size).max(1))
    }

    fn is_sane(&self) -> bool {
        self.tile_size > 0
            && self.tile_size <= MAX_TILE_SIZE
            && self.width > 0
            && self.height > 0
            && self.width <= MAX_RASTER_SIDE
            && self.height <= MAX_RASTER_SIDE
    }
}

/// 一个图层。
///
/// 图层顺序即绘制顺序：索引 0 在最底层。
///
/// **不变量**：`raster.is_some()` 的图层 `strokes` 必须为空。两种内容不会同时存在
/// （方案 C 混合层已明确不做），因此「图层类型」不需要额外的字段。
#[derive(Debug, Clone, PartialEq)]
pub struct Layer {
    pub name: String,
    /// 不透明度，0.0 ~ 1.0。
    pub opacity: f64,
    /// 是否参与合成。
    pub visible: bool,
    /// 与下方图层内容的混合方式。
    pub blend_mode: LayerBlendMode,
    /// 矢量内容；位图图层恒为空。
    pub strokes: Vec<Stroke>,
    /// 位图内容；矢量图层为 `None`。
    pub raster: Option<RasterInfo>,
}

impl Layer {
    pub fn new(name: String) -> Self {
        Self {
            name,
            opacity: 1.0,
            visible: true,
            blend_mode: LayerBlendMode::Normal,
            strokes: Vec::new(),
            raster: None,
        }
    }

    /// 新建位图图层：不带任何瓦片，等于一张全透明画布。
    pub fn raster_layer(name: String, info: RasterInfo) -> Self {
        Self {
            name,
            opacity: 1.0,
            visible: true,
            blend_mode: LayerBlendMode::Normal,
            strokes: Vec::new(),
            raster: Some(info),
        }
    }

    pub fn kind(&self) -> LayerKind {
        match self.raster {
            Some(_) => LayerKind::Raster,
            None => LayerKind::Vector,
        }
    }
}

/// 文档解码结果。
///
/// 解码采用「部分恢复」策略：文档截断或尾部损坏时，保留此前已完整解析的图层，
/// 并通过 `error` 说明原因。对绘画应用而言，「保住大部分作品」优于「全有或全无」。
#[derive(Debug, Clone, PartialEq)]
pub struct DecodeOutcome {
    pub layers: Vec<Layer>,
    pub error: Option<String>,
}

/// 把图层序列编码为字节流，供前端原子写入磁盘。
pub fn encode_document(layers: Vec<Layer>) -> Vec<u8> {
    let payload: usize = layers
        .iter()
        .map(|layer| {
            let body = match &layer.raster {
                Some(info) => RASTER_PAYLOAD_HEADER + info.tiles.len() * TILE_REF_LEN,
                None => {
                    VECTOR_PAYLOAD_HEADER
                        + layer
                            .strokes
                            .iter()
                            .map(|s| STROKE_HEADER + s.points.len() * POINT_LEN)
                            .sum::<usize>()
                }
            };
            LAYER_HEADER_FIXED + layer.name.len() + body
        })
        .sum();
    let mut out = Vec::with_capacity(DOC_HEADER_LEN + payload);

    out.extend_from_slice(&DOC_MAGIC);
    out.extend_from_slice(&DOC_VERSION.to_le_bytes());
    out.extend_from_slice(&(layers.len() as u32).to_le_bytes());

    for layer in &layers {
        let name = layer.name.as_bytes();
        let name_len = name.len().min(u16::MAX as usize);
        out.extend_from_slice(&(name_len as u16).to_le_bytes());
        out.extend_from_slice(&name[..name_len]);
        out.extend_from_slice(&(layer.opacity as f32).to_le_bytes());
        out.push(if layer.visible { 1 } else { 0 });
        out.push(layer.blend_mode.to_code());
        out.push(layer.kind().to_code());

        match &layer.raster {
            Some(info) => {
                out.extend_from_slice(&info.width.to_le_bytes());
                out.extend_from_slice(&info.height.to_le_bytes());
                out.extend_from_slice(&info.tile_size.to_le_bytes());
                out.extend_from_slice(&(info.tiles.len() as u32).to_le_bytes());
                for tile in &info.tiles {
                    out.extend_from_slice(&tile.x.to_le_bytes());
                    out.extend_from_slice(&tile.y.to_le_bytes());
                }
            }
            None => {
                out.extend_from_slice(&(layer.strokes.len() as u32).to_le_bytes());
                for stroke in &layer.strokes {
                    // 笔画头顺序固定为 id | color | width | point_count | tool | uses_pressure，
                    // 与图层外壳解耦，便于后续只演进图层结构而不动笔画。
                    // 新增字段只能追加在末尾（见 ADR-008、ADR-019）。
                    out.extend_from_slice(&stroke.id.to_le_bytes());
                    out.extend_from_slice(&stroke.color.to_le_bytes());
                    out.extend_from_slice(&(stroke.width as f32).to_le_bytes());
                    out.extend_from_slice(&(stroke.points.len() as u32).to_le_bytes());
                    out.push(stroke.tool.to_code());
                    out.push(if stroke.uses_pressure { 1 } else { 0 });
                    for p in &stroke.points {
                        out.extend_from_slice(&(p.x as f32).to_le_bytes());
                        out.extend_from_slice(&(p.y as f32).to_le_bytes());
                        out.extend_from_slice(&(p.pressure as f32).to_le_bytes());
                        out.extend_from_slice(&p.timestamp_ms.to_le_bytes());
                    }
                }
            }
        }
    }
    out
}

/// 把字节流解码为图层列表；损坏时尽可能恢复已解析的部分。
pub fn decode_document(bytes: Vec<u8>) -> DecodeOutcome {
    let data = bytes.as_slice();
    if data.len() < DOC_HEADER_LEN {
        return DecodeOutcome {
            layers: Vec::new(),
            error: Some(format!(
                "文档长度不足：{} 字节（头部需要 {} 字节）",
                data.len(),
                DOC_HEADER_LEN
            )),
        };
    }
    if data[0..4] != DOC_MAGIC {
        return DecodeOutcome {
            layers: Vec::new(),
            error: Some("文件标识不匹配，不是 YStrokes 文档".to_string()),
        };
    }

    let version = read_u16(data, 4);
    if version != DOC_VERSION {
        return DecodeOutcome {
            layers: Vec::new(),
            error: Some(format!(
                "不支持的文档版本 {version}（当前版本 {DOC_VERSION}）"
            )),
        };
    }
    decode_layers(data, read_u32(data, 6) as usize)
}

/// 解析图层树。
fn decode_layers(data: &[u8], layer_count: usize) -> DecodeOutcome {
    let mut cursor = DOC_HEADER_LEN;
    let mut layers = Vec::new();
    let mut error = None;

    for index in 0..layer_count {
        if data.len() < cursor + 2 {
            error = Some(format!(
                "文档在第 {} 个图层处截断（共声明 {} 个）",
                index + 1,
                layer_count
            ));
            break;
        }
        let name_len = read_u16(data, cursor) as usize;
        cursor += 2;

        if name_len > MAX_LAYER_NAME_LEN || data.len() < cursor + name_len + 7 {
            error = Some(format!("第 {} 个图层的名称长度非法或已截断", index + 1));
            break;
        }
        let name = String::from_utf8_lossy(&data[cursor..cursor + name_len]).to_string();
        cursor += name_len;

        let opacity = read_f32(data, cursor) as f64;
        let visible = data[cursor + 4] != 0;
        let blend_mode = LayerBlendMode::from_code(data[cursor + 5]);
        let kind = LayerKind::from_code(data[cursor + 6]);
        cursor += 7;

        let mut layer = Layer {
            name,
            opacity: opacity.clamp(0.0, 1.0),
            visible,
            blend_mode,
            strokes: Vec::new(),
            raster: None,
        };

        let layer_error = match kind {
            LayerKind::Vector => read_vector_payload(data, cursor, &mut layer),
            LayerKind::Raster => read_raster_payload(data, cursor, &mut layer),
        };

        layers.push(layer);
        match layer_error {
            Ok(next) => cursor = next,
            Err(message) => {
                error = Some(message);
                break;
            }
        }
    }

    if layers.is_empty() && error.is_none() {
        error = Some("文档不含任何图层".to_string());
    }

    DecodeOutcome { layers, error }
}

/// 解析矢量 payload，返回下一个游标。
///
/// 出错时已解析的笔画会留在 `layer.strokes` 里：这是「部分恢复」的实现方式——
/// 首条笔画就坏与第 100 条才坏的差别只在保住多少内容，不在是否整层丢弃。
fn read_vector_payload(
    data: &[u8],
    start: usize,
    layer: &mut Layer,
) -> Result<usize, String> {
    if data.len() < start + VECTOR_PAYLOAD_HEADER {
        return Err(format!("图层「{}」在笔画数处截断", layer.name));
    }
    let stroke_count = read_u32(data, start) as usize;
    let mut cursor = start + VECTOR_PAYLOAD_HEADER;

    for index in 0..stroke_count {
        match read_stroke(data, cursor) {
            Ok((stroke, next)) => {
                layer.strokes.push(stroke);
                cursor = next;
            }
            Err(message) => {
                return Err(format!(
                    "图层「{}」第 {} 条笔画：{message}",
                    layer.name,
                    index + 1
                ));
            }
        }
    }
    Ok(cursor)
}

/// 解析位图 payload，返回下一个游标。
///
/// 截断发生在瓦片清单中途时保留已解析的瓦片——文档本身不含像素，
/// 保住清单就等于保住了「哪些瓦片要读」，像素文件仍在磁盘上。
fn read_raster_payload(
    data: &[u8],
    start: usize,
    layer: &mut Layer,
) -> Result<usize, String> {
    if data.len() < start + RASTER_PAYLOAD_HEADER {
        return Err(format!("位图图层「{}」在尺寸处截断", layer.name));
    }
    let width = read_u32(data, start);
    let height = read_u32(data, start + 4);
    let tile_size = read_u16(data, start + 8);
    let tile_count = read_u32(data, start + 10) as usize;
    let mut cursor = start + RASTER_PAYLOAD_HEADER;

    let mut info = RasterInfo::new(width, height, tile_size);
    if !info.is_sane() {
        return Err(format!(
            "位图图层「{}」的尺寸非法：{}×{}，瓦片 {}",
            layer.name, width, height, tile_size
        ));
    }

    let (cols, rows) = info.grid();
    let available = tile_count.min(data.len().saturating_sub(cursor) / TILE_REF_LEN);

    for _ in 0..available {
        let x = read_u16(data, cursor);
        let y = read_u16(data, cursor + 2);
        cursor += TILE_REF_LEN;
        // 越界坐标直接丢弃：读到网格外的瓦片只可能是文件损坏，
        // 让它进入渲染路径会让采样越界。
        if (x as u32) < cols && (y as u32) < rows {
            info.tiles.push(TileRef { x, y });
        }
    }

    layer.raster = Some(info);

    if available < tile_count {
        return Err(format!(
            "位图图层「{}」的瓦片清单截断（声明 {}，可读 {}）",
            layer.name, tile_count, available
        ));
    }
    Ok(cursor)
}

/// 解析一条笔画，返回（笔画, 下一个游标）。
fn read_stroke(data: &[u8], start: usize) -> Result<(Stroke, usize), String> {
    if data.len() < start + STROKE_HEADER {
        return Err("数据截断".to_string());
    }
    let id = read_u32(data, start);
    let color = read_u32(data, start + 4);
    let width = read_f32(data, start + 8) as f64;
    let point_count = read_u32(data, start + 12) as usize;
    let tool = ToolKind::from_code(data[start + 16]);
    let uses_pressure = data[start + 17] != 0;

    let mut cursor = start + STROKE_HEADER;
    if point_count > data.len().saturating_sub(cursor) / POINT_LEN {
        return Err(format!("点数声明为 {point_count}，超出文件剩余长度"));
    }

    let mut points = Vec::with_capacity(point_count);
    for _ in 0..point_count {
        let x = read_f32(data, cursor) as f64;
        let y = read_f32(data, cursor + 4) as f64;
        let pressure = read_f32(data, cursor + 8) as f64;
        let timestamp_ms = read_u32(data, cursor + 12);
        cursor += POINT_LEN;

        if !x.is_finite() || !y.is_finite() || !pressure.is_finite() {
            return Err("包含非法坐标".to_string());
        }
        points.push(StrokePoint::new(x, y, pressure, timestamp_ms));
    }

    Ok((
        Stroke {
            id,
            tool,
            color,
            width,
            points,
            uses_pressure,
        },
        cursor,
    ))
}

fn read_u16(data: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([data[at], data[at + 1]])
}

fn read_u32(data: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]])
}

fn read_f32(data: &[u8], at: usize) -> f32 {
    f32::from_le_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_stroke(id: u32, tool: ToolKind) -> Stroke {
        Stroke {
            id,
            tool,
            color: 0xFFEF4444,
            width: 0.0125,
            points: vec![
                StrokePoint::new(0.25, 0.5, 1.0, 0),
                StrokePoint::new(0.5, 0.75, 0.5, 16),
                StrokePoint::new(0.75, 0.125, 0.25, 32),
            ],
            uses_pressure: tool == ToolKind::Brush,
        }
    }

    fn sample_layers() -> Vec<Layer> {
        vec![
            Layer {
                name: "背景".to_string(),
                opacity: 1.0,
                visible: true,
                blend_mode: LayerBlendMode::Normal,
                strokes: vec![sample_stroke(0, ToolKind::Brush)],
                raster: None,
            },
            Layer {
                name: "线稿".to_string(),
                opacity: 0.4,
                visible: false,
                blend_mode: LayerBlendMode::Multiply,
                strokes: vec![
                    sample_stroke(7, ToolKind::Brush),
                    sample_stroke(8, ToolKind::Eraser),
                ],
                raster: None,
            },
        ]
    }

    fn sample_raster_layer() -> Layer {
        let mut info = RasterInfo::new(1080, 1920, 256);
        info.tiles = vec![
            TileRef { x: 0, y: 0 },
            TileRef { x: 3, y: 7 },
            TileRef { x: 4, y: 2 },
        ];
        Layer::raster_layer("位图".to_string(), info)
    }

    #[test]
    fn round_trip_preserves_layers_and_strokes() {
        let original = sample_layers();
        let outcome = decode_document(encode_document(original.clone()));

        assert!(outcome.error.is_none(), "不应产生错误：{:?}", outcome.error);
        assert_eq!(outcome.layers.len(), 2);

        let decoded = &outcome.layers;
        assert_eq!(decoded[0].name, original[0].name);
        assert_eq!(decoded[1].name, original[1].name);
        assert!((decoded[1].opacity - 0.4).abs() < 1e-6);
        assert!(!decoded[1].visible);
        assert_eq!(decoded[1].blend_mode, LayerBlendMode::Multiply);
        assert_eq!(decoded[0].blend_mode, LayerBlendMode::Normal);
        assert_eq!(decoded[1].strokes.len(), 2);
        assert_eq!(decoded[1].strokes[1].tool, ToolKind::Eraser);
        assert_eq!(decoded[0].strokes[0].points.len(), 3);
    }

    #[test]
    fn header_layout_is_stable() {
        let bytes = encode_document(sample_layers());
        assert_eq!(&bytes[0..4], b"YSTK");
        assert_eq!(read_u16(&bytes, 4), DOC_VERSION);
        assert_eq!(read_u32(&bytes, 6), 2);
    }

    #[test]
    fn empty_document_reports_error() {
        // v3 且零图层：结构上不合法（至少应有一个图层）。
        let bytes = encode_document(Vec::new());
        let outcome = decode_document(bytes);
        assert!(outcome.layers.is_empty());
        assert!(outcome.error.is_some());
    }

    #[test]
    fn rejects_short_input() {
        let outcome = decode_document(vec![0u8; 5]);
        assert!(outcome.error.is_some());
        assert!(outcome.layers.is_empty());
    }

    #[test]
    fn rejects_bad_magic() {
        let mut bytes = encode_document(sample_layers());
        bytes[0] = b'X';
        let outcome = decode_document(bytes);
        assert!(outcome.error.is_some());
        assert!(outcome.layers.is_empty());
    }

    #[test]
    fn rejects_unknown_version() {
        let mut bytes = encode_document(sample_layers());
        bytes[4..6].copy_from_slice(&999u16.to_le_bytes());
        let outcome = decode_document(bytes);
        assert!(outcome.error.as_deref().unwrap_or("").contains("999"));
        assert!(outcome.layers.is_empty());
    }

    #[test]
    fn recovers_completed_layers_when_truncated() {
        let bytes = encode_document(sample_layers());
        let truncated = bytes[..bytes.len() - 24].to_vec();
        let outcome = decode_document(truncated);

        assert_eq!(outcome.layers.len(), 2);
        // 第二个图层被截断：其笔画只剩能完整解析的部分。
        assert!(outcome.layers[1].strokes.len() < 2);
        assert!(outcome.error.is_some());
    }

    #[test]
    fn ignores_trailing_bytes() {
        let mut bytes = encode_document(sample_layers());
        bytes.extend_from_slice(&[0xAB; 8]);
        let outcome = decode_document(bytes);
        assert!(outcome.error.is_none());
        assert_eq!(outcome.layers.len(), 2);
    }

    #[test]
    fn every_blend_mode_survives_round_trip() {
        for mode in [
            LayerBlendMode::Normal,
            LayerBlendMode::Multiply,
            LayerBlendMode::Screen,
            LayerBlendMode::Overlay,
            LayerBlendMode::Darken,
            LayerBlendMode::Lighten,
            LayerBlendMode::ColorDodge,
            LayerBlendMode::ColorBurn,
            LayerBlendMode::SoftLight,
            LayerBlendMode::HardLight,
            LayerBlendMode::Difference,
            LayerBlendMode::Exclusion,
        ] {
            let mut layer = Layer::new("层".to_string());
            layer.blend_mode = mode;
            let outcome = decode_document(encode_document(vec![layer]));
            assert_eq!(outcome.layers[0].blend_mode, mode);
        }
    }

    #[test]
    fn unknown_blend_code_falls_back_to_normal() {
        let mut bytes = encode_document(vec![Layer::new("层".to_string())]);
        // 图层头：10 字节文档头 + name_len(2) + name(3 字节「层」) + opacity(4) + visible(1)
        let blend_offset = DOC_HEADER_LEN + 2 + "层".len() + 4 + 1;
        bytes[blend_offset] = 200;
        let outcome = decode_document(bytes);
        assert_eq!(outcome.layers[0].blend_mode, LayerBlendMode::Normal);
    }

    #[test]
    fn clamps_out_of_range_opacity() {
        let mut layers = sample_layers();
        layers[0].opacity = 5.0;
        let outcome = decode_document(encode_document(layers));
        assert!((outcome.layers[0].opacity - 1.0).abs() < 1e-6);
    }

    #[test]
    fn rejects_previous_version() {
        // 只改版本号，其余字节保持合法：报错必须来自版本检查，而不是解析失败。
        let mut bytes = encode_document(sample_layers());
        bytes[4..6].copy_from_slice(&5u16.to_le_bytes());

        let outcome = decode_document(bytes);
        assert!(outcome.layers.is_empty());
        let error = outcome.error.unwrap_or_default();
        assert!(error.contains('5'), "错误信息应指出实际版本：{error}");
        assert!(error.contains('6'), "错误信息应指出当前版本：{error}");
    }

    #[test]
    fn round_trip_preserves_pressure_flag() {
        let mut layers = sample_layers();
        layers[0].strokes[0].uses_pressure = false;
        layers[1].strokes[0].uses_pressure = true;

        let outcome = decode_document(encode_document(layers));
        assert!(outcome.error.is_none());
        assert!(!outcome.layers[0].strokes[0].uses_pressure);
        assert!(outcome.layers[1].strokes[0].uses_pressure);
    }

    #[test]
    fn writes_current_version() {
        let bytes = encode_document(sample_layers());
        assert_eq!(read_u16(&bytes, 4), DOC_VERSION);
        assert_eq!(DOC_VERSION, 6);
    }

    // ---- v6 位图图层 ----

    #[test]
    fn raster_layer_round_trips() {
        let original = vec![sample_raster_layer()];
        let outcome = decode_document(encode_document(original.clone()));

        assert!(outcome.error.is_none(), "不应产生错误：{:?}", outcome.error);
        let decoded = &outcome.layers[0];
        assert_eq!(decoded.kind(), LayerKind::Raster);
        assert!(decoded.strokes.is_empty(), "位图图层不应带笔画");

        let info = decoded.raster.as_ref().expect("应保留位图信息");
        assert_eq!(info.width, 1080);
        assert_eq!(info.height, 1920);
        assert_eq!(info.tile_size, 256);
        assert_eq!(info.tiles, original[0].raster.as_ref().unwrap().tiles);
    }

    #[test]
    fn mixed_layers_keep_order_and_kind() {
        let layers = vec![
            Layer::new("底".to_string()),
            sample_raster_layer(),
            Layer::new("顶".to_string()),
        ];
        let outcome = decode_document(encode_document(layers));
        assert!(outcome.error.is_none());
        assert_eq!(outcome.layers.len(), 3);
        assert_eq!(outcome.layers[0].kind(), LayerKind::Vector);
        assert_eq!(outcome.layers[1].kind(), LayerKind::Raster);
        assert_eq!(outcome.layers[2].kind(), LayerKind::Vector);
    }

    #[test]
    fn raster_grid_uses_ceil_division() {
        let info = RasterInfo::new(1080, 1920, 256);
        // 1080 / 256 = 4.22 → 5 列；1920 / 256 = 7.5 → 8 行。
        assert_eq!(info.grid(), (5, 8));
    }

    #[test]
    fn raster_rejects_insane_dimensions() {
        let mut info = RasterInfo::new(0, 1920, 256);
        let layer = Layer::raster_layer("坏".to_string(), info.clone());
        assert!(decode_document(encode_document(vec![layer]))
            .error
            .is_some());

        info = RasterInfo::new(1080, 1920, 0);
        let layer = Layer::raster_layer("坏".to_string(), info);
        assert!(decode_document(encode_document(vec![layer]))
            .error
            .is_some());

        let layer = Layer::raster_layer("坏".to_string(), RasterInfo::new(100_000, 100_000, 256));
        assert!(decode_document(encode_document(vec![layer]))
            .error
            .is_some());
    }

    #[test]
    fn raster_drops_out_of_grid_tiles() {
        let mut info = RasterInfo::new(512, 512, 256);
        // 512/256 = 2 列 × 2 行，合法范围是 0..1；(2,0) 与 (0,9) 越界。
        info.tiles = vec![
            TileRef { x: 0, y: 0 },
            TileRef { x: 2, y: 0 },
            TileRef { x: 0, y: 9 },
            TileRef { x: 1, y: 1 },
        ];
        let layer = Layer::raster_layer("位图".to_string(), info);
        let outcome = decode_document(encode_document(vec![layer]));
        let tiles = &outcome.layers[0].raster.as_ref().unwrap().tiles;
        assert_eq!(tiles, &vec![TileRef { x: 0, y: 0 }, TileRef { x: 1, y: 1 }]);
    }

    #[test]
    fn raster_truncation_keeps_parsed_tiles() {
        let bytes = encode_document(vec![sample_raster_layer()]);
        // 砍掉最后两个瓦片引用（8 字节）。
        let truncated = bytes[..bytes.len() - 8].to_vec();
        let outcome = decode_document(truncated);

        assert!(outcome.error.is_some());
        let tiles = &outcome.layers[0].raster.as_ref().unwrap().tiles;
        assert_eq!(tiles.len(), 1, "只应保住完整读到的那个瓦片");
    }
}

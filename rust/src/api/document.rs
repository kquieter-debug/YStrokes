//! 文档二进制编解码。
//!
//! 磁盘格式（全部小端序）：
//!
//! ```text
//! header : magic "YSTK"(4) | version u16 | layer_count u32
//! layer  : name_len u16 | name utf8 | opacity f32 | visible u8 | blend u8 | stroke_count u32
//! stroke : id u32 | color u32 | width f32 | point_count u32 | tool u8 | uses_pressure u8
//! point  : x f32 | y f32 | pressure f32 | timestamp_ms u32
//! ```
//!
//! 当前版本 v5：笔画头末尾带 `uses_pressure`（该笔是否按压感渲染）。
//!
//! **只接受 v5**（ADR-020）：第一版 release 尚未发布，没有需要照顾的旧文件，
//! 因此不留迁移分支。迁移代码一旦写下来就永久背负两套结构，而它保护的用户
//! 群体目前为零——这类代码应当在真有历史包袱时再加，而不是提前预留。
//!
//! 坐标用 f32 而非 f64：归一化值域固定在 0~1，绝对精度约 6e-8，
//! 远小于简化容差（1e-3 量级），体积却减半。

use super::stroke::{Stroke, StrokePoint};
use super::tools::ToolKind;

/// 文档魔数，用于快速识别非本应用文件。
const DOC_MAGIC: [u8; 4] = *b"YSTK";

/// 当前文档版本。解码只接受这一版。
pub const DOC_VERSION: u16 = 5;

/// 头部长度：magic(4) + version(2) + layer_count(4)。
const DOC_HEADER_LEN: usize = 10;

/// 单条笔画头部：id + color + width + point_count + tool + uses_pressure。
const STROKE_HEADER: usize = 18;

/// 图层头部中与名称无关的固定部分：
/// name_len(2) + opacity(4) + visible(1) + blend(1) + stroke_count(4)。
const LAYER_HEADER_FIXED: usize = 12;

/// 单个采样点长度：x + y + pressure + timestamp。
const POINT_LEN: usize = 16;

/// 图层名长度上限，防止损坏文件把它解释成一个巨大的分配。
const MAX_LAYER_NAME_LEN: usize = 512;

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

/// 一个图层。
///
/// 图层顺序即绘制顺序：索引 0 在最底层。
#[derive(Debug, Clone, PartialEq)]
pub struct Layer {
    pub name: String,
    /// 不透明度，0.0 ~ 1.0。
    pub opacity: f64,
    /// 是否参与合成。
    pub visible: bool,
    /// 与下方图层内容的混合方式。
    pub blend_mode: LayerBlendMode,
    pub strokes: Vec<Stroke>,
}

impl Layer {
    pub fn new(name: String) -> Self {
        Self {
            name,
            opacity: 1.0,
            visible: true,
            blend_mode: LayerBlendMode::Normal,
            strokes: Vec::new(),
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
            LAYER_HEADER_FIXED
                + layer.name.len()
                + layer
                    .strokes
                    .iter()
                    .map(|s| STROKE_HEADER + s.points.len() * POINT_LEN)
                    .sum::<usize>()
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

        if name_len > MAX_LAYER_NAME_LEN || data.len() < cursor + name_len + 10 {
            error = Some(format!("第 {} 个图层的名称长度非法或已截断", index + 1));
            break;
        }
        let name = String::from_utf8_lossy(&data[cursor..cursor + name_len]).to_string();
        cursor += name_len;

        let opacity = read_f32(data, cursor) as f64;
        let visible = data[cursor + 4] != 0;
        let blend_mode = LayerBlendMode::from_code(data[cursor + 5]);
        let stroke_count = read_u32(data, cursor + 6) as usize;
        cursor += 10;

        let mut layer = Layer {
            name,
            opacity: opacity.clamp(0.0, 1.0),
            visible,
            blend_mode,
            strokes: Vec::new(),
        };
        let mut layer_error = None;

        for index in 0..stroke_count {
            match read_stroke(data, cursor) {
                Ok((stroke, next)) => {
                    layer.strokes.push(stroke);
                    cursor = next;
                }
                Err(message) => {
                    layer_error = Some(format!(
                        "图层「{}」第 {} 条笔画：{message}",
                        layer.name,
                        index + 1
                    ));
                    break;
                }
            }
        }

        layers.push(layer);
        if layer_error.is_some() {
            error = layer_error;
            break;
        }
    }

    if layers.is_empty() && error.is_none() {
        error = Some("文档不含任何图层".to_string());
    }

    DecodeOutcome { layers, error }
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
            },
        ]
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
        bytes[4..6].copy_from_slice(&4u16.to_le_bytes());

        let outcome = decode_document(bytes);
        assert!(outcome.layers.is_empty());
        let error = outcome.error.unwrap_or_default();
        assert!(error.contains('4'), "错误信息应指出实际版本：{error}");
        assert!(error.contains('5'), "错误信息应指出当前版本：{error}");
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
        assert_eq!(DOC_VERSION, 5);
    }
}

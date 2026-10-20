//! 文档二进制编解码。
//!
//! 磁盘格式（全部小端序）：
//!
//! ```text
//! header : magic "YSTK"(4) | version u16 | layer_count u32
//! layer  : name_len u16 | name utf8 | opacity f32 | visible u8 | stroke_count u32
//! stroke : id u32 | color u32 | width f32 | point_count u32 | tool u8
//! point  : x f32 | y f32 | pressure f32 | timestamp_ms u32
//! ```
//!
//! - v3：引入图层（名称、不透明度、可见性）。
//! - v2：扁平笔画列表，每条笔画带 `tool`。
//! - v1：扁平笔画列表，无 `tool`。
//!
//! 解码兼容 v1/v2，统一折叠成「单个图层」。**编码永远输出 v3**，因此升级是单向的：
//! 一旦用新版本保存过，旧版本客户端就无法再打开该文档。
//!
//! 坐标用 f32 而非 f64：归一化值域固定在 0~1，绝对精度约 6e-8，
//! 远小于简化容差（1e-3 量级），体积却减半。

use super::stroke::{Stroke, StrokePoint};
use super::tools::ToolKind;

/// 文档魔数，用于快速识别非本应用文件。
const DOC_MAGIC: [u8; 4] = *b"YSTK";

/// 当前写入的文档版本。
pub const DOC_VERSION: u16 = 3;

/// 头部长度：magic(4) + version(2) + layer_count(4)。
const DOC_HEADER_LEN: usize = 10;

/// v1 单条笔画头部：id + color + width + point_count。
const STROKE_HEADER_V1: usize = 16;

/// v2/v3 单条笔画头部：id + color + width + point_count + tool。
const STROKE_HEADER_V2: usize = 17;

/// v3 图层头部中与名称无关的固定部分：
/// name_len(2) + opacity(4) + visible(1) + stroke_count(4)。
const LAYER_HEADER_FIXED: usize = 11;

/// 单个采样点长度：x + y + pressure + timestamp。
const POINT_LEN: usize = 16;

/// 图层名长度上限，防止损坏文件把它解释成一个巨大的分配。
const MAX_LAYER_NAME_LEN: usize = 512;

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
    pub strokes: Vec<Stroke>,
}

impl Layer {
    pub fn new(name: String) -> Self {
        Self {
            name,
            opacity: 1.0,
            visible: true,
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
                    .map(|s| STROKE_HEADER_V2 + s.points.len() * POINT_LEN)
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
        out.extend_from_slice(&(layer.strokes.len() as u32).to_le_bytes());

        for stroke in &layer.strokes {
            // 与 v2 的笔画头保持完全一致的字节顺序：
            // 升到 v3 只是加了图层外壳，笔画本身没有变化。
            out.extend_from_slice(&stroke.id.to_le_bytes());
            out.extend_from_slice(&stroke.color.to_le_bytes());
            out.extend_from_slice(&(stroke.width as f32).to_le_bytes());
            out.extend_from_slice(&(stroke.points.len() as u32).to_le_bytes());
            out.push(stroke.tool.to_code());
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
    let layer_count = read_u32(data, 6) as usize;

    match version {
        1 | 2 => decode_flat(data, version, layer_count),
        3 => decode_layers(data, layer_count),
        other => DecodeOutcome {
            layers: Vec::new(),
            error: Some(format!(
                "不支持的文档版本 {other}（当前支持 1~{DOC_VERSION}）"
            )),
        },
    }
}

/// 解析 v1/v2：扁平笔画列表，折叠成单个图层。
fn decode_flat(data: &[u8], version: u16, stroke_count: usize) -> DecodeOutcome {
    let stroke_header_len = if version == 1 {
        STROKE_HEADER_V1
    } else {
        STROKE_HEADER_V2
    };
    let has_tool = version >= 2;

    let mut cursor = DOC_HEADER_LEN;
    let mut strokes = Vec::new();
    let mut error = None;

    for index in 0..stroke_count {
        match read_stroke(data, cursor, stroke_header_len, has_tool) {
            Ok((stroke, next)) => {
                strokes.push(stroke);
                cursor = next;
            }
            Err(message) => {
                error = Some(format!("第 {} 条笔画：{message}", index + 1));
                break;
            }
        }
    }

    DecodeOutcome {
        layers: vec![Layer {
            name: "图层 1".to_string(),
            opacity: 1.0,
            visible: true,
            strokes,
        }],
        error,
    }
}

/// 解析 v3：图层树。
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

        if name_len > MAX_LAYER_NAME_LEN || data.len() < cursor + name_len + 9 {
            error = Some(format!("第 {} 个图层的名称长度非法或已截断", index + 1));
            break;
        }
        let name = String::from_utf8_lossy(&data[cursor..cursor + name_len]).to_string();
        cursor += name_len;

        let opacity = read_f32(data, cursor) as f64;
        let visible = data[cursor + 4] != 0;
        let stroke_count = read_u32(data, cursor + 5) as usize;
        cursor += 9;

        let mut layer = Layer {
            name,
            opacity: opacity.clamp(0.0, 1.0),
            visible,
            strokes: Vec::new(),
        };
        let mut layer_error = None;

        for index in 0..stroke_count {
            match read_stroke(data, cursor, STROKE_HEADER_V2, true) {
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
fn read_stroke(
    data: &[u8],
    start: usize,
    header_len: usize,
    has_tool: bool,
) -> Result<(Stroke, usize), String> {
    if data.len() < start + header_len {
        return Err("数据截断".to_string());
    }
    let id = read_u32(data, start);
    let color = read_u32(data, start + 4);
    let width = read_f32(data, start + 8) as f64;
    let point_count = read_u32(data, start + 12) as usize;
    let tool = if has_tool {
        ToolKind::from_code(data[start + 16])
    } else {
        ToolKind::Brush
    };

    let mut cursor = start + header_len;
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
        }
    }

    fn sample_layers() -> Vec<Layer> {
        vec![
            Layer {
                name: "背景".to_string(),
                opacity: 1.0,
                visible: true,
                strokes: vec![sample_stroke(0, ToolKind::Brush)],
            },
            Layer {
                name: "线稿".to_string(),
                opacity: 0.4,
                visible: false,
                strokes: vec![
                    sample_stroke(7, ToolKind::Brush),
                    sample_stroke(8, ToolKind::Eraser),
                ],
            },
        ]
    }

    /// 手工拼一份 v2 文档（扁平笔画），用于验证旧文件兼容性。
    fn legacy_v2_bytes() -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"YSTK");
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&1u32.to_le_bytes());
        out.extend_from_slice(&7u32.to_le_bytes());
        out.extend_from_slice(&0xFF000000u32.to_le_bytes());
        out.extend_from_slice(&(0.5f32).to_le_bytes());
        out.extend_from_slice(&2u32.to_le_bytes());
        out.push(ToolKind::Eraser.to_code());
        for (x, t) in [(0.25f32, 0u32), (0.75, 16)] {
            out.extend_from_slice(&x.to_le_bytes());
            out.extend_from_slice(&(0.5f32).to_le_bytes());
            out.extend_from_slice(&(1.0f32).to_le_bytes());
            out.extend_from_slice(&t.to_le_bytes());
        }
        out
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
    fn legacy_v2_document_folds_into_single_layer() {
        let outcome = decode_document(legacy_v2_bytes());
        assert!(outcome.error.is_none(), "{:?}", outcome.error);

        assert_eq!(outcome.layers.len(), 1);
        let layer = &outcome.layers[0];
        assert_eq!(layer.opacity, 1.0);
        assert!(layer.visible);
        assert_eq!(layer.strokes.len(), 1);
        assert_eq!(layer.strokes[0].tool, ToolKind::Eraser);
        assert!((layer.strokes[0].points[1].x - 0.75).abs() < 1e-6);
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
    fn clamps_out_of_range_opacity() {
        let mut layers = sample_layers();
        layers[0].opacity = 5.0;
        let outcome = decode_document(encode_document(layers));
        assert!((outcome.layers[0].opacity - 1.0).abs() < 1e-6);
    }
}

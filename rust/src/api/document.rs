//! 文档二进制编解码。
//!
//! 磁盘格式（全部小端序）：
//!
//! ```text
//! header : magic "YSTK"(4) | version u16 | stroke_count u32
//! stroke : id u32 | color u32 | width f32 | point_count u32 | tool u8   (v2)
//! point  : x f32 | y f32 | pressure f32 | timestamp_ms u32
//! ```
//!
//! v1 的 stroke 头部没有 `tool` 字节。解码同时支持两个版本：v1 的笔画一律视为画笔，
//! 这样升级后旧作品仍能正常打开；编码始终输出最新版本。
//!
//! 坐标用 f32 而非 f64：归一化值域固定在 0~1，绝对精度约 6e-8，
//! 远小于简化容差（1e-3 量级），体积却减半。

use super::stroke::{Stroke, StrokePoint};
use super::tools::ToolKind;

/// 文档魔数，用于快速识别非本应用文件。
const DOC_MAGIC: [u8; 4] = *b"YSTK";

/// 当前写入的文档版本。
pub const DOC_VERSION: u16 = 2;

/// 头部长度：magic(4) + version(2) + stroke_count(4)。
const DOC_HEADER_LEN: usize = 10;

/// v1 单条笔画头部：id + color + width + point_count。
const STROKE_HEADER_V1: usize = 16;

/// v2 单条笔画头部：v1 + tool。
const STROKE_HEADER_V2: usize = 17;

/// 单个采样点长度：x + y + pressure + timestamp。
const POINT_LEN: usize = 16;

/// 文档解码结果。
///
/// 解码采用「部分恢复」策略：文档截断或尾部损坏时，保留此前已完整解析的笔画，
/// 并通过 `error` 说明原因。对绘画应用而言，「保住大部分作品」优于「全有或全无」。
#[derive(Debug, Clone, PartialEq)]
pub struct DecodeOutcome {
    pub strokes: Vec<Stroke>,
    pub error: Option<String>,
}

/// 把笔画序列编码为字节流，供前端原子写入磁盘。
pub fn encode_document(strokes: Vec<Stroke>) -> Vec<u8> {
    let payload: usize = strokes
        .iter()
        .map(|s| STROKE_HEADER_V2 + s.points.len() * POINT_LEN)
        .sum();
    let mut out = Vec::with_capacity(DOC_HEADER_LEN + payload);

    out.extend_from_slice(&DOC_MAGIC);
    out.extend_from_slice(&DOC_VERSION.to_le_bytes());
    out.extend_from_slice(&(strokes.len() as u32).to_le_bytes());

    for stroke in &strokes {
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
    out
}

/// 把字节流解码为笔画列表；损坏时尽可能恢复已解析的部分。
pub fn decode_document(bytes: Vec<u8>) -> DecodeOutcome {
    let data = bytes.as_slice();
    if data.len() < DOC_HEADER_LEN {
        return DecodeOutcome {
            strokes: Vec::new(),
            error: Some(format!(
                "文档长度不足：{} 字节（头部需要 {} 字节）",
                data.len(),
                DOC_HEADER_LEN
            )),
        };
    }
    if data[0..4] != DOC_MAGIC {
        return DecodeOutcome {
            strokes: Vec::new(),
            error: Some("文件标识不匹配，不是 YStrokes 文档".to_string()),
        };
    }

    let version = read_u16(data, 4);
    let (stroke_header_len, has_tool) = match version {
        1 => (STROKE_HEADER_V1, false),
        2 => (STROKE_HEADER_V2, true),
        other => {
            return DecodeOutcome {
                strokes: Vec::new(),
                error: Some(format!("不支持的文档版本 {other}（当前支持 1~{DOC_VERSION}）")),
            };
        }
    };

    let stroke_count = read_u32(data, 6) as usize;
    let mut cursor = DOC_HEADER_LEN;
    let mut strokes = Vec::new();
    let mut error = None;

    for index in 0..stroke_count {
        if data.len() < cursor + stroke_header_len {
            error = Some(format!(
                "文档在第 {} 条笔画处截断（共声明 {} 条）",
                index + 1,
                stroke_count
            ));
            break;
        }
        let id = read_u32(data, cursor);
        let color = read_u32(data, cursor + 4);
        let width = read_f32(data, cursor + 8) as f64;
        let point_count = read_u32(data, cursor + 12) as usize;
        let tool = if has_tool {
            ToolKind::from_code(data[cursor + 16])
        } else {
            ToolKind::Brush
        };
        cursor += stroke_header_len;

        // 下界校验：声明点数超过剩余字节能容纳的数量，说明数据已损坏。
        if point_count > data.len().saturating_sub(cursor) / POINT_LEN {
            error = Some(format!(
                "第 {} 条笔画的点数声明为 {point_count}，超出文件剩余长度",
                index + 1
            ));
            break;
        }

        let mut points = Vec::with_capacity(point_count);
        let mut corrupt = false;
        for _ in 0..point_count {
            let x = read_f32(data, cursor) as f64;
            let y = read_f32(data, cursor + 4) as f64;
            let pressure = read_f32(data, cursor + 8) as f64;
            let timestamp_ms = read_u32(data, cursor + 12);
            cursor += POINT_LEN;

            if !x.is_finite() || !y.is_finite() || !pressure.is_finite() {
                corrupt = true;
                break;
            }
            points.push(StrokePoint::new(x, y, pressure, timestamp_ms));
        }
        if corrupt {
            error = Some(format!("第 {} 条笔画包含非法坐标", index + 1));
            break;
        }

        strokes.push(Stroke {
            id,
            tool,
            color,
            width,
            points,
        });
    }

    DecodeOutcome { strokes, error }
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

    /// 手工拼一份 v1 文档，用于验证旧文件兼容性。
    fn legacy_v1_bytes() -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"YSTK");
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&1u32.to_le_bytes());
        out.extend_from_slice(&7u32.to_le_bytes());
        out.extend_from_slice(&0xFF000000u32.to_le_bytes());
        out.extend_from_slice(&(0.5f32).to_le_bytes());
        out.extend_from_slice(&2u32.to_le_bytes());
        for (x, t) in [(0.25f32, 0u32), (0.75, 16)] {
            out.extend_from_slice(&x.to_le_bytes());
            out.extend_from_slice(&(0.5f32).to_le_bytes());
            out.extend_from_slice(&(1.0f32).to_le_bytes());
            out.extend_from_slice(&t.to_le_bytes());
        }
        out
    }

    #[test]
    fn round_trip_preserves_tools_and_points() {
        let original = vec![
            sample_stroke(0, ToolKind::Brush),
            sample_stroke(7, ToolKind::Eraser),
        ];
        let outcome = decode_document(encode_document(original.clone()));

        assert!(outcome.error.is_none(), "不应产生错误：{:?}", outcome.error);
        assert_eq!(outcome.strokes.len(), 2);

        for (decoded, expected) in outcome.strokes.iter().zip(original.iter()) {
            assert_eq!(decoded.id, expected.id);
            assert_eq!(decoded.tool, expected.tool);
            assert_eq!(decoded.color, expected.color);
            assert!((decoded.width - expected.width).abs() < 1e-6);
            assert_eq!(decoded.points.len(), expected.points.len());
            for (d, e) in decoded.points.iter().zip(expected.points.iter()) {
                assert!((d.x - e.x).abs() < 1e-6);
                assert!((d.y - e.y).abs() < 1e-6);
                assert!((d.pressure - e.pressure).abs() < 1e-6);
                assert_eq!(d.timestamp_ms, e.timestamp_ms);
            }
        }
    }

    #[test]
    fn header_layout_is_stable() {
        let bytes = encode_document(vec![sample_stroke(0, ToolKind::Brush)]);
        assert_eq!(&bytes[0..4], b"YSTK");
        assert_eq!(read_u16(&bytes, 4), DOC_VERSION);
        assert_eq!(read_u32(&bytes, 6), 1);
        assert_eq!(
            bytes.len(),
            DOC_HEADER_LEN + STROKE_HEADER_V2 + 3 * POINT_LEN
        );
    }

    #[test]
    fn legacy_v1_document_decodes_as_brush() {
        let outcome = decode_document(legacy_v1_bytes());
        assert!(outcome.error.is_none(), "{:?}", outcome.error);
        assert_eq!(outcome.strokes.len(), 1);

        let stroke = &outcome.strokes[0];
        assert_eq!(stroke.id, 7);
        assert_eq!(stroke.tool, ToolKind::Brush, "旧文件没有工具字段，按画笔处理");
        assert_eq!(stroke.points.len(), 2);
        assert!((stroke.points[1].x - 0.75).abs() < 1e-6);
    }

    #[test]
    fn empty_document_round_trip() {
        let bytes = encode_document(Vec::new());
        assert_eq!(bytes.len(), DOC_HEADER_LEN);
        let outcome = decode_document(bytes);
        assert!(outcome.error.is_none());
        assert!(outcome.strokes.is_empty());
    }

    #[test]
    fn rejects_short_input() {
        let outcome = decode_document(vec![0u8; 5]);
        assert!(outcome.error.is_some());
        assert!(outcome.strokes.is_empty());
    }

    #[test]
    fn rejects_bad_magic() {
        let mut bytes = encode_document(vec![sample_stroke(0, ToolKind::Brush)]);
        bytes[0] = b'X';
        let outcome = decode_document(bytes);
        assert!(outcome.error.is_some());
        assert!(outcome.strokes.is_empty());
    }

    #[test]
    fn rejects_unknown_version() {
        let mut bytes = encode_document(vec![sample_stroke(0, ToolKind::Brush)]);
        bytes[4..6].copy_from_slice(&999u16.to_le_bytes());
        let outcome = decode_document(bytes);
        assert!(outcome.error.as_deref().unwrap_or("").contains("999"));
        assert!(outcome.strokes.is_empty());
    }

    #[test]
    fn recovers_prefix_when_truncated() {
        let bytes = encode_document(vec![
            sample_stroke(0, ToolKind::Brush),
            sample_stroke(1, ToolKind::Brush),
            sample_stroke(2, ToolKind::Brush),
        ]);
        let truncated = bytes[..bytes.len() - 24].to_vec();
        let outcome = decode_document(truncated);

        assert_eq!(outcome.strokes.len(), 2);
        assert_eq!(outcome.strokes[1].id, 1);
        assert!(outcome.error.is_some());
    }

    #[test]
    fn ignores_trailing_bytes() {
        let mut bytes = encode_document(vec![sample_stroke(0, ToolKind::Brush)]);
        bytes.extend_from_slice(&[0xAB; 8]);
        let outcome = decode_document(bytes);
        assert!(outcome.error.is_none());
        assert_eq!(outcome.strokes.len(), 1);
    }
}

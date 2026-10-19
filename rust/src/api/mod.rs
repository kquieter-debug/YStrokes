//! Rust 后端 API 入口。
//!
//! flutter_rust_bridge 会把本模块中的公开函数/类型生成为 Dart 绑定，
//! 供 Flutter 前端调用。
//!
//! 架构约定：
//! - Flutter 负责渲染与交互状态（笔画列表、撤销/重做栈、工具栏）。
//! - Rust 负责计算密集的几何处理：笔画简化、平滑、包围盒等。

/// 一个笔画采样点。
///
/// 坐标使用画布归一化坐标（0.0 ~ 1.0），压力范围 0.0 ~ 1.0，
/// 时间戳为自笔画起始起的毫秒数。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StrokePoint {
    pub x: f64,
    pub y: f64,
    pub pressure: f64,
    pub timestamp_ms: u32,
}

impl StrokePoint {
    pub fn new(x: f64, y: f64, pressure: f64, timestamp_ms: u32) -> Self {
        Self {
            x,
            y,
            pressure,
            timestamp_ms,
        }
    }
}

/// 笔画的轴对齐包围盒。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StrokeBounds {
    pub min_x: f64,
    pub min_y: f64,
    pub max_x: f64,
    pub max_y: f64,
}

/// 一条完整笔画。
///
/// - `id`：工程内递增 id，用于稳定排序与后续的图层操作。
/// - `color`：ARGB 颜色（0xAARRGGBB）。
/// - `width`：画笔宽度，**归一化比例**（相对画布短边，例如 0.01 表示 1%）。
///   与坐标同为无量纲量，保证缩放/导出后笔触比例不失真。
/// - `points`：归一化采样点，按绘制顺序排列。
#[derive(Debug, Clone, PartialEq)]
pub struct Stroke {
    pub id: u32,
    pub color: u32,
    pub width: f64,
    pub points: Vec<StrokePoint>,
}

/// 文档解码结果。
///
/// 解码采用「部分恢复」策略：文档截断或尾部损坏时，保留此前已完整解析的笔画，
/// 并通过 `error` 说明原因。对绘画应用而言，「保住大部分作品」优于「全有或全无」。
#[derive(Debug, Clone, PartialEq)]
pub struct DecodeOutcome {
    pub strokes: Vec<Stroke>,
    pub error: Option<String>,
}

/// 验证 FFI 链路的往返调用：前端调用后应收到 "pong"。
pub fn ping() -> String {
    "pong".to_string()
}

/// 返回当前 Rust crate 的版本号。
pub fn rust_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Douglas-Peucker 简化：在保留笔画整体形状的前提下减少采样点数量。
///
/// - `points`: 原始采样点（按时间顺序）
/// - `tolerance`: 允许的最大垂直偏差（与坐标同量纲，例如 0.002）
///
/// 返回按原顺序排列的简化点集；少于 3 个点或容差非正时原样返回。
pub fn simplify_stroke(points: Vec<StrokePoint>, tolerance: f64) -> Vec<StrokePoint> {
    if points.len() <= 2 || tolerance <= 0.0 {
        return points;
    }
    douglas_peucker(&points, tolerance)
}

/// 移动平均平滑：对 x/y/压力做滑动窗口平均，降低手抖噪声。
///
/// - `window`: 平滑窗口大小（奇数更对称），小于 3 或点数不足时原样返回。
///
/// 返回与输入等长的平滑点集（时间戳保持原值）。
pub fn smooth_stroke(points: Vec<StrokePoint>, window: u32) -> Vec<StrokePoint> {
    let window = window as usize;
    if window < 3 || points.len() < 3 {
        return points;
    }
    let n = points.len();
    let half = window / 2;
    let mut result = Vec::with_capacity(n);
    for i in 0..n {
        let start = i.saturating_sub(half);
        let end = (i + half + 1).min(n);
        let count = (end - start) as f64;
        let (mut sx, mut sy, mut sp) = (0.0, 0.0, 0.0);
        for p in &points[start..end] {
            sx += p.x;
            sy += p.y;
            sp += p.pressure;
        }
        result.push(StrokePoint::new(
            sx / count,
            sy / count,
            sp / count,
            points[i].timestamp_ms,
        ));
    }
    result
}

/// 计算点集的轴对齐包围盒；空输入返回全 0 的包围盒。
pub fn stroke_bounds(points: Vec<StrokePoint>) -> StrokeBounds {
    let mut bounds = StrokeBounds {
        min_x: 0.0,
        min_y: 0.0,
        max_x: 0.0,
        max_y: 0.0,
    };
    for (i, p) in points.iter().enumerate() {
        if i == 0 {
            bounds.min_x = p.x;
            bounds.max_x = p.x;
            bounds.min_y = p.y;
            bounds.max_y = p.y;
        } else {
            bounds.min_x = bounds.min_x.min(p.x);
            bounds.max_x = bounds.max_x.max(p.x);
            bounds.min_y = bounds.min_y.min(p.y);
            bounds.max_y = bounds.max_y.max(p.y);
        }
    }
    bounds
}

// ---------------------------------------------------------------------------
// 文档编解码
// ---------------------------------------------------------------------------
//
// 磁盘格式（全部小端序）：
//
//   header : magic "YSTK"(4) | version u16 | stroke_count u32
//   stroke : id u32 | color u32 | width f32 | point_count u32
//   point  : x f32 | y f32 | pressure f32 | timestamp_ms u32
//
// 设计取舍：
// - 坐标用 f32 而非 f64：归一化坐标的取值范围固定在 0~1，f32 在该区间内
//   绝对精度约 6e-8，远小于简化容差（2e-3），体积却减半。
// - 头部携带 version，为未来格式演进（图层、工具类型）预留迁移路径。
// - 不做压缩：笔画数据高度稀疏，通用压缩收益有限且增加解码 CPU 开销。

/// 文档魔数，用于快速识别非本应用文件。
const DOC_MAGIC: [u8; 4] = *b"YSTK";

/// 当前文档格式版本。
const DOC_VERSION: u16 = 1;

/// 头部长度：magic(4) + version(2) + stroke_count(4)。
const DOC_HEADER_LEN: usize = 10;

/// 单条笔画头部长度：id(4) + color(4) + width(4) + point_count(4)。
const DOC_STROKE_HEADER_LEN: usize = 16;

/// 单个采样点长度：x(4) + y(4) + pressure(4) + timestamp(4)。
const DOC_POINT_LEN: usize = 16;

/// 把笔画序列编码为字节流，供前端原子写入磁盘。
pub fn encode_document(strokes: Vec<Stroke>) -> Vec<u8> {
    let payload: usize = strokes
        .iter()
        .map(|s| DOC_STROKE_HEADER_LEN + s.points.len() * DOC_POINT_LEN)
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
    if version != DOC_VERSION {
        return DecodeOutcome {
            strokes: Vec::new(),
            error: Some(format!(
                "不支持的文档版本 {version}（当前支持 {DOC_VERSION}）"
            )),
        };
    }

    let stroke_count = read_u32(data, 6) as usize;
    let mut cursor = DOC_HEADER_LEN;
    let mut strokes = Vec::new();
    let mut error = None;

    for index in 0..stroke_count {
        if data.len() < cursor + DOC_STROKE_HEADER_LEN {
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
        cursor += DOC_STROKE_HEADER_LEN;

        // 下界校验：声明点数超过剩余字节能容纳的数量，说明数据已损坏。
        if point_count > data.len().saturating_sub(cursor) / DOC_POINT_LEN {
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
            cursor += DOC_POINT_LEN;

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

/// Douglas-Peucker 递归实现，保证输出顺序与输入一致。
fn douglas_peucker(points: &[StrokePoint], tolerance: f64) -> Vec<StrokePoint> {
    if points.len() <= 2 {
        return points.to_vec();
    }
    let first = points[0];
    let last = points[points.len() - 1];

    let mut max_dist = 0.0_f64;
    let mut max_idx = 0;
    for i in 1..points.len() - 1 {
        let d = perpendicular_distance(points[i], first, last);
        if d > max_dist {
            max_dist = d;
            max_idx = i;
        }
    }

    if max_dist > tolerance {
        let mut left = douglas_peucker(&points[..=max_idx], tolerance);
        let right = douglas_peucker(&points[max_idx..], tolerance);
        // 左右两段共享连接点，去掉重复后拼接。
        left.pop();
        left.extend(right);
        left
    } else {
        vec![first, last]
    }
}

/// 点 `p` 到线段 `a-b` 的垂直距离。
fn perpendicular_distance(p: StrokePoint, a: StrokePoint, b: StrokePoint) -> f64 {
    let dx = b.x - a.x;
    let dy = b.y - a.y;
    if dx == 0.0 && dy == 0.0 {
        return ((p.x - a.x).powi(2) + (p.y - a.y).powi(2)).sqrt();
    }
    // 线段参数 t（p 在 a-b 上的投影位置，夹在 0..1 之间）。
    let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy);
    let t = t.clamp(0.0, 1.0);
    let proj_x = a.x + t * dx;
    let proj_y = a.y + t * dy;
    ((p.x - proj_x).powi(2) + (p.y - proj_y).powi(2)).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pt(x: f64, y: f64) -> StrokePoint {
        StrokePoint::new(x, y, 1.0, 0)
    }

    #[test]
    fn ping_returns_pong() {
        assert_eq!(ping(), "pong");
    }

    #[test]
    fn rust_version_is_non_empty() {
        assert!(!rust_version().is_empty());
    }

    #[test]
    fn simplify_keeps_short_input() {
        let pts = vec![pt(0.0, 0.0), pt(1.0, 1.0)];
        assert_eq!(simplify_stroke(pts.clone(), 0.01), pts);
    }

    #[test]
    fn simplify_collapses_straight_line() {
        // 一条完全共线的点集应简化为首尾两点。
        let pts: Vec<StrokePoint> = (0..=10).map(|i| pt(i as f64, 0.0)).collect();
        let out = simplify_stroke(pts, 0.01);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0], pt(0.0, 0.0));
        assert_eq!(out[out.len() - 1], pt(10.0, 0.0));
    }

    #[test]
    fn simplify_keeps_corner() {
        // 明显的拐角在容差内不应被抹掉。
        let pts = vec![
            pt(0.0, 0.0),
            pt(1.0, 1.0),
            pt(2.0, 0.0),
        ];
        let out = simplify_stroke(pts, 0.01);
        assert_eq!(out.len(), 3);
    }

    #[test]
    fn simplify_preserves_order() {
        let pts: Vec<StrokePoint> = (0..20).map(|i| pt(i as f64, (i % 3) as f64 * 0.1)).collect();
        let out = simplify_stroke(pts, 0.02);
        for w in out.windows(2) {
            assert!(w[0].x < w[1].x, "输出必须保持输入顺序");
        }
    }

    #[test]
    fn smooth_moves_middle_toward_average() {
        // 中间一个尖峰，平滑后应被压低。
        let pts = vec![
            pt(0.0, 0.0),
            pt(1.0, 0.0),
            pt(2.0, 1.0),
            pt(3.0, 0.0),
            pt(4.0, 0.0),
        ];
        let out = smooth_stroke(pts, 3);
        assert_eq!(out.len(), 5);
        // 尖峰点 (2.0, 1.0) 平滑后 y 应低于 1.0。
        assert!(out[2].y < 1.0);
        // 端点应基本不变（窗口截断）。
        assert!((out[0].y - 0.0).abs() < 1e-9);
    }

    #[test]
    fn smooth_short_input_unchanged() {
        let pts = vec![pt(0.0, 0.0), pt(1.0, 1.0)];
        assert_eq!(smooth_stroke(pts.clone(), 3), pts);
    }

    #[test]
    fn bounds_computed_correctly() {
        let pts = vec![pt(0.1, 0.9), pt(0.8, 0.2), pt(0.5, 0.5)];
        let b = stroke_bounds(pts);
        assert_eq!(b.min_x, 0.1);
        assert_eq!(b.max_x, 0.8);
        assert_eq!(b.min_y, 0.2);
        assert_eq!(b.max_y, 0.9);
    }

    #[test]
    fn bounds_empty_is_zero() {
        let b = stroke_bounds(Vec::new());
        assert_eq!(b.min_x, 0.0);
        assert_eq!(b.max_y, 0.0);
    }

    // ---- 文档编解码 ----

    fn sample_stroke(id: u32) -> Stroke {
        Stroke {
            id,
            color: 0xFFEF4444,
            width: 0.0125,
            points: vec![
                StrokePoint::new(0.25, 0.5, 1.0, 0),
                StrokePoint::new(0.5, 0.75, 0.5, 16),
                StrokePoint::new(0.75, 0.125, 0.25, 32),
            ],
        }
    }

    #[test]
    fn document_round_trip_preserves_strokes() {
        let original = vec![sample_stroke(0), sample_stroke(7)];
        let bytes = encode_document(original.clone());
        let outcome = decode_document(bytes);

        assert!(outcome.error.is_none(), "不应产生错误：{:?}", outcome.error);
        assert_eq!(outcome.strokes.len(), 2);

        for (decoded, expected) in outcome.strokes.iter().zip(original.iter()) {
            assert_eq!(decoded.id, expected.id);
            assert_eq!(decoded.color, expected.color);
            assert!((decoded.width - expected.width).abs() < 1e-6);
            assert_eq!(decoded.points.len(), expected.points.len());
            for (d, e) in decoded.points.iter().zip(expected.points.iter()) {
                // f32 落盘，按精度而非位相等比较。
                assert!((d.x - e.x).abs() < 1e-6);
                assert!((d.y - e.y).abs() < 1e-6);
                assert!((d.pressure - e.pressure).abs() < 1e-6);
                assert_eq!(d.timestamp_ms, e.timestamp_ms);
            }
        }
    }

    #[test]
    fn document_empty_round_trip() {
        let bytes = encode_document(Vec::new());
        assert_eq!(bytes.len(), DOC_HEADER_LEN);
        let outcome = decode_document(bytes);
        assert!(outcome.error.is_none());
        assert!(outcome.strokes.is_empty());
    }

    #[test]
    fn document_header_is_stable() {
        let bytes = encode_document(vec![sample_stroke(0)]);
        assert_eq!(&bytes[0..4], b"YSTK");
        assert_eq!(read_u16(&bytes, 4), DOC_VERSION);
        assert_eq!(read_u32(&bytes, 6), 1);
        assert_eq!(
            bytes.len(),
            DOC_HEADER_LEN + DOC_STROKE_HEADER_LEN + 3 * DOC_POINT_LEN
        );
    }

    #[test]
    fn document_rejects_short_input() {
        let outcome = decode_document(vec![0u8; 5]);
        assert!(outcome.error.is_some());
        assert!(outcome.strokes.is_empty());
    }

    #[test]
    fn document_rejects_bad_magic() {
        let mut bytes = encode_document(vec![sample_stroke(0)]);
        bytes[0] = b'X';
        let outcome = decode_document(bytes);
        assert!(outcome.error.is_some());
        assert!(outcome.strokes.is_empty());
    }

    #[test]
    fn document_rejects_unknown_version() {
        let mut bytes = encode_document(vec![sample_stroke(0)]);
        bytes[4..6].copy_from_slice(&999u16.to_le_bytes());
        let outcome = decode_document(bytes);
        assert!(outcome.error.as_deref().unwrap_or("").contains("999"));
        assert!(outcome.strokes.is_empty());
    }

    #[test]
    fn document_recovers_prefix_when_truncated() {
        let bytes = encode_document(vec![sample_stroke(0), sample_stroke(1), sample_stroke(2)]);
        let truncated = bytes[..bytes.len() - 24].to_vec();
        let outcome = decode_document(truncated);

        // 前两条完整，第三条损坏：保留前两条并报告错误。
        assert_eq!(outcome.strokes.len(), 2);
        assert_eq!(outcome.strokes[1].id, 1);
        assert!(outcome.error.is_some());
    }

    #[test]
    fn document_ignores_trailing_bytes() {
        let mut bytes = encode_document(vec![sample_stroke(0)]);
        bytes.extend_from_slice(&[0xAB; 8]);
        let outcome = decode_document(bytes);
        assert!(outcome.error.is_none());
        assert_eq!(outcome.strokes.len(), 1);
    }
}

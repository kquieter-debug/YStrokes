//! 笔画模型与几何处理。
//!
//! 这里是「与工具无关」的通用几何：坐标归一化、平滑、简化、包围盒。
//! 工具特有的参数放在 `tools` 子模块。

use super::tools::ToolKind;

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
/// - `tool`：产生该笔画的工具。橡皮笔画同样入栈，渲染时以清空方式合成，
///   因此撤销橡皮只需求撤销这条记录，无需保存被擦除的像素。
/// - `color`：ARGB 颜色（0xAARRGGBB）；橡皮忽略该字段。
/// - `width`：宽度，**归一化比例**（相对画布短边，例如 0.01 表示 1%）。
/// - `points`：归一化采样点，按绘制顺序排列。
/// - `uses_pressure`：这一笔是否按压感渲染。**属于笔画自身**，不跟随工具上的开关：
///   开关只决定「接下来画的笔怎么画」，已经画下的笔保持画下时的样子（ADR-019）。
#[derive(Debug, Clone, PartialEq)]
pub struct Stroke {
    pub id: u32,
    pub tool: ToolKind,
    pub color: u32,
    pub width: f64,
    pub points: Vec<StrokePoint>,
    pub uses_pressure: bool,
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
        let pts = vec![pt(0.0, 0.0), pt(1.0, 1.0), pt(2.0, 0.0)];
        let out = simplify_stroke(pts, 0.01);
        assert_eq!(out.len(), 3);
    }

    #[test]
    fn simplify_preserves_order() {
        let pts: Vec<StrokePoint> = (0..20)
            .map(|i| pt(i as f64, (i % 3) as f64 * 0.1))
            .collect();
        let out = simplify_stroke(pts, 0.02);
        for w in out.windows(2) {
            assert!(w[0].x < w[1].x, "输出必须保持输入顺序");
        }
    }

    #[test]
    fn simplify_rejects_non_positive_tolerance() {
        let pts: Vec<StrokePoint> = (0..5).map(|i| pt(i as f64, 0.0)).collect();
        assert_eq!(simplify_stroke(pts.clone(), 0.0), pts);
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
}

//! 画笔：叠加颜色，走完整的手抖平滑。

use super::ToolProfile;

/// 画笔参数。
///
/// - 窗口 5：在 60~120Hz 采样下足以压平抖动，又不至于让笔迹迟钝。
/// - 容差 0.002：归一化量纲，约等于屏幕短边的 0.2%，肉眼不可辨。
pub fn profile() -> ToolProfile {
    ToolProfile {
        smooth_window: 5,
        simplify_tolerance: 0.002,
        erases: false,
    }
}

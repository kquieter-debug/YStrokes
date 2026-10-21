//! 画笔：叠加颜色，走完整的手抖平滑。

use super::ToolProfile;

/// 画笔参数。
///
/// - 窗口 5：在 60~120Hz 采样下足以压平抖动，又不至于让笔迹迟钝。
pub fn profile() -> ToolProfile {
    ToolProfile {
        smooth_window: 5,
        erases: false,
    }
}

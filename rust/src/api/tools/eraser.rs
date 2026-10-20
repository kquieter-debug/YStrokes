//! 橡皮：以「清空目标像素」的方式合成，露出下方纸面。
//!
//! 与画笔的差异体现在两点：
//! 1. 合成方式不同（`erases = true`），渲染时使用清空混合模式；
//! 2. 平滑窗口更小、容差更紧，因为擦除路径对偏移更敏感——擦偏一点就会
//!    啃掉不该动的线条。

use super::ToolProfile;

pub fn profile() -> ToolProfile {
    ToolProfile {
        smooth_window: 3,
        simplify_tolerance: 0.001,
        erases: true,
    }
}

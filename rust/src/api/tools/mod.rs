//! 绘画工具定义与分发。
//!
//! 每个工具一个子模块，各自拥有独立的参数与（将来的）几何处理逻辑。
//! 新增工具时只需：加枚举分支 + 新建子模块，不必改动调用方。

pub mod brush;
pub mod eraser;

/// 笔画所属的工具类型。
///
/// 该值会写入文档（见 `document` 模块），因此**新增分支必须追加在末尾**，
/// 不能插入或重排，否则历史文件会解释成错误的工具。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolKind {
    Brush,
    Eraser,
}

impl ToolKind {
    /// 转为文档中的存储值。
    pub fn to_code(self) -> u8 {
        match self {
            ToolKind::Brush => 0,
            ToolKind::Eraser => 1,
        }
    }

    /// 从文档存储值还原。
    ///
    /// 未知值一律按画笔处理：这是针对**单字节数据损坏**的容错，
    /// 而不是版本兼容——整份文档的版本号在解码入口已经校验过。
    pub fn from_code(code: u8) -> Self {
        match code {
            1 => ToolKind::Eraser,
            _ => ToolKind::Brush,
        }
    }
}

/// 工具的行为参数。
///
/// 由 Rust 作为单一事实来源，前端在进入画板时读取一次并缓存，
/// 逐点处理仍在本地完成——热路径不跨 FFI（见 ADR-006）。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ToolProfile {
    /// 平滑窗口（奇数）。
    pub smooth_window: u32,
    /// Douglas-Peucker 容差（归一化坐标）。
    pub simplify_tolerance: f64,
    /// 是否以「擦除」方式合成（清空目标像素而非叠加颜色）。
    pub erases: bool,
}

/// 取指定工具的行为参数。
pub fn tool_profile(tool: ToolKind) -> ToolProfile {
    match tool {
        ToolKind::Brush => brush::profile(),
        ToolKind::Eraser => eraser::profile(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_code_round_trip() {
        for tool in [ToolKind::Brush, ToolKind::Eraser] {
            assert_eq!(ToolKind::from_code(tool.to_code()), tool);
        }
    }

    #[test]
    fn unknown_tool_code_falls_back_to_brush() {
        assert_eq!(ToolKind::from_code(200), ToolKind::Brush);
    }

    #[test]
    fn profiles_differ_between_tools() {
        let brush = tool_profile(ToolKind::Brush);
        let eraser = tool_profile(ToolKind::Eraser);
        assert!(!brush.erases);
        assert!(eraser.erases);
        assert!(brush.smooth_window >= 3 && brush.smooth_window % 2 == 1);
        assert!(eraser.smooth_window >= 3 && eraser.smooth_window % 2 == 1);
    }
}

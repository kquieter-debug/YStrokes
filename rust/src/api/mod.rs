//! Rust 后端 API 入口。
//!
//! flutter_rust_bridge 会把本模块树中的公开函数/类型生成为 Dart 绑定。
//!
//! 模块划分：
//! - [`stroke`]：笔画模型与通用几何（平滑、简化、包围盒）。
//! - [`document`]：文档二进制编解码，兼容 v1。
//! - [`tools`]：绘画工具。每个工具一个子模块，各自持有参数与处理逻辑，
//!   新增工具只需加一个子模块与一个枚举分支。
//!
//! 架构约定：
//! - Flutter 负责交互状态（笔画列表、撤销/重做、工具栏）与逐帧渲染。
//! - Rust 负责文档格式、批量几何处理，以及「工具行为参数」的单一事实来源。
//!   逐点处理留在本地：热路径不跨 FFI。

pub mod document;
pub mod stroke;
pub mod tools;

/// 验证 FFI 链路的往返调用：前端调用后应收到 "pong"。
pub fn ping() -> String {
    "pong".to_string()
}

/// 返回当前 Rust crate 的版本号。
pub fn rust_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_returns_pong() {
        assert_eq!(ping(), "pong");
    }

    #[test]
    fn rust_version_is_non_empty() {
        assert!(!rust_version().is_empty());
    }
}

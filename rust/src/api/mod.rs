//! Rust 后端 API 入口。
//!
//! flutter_rust_bridge 会把本模块中的公开函数/类型生成为 Dart 绑定，
//! 供 Flutter 前端调用。

/// 验证 FFI 链路的往返调用：前端调用后应收到 "pong"。
pub fn ping() -> String {
    "pong".to_string()
}

/// 返回当前 Rust crate 的版本号。
pub fn rust_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

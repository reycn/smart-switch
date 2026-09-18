# SmartSwitch

[English](README.md) | 简体中文

在 macOS 上使用前沿人工智能的新版窗口切换器。它就知道你想使用哪个窗口。

通过 TypeSafe 的 [Jev](https://docs.typesafe.ai) 模型预测，根据你最近的切换历史，实时预测。

⌃`键的按tab键功能尚未实现。

## 工作原理

- 记录每次应用激活（最近 200 条），并标注来源：⌘Tab 手动切换、SmartSwitch 切换、或其他。
- 按下 ⌘` 时，最近使用的 10 个正在运行的应用会作为一个 Jev `choice` 问题的选项。请求中包含最近的切换记录、在每个应用停留的时长、当前时间，以及你最近 10 次手动 ⌘Tab 切换。
- 激活概率最高的应用。任何失败或超过 1 秒超时都会回退到上一个使用的应用。

## 构建、签名、安装

```bash
./build.sh
```

编译 Rust 核心（`core/`），用 SwiftPM 构建 Swift 应用（`Package.swift`，会拉取 [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow)），渲染图标，用你的第一个 "Apple Development" 证书签名（可用 `SIGN_IDENTITY=… ./build.sh` 指定），安装到 `/Applications/SmartSwitch.app` 并启动。`./build.sh build` 只构建和签名，不安装。

## 首次运行

1. 首次启动会自动打开设置。点击辅助功能旁的**授权**：系统设置会直接打开对应页面，并弹出一个可以把应用拖进去的浮动面板（拦截 ⌘` 需要）。
2. 点击菜单栏图标打开**设置…**，粘贴你的 TypeSafe API key（保存在登录钥匙串中）。
3. 在几个应用之间切换一下，然后按 ⌘`。

菜单会显示最近一次决策，并提供**上次请求**/**上次响应**子菜单。悬停某一行可查看发送给 Jev 或从 Jev 收到的原文，点击即可复制。**开发者模式**（设置 → 通用）会在触发回退时发送通知。

## 目录结构

- `core/src/lib.rs` — 历史记录、Jev 请求/响应、回退、连接保活。`cargo test`；`TYPESAFE_API_KEY=… cargo run --example predict` 可调用真实 API。
- `core/ffi/include/ss_core.h` — Swift 使用的 4 个 C ABI 函数（SwiftPM 目标 `SSCore`）。
- `app/` — SwiftUI 菜单栏与设置界面、`CGEventTap` 快捷键、钥匙串、通知、PermissionFlow 引导的辅助功能授权。
- `tools/make-icon.swift` — 从 `icon.png` 生成 `AppIcon.icns`。

## 作者

Rongxin · [rongxin@u.nus.edu](mailto:rongxin@u.nus.edu) · [github.com/reycn/smart-switch](https://github.com/reycn/smart-switch)

## 许可证

[GNU Affero General Public License v3.0](LICENSE)

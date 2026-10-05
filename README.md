# VoiceInput

macOS 中文语音输入工具：按住 Fn / 🌐 录音，松开后将识别文字输入当前输入框。当前版本 **1.3.7**。

这是基于开源 VoiceInput 的社区改进版，提供原生 Metal 玻璃光波、桌面背景折射、旧厚玻璃外观和可选大模型纠错。**不是 Apple 官方产品，与 Apple 无隶属或背书关系。**

## 使用与构建

- macOS 14+；默认简体中文，也支持切换识别语言。
- 按需授予麦克风、语音识别、设备控制/辅助功能权限；背景折射另需屏幕录制权限。
- Apple 语音识别可能使用在线服务；大模型纠错默认关闭。背景画面仅用于内存中的即时渲染，不保存、不上传。
- `make build` 构建 `.build/VoiceInput.app`；`make test` 运行检查。安装和权限说明见 [中文使用说明](README_CN.md)。

## 1.3.7 优化

背景采集缓冲通过 CVMetalTextureCache 映射为 Metal 纹理，减少重复图片转换和上传；等待主线程时只保留最新帧，兼容旧材质与捕获回退。

32 项检查通过。相同模拟背景的两轮窗口测试中，CPU 配对下降约 52%–67%；真实静默 Fn 测试应用 CPU 约 11.7%。这些是特定设备/场景数据，**不是整机耗电降幅，也不代表与官方 Siri AI 同级**。见 [性能说明](docs/PERFORMANCE.md)。

## 来源、许可证与致谢

| 来源 | 使用范围 | 许可证 |
|---|---|---|
| [yetone/voice-input-dist](https://github.com/yetone/voice-input-dist)，基线提交 `98c9ac5`；相关 [voice-input-src](https://github.com/yetone/voice-input-src) | 原始 Swift 应用、Fn 输入及语音识别基础 | MIT；Copyright (c) 2025 yetone，见 [LICENSE](LICENSE) |
| [neeldedkawala/ios-siri-animation](https://github.com/neeldedkawala/ios-siri-animation) | 光波与玻璃着色公式，移植和修改为原生 Metal | MIT；Copyright (c) 2026 Neel Dedkawala，见 [第三方许可证](Sources/VoiceInput/Resources/THIRD_PARTY_LICENSE) |
| Apple 公开 SDK | AppKit、AVFoundation、Speech、ScreenCaptureKit、Core Image、Core Video、Metal、系统 Keychain | 使用系统框架/API；不随仓库分发 Apple SDK 或内部 Siri 代码 |

本版修改包含录音会话管理、焦点与剪贴板保护、中文设置、外观/动效、背景采集及纹理路径优化。原作者版权声明与许可证全文保留，构建时一并放入应用资源。

Apple 的公开视频只作为外观参考，不包含在此仓库/发布包中；不分发官方截图、视频、图标或提取的素材。Siri、Apple、macOS 和 Liquid Glass 等名称用于说明兼容性或视觉参考，相关名称归其权利人所有。视觉效果由公开接口与上述开源公式实现，不提供或开启官方 Siri AI 功能。

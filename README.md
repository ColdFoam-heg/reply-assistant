# 回话助手

**聊天截图 → 本地 OCR 分清谁说了啥 → AI 起草回复 → 复制粘贴 / 画中画悬浮照着打**

不会回消息、斟酌措辞的时候，把聊天截图给它：它在本机识别对话（按气泡左右自动区分「对方 / 我」），把上下文交给 AI，一次起草 3 条不同风格的候选回复。选好的回复还能放进画中画小窗，飘在聊天界面上方照着打——这是 iOS 上最接近「悬浮 AI 参谋」的实现方式。

![version](https://img.shields.io/badge/version-1.0.0-blue)
![platform](https://img.shields.io/badge/platform-iOS%2015%2B-lightgrey)
![license](https://img.shields.io/badge/license-MIT-green)

## 功能

- **截图导入**：从相册选任意聊天 App 的截图（微信 / QQ / WhatsApp / 短信都行）
- **本地 OCR**：苹果 Vision 框架离线识别，截图不上传；按气泡位置自动标注「对方 / 我」，居中短文本判为系统消息并忽略；识别结果可手动改错字
- **AI 起草**：接 OpenRouter，一次出 3 条候选；可填「我想表达」和语气基调（自然接话 / 温柔体贴 / 幽默风趣 / 直截了当 / 正式礼貌）
- **一键复制**：点候选即复制，回去粘贴发送
- **PiP 悬浮**：把候选放进画中画小窗，飘在聊天 App 上方照着打字（iOS 唯一合规的跨 App 悬浮方式）
- **设置**：自己的 OpenRouter Key 只存本机；模型可换（每日免费模型名单见 FreeToken-Bots 扫描）

## 为什么不是「真悬浮窗 + 自动读取」

iOS 沙盒不允许 App 把界面画到别的 App 上面，也不允许读取其他 App 的内容（那需要注入目标 App 或越狱）。本 App 用「截图 + 本地 OCR + 画中画」在规则内实现最接近的效果。

## 隐私

- OCR 在本机离线完成，截图永不上传
- 只有点「AI 起草」时，对话文字会发给你自己 Key 对应的 OpenRouter 接口
- 介意的内容可以在起草前在对话记录框里删掉

## 安装

下载 Release 里的未签名 IPA，用自己的证书签名安装（AltStore / SideStore / ESign / 爱思助手均可）。首次使用去「设置」页填入 OpenRouter API Key（openrouter.ai 免费注册），只能用带 `:free` 后缀的免费模型，否则会走付费额度。

## 技术

单文件 SwiftUI（`Sources/App.swift`）：Vision OCR + 气泡几何重建、OpenRouter Chat Completions、AVPictureInPictureController（SampleBuffer 渲染文本帧）。GitHub Actions 云端打包。

## 开发者

LengMo（需求与测试：ColdFoam-heg）。姊妹项目：[IP 体检](https://github.com/ColdFoam-heg/ip-checker)。

## 免责声明

AI 起草仅供参考，发送前请自己过目。本工具不读取、不拦截任何 App 的数据，所有内容均来自你主动选择的截图。

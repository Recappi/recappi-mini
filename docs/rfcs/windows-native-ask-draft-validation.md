# 问答草稿保留验证（2026-09-16）

Windows 问答原先在回答结束时清空输入框，会删除等待期间输入的下一条问题。现在与 macOS 的发送时机对齐：发送后立即清空，完成后保留新草稿；失败或取消时，只有输入框自发送以来未被编辑，才恢复原问题。主动输入后清空也属于编辑，不会被旧问题覆盖。

## 验证

- 新回归在修改前失败（发送时未清空），修改后完整 Release WPF 测试通过。
- 成功、HTTP 500、取消分别覆盖未编辑、新草稿、主动清空，共 9 种组合；既有跨录音延迟响应隔离测试继续通过。网络为测试替身，不作为真实服务验收。
- `Recappi.Desktop.Tests --ask-draft-preview` 打开生产 AskPanel，顶部明确标记受控响应；实际键鼠发送、输入下一条、返回成功，确认草稿保留；再次发送并返回失败，确认原问题恢复。
- 本地录像：`build/native-desktop-validation/ask-draft-ui-01/capture-even.mp4`，67.2 秒、672 帧，分析保留 7 个变化帧，已查看联系表及额外 38 秒帧。报告：同目录 `acceptance.html`。视频 SHA256：`250b48d562156ec64474bb3f24d719ce43539ed193c62ca1063865cc58b39efa`。

## 推荐慢响应补验

历史与推荐原先串行，推荐请求未结束时发送按钮一直禁用。现参考 macOS `loadIfNeeded` 的独立加载方式，推荐使用独立取消源；换录音/清理/刷新会取消旧推荐，迟到结果同时检查录音代数及请求身份，不修改发送忙状态。

- 回归修改前复现 `Optional Ask suggestions blocked the loaded conversation`，修改后完整 Release WPF 测试通过：推荐挂起时历史加载完成且可发送，切录音后旧推荐/旧回答不能回填。
- `--ask-slow-suggestions-preview` 中推荐请求一直挂起，真实键鼠成功发送并显示受控回答。视频 `build/native-desktop-validation/ask-slow-suggestions-ui-01/capture.mp4`，51.2 秒、512 帧、6 关键帧已查看；同目录 `acceptance.html` 一项通过。SHA256：`0c1b4fed39e348f7597cd69d94beae3159a2404fa82f1bf9358c8e82ab80540b`。
- 双架构发布报告：`build/native-desktop-release/cb77548ab3d44e45bdc2b167a5c73dc7/release-report.json`，源码 `80448a4` 加本轮改动。ARM64 实机、真实服务慢响应及完整应用各尺寸仍待验；录像背景捕获局限同下。

## 范围与发布记录

本轮双架构自包含便携包已构建，报告：`build/native-desktop-release/ea09b7cfb08b449ab351af06a7cabd33/release-report.json`。源码标记为 `3db04a4` 加本轮未提交改动；x64 ZIP 76,835,848 B、ARM64 ZIP 71,233,932 B。此处证明打包成功，不代表 ARM64 实机、签名或干净环境验收。

受控窗口不是完整应用或真实云端流程。取消及主动清空由自动回归覆盖，未作键鼠录像验收。标题窗口捕获将 WPF 透明背景显示为黑色，因此只评估可见输入与回答，不能证明主题、状态文字对比度或完整布局。10 fps 无声录像不能排除帧间短闪。首次录像因奇数高度编码失败，改用向上补齐偶数尺寸后成功；失败文件未用于验收。

# Windows 原生云接口核对

2026-09-16，首轮核对客户端提交 `43eb550`；随后读取后端固定提交 `4c3eeb7c8cc6f463e30dca6086551bc8080f4e9c`，发现并修复推荐问题响应格式不兼容。后端源码不证明线上部署版本。真实成功路径的范围见 [云端 UI 验证](windows-native-cloud-ui-validation.md)，不能据本表勾选全部账号、云处理或异常恢复验收。

## 后端源码补证与修复

2026-09-16 重新转写 provider 对齐：当前 macOS `CloudLibraryStore+Processing.swift` 的重新转写明确传 `provider: "gemini"`。Windows ReviewPanel 现同样显式传 Gemini，保留 force、语言和上下文提示；首次后台转写继续省略 provider，使用服务端默认值。此项对齐请求选择，不声称固定服务端 model 或证明生产部署版本。

2026-09-16 单句字幕失败：[官方 server events](https://developers.openai.com/api/reference/resources/realtime/server-events) 将 conversation.item.input_audio_transcription.failed 定义为与通用 error 分离的转写失败事件，携带 item_id、content_index 和 error。Windows 不再忽略此事件：释放对应等待状态、结束该分段并保留失败标记，后续输入继续。失败半句不会发为 IsFinal 成功文本；JSONL 新增可选 IsFailed，TXT 与窗口用同一格式标识不完整。错误正文不进入 UI 或归档。受控协议与窗口回归已验，真实服务端失败诱发及重连组合未验。

2026-09-16 字幕顺序：[OpenAI 实时转写文档](https://developers.openai.com/api/docs/guides/realtime-transcription) 明确不同语音轮次的完成事件不保证有序。Windows 现在在 input_audio_buffer.committed 时按当前顺序追加音频链记录句序，completed/delta 带上同一位置和 content_index；没有提交事件的兼容输入仍按首次出现记录。重连保留单个消费者的 session，重新创建消费者使用新 session，避免归档恢复后序号重置导致跨会话排序。窗口与 TXT 导出使用位置，JSONL 原始事件顺序不变。受控测试覆盖完成逆序和重复/迟到事件；没有证明任意前驱回填、插入式会话修改或公网服务端所有时序，不能据此宣称已完全等价 macOS 的 previous_item_id 时间线。

2026-09-16 设备登录期限修复：轮询响应返回后重新核对取消及验证码本地期限，确定性回归复现并阻止迟到授权。DeviceLoginTests 补齐轮询状态与非法响应分支；完整 Release 核心 35 组和 WPF 回归通过，范围见验证记录，未进行真实浏览器认证。

2026-09-16 客户端取消语义修复：授权响应解析完成与保存凭据之间取消时，AccountSession 现在在持久化前重新检查取消状态。AccountLoginCancellationTests 使用响应流处置钩子复现旧代码仍保存账号，覆盖首次/已有账号及 CancelLogin/外部取消四种组合，要求原受保护文件不变并可再次登录。核心 34 组及完整 WPF 通过；这是客户端竞争回归，不是设备登录 denied/slow_down 全分支或实际浏览器认证验收。

真实服务补验：`3a97747` 上同账号同时启动两条本地处理任务均上传成功；一条完成真实转写/下载/问答，推荐解析为 4 条非空问题，两条测试云录音已清理。报告 `core-tests-72b9576f519b4836a5bacaa1b0fa7c5b/cloud-pipeline-smoke.json`，范围见 [验证记录](windows-native-validation.md)。这证实该次部署的推荐响应可被当前解析器接受，不据此推断具体部署 SHA，也不替代推荐 UI 或跨客户端冲突验收。

2026-09-16 上传并发修复：进一步读取同一后端提交的 `apps/server/routes/api/recordings/index.ts`，确认 `recordings_one_upload_per_user_idx` 冲突返回 409。Windows 在创建至 complete 之间按账号串行化上传，完成后立即释放，不占用后续转写轮询；仍保留两个整体处理槽位。ProcessingConcurrencyTests 先复现两条上传相撞，修复后验证第二条上传完成时第一条仍在转写，以及整批取消后先恢复原上传再继续第二条。取消回归另复现释放许可期间下一条抢先创建，增加同步取消检查后核心 33 组通过（`core-tests-9abfbf8d53874252a7d1efeb19db3e0a`）。测试使用实现服务端单上传限制的 HTTP 替身，不是线上压力测试。其他客户端已有上传、旧暂停任务占用名额及任意顺序恢复仍可能返回 409，需后续完整恢复体验验收；本修复不自动 abort 或删除云数据。

- [推荐路由](https://github.com/Recappi/recappi-monorepo/blob/4c3eeb7c8cc6f463e30dca6086551bc8080f4e9c/apps/server/routes/api/recordings/%5Bid%5D/ask-suggestions.ts) 返回 `suggestions: { question, reason? }[]`，并非 macOS/C# 旧 DTO 的字符串数组。C# 新增对象解析并兼容旧字符串，忽略无问题文本的无效条目，保持顺序。回归先复现 JsonException，修复后核心 32 组通过（`core-tests-589cf127ff9b4411a8b674312e490fd6`）；WPF 另验证对象推荐显示及选择后填入输入框。真实线上推荐 UI 尚未验，不沿用此前只有空推荐的成功路径。
- [provider 选择](https://github.com/Recappi/recappi-monorepo/blob/4c3eeb7c8cc6f463e30dca6086551bc8080f4e9c/apps/server/src/transcription/select.ts) 顺序为请求 provider → 环境默认值 → gemini；model 也可由环境覆盖。因此省略 provider 仅在相应环境默认一致时等价，当前仍未读取生产配置。
- [推荐语言解析](https://github.com/Recappi/recappi-monorepo/blob/4c3eeb7c8cc6f463e30dca6086551bc8080f4e9c/apps/server/src/recordings/ask.ts) 顺序为请求 language → Accept-Language → transcript.language → 分段主导语言 → 通用语言提示。Windows 省略前两者，通常跟随转写；不能说等同 macOS 的显式语言偏好。
- [上传生命周期说明](https://github.com/Recappi/recappi-monorepo/blob/4c3eeb7c8cc6f463e30dca6086551bc8080f4e9c/docs/upload-pipeline.md) 说明每账号一个进行中上传，卡住的上传需恢复或 abort；[parts 路由](https://github.com/Recappi/recappi-monorepo/blob/4c3eeb7c8cc6f463e30dca6086551bc8080f4e9c/apps/server/routes/api/recordings/%5Bid%5D/parts/%5BpartNumber%5D.ts) 支持相同 partNumber 覆写。尚未确认具体 R2 生命周期期限。Windows 当前两个处理槽位包含上传阶段，仍需核验同账号并发上传与 409 恢复；不可因分块幂等就判并发流程已通过。

## 请求与响应依据

上传并发修复的完整 WPF 回归通过；双架构自包含发布报告为 `build/native-desktop-release/ca1d27ef64d04b4d9b35656ab2a677d6/release-report.json`，来源 `914b7be` 加本轮改动（dirty）。本轮未录制真实双上传视频，未重复签名/安装或 ARM64 实机验证。

路径中的 `{id}` 是录音 ID，`{job}` 是作业 ID。C# 路径段拒绝空值、点目录和斜杠，再 URI 编码；cursor/jobId 使用查询参数编码。普通业务请求携带 Bearer，禁止自动重定向及 cookie；401 通知当前 AccountSession，原始错误正文不展示。普通 JSON 请求含正文读取期限，创建请求不做隐式重试。

| 能力 | C# 请求及关键响应 | 仓库基线与核对结论 | 证据边界 |
| --- | --- | --- | --- |
| 账号恢复/退出 | GET `/api/auth/get-session`；POST `/api/auth/sign-out`。恢复要求 session/user 对象及匹配的 user.id，读取 `set-auth-token` 更新凭据 | `CloudClient.ValidateAccountAsync` 对照 `RecappiAPIClient.getSession`、CLI `authStatus`；C# 更严格验证保存账号身份 | AccountExpiryTests、CloudClientTests；完整过期→再次登录仍待实操 |
| 设备登录 | POST `/api/device-auth/start`；POST `/api/device-auth/poll`，正文 `device_code`。start 读取 code、同源完整验证链接、expires_in、interval；poll 支持 pending/slow_down/denied/expired/authorized；响应返回后重验取消与本地期限 | `DeviceLogin` 对照 `cli/recappi/src/auth-login.ts`；macOS 使用自己的 NativeOAuthCoordinator，不能声称流程相同 | DeviceLoginTests 用受控时钟/HTTP 验证 pending 间隔、slow_down 回退/显式值/上限、denied、expired、未知状态、本地期限、迟到授权、取消及 URL/时序拒绝；完整浏览器认证与网络故障实操仍待验 |
| 创建与分块上传 | POST `/api/recordings`，`title/contentType/durationMs`；响应 `id/partSize/maxPartBytes`。PUT `/{id}/parts/{n}` 二进制，响应 `partNumber/etag`；POST `/{id}/complete`，`parts` 数组 | `CloudClient` 对照 macOS `createRecording/uploadRecording/completeRecording`；C# 验证分块上限和回执，CLI 创建 DTO 仅声明 id/partSize | CloudClientTests 验证字节拼接、完成描述符及认证；真实合成 WAV 流水线已验，不代表全部尺寸/断网情况 |
| 暂停/中断上传 | C# CancelAll 取消本地等待并持久化 Paused；后续 GET `/{id}` 核对 ready 后继续，保留 ticket；没有 POST abort | macOS `SessionProcessor` 失败路径调用 `abortRecordingIfNeeded`，Windows 的可恢复上传设计不同 | 不将 abort 写成 C# 已支持；服务端未完成上传的保留期、过期 ticket 恢复和垃圾回收契约仍待确认 |
| 列表/详情/删除 | GET `/api/recordings?limit=50&cursor=…`，`items/nextCursor`；GET/DELETE `/api/recordings/{id}` | macOS 同路径，默认页大小不同；C# 204/空响应可接受，删除确认后重验账号和选择 | CloudLibraryTests、CloudLibraryActionTests；真实样本清理不等于全部删除 UI 验收 |
| 转写 | POST `/{id}/transcribe`，`language/force/prompt` 和可选 provider；读取 `jobId`，GET `/api/jobs/{job}`，识别 queued/running/succeeded/failed | Windows 与 macOS 重新转写均显式 `gemini`；首次后台转写省略 provider。CLI 还可传 model | 请求体与原生 ReviewPanel 回归验证选择；model/生产环境默认值未确认，不把请求一致推导为模型完全一致 |
| 摘要 | POST `/{id}/summarize`，可选 prompt；随后读取 transcript 的 summaryStatus/summary | 对照 CLI `summarizeRecording`；当前 macOS 独立 API 客户端未暴露此 POST，不能凭 UI 名称断言调用一致 | ReviewPanel 回归及真实生成已验；拒绝/响应丢失路径需分别验收 |
| 历史/失败分块 | GET `/{id}/jobs?limit=10`；GET `/{id}/transcript?jobId=…`；POST `/api/jobs/{job}/retry-failed-chunks` | 对照 macOS `listRecordingJobs/getRecordingTranscript/retryFailedChunks`。C# 响应丢失后先核对任务，不直接重复提交 | WPF 历史/重试替身回归；真实两版选择已验，真实失败分块仍待验 |
| 正文与兼容格式 | GET `/{id}/transcript`；C# CloudTranscript 接受结构化字段与旧 JSON 字符串字段，保留分段时间/说话人 | 对照 CLI mapTranscript、macOS transcript DTO；客户端兼容解码不是后端新旧格式均在线的证明 | CloudLibraryTests 和真实三段样本；损坏字段及长内容另有验收范围 |
| 搜索/说话人 | CloudContentCache 搜索当前账号已缓存标题/摘要/正文；SpeakerProfileStore 保存本机显示覆盖 | 对照 macOS `CloudLibraryStore+Cache.searchCachedRecordings`。CLI 列表存在 search 参数，但 Windows 不请求全服务端搜索 | 缓存未覆盖内容不会出现在结果；说话人编辑不云同步 |
| 问答 | GET `/{id}/ask-thread` 返回 messages；GET `/{id}/ask-suggestions` 返回 question/reason 对象数组，C# 也兼容旧字符串数组；POST `/{id}/ask-thread/messages` 传 question/webSearch/可选 model，Accept SSE | 对照后端推荐路由与 `RecappiAPIClient+Ask.swift`；识别 metadata/answer_delta/citation/done/error。C# 要求 done，否则标断流；支持分片 UTF-8 与 CR/LF | AskTests、真实回答及完整 App 四条推荐显示/选择/发送视频已验。macOS 推荐可传 language，C# 当前省略；生产部署 SHA 和语言偏好一致性未确认 |
| 实时字幕 | POST `/api/openai/realtime/sessions` 携带 Origin；mode、language、delay=low、expiresAfterSeconds=60；翻译含 targetLanguage/includeSourceTranscript，普通转写 turnDetection.type=none | 对照 macOS 两种会话请求。返回 websocketUrl/tokenType/token，WebSocket 携带声明令牌和 Origin；48 kHz float 输入转 24 kHz PCM16 | CaptionHandshake/Transport/Tests 及真实双语样本；公网断网/过期恢复仍待验 |
| 音频与导出 | GET `/{id}/audio`；C# 依据音频 Content-Type 选扩展名，临时文件完整后替换，限制 4 GiB；文字/字幕导出在本机完成 | 对照 macOS downloadRecordingAudio、CLI downloadRecordingAudio。不存在统一“服务端导出”调用 | AudioDownloadTests、导出回归及实际 TXT；超过 4 GiB 云音频不受支持，不能以本机大文件导入证明可云下载 |
| 用量/管理 | GET `/api/billing/status`；POST `/api/billing/portal` 正文 `{}`，读取 url；409 转 `/plans` | 对照 macOS Billing API；C# 只接受可信 HTTPS 管理链接，不调用 checkout | BillingTests 及真实只读用量；真实 portal 操作未验，不执行订阅变更 |
| 标题重命名 | 无 C# 保存操作 | `RecappiMini/Views/CloudCenterPanel.swift` Save 明确 TODO 后端接线 | 排除 macOS 已实现功能对齐，不虚构成功或后端路径 |

## 关键差异与后续门禁

1. 上传中止与恢复：须确认服务端 ticket 保留期和过期表现，再决定恢复提示/显式清理；不能自动 abort 正在保留供恢复的上传。
2. 转写 provider 与推荐语言的源码回退规则已有上文依据；生产环境覆盖值、实际部署版本及与 macOS 一致性仍未确认。
3. 现有测试中的 HTTP handler 是协议样本，不是后端实现；真实成功路径也不能证明 401/402/409/429/5xx、断网或响应丢失的全部行为。
4. 完整契约验收仍需部署侧文档/源码或针对已授权测试样本的服务证据，以及实际设备登录、过期、失败分块与网络恢复操作。保留主计划“核对后端契约”为未完成。

核对入口：`native/desktop/Recappi.Core/{CloudClient,CloudProcessing,DeviceLogin,AskClient,CaptionConnection,LiveCaptions,CloudLibraryModels,BillingStatus}.cs`；`RecappiMini/Services/RecappiAPIClient.swift`、`RecappiAPIClient+Ask.swift`、`SessionProcessor.swift`、`Cloud/CloudLibraryStore+Processing.swift`；`cli/recappi/src/api.ts`、`auth-login.ts`。上表随实现及证据更新；历史样本不能替代未覆盖分支。

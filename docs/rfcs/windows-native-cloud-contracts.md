# Windows 原生云接口核对

2026-09-16，核对源码提交 `43eb550`。这是仓库内 macOS、CLI、C# 客户端的协议对照，不是服务端路由实现或部署契约审计。本轮未调用真实服务、未改生产代码；真实成功路径的范围见 [云端 UI 验证](windows-native-cloud-ui-validation.md)。不能据本表勾选全部账号、云处理或异常恢复验收。

## 请求与响应依据

路径中的 `{id}` 是录音 ID，`{job}` 是作业 ID。C# 路径段拒绝空值、点目录和斜杠，再 URI 编码；cursor/jobId 使用查询参数编码。普通业务请求携带 Bearer，禁止自动重定向及 cookie；401 通知当前 AccountSession，原始错误正文不展示。普通 JSON 请求含正文读取期限，创建请求不做隐式重试。

| 能力 | C# 请求及关键响应 | 仓库基线与核对结论 | 证据边界 |
| --- | --- | --- | --- |
| 账号恢复/退出 | GET `/api/auth/get-session`；POST `/api/auth/sign-out`。恢复要求 session/user 对象及匹配的 user.id，读取 `set-auth-token` 更新凭据 | `CloudClient.ValidateAccountAsync` 对照 `RecappiAPIClient.getSession`、CLI `authStatus`；C# 更严格验证保存账号身份 | AccountExpiryTests、CloudClientTests；完整过期→再次登录仍待实操 |
| 设备登录 | POST `/api/device-auth/start`；POST `/api/device-auth/poll`，正文 `device_code`。start 读取 code、同源完整验证链接、expires_in、interval；poll 支持 pending/slow_down/denied/expired/authorized | `DeviceLogin` 对照 `cli/recappi/src/auth-login.ts`；macOS 使用自己的 NativeOAuthCoordinator，不能声称流程相同 | 现有 CloudClientTests 只实际覆盖 pending→authorized，不能冒称覆盖全部分支 |
| 创建与分块上传 | POST `/api/recordings`，`title/contentType/durationMs`；响应 `id/partSize/maxPartBytes`。PUT `/{id}/parts/{n}` 二进制，响应 `partNumber/etag`；POST `/{id}/complete`，`parts` 数组 | `CloudClient` 对照 macOS `createRecording/uploadRecording/completeRecording`；C# 验证分块上限和回执，CLI 创建 DTO 仅声明 id/partSize | CloudClientTests 验证字节拼接、完成描述符及认证；真实合成 WAV 流水线已验，不代表全部尺寸/断网情况 |
| 暂停/中断上传 | C# CancelAll 取消本地等待并持久化 Paused；后续 GET `/{id}` 核对 ready 后继续，保留 ticket；没有 POST abort | macOS `SessionProcessor` 失败路径调用 `abortRecordingIfNeeded`，Windows 的可恢复上传设计不同 | 不将 abort 写成 C# 已支持；服务端未完成上传的保留期、过期 ticket 恢复和垃圾回收契约仍待确认 |
| 列表/详情/删除 | GET `/api/recordings?limit=50&cursor=…`，`items/nextCursor`；GET/DELETE `/api/recordings/{id}` | macOS 同路径，默认页大小不同；C# 204/空响应可接受，删除确认后重验账号和选择 | CloudLibraryTests、CloudLibraryActionTests；真实样本清理不等于全部删除 UI 验收 |
| 转写 | POST `/{id}/transcribe`，`language/force/prompt`；读取 `jobId`，GET `/api/jobs/{job}`，识别 queued/running/succeeded/failed | macOS 还传可选 provider，重新转写调用显式 `gemini`；C# 不传 provider，使用服务默认值。CLI 也可传 model | 默认 provider 是否与 macOS 一致未获服务端证据，不把真实成功推导为模型完全一致 |
| 摘要 | POST `/{id}/summarize`，可选 prompt；随后读取 transcript 的 summaryStatus/summary | 对照 CLI `summarizeRecording`；当前 macOS 独立 API 客户端未暴露此 POST，不能凭 UI 名称断言调用一致 | ReviewPanel 回归及真实生成已验；拒绝/响应丢失路径需分别验收 |
| 历史/失败分块 | GET `/{id}/jobs?limit=10`；GET `/{id}/transcript?jobId=…`；POST `/api/jobs/{job}/retry-failed-chunks` | 对照 macOS `listRecordingJobs/getRecordingTranscript/retryFailedChunks`。C# 响应丢失后先核对任务，不直接重复提交 | WPF 历史/重试替身回归；真实两版选择已验，真实失败分块仍待验 |
| 正文与兼容格式 | GET `/{id}/transcript`；C# CloudTranscript 接受结构化字段与旧 JSON 字符串字段，保留分段时间/说话人 | 对照 CLI mapTranscript、macOS transcript DTO；客户端兼容解码不是后端新旧格式均在线的证明 | CloudLibraryTests 和真实三段样本；损坏字段及长内容另有验收范围 |
| 搜索/说话人 | CloudContentCache 搜索当前账号已缓存标题/摘要/正文；SpeakerProfileStore 保存本机显示覆盖 | 对照 macOS `CloudLibraryStore+Cache.searchCachedRecordings`。CLI 列表存在 search 参数，但 Windows 不请求全服务端搜索 | 缓存未覆盖内容不会出现在结果；说话人编辑不云同步 |
| 问答 | GET `/{id}/ask-thread` 返回 messages；GET `/{id}/ask-suggestions` 返回字符串数组；POST `/{id}/ask-thread/messages` 传 question/webSearch/可选 model，Accept SSE | 对照 `RecappiAPIClient+Ask.swift`；识别 metadata/answer_delta/citation/done/error。C# 要求 done，否则标断流；支持分片 UTF-8 与 CR/LF | AskTests 与真实回答已验。macOS 推荐可传 language，C# 当前省略；CLI 另兼容对象建议，不代表当前服务已改成对象格式 |
| 实时字幕 | POST `/api/openai/realtime/sessions` 携带 Origin；mode、language、delay=low、expiresAfterSeconds=60；翻译含 targetLanguage/includeSourceTranscript，普通转写 turnDetection.type=none | 对照 macOS 两种会话请求。返回 websocketUrl/tokenType/token，WebSocket 携带声明令牌和 Origin；48 kHz float 输入转 24 kHz PCM16 | CaptionHandshake/Transport/Tests 及真实双语样本；公网断网/过期恢复仍待验 |
| 音频与导出 | GET `/{id}/audio`；C# 依据音频 Content-Type 选扩展名，临时文件完整后替换，限制 4 GiB；文字/字幕导出在本机完成 | 对照 macOS downloadRecordingAudio、CLI downloadRecordingAudio。不存在统一“服务端导出”调用 | AudioDownloadTests、导出回归及实际 TXT；超过 4 GiB 云音频不受支持，不能以本机大文件导入证明可云下载 |
| 用量/管理 | GET `/api/billing/status`；POST `/api/billing/portal` 正文 `{}`，读取 url；409 转 `/plans` | 对照 macOS Billing API；C# 只接受可信 HTTPS 管理链接，不调用 checkout | BillingTests 及真实只读用量；真实 portal 操作未验，不执行订阅变更 |
| 标题重命名 | 无 C# 保存操作 | `RecappiMini/Views/CloudCenterPanel.swift` Save 明确 TODO 后端接线 | 排除 macOS 已实现功能对齐，不虚构成功或后端路径 |

## 关键差异与后续门禁

1. 上传中止与恢复：须确认服务端 ticket 保留期和过期表现，再决定恢复提示/显式清理；不能自动 abort 正在保留供恢复的上传。
2. 转写 provider 默认值、推荐 language 默认值尚无服务端依据。当前客户端省略这些字段是已验证事实，默认结果一致是未证实推断。
3. 现有测试中的 HTTP handler 是协议样本，不是后端实现；真实成功路径也不能证明 401/402/409/429/5xx、断网或响应丢失的全部行为。
4. 完整契约验收仍需部署侧文档/源码或针对已授权测试样本的服务证据，以及实际设备登录、过期、失败分块与网络恢复操作。保留主计划“核对后端契约”为未完成。

核对入口：`native/desktop/Recappi.Core/{CloudClient,CloudProcessing,DeviceLogin,AskClient,CaptionConnection,LiveCaptions,CloudLibraryModels,BillingStatus}.cs`；`RecappiMini/Services/RecappiAPIClient.swift`、`RecappiAPIClient+Ask.swift`、`SessionProcessor.swift`、`Cloud/CloudLibraryStore+Processing.swift`；`cli/recappi/src/api.ts`、`auth-login.ts`。本轮只新增审计记录，不重复运行未变化代码的测试。最近核心 32 组实际执行记录为 `core-tests-cda8848e46204e748648c99cefa55589`。

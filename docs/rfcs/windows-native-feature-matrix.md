# Windows 原生版功能矩阵

更新：2026-09-15。macOS 行为基线为此前核对的 origin/main `19b229e` 源码与 UI 测试，不代表 macOS 实机全量验收。以下 Windows 列反映当前工作树，取代早期“只有 CLI/helper”的状态；历史增量与原始报告定位统一见 [验证记录](windows-native-validation.md)。

**当前没有将整个 N01–N26 标为验收完成。** “已有实现”“自动回归通过”“真实 API 测试”“完整桌面操作”分别列出，不能互相替代。N27 是 macOS 占位，不计入已实现功能对齐。整体阶段勾选仍以 [实施计划](windows-native-desktop.md) 为准。

代码定位：核心文件位于 `native/desktop/Recappi.Core`，窗口文件位于 `native/desktop/Recappi.Desktop`；同名测试分别位于 `Recappi.Core.Tests` / `Recappi.Desktop.Tests`。所有测试证据的具体执行范围、日期、样本和报告见验证记录，不把测试文件存在当作通过。

| ID | macOS 功能 / 源码基线 | 当前 Windows 实现 | 已有证据及剩余缺口 |
|---|---|---|---|
| N01 | 托盘、录音指示、普通与非激活窗口；RecappiMiniApp / FloatingPanel | App 托盘、品牌状态图标；RecorderWindow 无标题栏、关闭隐藏；选项/更多及托盘共用退出流程 | 实际隐藏/重复启动恢复、录音中取消退出/继续/保存退出已验；托盘点击、红点录音图标实测、全窗口焦点及退出并发仍待验 |
| N02 | 单实例、拖动、屏幕与尺寸；ManagedWindowRegistry / FloatingPanelController | App 命名互斥/管道激活；DragMove/键盘手柄；WindowVisibility 依据实际显示器工作区恢复、监听显示/DPI/工作区变化 | WPF 实窗越界/增大/隐藏恢复与无激活回归，完整 App 实际拖动边界和同实例位置保留通过；物理 DPI、多屏、屏幕移除与超大窗口全部控件可达仍待验 |
| N03 | 首次引导、权限、跳过登录；OnboardingView / PermissionsSettingsPage | OnboardingWindow 四步、进度持久化、跳过/重启；SettingsWindow 权限入口 | OnboardingWindowTests 覆盖导航、保存失败与并发设置；真实免登录引导通过；权限拒绝/设备状态即时反馈及真实登录引导待验 |
| N04 | 登录、过期、重连、退出、Keychain；AuthSessionStore / NativeOAuthCoordinator | AccountSession + DeviceLogin 浏览器设备确认；AccountStore DPAPI；业务 HTTP/字幕握手 401 传递过期状态 | AccountExpiryTests、CaptionHandshakeTests、延迟旧凭据隔离；已有真实 C# 服务认证证据；完整 App 过期→登录→恢复与退出竞争仍待验，不把 device auth 称作 macOS OAuth 实现相同 |
| N05 | 系统/应用声音与活动来源；IdleState / AudioRecorder | RecordingModels / CaptureInput 链接现有 WASAPI helper；含子进程的进程采集 | 既有真实系统/进程隔离记录及完整 App 可控进程录音通过；所有系统版本、活动源交互和最终 CLI 回归仍需汇总 |
| N06 | 麦克风选择、录音中开关；MicrophoneInputPicker / RecordingState | RecorderViewModel + RecordingEngine 切换麦克风；设备消失不静默换成其他来源 | 核心开关回归、SourceSelectionTests；真实混录/中断/重新接入与无泄漏的完整桌面验收待完成 |
| N07 | 语言、翻译、场景与上下文；RecordingTemplateDrawer | DesktopPreferences 持久化、每会话不可变处理选项；录音条和设置配置 | PreferencesArchiveTests、SettingsWindowTests；云请求选项契约及字幕真实服务记录；所有配置组合实际操作仍待验 |
| N08 | idle/starting/recording/processing/done/error；RecordingPanel / States | RecordingEngine 状态机；RecorderViewModel 命令；云任务与录音状态分离 | 核心重复开始/停止、启动失败、处置落盘回归；实际录音→Done/退出保存通过；开始/退出/丢弃多窗口竞争仍待验 |
| N09 | 计时、电平、停止与丢弃；RecordingState / DotMatrixWaveform | 紧凑计时、电平条、停止、丢弃确认；PcmWaveWriter 持续更新头 | 实际可控音频电平与 WAV 完整保存；核心丢弃边界回归；用电平条替代点阵波形，长时间增长与实际丢弃确认仍待验 |
| N10 | 活动/会议录音建议与隐藏抑制；AudioActivityMonitor / AppDelegate | RecordingSuggestion + AudioActivity 峰值观察，托盘建议只选择来源、不自动录制 | AttentionTests/策略回归；普通浏览器音频不冒充会议。浏览器会议检测未实现，真实通知操作与长期性能待验 |
| N11 | 静音/会议结束建议停止、隐藏提醒、时长上限；RecordingAttentionPolicy | RecordingAttention + App 定时检查；原生继续/停止提醒 | 策略和 WPF Keep/Stop 回归；真实长时/静音/通知操作待验；不能用普通音频静音证明会议已结束 |
| N12 | 上传、分块、排队、后台处理；processSession | CloudProcessing 持久任务/上传关联、轮询/取消/重试；App 完成提醒与自动上传 | ProcessingTests 恢复/隔离、真实 C# 上传转写流水线；完整桌面后台处理并录新会、关窗与网络恢复待验 |
| N13 | 本地完成与失败恢复；DoneState / ErrorState | LocalRecordingStore、LocalLibraryView；启动恢复中断会话的 WAV/时长，保留载荷、标记中断、禁止自动上传 | 完整 App 实际 WASAPI 进程录音强制结束→重启恢复 93.723 秒音频，载荷哈希保持；恢复提示/播放视频通过。合成故障回归与 WPF 媒体打开已验；掉电、混录、云字幕恢复仍待验 |
| N14 | 双语实时流、连接与重连；LiveRealtimeSessionConnector | LiveCaptions / CaptionConnection / CaptionPcmEncoder；延迟启动屏障、有界队列、手动重连、重新登录续写 | CaptionTests 首条归档、停止/终止、重试、归档故障隔离；新增真实回环 WebSocket 断连/握手等待期间音频增长、重连及双语尾句归档回归；完整 App 受控 WASAPI→真实双语归档已验。回环测试用合成音频/服务；混录、公网断网/过期/账号竞争仍待验 |
| N15 | 字幕展开/紧凑、显隐、完整句；LiveCaptionFloatingPanel | CaptionWindow 双语/紧凑/显示选项、隐藏恢复、独立持续归档警告 | CaptionWindowTests 通过；所有实窗尺寸、焦点、DPI 与完整 App 重连操作待验 |
| N16 | 库分页、账号隔离与状态；CloudCenterPanel / CloudLibraryStore | CloudLibraryWindow 统一日期列表、本机/云端详情、当前会议、已确认副本关联；单一 App 窗口 | CloudLibraryTests 500 行真实 WPF 容器/分页/选择/隔离；10,000 行合成数据性能；实际本机搜索/选择/播放。真实云合并、离线切换与整套导航待验 |
| N17 | 音频导入、本地副本、浏览器/目录；CloudLibraryStore+Audio | AudioImport 使用 Media Foundation；LocalLibraryView 导入/上传；云音频下载/副本/可信来源浏览器链接 | AudioImportTests 实际 WAV/MP3/M4A 编解码与取消；AudioDownloadTests、WPF 副本/关联测试；完整文件对话框、大文件与可选编解码器待验 |
| N18 | 全库缓存搜索与说话人过滤；searchCachedRecordings / CloudRecordingDetail | CloudContentCache + 统一搜索；仅搜索本机标题与当前账号已缓存云内容；TranscriptPanel 说话人/文字过滤 | 缓存持久化/隔离/损坏回归、CloudSearchTests、实际本机关键词定位；真实大云库和统一说话人搜索操作待验 |
| N19 | 摘要/逐字稿/复制/说话人编辑；CloudDetailSummarySection / CloudRecordingDetail | CloudLibraryModels 新旧格式兼容；TranscriptPanel；SpeakerProfileStore / SpeakerEditor 录音内本地显示覆盖 | 10,000 行虚拟化、SpeakerProfileTests 与 WPF 弹窗保存；真实服务内容解码；完整取消、账号变化期间编辑与键鼠复制待验。姓名覆盖不云写入，与 macOS 作用域一致 |
| N20 | 播放/倍速/seek/活动片段/跨录音；CloudMeetingAudioPlayer / CloudPlayback | AudioPlayer 原生媒体；TranscriptPanel 定位与活动高亮；本机暂停 seek 即时更新时间、选择/结束复位；云详情切换保留独立播放 | AudioDownloadTests、WPF 实际媒体打开/seek/清理、跨录音回归；真实本机播放暂停、拖动/Home/End/结束复位视频通过；完整倍速/引用/高亮/跨录音操作和性能待验 |
| N21 | 问答历史/建议/流式回答/引用；AskConversationViewModel | AskClient SSE + AskPanel，切会议取消与隔离、停止和引用定位 | AskTests 分片/断流/错误，AskPanelTests 延迟响应；真实 C# Ask 流水线；完整桌面请求/重试/引用边界待验 |
| N22 | 重新处理、历史、失败分块重试；CloudLibraryStore+Processing | ReviewPanel / CloudJob，确认、版本选择、处理状态刷新与重复提交抑制 | ReviewPanelTests 取消/重试/历史/隔离；真实服务流水线并不证明所有重处理分支，完整 UI 服务操作待验 |
| N23 | 删除确认/索引关联/失败恢复；CloudCenterPanel+Detail | 云库删除确认、处理关联清理；云副本删除保留本机录音 | CloudLibraryActionTests 取消/失败/成功/隔离；真实 API 测试记录清理；完整桌面删除与账户变化竞争待验 |
| N24 | 用量、套餐与管理链接；BillingStatus / CloudCenterPanel+AccountHeader | BillingStatus DTO + BillingPanel 嵌入 AccountWindow；刷新/超额/不限量/周期；POST portal，409 转 plans；只打开可信链接 | BillingTests、BillingPanelTests 覆盖配额/URL/延迟响应/失败/账号隔离/401；真实只读 GET 解析成功，实际窗口用明确测试数据作布局检查。完整 App 真实用量/管理服务、账号状态与键盘实机待验 |
| N25 | 主题、设置、关于、更新；SettingsView / AppUpdater | SettingsWindow 五组配置即时保存；共用现代样式；DesktopUpdates / UpdatePanel 官方发布源、架构/通道/摘要检查；独立安装器 | Settings/Theme/Update 测试、实际浅深色设置；已有 x64 安装升级/回滚/数据保留测试。生产签名/可用更新发布、自动安装、全部窗口视觉/高对比度/ARM64 实机未完成 |
| N26 | 文本/字幕/音频导出；CLI export / macOS 复制与本地副本 | 云文字导出/音频副本；CaptionArchive 和本机 TXT/JSONL 导出；对话框返回后重新核对账号及来源 | WPF 回归覆盖文字/音频内容、取消保留目标文件、对话框期间切换录音/退出账号；回调替代真实对话框。归档恢复和下载内容回归已验；系统对话框实操、全部格式/编码/时间轴仍待验 |
| N27 | 录音标题重命名；CloudCenterPanel Rename Save TODO | 不提供假成功操作 | 基线 macOS Save 未接后端，排除已实现对齐范围；若后续有真实契约再评估 |

## 验证入口与证据边界

- 核心：`dotnet run --project native/desktop/Recappi.Core.Tests/Recappi.Core.Tests.csproj`。目前 26 组；网络场景含测试 handler 和真实回环 WebSocket，部分文件/媒体/Windows API 为实际执行，不能统一称为真实后端测试。
- 原生控件：`dotnet run --project native/desktop/Recappi.Desktop.Tests/Recappi.Desktop.Tests.csproj`。目前 18 组；实际 WPF 控件与媒体运行，账号/网络数据主要为测试替身。
- 实际服务：`CloudSmoke` / `CloudPipelineSmoke` 的原始记录见验证文档。它们不是完整 App 的人工交互验收，禁止因为既有服务样本成功而勾选所有 UI 路径。
- 实际桌面：验证文档分别记录受控进程录音、本机库/播放、设置/引导、隐藏恢复、取消退出和最终保存等已观察操作。
- 性能：见 [性能报告](windows-native-performance.md)，区分探针、测试宿主和完整自包含 App；录音/字幕长期、冷启动全流程和 ARM64 仍有缺口。
- 发布：`scripts/publish-native-desktop.ps1` 为 x64/ARM64 自包含 ZIP；`scripts/build-native-installer.ps1` 为安装器。必须把报告对应源码批次写清楚，不把旧包当最新实现。
- 兼容：核心通过源码链接复用 `native/windows`；CLI 与 macOS 仍有独立验证范围，原生测试不能代替最终 CLI 检查，Windows 不能执行 macOS XCTest。

macOS 参考测试保留：
`RecappiMiniLaunchSmokeUITests.swift`（建议、字幕、隐藏、录音状态），
`RecappiMiniEndToEndSkeletonUITests.swift`（认证/转写/退出），
`RecappiMiniStateBoardUITests.swift`（逐字稿/说话人弹窗），均位于 `Tests/RecappiMiniUITests`。

## 云接口核对范围

- 认证：`/api/auth/get-session`、`/api/auth/sign-out`、Windows device-auth start/poll；macOS native OAuth bridge 保留自己的流程。
- 录音：创建、parts PUT、complete、列表/详情/删除、audio、abort；处理：transcribe、summarize、jobs、retry-failed-chunks、带 jobId 的 transcript。
- 实时：`POST /api/openai/realtime/sessions` 的连接声明与实际音频格式。
- 问答：ask-thread、ask-suggestions、ask-thread/messages SSE。
- 用量：`GET /api/billing/status`；管理入口：`POST /api/billing/portal`。桌面不直接创建 checkout 或执行订阅变更。

接口存在、DTO 解析通过和真实服务可用是三种不同证据。完整请求/响应契约、所有失败分支和服务限制仍需按 N 项补验。

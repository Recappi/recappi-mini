# Windows 原生版功能矩阵

2026-09-16 兼容补验：当前 `9f99fbf` 的 Windows CLI 类型检查、226 项测试、构建、隔离安装后的启动及严格包检查通过；6 项按平台/真实服务开关跳过。x64/ARM64 helper 重建与包内架构/许可证通过，x64 版本执行和无账号 sidecar 握手通过。未新增真实音频/服务/macOS 或 ARM64 实机证据，详见验证记录。

2026-09-16 N14/N15：处理单句 input_audio_transcription.failed，清理该句等待/增量状态，不将可用连接重启；失败半句与空结果通过 IsFailed 元数据保留，窗口与 TXT 明确标注。160 次失败后继续、终态幂等、content_index 隔离和停止尾句回归通过，核心增至 36 组；完整 WPF、受控生产字幕窗视频三项及双架构发布通过。视频不连接网络、不录音，不替代完整 App、公网失败或其他 DPI 验收，见验证记录。

2026-09-16 N14/N15：普通转写按提交确认分配句序及 content_index；窗口、紧凑显示、隐藏期间缓存淘汰和 TXT 导出按此顺序处理迟到完成。JSONL 仍保留接收顺序并增加可选 Position；旧归档兼容。核心 35 组、实际 WPF 回归、4,102 条有序导出及双架构发布通过。当前顺序源是正常追加的提交确认，未实现 macOS 任意 previous_item_id 回填/插入重排，真实乱序服务视频未验，不将整个字幕功能勾为完成。

2026-09-16 N14/N15：修复字幕重连迟到 false/异常覆盖新录音或已连接/停止状态；窗口状态版本隔离并在关闭时失效。十二种实际 WPF 状态组合及完整 Release WPF 回归通过，双架构发布完成；受控委托回归不替代真实断网/账号重连实操，见验证记录。

2026-09-16 N04：DeviceLogin 在响应返回后拒绝超过本地验证码期限的授权，旧代码失败复现、修复后 pending/slow_down/denied/expired/未知状态、取消、链接及间隔校验回归通过；核心 35 组、完整 Release WPF 与双架构发布通过。测试为受控时钟/HTTP，真实浏览器设备登录仍未验，见验证记录。

2026-09-16 N08/N09：迟到丢弃停止/删除替换录音的竞争已复现并修复；确认前后及引擎锁内核对目标会话，取消/失败/替换/已保存原录音回归通过。完整发布 App 确认布局、保留继续、确认恢复空闲视频三项通过，磁盘核对仅目标删除、其他五文件不变。核心 34 组、完整 WPF、双架构发布通过；真实字幕排空竞争、多屏/DPI 和完整键盘仍待验，见验证记录。

2026-09-16 N04：取消登录后迟到授权仍保存凭据的竞争已复现并修复；四种取消组合验证原身份/加密文件不变和后续登录可用，核心 34 组、完整 WPF 与双架构发布通过。真实浏览器认证/取消仍待验。N19 另补默认资料保存、重新打开取消、新进程恢复图标三项视频通过（`speaker-save-cloud-ui-01`）；实际文字修改仍证据不足，详情见验证记录。

2026-09-16 N19：完整 x64 App 真实转写后的说话人弹窗布局、未修改取消返回视频两项通过；输入工具未能写入姓名，保存/重启保持仍证据不足。新增实际 ShowDialog 的修改后取消、账号/录音变化、清空与校验重试五类回归，反向移除隔离检查可复现失败，最终完整 WPF 通过。范围见 [验证记录](windows-native-validation.md)。N20 另已补齐生产播放器控件独立窗口的 Tab/Home 与焦点下进度刷新视频，物理长按仍待验。

2026-09-16 N21 真实推荐 UI 补验：完整 x64 App 显示 4 条真实推荐、选择后填入问题、发送后显示回答及引用；58.8 秒视频三项通过。真实流式期间新草稿仍证据不足，未验失败重试/全部键盘/其他主题尺寸；证据 `ask-suggestions-cloud-ui-01` 见 [云端 UI 验证](windows-native-cloud-ui-validation.md)。

2026-09-16 真实回顾补验：完整 x64 App 以独立合成语音完成真实上传、摘要生成、问答、TXT 导出、重转写保留两版并读取新版本；视频 5 项通过、2 项证据不足，云样本及临时凭据已清理。N19/N21/N22/N26 的上述成功路径新增实操证据；确认框完整布局、真实草稿时序、失败分块/网络异常仍未覆盖，见 [云端回顾验证](windows-native-cloud-ui-validation.md)。

2026-09-16 滚轮补验：最小库本机详情移除嵌入模式冗余滚动容器，WPF 嵌入往返/独立库回归与真实滚轮视频两项通过，补齐上一增量的本机详情滚轮缺口；其他视觉状态仍未全部验收。证据 `local-wheel-ui-01` 见验证记录。

2026-09-16 视觉增量：紧凑间距与矢量操作图标已实现，完整 WPF 回归和双架构发布通过；默认深色库、最小明暗库及浅色设置四项限定视频复核通过。其余页面状态、多 DPI、最小库嵌套详情滚轮传递仍待完成；不改变整体未验收结论。云处理响应丢失后的三类重复提交防护已有 WPF/HTTP 替身回归，未冒充真实断网验收。

更新：2026-09-16。macOS 行为基线为此前核对的 origin/main `19b229e` 源码与 UI 测试，不代表 macOS 实机全量验收。以下 Windows 列反映当前工作树，取代早期“只有 CLI/helper”的状态；历史增量与原始报告定位统一见 [验证记录](windows-native-validation.md)。

**当前没有将整个 N01–N26 标为验收完成。** “已有实现”“自动回归通过”“真实 API 测试”“完整桌面操作”分别列出，不能互相替代。N27 是 macOS 占位，不计入已实现功能对齐。整体阶段勾选仍以 [实施计划](windows-native-desktop.md) 为准。

2026-09-16 云端 UI 增量：N16 真实上传完成自动副本关联、N19 默认窗口三段转写可读、N21 真实问答与引用、N20 下载后引用定位已通过限定范围的视频检查；详见 [云端 UI 验证](windows-native-cloud-ui-validation.md)。N21 推荐与历史现独立加载，挂起推荐不阻塞发送，跨录音旧推荐隔离回归及受控窗口视频通过，见 [问答验证](windows-native-ask-draft-validation.md)。各行未覆盖的异常/尺寸/完整操作仍保留。

2026-09-16 N17/N20 大文件增量：`import-complete-ui-01` 完整 x64 App 实际完成 344.6 MB 合成 MP3 导入，生成 2.76 GB、7:58:40 WAV；自动选中入库及接近末尾 seek 后播放/暂停视频两项通过，源哈希保持且末五秒数据可读。此前大文件完成缺口对这一格式/样本已补验；不代表其他格式、八小时连续播放或云详情期间导入已完成。原始证据和限制见 [实施计划](windows-native-desktop.md)。

2026-09-16 N08/N16/N17 并行增量：`import-recording-ui-01` 完整 x64 App 在真实 WASAPI 进程录音期间完成同一大 MP3 导入，当前会议继续计时，导入与新录音分别保存；视频三项通过。143.380 秒录音的六个时点及 1423 个 100 ms 信号窗口验证通过；不代表云后台处理、麦克风混录或逐样本无缝已验，具体证据见实施计划。

代码定位：核心文件位于 `native/desktop/Recappi.Core`，窗口文件位于 `native/desktop/Recappi.Desktop`；同名测试分别位于 `Recappi.Core.Tests` / `Recappi.Desktop.Tests`。所有测试证据的具体执行范围、日期、样本和报告见验证记录，不把测试文件存在当作通过。

| ID | macOS 功能 / 源码基线 | 当前 Windows 实现 | 已有证据及剩余缺口 |
|---|---|---|---|
| N01 | 托盘、录音指示、普通与非激活窗口；RecappiMiniApp / FloatingPanel | App 托盘、品牌状态图标；RecorderWindow 无标题栏、关闭隐藏；选项/更多及托盘共用退出流程 | 实际隐藏/重复启动恢复、录音中取消退出/继续/保存退出已验；托盘点击、红点录音图标实测、全窗口焦点及退出并发仍待验 |
| N02 | 单实例、拖动、屏幕与尺寸；ManagedWindowRegistry / FloatingPanelController | App 命名互斥/管道激活；DragMove/键盘手柄；WindowVisibility 依据实际显示器工作区恢复、监听显示/DPI/工作区变化 | WPF 实窗越界/增大/隐藏恢复与无激活回归，完整 App 实际拖动边界和同实例位置保留通过；物理 DPI、多屏、屏幕移除与超大窗口全部控件可达仍待验 |
| N03 | 首次引导、权限、跳过登录；OnboardingView / PermissionsSettingsPage | OnboardingWindow 四步、进度持久化、跳过/重启；SettingsWindow 权限入口 | OnboardingWindowTests 覆盖导航、保存失败与并发设置；完整应用免登录四步/返回视频通过，完成标记及重启不再出现已观察；启动/退出过渡视频、权限拒绝/设备状态即时反馈及真实登录引导待验 |
| N04 | 登录、过期、重连、退出、Keychain；AuthSessionStore / NativeOAuthCoordinator | AccountSession + DeviceLogin 浏览器设备确认；AccountStore DPAPI；业务 HTTP/字幕握手 401 传递过期状态 | AccountExpiryTests、CaptionHandshakeTests、延迟旧凭据隔离；已有真实 C# 服务认证证据；完整 App 过期→登录→恢复与退出竞争仍待验，不把 device auth 称作 macOS OAuth 实现相同 |
| N05 | 系统/应用声音与活动来源；IdleState / AudioRecorder | RecordingModels / CaptureInput 链接现有 WASAPI helper；含子进程的进程采集 | 既有真实系统/进程隔离记录及完整 App 可控进程录音通过；所有系统版本、活动源交互和最终 CLI 回归仍需汇总 |
| N06 | 麦克风选择、录音中开关；MicrophoneInputPicker / RecordingState | RecorderViewModel + RecordingEngine 切换麦克风；关闭清除电平、终止清除启用状态；设备消失不静默换成其他来源 | 合成 PCM/重开失败/终止与 WPF 电平回归通过；实际进程音源+Steam 虚拟麦克风开关/重开/保存视频 3 项通过、2 项证据不足。物理非零声音混录、拔插/中断/重新接入与泄漏验收仍待完成 |
| N07 | 语言、翻译、场景与上下文；RecordingTemplateDrawer | DesktopPreferences 持久化、每会话不可变处理选项；录音条和设置配置 | PreferencesArchiveTests、SettingsWindowTests；云请求选项契约及字幕真实服务记录；所有配置组合实际操作仍待验 |
| N08 | idle/starting/recording/processing/done/error；RecordingPanel / States | RecordingEngine 状态机；RecorderViewModel 命令；云任务与录音状态分离 | 核心重复开始/停止、启动失败、处置落盘回归；实际录音→Done/退出保存通过；开始/退出/丢弃多窗口竞争仍待验 |
| N09 | 计时、电平、停止与丢弃；RecordingState / DotMatrixWaveform | 紧凑计时、电平条、停止、原生丢弃确认默认保留；会话 ID 与状态隔离；PcmWaveWriter 持续更新头 | 实际可控音频电平与 WAV 完整保存；丢弃取消/失败/迟到会话回归；完整 App 保留继续与只删除当前样本视频/磁盘通过（discard-ui-01）。用电平条替代点阵波形，长时间增长、真实字幕丢弃及完整键盘/DPI 仍待验 |
| N10 | 活动/会议录音建议与隐藏抑制；AudioActivityMonitor / AppDelegate | RecordingSuggestion + AudioActivity 峰值观察，托盘建议只选择来源、不自动录制；RecordingNotifications 隔离普通通知与旧建议、丢弃失效刷新 | AttentionTests/策略与 RecordingNotificationTests 来源控件回归；真实独立音源触发 Windows 建议、应用保持空闲视频通过（notification-ui-01），实际系统点击/替换证据不足。普通浏览器音频不冒充会议；浏览器会议检测未实现，历史通知行为与长期性能待验 |
| N11 | 静音/会议结束建议停止、隐藏提醒、时长上限；RecordingAttentionPolicy | RecordingAttention + App 定时检查；原生继续/停止提醒；关闭麦克风的旧电平不再阻止静音判断 | 策略、麦克风静音及 WPF Keep/Stop 回归；完整 App 独立测试进程录音的一分钟时长提醒→继续→手动保存视频三项通过（duration-reminder-ui-01），同一会话 117.497 秒 PCM 与分段信号检查通过。隐藏通知、静音、提醒内停止按钮及真实长会待验；不能用普通音频静音证明会议已结束 |
| N12 | 上传、分块、排队、后台处理；processSession | CloudProcessing 持久任务/上传关联、轮询/取消/重试；目标记录不可读时停止，避免重复创建；JSON 有界替换保护 | ProcessingTests / ProcessingJournalReadTests 覆盖恢复、隔离、损坏及真实文件锁下零云请求/原记录保留；既有真实 C# 流水线。完整桌面后台处理并录新会、关窗与网络恢复待验 |
| N13 | 本地完成与失败恢复；DoneState / ErrorState | LocalRecordingStore、LocalLibraryView；启动恢复中断会话的 WAV/时长，保留载荷、标记中断、禁止自动上传 | 完整 App 实际 WASAPI 进程录音强制结束→重启恢复 93.723 秒音频，载荷哈希保持；恢复提示/播放视频通过。合成故障回归与 WPF 媒体打开已验；掉电、混录、云字幕恢复仍待验 |
| N14 | 双语实时流、连接与重连；LiveRealtimeSessionConnector | LiveCaptions / CaptionConnection / CaptionPcmEncoder；延迟启动屏障、有界队列、手动重连、重新登录续写 | CaptionTests 首条归档、停止/终止、重试、归档故障隔离；新增真实回环 WebSocket 断连/握手等待期间音频增长、重连及双语尾句归档回归；完整 App 受控 WASAPI→真实双语归档已验。回环测试用合成音频/服务；混录、公网断网/过期/账号竞争仍待验 |
| N15 | 字幕展开/紧凑、显隐、完整句；LiveCaptionFloatingPanel | CaptionWindow 展开独立双栏/紧凑双行、单路占满、至少一路、纯转写配置、各自跟随与历史滚动、隐藏恢复、独立归档警告 | 长句末字几何/360 与 650 宽度/状态组合 WPF 通过；真实 App 视频 5 项通过、3 项证据不足，覆盖双语可见/停止保留/自然重连。历史滚动视频、模式及隐藏连续过程、全部尺寸/焦点/DPI/断网与过期恢复仍待验 |
| N16 | 库分页、账号隔离与状态；CloudCenterPanel / CloudLibraryStore | CloudLibraryWindow 统一日期列表、本机/云端详情、当前会议、已确认副本关联；单一 App 窗口 | CloudLibraryTests 500 行真实 WPF 容器/分页/选择/隔离；10,000 行合成数据性能；实际本机搜索/选择/播放与真实完成自动云合并视频通过。离线切换与整套导航待验 |
| N17 | 音频导入、本地副本、浏览器/目录；CloudLibraryStore+Audio | AudioImport 使用 Media Foundation；统一侧栏导入状态/取消、重复操作保护；云音频下载/副本/可信来源浏览器链接 | AudioImportTests 实际 WAV/MP3/M4A 编解码与取消；ImportLifecycleTests 云详情期间取消/失败/重复操作回归；完整 App WAV 导入及无效文件→MP3 重试/播放视频通过（import-ui-01、import-recovery-ui-01）。344.6 MB MP3 转码中取消、临时目录清理/源文件不变、取消后短 MP3 重试视频与磁盘检查通过（import-cancel-ui-01）；同一大 MP3 完整导入及近末尾播放视频/磁盘验证通过（import-complete-ui-01，范围见上文）。云详情期间取消实操、其他格式完整操作与可选编解码器待验 |
| N18 | 全库缓存搜索与说话人过滤；searchCachedRecordings / CloudRecordingDetail | CloudContentCache + 统一搜索；仅搜索本机标题与当前账号已缓存云内容；TranscriptPanel 说话人/文字过滤 | 缓存持久化/隔离/损坏回归、CloudSearchTests、实际本机关键词定位；真实大云库和统一说话人搜索操作待验 |
| N19 | 摘要/逐字稿/复制/说话人编辑；CloudDetailSummarySection / CloudRecordingDetail | CloudLibraryModels 新旧格式兼容；TranscriptPanel；SpeakerProfileStore / SpeakerEditor 录音内本地显示覆盖 | 10,000 行虚拟化、资料存储与实际 ShowDialog 保存/取消/上下文变化/校验重试回归；完整 App 真实转写弹窗布局、未修改取消视频通过。真实输入保存、账号变化期间编辑及键鼠复制待验。姓名覆盖不云写入，与 macOS 作用域一致 |
| N20 | 播放/倍速/seek/活动片段/跨录音；CloudMeetingAudioPlayer / CloudPlayback | AudioPlayer 原生媒体；TranscriptPanel 定位与活动高亮；本机暂停 seek 即时更新时间、超过一小时保留小时、选择/结束复位；云详情切换保留独立播放 | AudioDownloadTests、WPF 实际媒体打开/seek/清理、跨录音回归；真实本机播放暂停、拖动/Home/End/结束复位视频通过。61 分钟 WAV 跨小时与回退回归通过；完整 App 长时间 seek/播放视频两项通过，回退操作视频证据不足（long-playback-ui-01）。完整倍速/引用/高亮/跨录音操作和性能待验 |
| N21 | 问答历史/建议/流式回答/引用；AskConversationViewModel | AskClient SSE + AskPanel，切会议取消与隔离、停止和引用定位；发送时清空问题，完成保留新草稿，失败/取消仅恢复未编辑的原问题 | AskTests 分片/断流/错误，AskPanelTests 延迟响应及成功/失败/取消 × 未编辑/新草稿/主动清空 9 种输入状态回归；真实 C# Ask 流水线及完整桌面请求/回答/单一引用定位视频通过；本次草稿行为实际云端 UI、重试、引用边界与所有窗口尺寸待验 |
| N22 | 重新处理、历史、失败分块重试；CloudLibraryStore+Processing | ReviewPanel / CloudJob，确认、版本选择、处理状态刷新与重复提交抑制；确认前后核对录音/账号及最新任务资格 | ReviewPanelTests 取消/重试/历史/隔离；新增嵌套 Dispatcher 回归先复现确认期间切换录音误发 POST，修复后切换/退出/活跃任务更新均零提交且正常请求可恢复。使用测试网络与确认委托；真实服务流水线并不证明所有重处理分支，完整 UI 服务操作待验 |
| N23 | 删除确认/索引关联/失败恢复；CloudCenterPanel+Detail | 云库删除确认、处理关联清理；云副本删除保留本机录音；确认后重新核对录音、登录状态和页面版本 | CloudLibraryActionTests 取消/失败/成功/隔离，以及确认期间切换录音或退出账号均不发送 DELETE（先复现失败，修复后完整 WPF 套件通过）；真实 API 测试记录清理；完整桌面删除与账户变化竞争待验 |
| N24 | 用量、套餐与管理链接；BillingStatus / CloudCenterPanel+AccountHeader | BillingStatus DTO + BillingPanel 嵌入 AccountWindow；刷新/超额/不限量/周期；POST portal，409 转 plans；只打开可信链接 | BillingTests、BillingPanelTests 覆盖配额/URL/延迟响应/失败/账号隔离/401；真实只读 GET 解析成功，实际窗口用明确测试数据作布局检查。完整 App 真实用量/管理服务、账号状态与键盘实机待验 |
| N25 | 主题、设置、关于、更新；SettingsView / AppUpdater | SettingsWindow 五组配置即时保存；共用现代样式；DesktopUpdates / UpdatePanel 官方发布源、架构/通道/摘要检查；独立安装器 | Settings/Theme/Update 测试、完整应用主题/提醒保存与重启恢复后画面视频通过；已有 x64 安装升级/回滚/数据保留测试。全部字段、生产签名/可用更新发布、自动安装、全部窗口视觉/高对比度/ARM64 实机未完成 |
| N26 | 文本/字幕/音频导出；CLI export / macOS 复制与本地副本 | 云文字导出/音频副本；CaptionArchive 和本机 TXT/JSONL 导出；对话框返回后核对来源，字幕完整写入后替换并拒绝录音库内目标 | WPF 文字/音频取消与来源变化回归；CaptionExportTests 验证失败保留原文件。完整 App 合成双语 TXT 保存、Escape 取消、目录拒绝视频 3 项通过/2 项证据不足；完整布局、JSONL/覆盖确认、全部编码/时间轴仍待验 |
| N27 | 录音标题重命名；CloudCenterPanel Rename Save TODO | 不提供假成功操作 | 基线 macOS Save 未接后端，排除已实现对齐范围；若后续有真实契约再评估 |

## 验证入口与证据边界

- 核心：`dotnet run --project native/desktop/Recappi.Core.Tests/Recappi.Core.Tests.csproj -c Release`。最近全量 36 组通过（`core-tests-2ad9d13099854e17997d55621a4e9467`）；网络场景含测试 handler 和真实回环 WebSocket，部分文件/媒体/Windows API 为实际执行，不能统一称为真实后端测试。本轮 CLI 兼容补验没有重跑该套件。
- 原生控件：`dotnet run --project native/desktop/Recappi.Desktop.Tests/Recappi.Desktop.Tests.csproj`。持续扩充，最近完整 Release 执行范围见验证记录；实际 WPF 控件与媒体运行，账号/网络数据主要为测试替身。
- 实际服务：`CloudSmoke` / `CloudPipelineSmoke` 的原始记录见验证文档。它们不是完整 App 的人工交互验收，禁止因为既有服务样本成功而勾选所有 UI 路径。
- 实际桌面：验证文档分别记录受控进程录音、本机库/播放、设置/引导、隐藏恢复、取消退出和最终保存等已观察操作。
- 性能：见 [性能报告](windows-native-performance.md)，区分探针、测试宿主和完整自包含 App；录音/字幕长期、冷启动全流程和 ARM64 仍有缺口。
- 发布：`scripts/publish-native-desktop.ps1` 为 x64/ARM64 自包含 ZIP；`scripts/build-native-installer.ps1` 为安装器。必须把报告对应源码批次写清楚，不把旧包当最新实现。
- 兼容：核心通过源码链接复用 `native/windows`；当前 Windows `pnpm cli:check` 与 `pnpm cli:pack:check` 已独立通过，226 项通过/6 项跳过及双架构 helper 包检查范围见验证记录。原生测试不替代 CLI 检查，Windows 不能执行 macOS XCTest。

macOS 参考测试保留：
`RecappiMiniLaunchSmokeUITests.swift`（建议、字幕、隐藏、录音状态），
`RecappiMiniEndToEndSkeletonUITests.swift`（认证/转写/退出），
`RecappiMiniStateBoardUITests.swift`（逐字稿/说话人弹窗），均位于 `Tests/RecappiMiniUITests`。

## 云接口核对范围

后端 `4c3eeb7` 源码补证：推荐问题返回对象数组；C# 已修复解析并保留旧字符串格式，真实推荐 UI 已补验。每账号单个进行中上传限制已落实为账号内串行上传；并发转写/上传的回归与真实双任务流水线证据见验证记录，其他客户端占用和故障恢复仍需分别验收。

逐接口请求、响应、源码依据及未确认差异见 [云契约核对](windows-native-cloud-contracts.md)。C# **未实现 abort 请求**，暂停上传保留 ticket 供恢复；下面的接口范围包含跨客户端基线，不表示 Windows 每条都已实现。

- 认证：`/api/auth/get-session`、`/api/auth/sign-out`、Windows device-auth start/poll；macOS native OAuth bridge 保留自己的流程。
- 录音：创建、parts PUT、complete、列表/详情/删除、audio、abort；处理：transcribe、summarize、jobs、retry-failed-chunks、带 jobId 的 transcript。
- 实时：`POST /api/openai/realtime/sessions` 的连接声明与实际音频格式。
- 问答：ask-thread、ask-suggestions、ask-thread/messages SSE。
- 用量：`GET /api/billing/status`；管理入口：`POST /api/billing/portal`。桌面不直接创建 checkout 或执行订阅变更。

接口存在、DTO 解析通过和真实服务可用是三种不同证据。完整请求/响应契约、所有失败分支和服务限制仍需按 N 项补验。

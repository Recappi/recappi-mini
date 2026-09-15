# Windows 商店发布与体积优化

2026-09-15 用户新增交付要求；本文件是主计划阶段 5 的强制验收项。当前完成参考调查和包审计，优化实现、MSIX 和干净环境验收尚未完成。

## 已核实的 ScreenCam 参考

读取本机 `C:/Users/pengx/Documents/GitHub/screen-cam-win`，HEAD `899b32b6f423708321441706c137069dad0af8cf`。工作区的 `docs/store-msix-release.md`、`scripts/build-store-msix.ps1` 有未提交修改，本节描述 2026-09-15 所读工作区，不冒充该提交或已上线商店的事实；未修改或运行该项目的发布脚本。

- 实际项目 `src/ScreenCam.App.WinUI/ScreenCam.App.WinUI.csproj` 使用 .NET 10、WinUI 3；`WindowsAppSDKSelfContained=true`。商店脚本同时传 `--self-contained true`：.NET 与 Windows App SDK 均随包，并非交给 Store 自动免除。
- `scripts/build-portable-zip.ps1` 使用细分 WinUI/Runtime/DWrite 包，排除未用 DirectML/ONNX/Windows ML；移出 PDB、限制 MUI 语言，校验必需文件及 SHA256。其 EditorWeb 仍依赖系统 WebView2，Node 仅用于构建。Recappi 不复制其 WebView、编辑器或 AI 依赖。
- 商店脚本从指定已提交 revision 的隔离工作树构建 x64 MSIX，生成包含 MSIX 和公共符号 APPXSYM 的 MSIXUPLOAD；验证身份、版本、文件与哈希，开发签名和正式 Store 签名分开。
- `Package.appxmanifest` 声明桌面 full-trust、麦克风/摄像头；生命周期方案通过 AUMID 启动安装后的进程、核对 package identity，验证录音、升级/卸载/重装及数据保留。不能仅凭 manifest 推断录音权限正常。
- ScreenCam 首发 x64 是该产品自身决策；Recappi 仍保留 x64/ARM64 交付与分架构实机验收。上述是源码/流程核实，本次未核验 ScreenCam 最新商店审核或实际分发结果。

## Recappi 决策与候选

主发布路径采用 WPF full-trust MSIX，商店管理更新；便携包保留测试用途。基线先使用自包含 .NET Desktop Runtime，独立包装 WPF，无须为 MSIX 引入 WinUI/Windows App SDK。商店身份必须使用 Recappi 自己的 Partner Center 值，不能复制 ScreenCam 身份。

| 候选 | 预期空间与约束 | 验收条件 |
| --- | --- | --- |
| 限制随包语言资源、分离符号 | 低风险优先；中英文和其他系统语言回退必须可用 | 逐文件清单、双架构构建、原生对话框/错误信息/主题/键盘视频验证；符号另存并对应精确构建 |
| 减少 WinForms 依赖 | 托盘当前用 NotifyIcon、ContextMenuStrip、气泡提示；不是无用 DLL | 若替换为原生托盘，验证托盘恢复、菜单、通知、Explorer 重启、DPI 和退出，再测发布差值；不能直接删程序集 |
| 清理设计支持等运行时文件 | 大文件名或未在一次运行中加载不足以证明冗余 | 先核查 SDK 发布依赖与动态加载；不能白名单盲删 .NET/WPF 框架 DLL |
| Framework-dependent MSIX | 应用包更小，但运行时前置条件可能转移给用户 | 必须核实可用且受支持的 .NET Desktop Runtime 分发/安装链路；无运行时系统从商店安装后直接运行，并计入首次依赖下载和占用，否则不采用 |
| MSIX 架构/资源选择、差分更新 | 可降低每设备实际传输；不同于压缩率 | 分别记录首装与版本升级实际传输，不把上传容器或双架构 bundle 总长作为单设备下载量 |
| ReadyToRun / 单文件 | 前者可能以体积换启动，后者不等于移除依赖 | 同条件 A/B 启动、总占用与临时解包占用；只采用有净收益且无回归的配置 |

WPF/WinForms 当前不支持常规 trimming；不启用强制裁剪或以 NativeAOT 作为已可用方案。微软文档明确 WPF 的动态反射限制：[trimming incompatibilities](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/incompatibilities)。MSIX 只是包装与部署格式，不会自动移除 .NET；WPF 包装路径见 [Package a .NET app with MSIX](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/dotnet/package-app)。商店更新和差分下载能力见 [Packaging overview](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/packaging/)。

## 优化前基线（已查包，非商店下载/安装测量）

产物 `build/native-desktop-release/70ee9a9268b5487eb7f98622137c7a70/release-report.json`，生成于 2026-09-15T10:53:44Z，源码标记 `3258b4b72ce0cc81b911e20789401cf5f6a11fd5` + dirty（随后提交的导出修复）；版本 `0.1.0-preview.1`。正式 A/B 必须再从同一干净提交生成未优化和优化包。

| 指标（字节） | x64 | ARM64 |
| --- | ---: | ---: |
| ZIP 文件长 | 74,449,657 | 69,275,966 |
| 解压文件逻辑长度合计 | 181,038,598 | 195,292,500 |
| 文件数 | 477 | 476 |
| PDB 合计 | 167,388 | 167,396 |
| 所有 satellite resources DLL 合计 | 17,942,416 | 17,942,768 |
| 优化后下载/安装占用/启动 | 待测 | 待测 |
| 实际 Store 首装/更新传输 | 待测 | 待测 |
| MSIX 安装后磁盘实际占用（含新增共享依赖） | 待测 | 待测 |

PDB/语言资源总量是候选范围，不是已可删除量。x64 大文件包括 CoreLib 16,029,968、PresentationFramework 15,816,968、WinForms 13,715,720、WinForms.Design 6,093,112 字节。按文件名检查两架构未发现 DirectML、ONNX、WebView、WindowsAppSDK、node.exe；仍须在自动包门禁中结合依赖清单与必需文件验证。

ZIP SHA256：x64 `6ba375464038e407b15b73ba88fdeb96b3497106f5c015bc9c7254fe6b1ceb66`；ARM64 `0230733c65051625d5b4722f6a3f77ca5ded86ef05b9f0546760af5a4decd819`。

既有另一批包测得 x64 新进程就绪中位 757 ms（5 次、暖文件缓存），见 [性能记录](windows-native-performance.md)。不是当前包冷启动或优化后数值，不能用于计算本次收益。

## 按依赖顺序执行与验收

- [x] 阅读 ScreenCam 实际项目、便携/MSIX 脚本、manifest 与发布说明，标注未提交状态与可复用边界。
- [x] 检查当前两架构包，记录大小、文件数、语言/符号候选和 WinForms 真实用途。
- [ ] 增加自动依赖/体积报告：逐文件来源、版本、哈希、分组与重复哈希；必需运行时/主题/录音依赖存在，禁止不需要的 Web/AI/CLI 载荷；保留原包用于回退。
- [ ] 从同一干净提交制作基线和逐项优化候选；每项记录字节差、收益比例、行为验证和保留/放弃原因，不合并无法归因的优化。
- [ ] 实现 WPF MSIX 与双架构构建、Recappi identity 参数、版本递增、公共符号/哈希清单、包内容验证。正式身份缺失时完成开发身份候选，不伪造上传就绪。
- [ ] 商店版更新入口交由 Store，避免现有 ZIP 更新器覆盖包目录；验证开始菜单/AUMID、托盘、单实例、登录回调及包身份下用户数据路径/迁移。
- [ ] 在可还原的干净 Windows VM/实体机测试最低支持版本及当前版本，记录 OS build/架构/硬件、预装运行时和网络状态；不得以隔离 PATH 的开发机测试替代无运行时环境。
- [ ] 首装→首次引导→不登录录音→播放/导出→退出/重开；实际系统/进程/麦克风采集，验证权限拒绝与恢复。UI 使用完整录像、去重关键帧和通过/失败/证据不足结论，文件结果独立校验。
- [ ] 测低版本升级、数据保留、卸载、重装、安装失败恢复；检查 MSIX 数据重定向/卸载行为及外部录音路径，不沿用便携版保留行为的假设。录音中升级不得损坏 WAV。
- [ ] 同系统快照比较优化前后：包文件长、实际网络传输、安装逻辑长度/实际分配空间、新增共享依赖、首次启动新增缓存；分别记录已装/未装共享依赖，首装与更新独立。
- [ ] 测首次安装后启动、重启系统后冷启动、后续新进程启动：外部启动至首帧/可录音，至少 5 次可重复样本，报告原始值、中位/范围及 CPU/私有内存；小样本不宣称 P95。同机相同设置、数据和网络条件，显著回归必须解释并修复或放弃优化。
- [ ] ARM64 真机独立安装/运行/性能验证；x64 CI 交叉编译不能勾选 ARM64 运行通过。
- [ ] 整理审核材料（隐私、录音/网络用途、权限、商店素材、支持版本）、包验证/认证结果和可提交产物；实际上传/公开发布前另行取得授权。

完成条件：优化前后可复现报告、无功能/启动回归的选定包、干净环境安装运行证据齐全。若共享运行时不适用，记录证据并保留优化后的自包含方案；不得仅以包变小视为交付完成。

## 第一轮候选实测：语言资源与符号（2026-09-15）

新增 `scripts/inspect-native-package.ps1`，输出逐文件 SHA256/逻辑长度/分类、重复内容及 deps.json 库版本；检查必需运行时、主题、音频依赖和禁止载荷。两架构原包均通过；发现 1 组相同内容文件，仅记录，未据此删文件。首次脚本用 OrderedDictionary 导致 Windows PowerShell 的 Measure-Object 不识别属性，已改为 PSCustomObject 后重跑两架构通过；后续聚合对象沿用显式属性类型。

`scripts/publish-native-desktop.ps1 -ResourceOptimizationCandidate` 是显式实验开关，默认配置不变。通过 SDK 限制 satellite resources 为 `zh-Hans`（英文为中性资源），PDB 移至发布根目录下独立 `symbols/<arch>`，不删除 WPF/WinForms DLL。

首次候选误用 `zh-CN`，实际移除了全部 satellite resources。包审计发现后判为无效，未作为可交付包；根因为未先核对 .NET 实际 culture 目录。已改为 `zh-Hans`，并加入 `zh-Hans/PresentationFramework.resources.dll` 必须存在的硬门禁。旧候选 `a4d8967e7e8a4ffcab666f8317859be3` 及其启动数据不得用于优化验收。

同一工作区源码、Release、.NET 10、自包含，基线 `build/native-desktop-release/ba4aa8d9d37b44748c08038882364d88`，修正候选 `build/native-desktop-release/9c1c4a312d0f43a6a5c42f03bc65e3af`。两者报告均标记 HEAD `88c8d57` + dirty；x64 应用程序集 SHA256 一致。尚非最终干净提交重建。

| 架构 | 基线 ZIP 字节 | 候选 ZIP 字节 | 基线解压逻辑字节 | 候选解压逻辑字节 |
| --- | ---: | ---: | ---: | ---: |
| x64 | 74,449,660 | 68,624,549 | 181,038,598 | 164,185,922 |
| ARM64 | 69,275,959 | 63,450,644 | 195,292,500 | 178,439,480 |

x64 ZIP 减少约 7.82%，解压文件长度减少约 9.31%；ARM64 分别约 8.41%、8.63%。这是便携包数据，不是 Store 下载或实际安装分配空间。

候选 ZIP SHA256：x64 `4658b17653f1dd0a4868d22b4c8390748e75808e9ecb61c0013f8e838ba97443`；ARM64 `4e784d1171ca3cf3f1089cc204c062560b21d05d1693d8f2f84d7ef7731db6b1`。

`measure-native-startup.ps1 -Iterations 5` 顺序测基线及候选，未登录、无录音/联网、隔离数据目录，正常退出均通过。基线中位 818.22 ms（787.53–918.17），候选 783.15 ms（778.03–882.30）。报告分别为 `build/native-desktop-validation/startup-profile-27b6b7d7a7144fbab713fe530f8afd6c/results.json` 和 `startup-profile-b87bd6454d68471994d4bcc92479a8b8/results.json`。开发机暖文件缓存、小样本、顺序测试，不能据此宣称启动性能提升；它只证明本轮就绪和退出未失败。此测量不作 UI 外观验收，没有替代要求中的录像。

仍待：候选双架构完整资源审计、中文/其他系统语言回退及原生对话框视频、录音/托盘功能回归、干净提交重建、MSIX、干净环境和 ARM64 真机。候选尚未替换默认发布配置。

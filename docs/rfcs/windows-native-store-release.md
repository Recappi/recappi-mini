# Windows 商店发布与体积优化

## 2026-09-16：当前代码的 MSIX 载荷复验

对 `8f40070` 对应的发布目录 `build/native-desktop-release/1eeaa4a1ceb84bfba1a2a052f56ec627` 运行双架构 `build-native-msix.ps1`。该发布报告为 `898c38a` 加随后提交于 `8f40070` 的长音频时间显示修改；本轮没有重建或改写载荷，也不将其标成干净提交发布。

| 架构 | 未签名 MSIX 字节 | 校验载荷数 | 报告目录（build/native-msix 下） | SHA256 |
| --- | ---: | ---: | --- | --- |
| x64 | 69,828,736 | 273 | `ee88c2cbe64f487885f2fac8161ed1af` | `cdd36c45fa61b5b6cef086666f8ec8b6868cac87aacffd214d3729dd69c004fd` |
| ARM64 | 64,863,377 | 272 | `177b341ba2b04a02a7ff152f3f130865` | `b4f0bb9ae12a733d7f0823136b78e4077d0b6db7363e66ac07a7529629156707` |

Windows SDK MakeAppx 与逐文件哈希核对均通过，包审计检查自包含运行时、WPF/音频必需载荷及禁止的 Node/WebView 等载荷。两包使用开发身份，`signed=false`、`installed=false`、`storeReady=false`；本轮未注册、签名、安装或上传，不替代签名生命周期、干净 Windows 或 ARM64 实机门禁。

2026-09-15 用户新增交付要求；本文件是主计划阶段 5 的强制验收项。当前已有语言/符号精简候选、双架构 MSIX、同一干净提交的体积/启动对照；签名安装、资源回退的完整行为验证及干净环境验收尚未完成。

## 在线 EXE 安装器候选（2026-09-15）

在前述小包基础上，增加显式 `build-native-installer.ps1 -FrameworkDependentCandidate`，默认自包含安装路径不变；文件名标注 `Online-Candidate`。不是 MSIX/Store 的替代交付。安装前把控制台 `Recappi.RuntimeProbe` 与应用的同一 runtimeconfig 提取到临时目录，实际由匹配架构的 apphost 解析 .NET/WindowsDesktop 依赖，避免只凭注册表推断。探针不打开窗口、账号或数据目录；两个 RID 的 locked publish 和本机 x64 执行已加入 CI。

已有运行时则直接进入原有每用户安装；缺失时，静默模式在写入应用前报错，交互模式说明额外下载、管理员授权、取消及共享运行时保留，然后经用户选择使用下载进度页获取 Microsoft .NET Desktop Runtime。下载取消、错误或哈希不符不执行文件；管理员授权被拒或运行时安装返回失败不继续写应用。接受返回码 0/3010 后重新执行探针，仍不可用则停止。此部分代码编译通过，真实缺失环境下下载/UAC/补装/重启/取消尚未端到端验证。

依赖固定于官方 10.0 发布元数据的 10.0.12（2026-09-08），记录在 `native/desktop/installer/dotnet-prerequisites.json`。构建脚本只下载验证，不执行运行时安装器；两架构官方 SHA512、有效签名 `CN=.NET, O=Microsoft Corporation` 均通过，再把实际 SHA256 编入安装器。以后更新依赖必须更新该固定清单并重验，不在终端用户安装时追随任意 latest 地址。

| 架构 | 在线候选 EXE | 缺失时另需运行时 EXE | 两文件长度合计（不含协议开销） |
| --- | ---: | ---: | ---: |
| x64 | 2,502,656 B | 60,032,984 B | 62,535,640 B |
| ARM64 | 2,492,237 B | 54,031,048 B | 56,523,285 B |

候选均使用测试产品身份且未签名；报告在小包发布目录 `22452f45a0c947e3b19f4044bc649198` 下的 `installer-win-x64-198635a853d54684b355fb38a92607d7` 与 `installer-win-arm64-b663624b646549f885854c618693e157`。用户没有运行时时总下载仍为约 62.54/56.52 MB，不应宣称完整应用安装只需 2.5 MB。

实际 x64 已有运行时验证：隔离测试 ProductId/目录静默安装成功，日志探针返回 0；安装后的应用通过启动就绪与正常退出（单次 888.4549 ms，不作性能结论），卸载清除测试注册并保留自建用户文件。证据 `build/native-desktop-validation/runtime-install-5eae7085e74d4c21b72e94d1054ee0cf`、`startup-profile-11ea5c47b7e64bb8b0f46d469d040307/results.json`。未升级、安装或卸载本机 .NET。

新增 `test-native-online-installer-guard.ps1` 在独立探针副本注入不存在的 WindowsDesktop 99.0.0，编译测试安装器并真实静默执行：非零退出、无应用文件和卸载注册，证明依赖失败不会冒充安装完成；证据 `online-installer-guard-4baf1b11f73a41d296c4b2978e1bca99/results.json`。默认自包含 EXE 在本轮仍编译通过。模拟探针不替代干净系统；ARM64 只验证构建，在线候选升级/回滚、签名与实际交互视频仍待验收。

提交 `aac44e021dc3786ac27a50a42e2da520e617f3ec` 的 [CI 34989843083](https://github.com/Recappi/recappi-mini/actions/runs/34989843083) 已于 2026-09-15 完成：Windows native desktop、Windows CLI、Swift tests 三项均成功。原生任务包含核心回归、WPF 交互测试项目构建、双架构发布检查，以及双架构运行时探针构建和 x64 探针执行；WPF 测试项目构建不等于交互测试运行，探针成功不等于首次安装成功。

本机干净环境可用性检查：`WindowsSandbox.exe` 不存在；Hyper-V 查询因权限不足失败，因此尚未找到可用的干净测试系统。未更改 Windows 功能、权限或本机运行时。后续仍需在无预装运行时环境完成交互下载、授权拒绝、取消、补装后启动及重装验收，此门禁保持未完成。

## 不附带运行时的体积候选（2026-09-15）

用户反馈约 70 MB MSIX 仍太大。检查最新 x64 MSIX 的 ZIP 条目压缩长度：应用/NAudio 约 578,274 B，中文资源 467,915 B，其余运行时/载荷约 68,727,632 B；不能靠压缩应用代码解决主要体积。条目分组用于定位占用，不等于可删除清单。

新增显式 `publish-native-desktop.ps1 -FrameworkDependentCandidate -ResourceOptimizationCandidate`，默认发布仍自包含。候选文件名带 `requires-dotnet-candidate`，报告记录 `selfContained=false`、两个共享框架名称/最低版本、架构及 ZIP 哈希；不把其称作便携版。工作区候选报告 `build/native-desktop-release/22452f45a0c947e3b19f4044bc649198/release-report.json`：

| 架构 | 文件数 | 解压逻辑字节 | ZIP 字节 |
| --- | ---: | ---: | ---: |
| x64 | 7 | 1,188,926 | 570,331 |
| ARM64 | 7 | 1,166,402 | 557,594 |

这是移出依赖后的应用载荷，不是完整首次下载或 MSIX/安装器大小。需要匹配架构的 Microsoft.NETCore.App 与 Microsoft.WindowsDesktop.App 10.0 兼容运行时。x64 已安装运行时的本机，显式 `measure-native-startup.ps1 -AllowFrameworkDependentCandidate -Iterations 1` 在无 Node PATH 下实际就绪并正常退出，单次 937.321 ms；证据 `startup-profile-d73727c6aaca4dedbf6ce5654bc9f203/results.json`，不据此宣称性能改善。

`test-native-framework-dependency.ps1` 在独立副本要求不存在的 WindowsDesktop 99.0.0，仅允许补丁前滚，实际 apphost 在应用就绪前拒绝启动，原配置哈希不变；证据 `framework-dependency-8ccf7d60af1d4d91ac10e13aaf9c6867/results.json`。这只是注入缺失依赖的负向验证，不是干净 Windows，也没有安装/卸载本机运行时。

默认 EXE 安装路径增加报告和实际 runtimeconfig/coreclr 双重门禁：候选及伪造 selfContained 标记均被拒绝；MSIX 原有载荷门禁也拒绝小包。后续新增的显式在线 EXE 候选路径见上节。默认自包含 x64 构建与 EXE 编译仍通过，`b0291359c3ef4a01b0240bb0a9c7968d` 下安装器为 53,285,850 B，未签名、未在该轮安装。自动检测、补装和可信下载校验现已实现，但真实缺失环境、取消和失败恢复、ARM64 实机仍待验收，不能把小包视为已通过首次安装门禁。

分发边界：独立 EXE 引导安装器可以规划运行时依赖安装，但 MSIX/Store 依赖机制不能未经验证就当成 WPF .NET Desktop Runtime 自动安装。Windows App SDK 的共享框架不是该运行时。相关依据：[.NET Windows 安装](https://learn.microsoft.com/en-us/dotnet/core/install/windows)、[Windows App SDK 部署架构](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/deployment-architecture)、[WPF 裁剪限制](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/incompatibilities)。本轮未修改 MSIX 的自包含交付策略。

## 同一干净提交的包与启动对照（2026-09-15）

从 `7b2272a9dbbb138a145def94060bf336eb3e67bc` 分别运行默认 `scripts/publish-native-desktop.ps1` 和 `-ResourceOptimizationCandidate`，两份报告均 `sourceDirty=false`、版本 `0.1.0-preview.1`。基线目录 `build/native-desktop-release/8e17103065be4428ad71e199ffedc0da`，候选目录 `build/native-desktop-release/093416eb1afc414f98a61e560ab5fdb5`。本节取代旧 dirty 构建作为当前包差值依据，旧数据保留为过程记录。

新增可重复门禁 `scripts/compare-native-packages.ps1 -BaselineReleaseDirectory <基线发布根目录> -CandidateReleaseDirectory <候选发布根目录> -OutputDirectory <全新证据目录>`。要求同一干净提交、同版本及准确的双架构配置；重新校验 ZIP 长度/SHA256，调用包审计核对运行时/音频/主题依赖及禁止载荷，比较全部保留文件哈希。只允许移出 PDB 和非 zh-Hans 的 satellite resources，PDB 必须在候选 `symbols/<runtime>` 中保留且哈希一致；任何新增、改写或其他删除均拒绝。不安装或改写发布目录。

当前候选 x64 的 271 个、ARM64 的 270 个保留文件全部与基线相同。每架构移出 204 个其他语言资源文件、2 个 PDB；17 个 zh-Hans 资源保留。解压逻辑减少中，x64 语言资源 16,685,288 B、符号 170,532 B；ARM64 分别 16,685,624 B / 170,540 B。没有删除 WPF/WinForms/NAudio 运行时程序集。这里按文件解释组合优化的逻辑字节；未声称可以把 ZIP/MSIX 压缩差值精确拆分到单项。

| 架构 / 度量（字节） | 基线 | 候选 | 减少 |
| --- | ---: | ---: | ---: |
| x64 ZIP | 76,822,806 | 70,962,627 | 5,860,179（7.63%） |
| ARM64 ZIP | 71,220,896 | 65,360,635 | 5,860,261（8.23%） |
| x64 发布文件逻辑长度 | 181,052,494 | 164,196,674 | 16,855,820（9.31%） |
| ARM64 发布文件逻辑长度 | 195,306,396 | 178,450,232 | 16,856,164（8.63%） |
| x64 未签名 MSIX | 75,818,059 | 69,823,005 | 5,995,054（7.91%） |
| ARM64 未签名 MSIX | 70,853,042 | 64,857,640 | 5,995,402（8.46%） |

四份 MSIX 使用相同开发身份、版本 `1.0.0.0` 和 SDK 校验流程。基线 x64/ARM64 分别验证 479/478 个载荷文件，候选为 273/272；均未签名、未安装、非 Store-ready。包长度不是实际商店传输或安装分配空间。

| 产物 | 报告所在目录（build/native-msix/ 下） | SHA256 |
| --- | --- | --- |
| 基线 x64 | `4ed3764eab594616ad6fa4528feae45a` | `a92251cebee72220cee660ba96e8ca090749ed7acdcd7d284076767e6316839f` |
| 候选 x64 | `b154682c71c849fd977159f874967a7c` | `7101417e4891f3984431f519c3fb68fe4956f6d047bba01174fc0051556e62b5` |
| 基线 ARM64 | `5d31cbd822304b64aa6eb4df2213fcb9` | `4f00608294bb147b477b4a445f193f51986a2eeb7400fe90eba335bb8a261c48` |
| 候选 ARM64 | `bf73b77ed6724b7c80b5e43739a43f8e` | `c081943a76b5b3a84e52aa9192d9f61029618ca65917a5d2a7f399eef6a22950` |

ZIP SHA256 基线 x64 `e68403be192a0e60ff8ad336d1044d7777a6b2c77ebb7e0d377753c814d6a43d`、ARM64 `d39e4151a67ec7ab1506a62995dca4a1ea7afa0a2efb45961d76d439cff9d4ff`；候选 x64 `b8fafdb9c8c2361f6d7b96070be92bb7f1d06868ec0a73ef6834e20739be8c7a`、ARM64 `8654baedd889c7622d95c75c247912827a343c1e3de49bfe80d069e73d54a7c8`。

完整 x64 App 交替顺序运行 5 对新进程启动，10 次都验证 SignedOut/Idle、首帧事件与设备枚举完成、开始命令可用，并正常退出码 0。基线就绪观察中位 **760.16 ms**（749.93–824.42），候选 **779.37 ms**（757.28–816.02），原始逐次值见 [性能报告](windows-native-performance.md)。使用暖文件缓存、隔离预配置数据、无账号/采集/字幕/上传/建议；没有清缓存或重启系统，也没有启动 CPU/内存对照。两组范围重叠、样本少，候选中位多约 19 ms，不据此声称提速或排除稳定回归。

证据根目录 `build/native-desktop-validation/release-ab-20260915`：`verified-comparison-v2/comparison.json` 及四份完整清单、`startup-pairs.json` 链接十份启动报告、`summary.json` 汇总。比较脚本用已知 dirty 候选及相同基线配置作负向检查，均在对应门禁拒绝；另以 `powershell -NoProfile -File` 完整执行通过，结果在 `windows-powershell-comparison`。首次汇总输出的 OrderedDictionary 经 Select-Object 变为 null，已改 PSCustomObject 并在新目录完整重跑，最终汇总字段有效。

本轮生产代码未改，不重述之前的录音/字幕视频为当前两包新增的行为验收。默认发布仍保留完整语言/符号，候选继续单独提供。冷启动、首次安装、实际占用/商店差分、各语言原生对话框/错误信息、ARM64 运行及签名生命周期仍待完成，相关总门禁不勾选。

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

仍待：中文/其他系统语言回退及原生对话框视频、录音/托盘功能回归、干净提交重建、MSIX 安装生命周期、干净环境和 ARM64 真机。候选尚未替换默认发布配置。

## 首轮 MSIX 构建（2026-09-15）

新增 `native/desktop/packaging/AppxManifest.xml` 和 `scripts/build-native-msix.ps1`。采用 WPF full-trust 桌面入口，声明麦克风，无摄像头/WebView/WinUI 依赖；默认开发身份 `Recappi.Mini.Development`，正式身份需显式传入。脚本接受已发布目录，先执行自包含依赖审计，再生成唯一输出目录，运行 Windows SDK MakeAppx（未跳过校验），逐个核对全部源文件与生成包内的长度和 SHA256。未执行签名、证书信任安装、MSIX 安装或 Store 上传。

复现：`powershell -NoProfile -File scripts/build-native-msix.ps1 -PackageDirectory '<已发布自包含目录>'`。可选 `-IdentityName`、`-Publisher`、`-PublisherDisplayName`、`-PackageVersion`、`-MakeAppxPath`。版本要求 Major.Minor.Patch.0，major >= 1，各分量 <= 65535；自动从已装 Windows SDK 选择 x64 MakeAppx 工具，产物架构从应用 PE 头读取。

输入为上节修正候选 `9c1c4a312d0f43a6a5c42f03bc65e3af`。新增完整审计通过：x64 271 文件、164,185,922 字节；ARM64 270 文件、178,439,480 字节。两者均保留 17 个简体中文 satellite DLL，分别 1,257,128 / 1,257,144 字节。报告 `build/native-package-audit/corrected-x64.json`、`corrected-arm64.json`。

| 架构 | 未签名 MSIX 字节 | 验证载荷文件 | 输出根目录（build/native-msix/ 下） |
| --- | ---: | ---: | --- |
| x64 | 69,816,521 | 273 | `1e335e185dd74a80862592da9e5c9df4` |
| ARM64 | 64,851,151 | 272 | `ea1da338df9a4323bee872739e630e10` |

各目录含 `msix-report.json`、`source-inventory.json`、`makeappx.log`、payload 和 MSIX。SHA256：x64 `e83c7d580ad9c69f5fa87a517b5db679bc6812c048158876334b2888a8c1cbc0`；ARM64 `5bf9faa340173a38fb1b913001b97bc09fbf3bd8464ca4ad0fb9ef9e913e8dbb`。MSIX 文件长度不是实际商店传输、安装占用或优化前后同格式对比。

首次核对把 OPC 包内 `Recappi%20Mini.exe` 当普通 ZIP 文件名，误报 deps.json 缺失。原因是未处理 MSIX part name 的 URL 编码，MakeAppx 本身成功；已解码后核对并拒绝重复映射，两架构所有载荷重新校验通过。后续不可退回以原始 ZIP entry 名对照 Windows 文件名。

此批仍明确 `signed=false`、`installed=false`、`storeReady=false`。manifest 的最低系统 19041 是候选值，必须结合 .NET 支持范围、进程音频限制和干净系统验收再定；当前沿用 256px 品牌图，尚未完成 Store 素材/高 DPI 图标验证。未完成 Store 更新路由、公共符号上传容器、包身份与数据路径、开发签名安装/升级/卸载/重装、Windows App Certification Kit 和正式身份校验，不勾选商店发布总门禁。打包没有 UI 操作，本节不声称通过视频验收。

实现参考：[微软手动生成 MSIX 包组件](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-manual-conversion)、[MakeAppx 工具](https://learn.microsoft.com/en-us/windows/msix/package/create-app-package-with-makeappx-tool)。

## MSIX 更新渠道隔离（2026-09-15）

应用使用 Windows `GetCurrentPackageFullName` 判断 Portable / Packaged / Unknown。只有明确未打包的应用才使用现有 GitHub ZIP 更新路径；MSIX 版隐藏 ZIP 检查/下载入口，打开 Microsoft Store 下载与更新页，并说明测试/组织分发需使用原安装渠道。包身份不等于已从 Store 安装，故不宣称开发包由 Store 自动更新。无法识别时禁用便携更新并显示恢复说明。

`dotnet run --project native/desktop/Recappi.Desktop.Tests -c Release` 全部通过，新增注入 Packaged/Unknown 的回归证明不会创建 ZIP 更新客户端或修改目标文件；Store 按钮 URI 路由和启动失败提示通过，既有便携检查、下载校验、取消回归仍通过。测试中本地 `Button(string)` 函数遮蔽了 Button 类型导致首次编译失败，已对 RoutedEvent 静态访问使用完整类型名；完整回归重跑成功。后续扩展这些测试时避免与局部帮助函数重名的未限定类型访问。

已重新生成双架构精简候选 `build/native-desktop-release/b377a7d0f140449fbf88d793f7134df7`（`797c908` + dirty，含本次更新路由改动）。x64 ZIP 68,625,280 字节 / 解压 164,187,970；ARM64 ZIP 63,451,377 / 解压 178,441,528。默认发布仍未启用精简。

新 MSIX 再次通过 SDK 与全部载荷哈希检查：x64 `build/native-msix/477ce849082a4685b5bfe5b22e866801`，69,817,161 字节，SHA256 `9125d8b28b1fbc4ba70b7ecd198722227b2a08b11c934d8c91c5fd20156f8c73`；ARM64 `build/native-msix/6829ee3ff4fd4413a3e64f59e786e375`，64,851,794 字节，SHA256 `7dd16506e63ec6e1b1f8da6f26d521099df82d4029fc0423b33dc1a9a5bec94e`。均未签名、未安装、非 Store-ready。

实际安装进程的包身份检测、设置外观/键盘/商店打开视频、录音期间更新策略和干净环境仍待验收。注入身份测试不能替代真实 MSIX 行为。参考：[包身份 API](https://learn.microsoft.com/en-us/windows/win32/api/appmodel/nf-appmodel-getcurrentpackagefullname)、[Store URI](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-store-app)。

## 真实包激活与设置视频（2026-09-15）

本机预检：Windows 开发者模式已开启、当前会话未提权、没有 Windows Sandbox。先从干净提交 `07127dd` 发布双架构精简候选 `8be365d0a9f94d8992e4855923275931`（报告 sourceDirty=false），没有把开发机当干净系统。

用 `Add-AppxPackage -Register` 注册独立开发身份；直接运行注册目录的 EXE 后，`GetPackageFullName` 返回 15700（未打包），因此拒绝把该次启动算作 MSIX 验收。改用 `IApplicationActivationManager` 的 AUMID 激活。为避免包激活不继承 shell 环境而读到原有账号，新增显式 `--validation-data-dir <绝对目录>` 和 `scripts/start-native-msix-validation.ps1`：要求无 Recappi 实例、唯一开发注册，创建无账号、无自动上传/字幕/麦克风的独立设置，按 AUMID 激活，再核对实际进程完整包身份。

实际进程 PID 44692，AUMID `Recappi.Mini.Development_j5b8m4d3awvt8!App`，核实完整身份 `Recappi.Mini.Development_1.0.0.0_x64__j5b8m4d3awvt8`。设置目录 UI 同时显示指定隔离目录。证据：`build/native-desktop-validation/msix-launch-bde8588f25904d89b37b2f1d8f2ffb8e/activation.json`。这是开发注册后的真实包身份，仍不是已签名 MSIX 安装或 Store 来源证明。

本次用于激活的 x64 包包含新的隔离目录参数：发布目录 `6cdc8792130242cc81b71385534f5165`，MSIX `build/native-msix/7d2576562d83460ba2a8b15303b7bd73`，69,817,969 字节，SHA256 `e6988cea644bb44edf6de0e902fc3879bf57ae60b69e068dd9ba0105b3216d0e`；后续 ARM64 对应发布 `726f33ee417146039f6c4485c53009c2`，MSIX `66665c7fa07d442c9f64ed15d59f7896`，64,852,616 字节，SHA256 `e305136c7a1c3daeeadc9d2c48109b81c5a0d57e3936b791fee194e2b11407ca`。新增参数后的包 sourceDirty=true；双架构 SDK/内容哈希验证通过，ARM64 未运行。

设置内容区视频 `build/native-desktop-validation/msix-video-20260915/settings.mp4`：53.733 秒 / 15 fps / 806 帧→4 个关键帧，SHA256 `b351ca954abfab6341c53013dbdaf034def4a79258c72801da548a90d6f5efc8`。实际查看全部关键帧及关于页原尺寸图，AI 分析加自动证据门禁报告 `acceptance.html`：

- 通过 3 项：MSIX 说明与 Store/原渠道入口、通用→关于往返保持渠道、当前浅色尺寸的关于页布局与中文换行。没有便携 ZIP 检查/下载/解压提示。
- 证据不足 2 项：未点击 Store 按钮；未验证签名安装/干净环境生命周期。视频不覆盖窗口边框、启动、录音、升级；停止录制后的末条事件被标为视频外，不用来判通过。

已清理本次开发注册，没有写入或导入系统证书；用户原有录音/账号未用于验收。清理时误把选项弹层的账号入口识别为退出，打开了账号窗口但未登录。随后的进程存活门禁拦住卸载；核对本次 PID/路径、UI 空闲、隔离目录无录音/账号后停止进程并移除精确注册，`cleanup.json` 明确 normalQuitVerified=false。后续弹层底部操作必须先获取可读标签或滚动后的清晰图，不以相近按钮位置推断退出。

本轮完整 WPF 回归曾在本地/云端关联删除用例失败：只等待 Dispatcher Idle 就假定 async Loaded 已载入列表。新增最多 5 秒等待目标录音实际出现，再运行原有严格删除/保留断言；重跑完整 Release 回归通过。不得把一次调度空闲当数据加载完成。

剩余：正式签名安装、真实 Store 打开、包身份下录音/导入/导出、正常退出、升级数据保留/卸载重装、干净系统及 ARM64 实机。开发注册清理不等于安装生命周期通过。

## 开发包选项与空闲退出视频（2026-09-15）

上一轮退出入口位于滚动表单最底部，当前尺寸下不可直接看到。本轮将设置/库/账号/目录/退出固定于弹层底部，表单独立滚动；打开时滚到顶部并聚焦名称，Tab 在弹层内循环。生产窗口 500/360 高度下实测退出按钮边界在可视区内、表单有可用滚动视口；完整 WPF Release 回归通过。改变的是录音条弹层，不是录音引擎或退出保存策略。

双架构精简发布 `build/native-desktop-release/c20f403ad0164bbe9e45929b5436e011`（baca33b + dirty）。x64 ZIP 68,625,615 / 解压 164,188,994 字节；ARM64 ZIP 63,451,712 / 解压 178,442,552 字节。MSIX SDK/全部载荷哈希验证通过：x64 `build/native-msix/81526e2b22fa46588f3ee102d809c374`，69,817,662 字节，SHA256 `d8591de2fa896a7920d583baae007450f590445e93205a48ebfbd08e2f2f036e`；ARM64 `c15efff8a43e4335838ebb830fcfaabd`，64,852,297 字节，SHA256 `e7518822abf3e825260b9d34360e64bb7ac65a7d065cf2f6e50ac6279032bec4`。仍未签名/安装认证，默认发布未切换精简。

使用 x64 开发注册，通过 AUMID 激活 PID 46564 并核对包身份；隔离数据根为 `build/native-desktop-validation/msix-launch-81e49de69dae4e249110af8eeba8c8a7`。没有登录、录音或修改采集选项。

视频证据 `build/native-desktop-validation/options-video-20260915/acceptance.html`：固定弹层区域录制，`options.mp4` 78 秒/1170 帧→8 关键帧，`quit.mp4` 29.533 秒/443 帧→4 关键帧，共 1613→12。实际查看全部关键帧与完整翻译字段/退出帧，AI 画面审查结合哈希、时间点和独立进程状态：

- 4 项通过：退出及其他底部按钮始终可见；名称框 Shift+Tab 到退出有清晰焦点；可滚至翻译语言完整输入框且底部保持；点击退出后弹层消失、进程结束且没有强制终止。
- 2 项证据不足：录音中退出保存；其他 DPI/屏幕和完整键盘循环。几何回归不替代这些视频。`exit.json` 的 exitCode 为 null，不能宣称退出码 0；只记录操作后进程结束。

首次按无障碍元素索引点击弹层退出时，工具误用主录音条 580×58 边界，拒绝目标点 (424,550)，不判成功。刷新截图后按已读清晰标签的弹层坐标重试，另段视频记录成功退出。该情况后续使用新截图的弹层区域定位，不重复旧元素索引。退出后画面露出原有本机验收报告窗口，不能当作 Recappi 页面；视频仅保存在本机。

已确认 PID 消失并移除本次精确开发注册，未强制结束应用、未改证书信任。此前不具备的空闲退出操作证据现已补齐；签名安装、录音中退出、升级/卸载数据语义和干净环境仍未通过。

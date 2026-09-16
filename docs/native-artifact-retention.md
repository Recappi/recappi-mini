# Windows 原生产物保留与清理

新发布默认每种配置保留最近 **3 组完整产物**；配置按架构组合、自包含/框架依赖、完整/精简资源区分。MSIX 每个架构保留最近 3 组。`publish-native-desktop.ps1` 和 `build-native-msix.ps1` 成功后执行规则，可用 `-KeepHistory N` 调整。失败或没有完成报告的目录保留，避免删除诊断现场。

旧产物不能被新脚本首次运行时直接删除：新报告带 `retentionPolicyVersion=1`，自动清理仅管理该标记或已明确纳入规则的目录。历史目录迁移须先预览、再执行同一份清单。迁移保留下来的完整产物通过独立 `.artifact-managed.json` 纳入后续保留规则，不改原报告内容。

## 预览与执行

```powershell
# 不删除产物；生成完整候选路径、大小、指纹、保留项及跳过原因。
powershell.exe -NoProfile -File scripts/clean-native-artifacts.ps1 `
  -IncludeLegacy -IncludeTestRuns -ReportPath build/native-artifact-cleanup-preview.json

# 检查清单后执行。路径、文件指纹或保护状态改变会拒绝，需重新预览。
powershell.exe -NoProfile -File scripts/clean-native-artifacts.ps1 `
  -ApplyPlan build/native-artifact-cleanup-preview.json
```

`-IncludeTestRuns` 是显式选择，仅覆盖至少 24 小时未更新的 `core-tests-<GUID>` / `ui-smoke-<GUID>`，每类保留最近 3 组符合年龄条件的输出；最近 24 小时的输出额外保留。具名实操目录（如 `import-complete-ui-01`）、其他诊断目录和大录音不参与默认删除。大于 100 MiB、未列为删除候选的录音/转储另列在 `largeEvidence`，仅供人工核对。测试输出不会因为发布脚本运行而自动清理。

清理保留原位置的 JSON/JSONL、日志、文本和 HTML 报告；测试目录中的图片和视频也保留。删除的是候选目录中的其余载荷，包括 ZIP、EXE/DLL/PDB、MSIX、测试音频等。完成后写 `.artifact-pruned.json`：旧报告记录当时的哈希与大小，**不代表二进制仍可用**。因此 GUID 报告目录仍在，但不再占完整运行时和压缩包的空间。

## 保留与保护

- 长期保留基线、安装验证源或重要测试样本：在对应 GUID 目录根部创建 `.keep` 文件。固定项不占最近 3 组名额。
- 跳过报告标为已签名、已安装或 Store-ready 的输出，以及包含已签名安装器报告的发布目录。外部签名后也应主动固定目录，不能只依赖未更新的旧报告。
- 跳过正在运行的 Recappi 所在目录，以及当前用户已注册包的安装位置。原生测试进程存在时跳过测试输出清理。
- 发布、MSIX、EXE 安装器打包及实际清理共用文件锁，不能并发操作这些载荷。比较/调试期间请固定所用基线。
- 只接收限定 `build` 子目录中的 GUID 产物。拒绝目录链接/junction、跨根路径、过期清单和无法检查的文件树。
- 删除过程中出现文件占用会报错，不会标为完成。已经删除的文件不会自动恢复；修复占用后重新预览。二进制可按原提交重新构建，但旧测试音频和原始转储不能保证原样重建。

## 避免额外副本

MSIX 在 SDK 与逐文件哈希校验成功后，默认删除本次 `payload` 临时副本，保留 `.msix`、清单和日志；报告记录 `stagingPayloadRetained=false`。需要开发注册的解包目录时，显式使用 `-KeepStaging`，并在注册前固定该目录。安装器仍需其临时副本完成既有依赖门禁，由整个发布目录的历史规则管理。

日常编译使用 `dotnet build`，不必每次生成可分发 ZIP。仅验证 x64 时可给发布脚本传 `-Runtimes win-x64`；最终双架构交付仍使用默认 x64/ARM64。框架依赖候选体积小，但仍需要共享运行时，不能当成自包含发布替代品。

## 本次验证（2026-09-16）

- Windows PowerShell 5.1 的清理回归使用小型隔离目录，覆盖独立配置/架构、预览不写产物、报告保留、旧目录迁移、固定项、真实文件锁、正在运行的测试 EXE、junction、过期清单和路径越界；未删除已有发布或验收载荷。
- 实际 x64 框架依赖候选发布通过，目录 `7e9fed63b80a4e40971e0838cd8082cc`；验证新报告标记及锁释放，未为验证再生成一套完整双架构运行时。
- 实际 SDK x64 MSIX 打包 `ee6990df94c040ca9aff67e477e24a46` 通过，479 个载荷校验完成；临时副本已删除，MSIX 哈希及原发布目录保持，报告 `stagingPayloadRetained=false`。
- 历史清理预览包括约 35.7 GiB；这是候选逻辑字节，实际释放量取决于文件系统。既有历史产物尚未执行清理。原生功能/录音/ARM64 实机验收不由本轮清理测试替代。

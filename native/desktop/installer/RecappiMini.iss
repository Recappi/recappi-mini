#ifndef SourceRoot
  #error SourceRoot is required
#endif
#ifndef ReleaseVersion
  #error ReleaseVersion is required
#endif
#ifndef VersionFolder
  #error VersionFolder is required
#endif
#ifndef ProductId
  #define ProductId "{749D413C-9DC3-4D4C-AED4-C91D6485932B}"
#endif
#ifndef ProductName
  #define ProductName "Recappi Mini"
#endif
#ifndef InstallerSuffix
  #define InstallerSuffix ""
#endif

[Setup]
AppId={{#ProductId}
AppName={#ProductName}
AppVersion={#ReleaseVersion}
VersionInfoVersion={#InstallerVersion}
AppPublisher=Recappi
AppPublisherURL=https://github.com/Recappi/recappi-mini
DefaultDirName={localappdata}\Programs\{#ProductName}
DefaultGroupName={#ProductName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.19041
ArchitecturesAllowed={#AllowedArchitecture}
ArchitecturesInstallIn64BitMode={#AllowedArchitecture}
UninstallDisplayIcon={app}\versions\{#VersionFolder}\Recappi Mini.exe
OutputDir={#OutputRoot}
OutputBaseFilename=Recappi-Mini-{#ReleaseVersion}-{#Runtime}{#InstallerSuffix}-Setup
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
SetupMutex=Local\RecappiMini.Desktop.Setup
AppMutex=Local\RecappiMini.Desktop.InstallGuard
CloseApplications=no
RestartApplications=no
UninstallLogMode=append

[Files]
Source: "{#SourceRoot}\*"; DestDir: "{app}\versions\{#VersionFolder}"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef FrameworkDependentCandidate
Source: "{#ProbeRoot}\Recappi.RuntimeProbe.exe"; Flags: dontcopy
Source: "{#ProbeRoot}\Recappi.RuntimeProbe.dll"; Flags: dontcopy
Source: "{#ProbeRoot}\Recappi.RuntimeProbe.deps.json"; Flags: dontcopy
Source: "{#ProbeRoot}\Recappi.RuntimeProbe.runtimeconfig.json"; Flags: dontcopy
#endif

[Icons]
Name: "{group}\{#ProductName}"; Filename: "{app}\versions\{#VersionFolder}\Recappi Mini.exe"; WorkingDir: "{app}\versions\{#VersionFolder}"

[Messages]
FinishedLabel=Setup has installed [name] for your Windows account.%n%nClose this installer, then open [name] from the Start menu.%n%nUninstall removes application files and shortcuts. Your recordings and account data are kept.

[Code]
#ifdef FrameworkDependentCandidate
var
  RuntimeDownloadPage: TDownloadWizardPage;

procedure InitializeWizard;
begin
  RuntimeDownloadPage := CreateDownloadPage('安装 .NET Desktop Runtime', '正在从 Microsoft 下载并校验运行时。', nil);
  RuntimeDownloadPage.ShowBaseNameInsteadOfUrl := True;
end;

function HasCompatibleRuntime: Boolean;
var
  ExitCode: Integer;
begin
  ExtractTemporaryFile('Recappi.RuntimeProbe.exe');
  ExtractTemporaryFile('Recappi.RuntimeProbe.dll');
  ExtractTemporaryFile('Recappi.RuntimeProbe.deps.json');
  ExtractTemporaryFile('Recappi.RuntimeProbe.runtimeconfig.json');
  ExitCode := -1;
  Result := Exec(ExpandConstant('{tmp}\Recappi.RuntimeProbe.exe'), '--check-runtime', ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
  Log('Runtime probe result: ' + IntToStr(ExitCode));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
  RuntimeFile: String;
begin
  Result := '';
  try
    if HasCompatibleRuntime then Exit;
    if WizardSilent then
    begin
      Result := '需要匹配架构的 .NET 10 Desktop Runtime。请先安装运行时，或交互运行此安装器；离线可使用自包含安装包。';
      Exit;
    end;
    if MsgBox('此应用需要 .NET 10 Desktop Runtime。是否从 Microsoft 下载并安装？' + #13#10 +
      '安装运行时可能要求管理员授权；取消不会安装 Recappi Mini。共享运行时不会随应用卸载。' + #13#10 +
      '离线安装请使用自包含安装包。', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) <> IDYES then
    begin
      Result := '尚未安装运行时，应用文件未更改。可稍后重试或使用自包含安装包。';
      Exit;
    end;
    RuntimeDownloadPage.Clear;
    RuntimeDownloadPage.Add('{#RuntimeDownloadUrl}', 'windowsdesktop-runtime.exe', '{#RuntimeDownloadSha256}');
    RuntimeDownloadPage.Show;
    try
      RuntimeDownloadPage.Download;
    finally
      RuntimeDownloadPage.Hide;
    end;
    RuntimeFile := ExpandConstant('{tmp}\windowsdesktop-runtime.exe');
    if GetSHA256OfFile(RuntimeFile) <> '{#RuntimeDownloadSha256}' then
    begin
      Result := '运行时校验失败，未执行下载的文件。';
      Exit;
    end;
    if not ShellExec('runas', RuntimeFile, '/install /passive /norestart', ExpandConstant('{tmp}'), SW_SHOWNORMAL, ewWaitUntilTerminated, ExitCode) then
    begin
      Result := '运行时安装未获授权或无法启动。应用文件未更改，可重试。';
      Exit;
    end;
    if (ExitCode <> 0) and (ExitCode <> 3010) then
    begin
      Result := '运行时安装未完成，退出码 ' + IntToStr(ExitCode) + '。应用文件未更改，可重试。';
      Exit;
    end;
    if ExitCode = 3010 then NeedsRestart := True;
    if not HasCompatibleRuntime then
      Result := '运行时仍不可用。请按运行时安装器提示重启，再重新运行此安装器。';
  except
    Result := '运行时准备失败或下载已取消。应用文件未更改，可检查网络后重试。' + #13#10 + GetExceptionMessage;
  end;
end;
#endif

function InitializeSetup: Boolean;
var
  PreviousVersion: String;
  PreviousPacked, CurrentPacked: Int64;
begin
  Result := True;
  PreviousVersion := GetPreviousData('InstallerVersion', '');
  if (PreviousVersion <> '') and StrToVersion(PreviousVersion, PreviousPacked) and
     StrToVersion('{#InstallerVersion}', CurrentPacked) and
     (ComparePackedVersion(PreviousPacked, CurrentPacked) > 0) then
  begin
    SuppressibleMsgBox('A newer version is already installed. Uninstall it before installing an older version. Your recordings will be kept.', mbError, MB_OK, IDOK);
    Result := False;
  end;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'InstallerVersion', '{#InstallerVersion}');
end;

function InitializeUninstall: Boolean;
begin
  Result := not CheckForMutexes('Local\RecappiMini.Desktop.Setup');
  if Result then CreateMutex('Local\RecappiMini.Desktop.Setup')
  else SuppressibleMsgBox('An installation is already running. Close it before uninstalling.', mbError, MB_OK, IDOK);
end;

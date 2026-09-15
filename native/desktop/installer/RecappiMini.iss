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
OutputBaseFilename=Recappi-Mini-{#ReleaseVersion}-{#Runtime}-Setup
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

[Icons]
Name: "{group}\{#ProductName}"; Filename: "{app}\versions\{#VersionFolder}\Recappi Mini.exe"; WorkingDir: "{app}\versions\{#VersionFolder}"

[Messages]
FinishedLabel=Setup has installed [name] for your Windows account.%n%nClose this installer, then open [name] from the Start menu.%n%nUninstall removes application files and shortcuts. Your recordings and account data are kept.

[Code]
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

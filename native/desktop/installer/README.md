# Windows installer

The installer contains the self-contained C# desktop application. It installs for
the current Windows user without elevation, under
`%LOCALAPPDATA%\Programs\Recappi Mini`. Recordings, preferences and protected
account storage remain in their existing data locations.

## Build

Use the official Inno Setup 7.1.0 x64 compiler in portable mode at
`build/native-installer-tools/inno-7.1.0`. Obtain it from the
[official download page](https://jrsoftware.org/isdl.php). The pinned installer
SHA-256 is `0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f`;
verify its Authenticode signature is valid and names Pyrsys B.V. before running
it. Inno's portable parameters are documented in its
[technical notes](https://jrsoftware.org/ishelp/topic_technotes.htm).

```powershell
powershell -NoProfile -File scripts/prepare-native-installer-tools.ps1
powershell -NoProfile -File scripts/publish-native-desktop.ps1
powershell -NoProfile -File scripts/build-native-installer.ps1 -ReleaseReport <release-report.json> -Runtime win-x64
powershell -NoProfile -File scripts/build-native-installer.ps1 -ReleaseReport <release-report.json> -Runtime win-arm64
```

The builder validates the ZIP against the release report, extracts that exact
archive with path/size bounds, checks executable architecture, and compiles it.
It does not use a potentially modified adjacent publish directory. Every build
writes a unique output directory and an `installer-report.json` with size, hash,
architecture, version and signature status. Production packages use a stable
AppId; tests use unique identities and separate installation directories.

Installer versions support `major.minor.patch` and `major.minor.patch-preview.N`.
Each component fits 16 bits, preview N is 1–65534, and a stable release maps to
revision 65535. This lets the installed version check reject downgrades, including
stable-to-preview downgrades. The application update feed uses SemVer separately.

## Lifecycle and rollback

Files go into `versions/<version>-<archive hash prefix>`; the Start menu shortcut
changes after file installation. Existing version directories remain available
after an upgrade. This protects the previous executable and dependencies from
replacement failures, at the cost of retaining old versions on disk. Automatic
old-version pruning and recovery from power loss at every installation phase
have not been implemented or verified.

Setup and uninstall check the application's installation mutex. They do not use
Restart Manager to terminate the app. The application also refuses startup while
the setup/uninstall mutex exists. Close the installer before launching from the
Start menu. The installer does not change microphone permissions or start a
recording.

The uninstaller tracks package-created files and appends records across upgrades.
There is no wildcard removal of the installation root or data folders. Files a
user adds are retained, including files inside the install directory.

## Validation

```powershell
powershell -NoProfile -File scripts/test-native-installer.ps1 -PreviousReleaseReport <older-report.json> -NextReleaseReport <newer-report.json>
```

This performs real per-user installs using isolated names/identities, launches the
installed app, verifies an active app blocks an upgrade, causes a native file
write failure, checks preservation of the old executable and shortcut, retries
the upgrade, rejects a downgrade, and uninstalls while retaining test user files.
It creates actual temporary Start menu and HKCU uninstall entries and removes
them on a successful run. A failed run retains logs and may require cleanup of
that specific test installation. It never stops an app that was already running.

Current x64 validation uses the development machine, not a clean Windows image.
ARM64 installer compilation is separate from ARM64 device validation. The current
packages and uninstallers are unsigned; publisher signing, real release delivery
and launching installers from the application's update flow remain outstanding.

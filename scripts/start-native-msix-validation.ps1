param([string]$IdentityName = 'Recappi.Mini.Development')
$ErrorActionPreference = 'Stop'
if (@(Get-Process -Name 'Recappi Mini' -ErrorAction SilentlyContinue).Count) { throw 'Close Recappi before isolated package validation.' }
$packages = @(Get-AppxPackage -Name $IdentityName)
if ($packages.Count -ne 1 -or -not $packages[0].IsDevelopmentMode) { throw 'Select exactly one registered development package.' }
$package = $packages[0]
$root = Join-Path (Split-Path -Parent $PSScriptRoot) ('build/native-desktop-validation/msix-launch-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$recordings = Join-Path $root 'Recordings'
[ordered]@{ onboardingCompleted = $true; theme = 'light'; autoUpload = $false; captionsEnabled = $false;
    includeMicrophone = $false; recordingSuggestions = $false; inactivityReminders = $false; sourceId = 'system'; recordingsRoot = $recordings } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'settings.json') -Encoding utf8
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class RecappiPackageActivation {
 [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 interface IActivation {
  void ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.LPWStr)] string args, uint options, out uint pid);
 }
 [DllImport("ole32.dll", PreserveSig=false)]
 static extern void CoCreateInstance(ref Guid clsid, IntPtr outer, uint context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IActivation value);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
 static extern int GetPackageFullName(IntPtr process, ref uint length, StringBuilder name);
 public static uint Launch(string id, string args) {
  var clsid = new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C");
  var iid = typeof(IActivation).GUID;
  IActivation activation; CoCreateInstance(ref clsid, IntPtr.Zero, 4, ref iid, out activation);
  try { uint pid; activation.ActivateApplication(id, args, 0, out pid); return pid; }
  finally { Marshal.ReleaseComObject(activation); }
 }
 public static string Identity(IntPtr handle) {
  uint length=0; var result=GetPackageFullName(handle,ref length,null);
  if(result!=122) throw new InvalidOperationException("GetPackageFullName: "+result);
  var name=new StringBuilder((int)length); result=GetPackageFullName(handle,ref length,name);
  if(result!=0) throw new InvalidOperationException("GetPackageFullName: "+result);
  return name.ToString();
 }
}
'@
$aumid = $package.PackageFamilyName + '!App'
$arguments = '--validation-data-dir "' + $recordings + '"'
$launchedId = [RecappiPackageActivation]::Launch($aumid, $arguments)
$process = Get-Process -Id $launchedId -ErrorAction Stop
$actualIdentity = [RecappiPackageActivation]::Identity($process.Handle)
if ($actualIdentity -ne $package.PackageFullName) { throw 'Activated process package identity mismatch.' }
$report = [ordered]@{ startedAt = [DateTimeOffset]::UtcNow.ToString('O'); processId = $launchedId; aumid = $aumid;
    packageFullName = $actualIdentity; executable = $process.Path; dataDirectory = $recordings;
    scope = 'Development registration and real package activation; not signed MSIX installation or clean environment acceptance' }
$report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'activation.json') -Encoding utf8
$report | ConvertTo-Json

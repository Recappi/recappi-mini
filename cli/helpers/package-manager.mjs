import { spawnSync } from "node:child_process";

// npm/pnpm are .cmd/.ps1 launchers on Windows. Pass arguments as data to
// PowerShell rather than interpolating filesystem paths into shell code.
export function runPackageManager(name, args, options = {}) {
  if (!["npm", "pnpm"].includes(name)) throw new Error("Unknown package manager");
  if (process.platform !== "win32") return spawnSync(name, args, options);
  return spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "$call = ConvertFrom-Json $env:RECAPPI_PACKAGE_COMMAND; $manager = $call.name; $managerArgs = @($call.args); & $manager @managerArgs; exit $LASTEXITCODE",
    ],
    {
      ...options,
      windowsHide: true,
      env: {
        ...process.env,
        ...options.env,
        RECAPPI_PACKAGE_COMMAND: JSON.stringify({ name, args }),
      },
    },
  );
}

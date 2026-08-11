import path from "node:path";

export interface PlatformCommand {
  command: string;
  args: string[];
}

export function openTargetCommand(
  target: string,
  platform: NodeJS.Platform = process.platform,
): PlatformCommand {
  if (platform === "darwin") return { command: "open", args: [target] };
  if (platform === "win32") return { command: "explorer.exe", args: [target] };
  return { command: "xdg-open", args: [target] };
}

export function revealTargetCommand(
  localPath: string,
  platform: NodeJS.Platform = process.platform,
): PlatformCommand {
  if (platform === "darwin") return { command: "open", args: ["-R", localPath] };
  if (platform === "win32") {
    return { command: "explorer.exe", args: ["/select,", localPath] };
  }
  return { command: "xdg-open", args: [path.dirname(localPath)] };
}

export function clipboardCommand(
  platform: NodeJS.Platform = process.platform,
): PlatformCommand | null {
  if (platform === "darwin") return { command: "pbcopy", args: [] };
  if (platform === "win32") return { command: "clip.exe", args: [] };
  return null;
}

export function fileManagerName(platform: NodeJS.Platform = process.platform): string {
  if (platform === "darwin") return "Finder";
  if (platform === "win32") return "File Explorer";
  return "file manager";
}

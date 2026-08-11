import { describe, expect, it } from "vitest";
import {
  clipboardCommand,
  fileManagerName,
  openTargetCommand,
  revealTargetCommand,
} from "../src/platform";

describe("platform integration commands", () => {
  it("uses Explorer and clip.exe on Windows", () => {
    const localPath = String.raw`C:\Users\Ada\Recappi\meeting.wav`;

    expect(openTargetCommand(localPath, "win32")).toEqual({
      command: "explorer.exe",
      args: [localPath],
    });
    expect(revealTargetCommand(localPath, "win32")).toEqual({
      command: "explorer.exe",
      args: ["/select,", localPath],
    });
    expect(clipboardCommand("win32")).toEqual({ command: "clip.exe", args: [] });
    expect(fileManagerName("win32")).toBe("File Explorer");
  });

  it("keeps macOS and Linux launch commands platform-native", () => {
    expect(openTargetCommand("/tmp/meeting.wav", "darwin")).toEqual({
      command: "open",
      args: ["/tmp/meeting.wav"],
    });
    expect(revealTargetCommand("/tmp/recappi/meeting.wav", "linux")).toEqual({
      command: "xdg-open",
      args: ["/tmp/recappi"],
    });
    expect(clipboardCommand("linux")).toBeNull();
  });
});

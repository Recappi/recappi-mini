import { useWindowSize } from "ink";

export interface TerminalSize {
  columns: number;
  rows: number;
}

export function useTerminalSize(): TerminalSize {
  return useWindowSize();
}

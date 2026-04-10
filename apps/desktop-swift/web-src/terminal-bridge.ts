import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import * as bridge from "./superset-bridge";

interface TerminalEntry {
  term: Terminal;
  fit: FitAddon;
  container: HTMLDivElement;
  resizeObserver: ResizeObserver;
}

const terminals = new Map<string, TerminalEntry>();
let activeSessionId: string | null = null;

const FONT_FAMILY = [
  "JetBrains Mono",
  "JetBrainsMono Nerd Font",
  "MesloLGM Nerd Font",
  "MesloLGM NF",
  "Menlo",
  "Monaco",
  "Courier New",
  "monospace",
].join(", ");

const THEME = {
  background: "#151110",
  foreground: "#d4d4d4",
  cursor: "#d4d4d4",
  cursorAccent: "#151110",
  selectionBackground: "#264f78",
  black: "#000000",
  red: "#cd3131",
  green: "#0dbc79",
  yellow: "#e5e510",
  blue: "#2472c8",
  magenta: "#bc3fbc",
  cyan: "#11a8cd",
  white: "#e5e5e5",
  brightBlack: "#666666",
  brightRed: "#f14c4c",
  brightGreen: "#23d18b",
  brightYellow: "#f5f543",
  brightBlue: "#3b8eea",
  brightMagenta: "#d670d6",
  brightCyan: "#29b8db",
  brightWhite: "#e5e5e5",
};

const rootContainer = document.getElementById("terminal-container")!;

function initTerminal(sessionId: string): void {
  // Destroy existing if re-initializing (WebView crash recovery)
  const existing = terminals.get(sessionId);
  if (existing) {
    existing.resizeObserver.disconnect();
    existing.term.dispose();
    existing.container.remove();
    terminals.delete(sessionId);
  }

  // Create container div
  const container = document.createElement("div");
  container.id = `term-${sessionId}`;
  container.style.cssText = "position:absolute;inset:0;visibility:hidden;";
  rootContainer.appendChild(container);

  const fitAddon = new FitAddon();
  const term = new Terminal({
    cols: 80,
    rows: 24,
    cursorBlink: true,
    fontFamily: FONT_FAMILY,
    fontSize: 14,
    allowProposedApi: true,
    scrollback: 10000,
    macOptionIsMeta: false,
    cursorStyle: "block",
    cursorInactiveStyle: "outline",
    theme: THEME,
  });

  term.loadAddon(fitAddon);

  const unicode11 = new Unicode11Addon();
  term.loadAddon(unicode11);
  term.unicode.activeVersion = "11";

  term.open(container);

  // WebGL addon — optional
  requestAnimationFrame(() => {
    try {
      const webgl = new WebglAddon();
      webgl.onContextLoss(() => {
        webgl.dispose();
        term.refresh(0, term.rows - 1);
      });
      term.loadAddon(webgl);
    } catch {
      // Canvas fallback
    }
  });

  // Wire keyboard input → Swift PTY
  term.onData((data) => {
    bridge.sendInput(sessionId, data);
  });

  // Wire resize — only send if this terminal is visible
  const resizeObserver = new ResizeObserver(() => {
    if (activeSessionId === sessionId) {
      fitAddon.fit();
      bridge.requestResize(sessionId, term.cols, term.rows);
    }
  });
  resizeObserver.observe(container);

  terminals.set(sessionId, { term, fit: fitAddon, container, resizeObserver });

  // Connect PTY output stream
  bridge.connectOutputStream(sessionId, {
    onData: (data) => term.write(data),
    onExit: (code, _signal) => {
      term.writeln(`\r\n\x1b[90m[Process exited with code ${code}]\x1b[0m`);
    },
    onError: (message) => {
      term.writeln(`\r\n\x1b[31m[Error: ${message}]\x1b[0m`);
    },
  });
}

function showTerminal(sessionId: string): void {
  // Hide all
  for (const [, entry] of terminals) {
    entry.container.style.visibility = "hidden";
  }

  // Show target
  const entry = terminals.get(sessionId);
  if (entry) {
    entry.container.style.visibility = "visible";
    activeSessionId = sessionId;
    entry.fit.fit();
    bridge.requestResize(sessionId, entry.term.cols, entry.term.rows);
    entry.term.focus();
  }
}

function destroyTerminal(sessionId: string): void {
  const entry = terminals.get(sessionId);
  if (entry) {
    entry.resizeObserver.disconnect();
    entry.term.dispose();
    entry.container.remove();
    terminals.delete(sessionId);
    if (activeSessionId === sessionId) {
      activeSessionId = null;
    }
  }
}

function getActiveSessionId(): string | null {
  return activeSessionId;
}

// Expose to Swift
(window as any).__superset = {
  initTerminal,
  showTerminal,
  destroyTerminal,
  getActiveSessionId,
};

// Signal readiness
bridge.signalReady();

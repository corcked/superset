# Phase 2a: Multi-Terminal + SQLite + Native Sidebar — Design Spec

## Context

Phase 1 delivered a native macOS Swift app with a single terminal in a WKWebView. Phase 2a extends this with:

- Multiple concurrent terminal sessions, one visible at a time (CSS show/hide)
- SQLite database (GRDB) for persisting projects and workspaces, compatible with the existing `packages/local-db` schema
- Native SwiftUI sidebar via NSSplitView for project/workspace navigation
- Full lifecycle: add project, create/delete workspace, switch between terminals

This is Phase 2a of the roadmap. Phase 2b adds git status, PR badges, drag-and-drop, sections, and keyboard shortcuts.

## Architecture

### Window Layout

```
┌──────────────────────────────────────────────────────────┐
│  NSWindow                                                 │
│  ┌─────────────────┬────────────────────────────────────┐ │
│  │  NSSplitView    │                                    │ │
│  │  ├─ Left pane   │  Right pane                        │ │
│  │  │  (SwiftUI    │  (WKWebView — all xterm instances) │ │
│  │  │   sidebar    │                                    │ │
│  │  │   via NSHost │  Active terminal: visibility:visible│ │
│  │  │   ingView)   │  Others: visibility:hidden          │ │
│  │  │              │                                    │ │
│  │  │  Projects    │  $ echo hello                      │ │
│  │  │  └ workspaces│  hello                             │ │
│  │  │              │  $                                 │ │
│  │  │  [+ Project] │                                    │ │
│  │  └──────────────┴────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

NSSplitView replaces the current bare WKWebView. Left pane holds a SwiftUI view via `NSHostingView`. Right pane holds the existing WKWebView. The divider is draggable and the sidebar is collapsible.

### Component Overview

```
MainWindowController
├── NSSplitView (NSSplitViewController)
│   ├── SidebarSplitItem (NSHostingView wrapping SwiftUI)
│   │   └── SidebarView
│   │       ├── SidebarToolbar (+ project, + workspace buttons)
│   │       └── ProjectListView
│   │           └── ProjectRow (disclosure group)
│   │               └── WorkspaceRow (selectable, deletable)
│   └── TerminalSplitItem (WKWebView — unchanged from Phase 1)
├── PTYSessionManager (existing)
├── SupersetSchemeHandler (existing)
├── ControlMessageHandler (existing, extended)
└── DatabaseManager (new — GRDB)
```

### Data Flow

```
SQLite (GRDB)
  ↕ ValueObservation (reactive)
SidebarViewModel (@Observable)
  ↕ SwiftUI binding
SidebarView
  → user action (select/create/delete)
  → SidebarViewModel
  → DatabaseManager (persist)
  → PTYSessionManager (create/destroy PTY)
  → MainWindowController.switchTerminal(sessionId)
  → evaluateJavaScript("__superset.showTerminal(id)")
  → JS: CSS visibility toggle + FitAddon.fit()
```

## Database (GRDB + SQLite)

### Location

`~/.superset/local.db` — same file as `packages/local-db` uses. WAL mode for concurrent reads.

### Schema

Compatible with the existing Drizzle schema in `packages/local-db/src/schema/`. Phase 2a uses a subset of the tables:

**projects**

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PRIMARY KEY | UUID v4 |
| name | TEXT NOT NULL | Display name |
| main_repo_path | TEXT NOT NULL | Absolute path to git repo |
| color | TEXT NOT NULL DEFAULT '#6366f1' | Sidebar accent color |
| tab_order | INTEGER NOT NULL DEFAULT 0 | Sort position |
| created_at | TEXT NOT NULL | ISO 8601 timestamp |
| last_opened_at | TEXT | ISO 8601 timestamp |

**workspaces**

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PRIMARY KEY | UUID v4 |
| project_id | TEXT NOT NULL REFERENCES projects(id) | Parent project |
| worktree_id | TEXT REFERENCES worktrees(id) | NULL for branch type |
| type | TEXT NOT NULL DEFAULT 'branch' | 'branch' or 'worktree' |
| branch | TEXT NOT NULL | Git branch name |
| name | TEXT NOT NULL | Display name |
| tab_order | INTEGER NOT NULL DEFAULT 0 | Sort within project |
| created_at | TEXT NOT NULL | ISO 8601 |
| last_opened_at | TEXT | ISO 8601 |
| is_active | INTEGER NOT NULL DEFAULT 0 | Currently selected |

**worktrees** (Phase 2a: created but not fully used until Phase 2b adds git worktree creation)

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PRIMARY KEY | UUID v4 |
| project_id | TEXT NOT NULL REFERENCES projects(id) | Parent project |
| path | TEXT NOT NULL | Absolute path to worktree |
| branch | TEXT NOT NULL | Branch checked out |
| created_at | TEXT NOT NULL | ISO 8601 |

### GRDB Models

```swift
struct Project: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var name: String
    var mainRepoPath: String
    var color: String
    var tabOrder: Int
    var createdAt: String
    var lastOpenedAt: String?

    static let workspaces = hasMany(Workspace.self)
}

struct Workspace: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var projectId: String
    var worktreeId: String?
    var type: String       // "branch" or "worktree"
    var branch: String
    var name: String
    var tabOrder: Int
    var createdAt: String
    var lastOpenedAt: String?
    var isActive: Bool

    static let project = belongsTo(Project.self)
}
```

### DatabaseManager

Singleton. Opens/creates `~/.superset/local.db`, runs migrations, provides read/write methods.

```swift
final class DatabaseManager {
    static let shared = DatabaseManager()
    private let dbQueue: DatabaseQueue

    // Read
    func allProjectsWithWorkspaces() -> [ProjectWithWorkspaces]
    func activeWorkspace() -> Workspace?

    // Write
    func insertProject(name: String, path: String) -> Project
    func insertWorkspace(projectId: String, name: String, branch: String) -> Workspace
    func setActiveWorkspace(id: String)
    func deleteWorkspace(id: String)
    func deleteProject(id: String)

    // Reactive
    func observeProjectsWithWorkspaces() -> ValueObservation<[ProjectWithWorkspaces]>
}
```

`ValueObservation` is GRDB's reactive primitive — it emits new values whenever the observed tables change. The sidebar subscribes to this for live updates.

## SwiftUI Sidebar

### View Hierarchy

```
SidebarView
├── ScrollView
│   └── LazyVStack
│       └── ForEach(projects)
│           └── DisclosureGroup
│               ├── ProjectHeaderView (name, color dot, workspace count)
│               └── ForEach(workspaces)
│                   └── WorkspaceRowView (name, active indicator)
├── Spacer
└── SidebarFooterView
    ├── Button: "Add Project" (+ icon)
    └── Button: "New Workspace" (+ icon, context: current project)
```

### SidebarViewModel

```swift
@Observable
final class SidebarViewModel {
    var projects: [ProjectWithWorkspaces] = []
    var activeWorkspaceId: String?

    private let db = DatabaseManager.shared
    private let sessionManager = PTYSessionManager.shared
    private var observation: AnyDatabaseCancellable?

    // Called by MainWindowController on init
    func startObserving()

    // User actions
    func addProject()          // Opens NSOpenPanel, inserts project + default workspace
    func createWorkspace(projectId: String)  // Inserts workspace, creates PTY
    func selectWorkspace(id: String)         // Sets active, notifies MainWindowController
    func deleteWorkspace(id: String)         // Removes from DB, destroys PTY
    func deleteProject(id: String)           // Removes project + all workspaces + PTYs
}
```

### ProjectWithWorkspaces

```swift
struct ProjectWithWorkspaces: Identifiable {
    let project: Project
    let workspaces: [Workspace]
    var id: String { project.id }
}
```

### WorkspaceRowView

Displays:
- Workspace name (bold if active)
- Type indicator icon (folder for branch, branch icon for worktree)
- Blue highlight background when active
- Swipe to delete (trailing swipe action)
- Click to select

### Add Project Flow

1. User clicks "+" button in sidebar footer
2. `NSOpenPanel` opens with directory selection (canChooseDirectories: true)
3. On selection: extract directory name as project name
4. Insert `Project` into SQLite with `mainRepoPath = selected path`
5. Auto-create one workspace (type: "branch", branch: "main", name: directory name)
6. Auto-create PTY session for the workspace
7. Switch to the new workspace

### Delete Workspace Flow

1. User swipes or right-clicks → delete on a workspace row
2. Confirmation if it's the last workspace in a project (deletes project too)
3. Destroy PTY session (SIGHUP child, clean up)
4. JS: `__superset.destroyTerminal(sessionId)` — removes div from DOM
5. Remove workspace from SQLite
6. If active workspace was deleted: switch to the nearest sibling or first workspace

## Multi-Terminal in WKWebView

### JS Changes

The current `terminal-bridge.ts` creates one terminal in `#terminal-container`. Phase 2a changes:

**Container structure:**
```html
<div id="terminal-container" style="position:relative; width:100%; height:100%;">
  <!-- Each terminal gets its own absolutely-positioned div -->
  <div id="term-{sessionId1}" style="position:absolute;inset:0;visibility:visible;"></div>
  <div id="term-{sessionId2}" style="position:absolute;inset:0;visibility:hidden;"></div>
  <div id="term-{sessionId3}" style="position:absolute;inset:0;visibility:hidden;"></div>
</div>
```

**New JS API (exposed on `window.__superset`):**

| Method | Purpose |
|--------|---------|
| `initTerminal(sessionId)` | Create div, init xterm, connect stream. Changed: no container param — creates its own div inside `#terminal-container` |
| `destroyTerminal(sessionId)` | Dispose xterm, remove div from DOM |
| `showTerminal(sessionId)` | Hide all divs, show target div, call fitAddon.fit(), requestResize |
| `getActiveSessionId()` | Returns currently visible session ID (or null) |

**`initTerminal` changes from Phase 1:**
- Creates a new `<div>` inside `#terminal-container` with `id="term-{sessionId}"` and `position:absolute;inset:0;visibility:hidden`
- Opens xterm.js Terminal in that div
- Does NOT auto-show — caller must follow up with `showTerminal`

**`showTerminal` implementation:**
```typescript
function showTerminal(sessionId: string): void {
  // Hide all terminal divs
  for (const [id, entry] of terminals) {
    entry.container.style.visibility = "hidden";
  }
  // Show target
  const entry = terminals.get(sessionId);
  if (entry) {
    entry.container.style.visibility = "visible";
    entry.fit.fit();
    bridge.requestResize(sessionId, entry.term.cols, entry.term.rows);
    entry.term.focus();
  }
}
```

### Why `visibility:hidden` not `display:none`

`display:none` removes the element from layout — xterm.js loses its dimensions and the canvas size becomes 0. `visibility:hidden` keeps the element in layout (takes space, maintains dimensions) but doesn't paint it. When we switch back and call `fitAddon.fit()`, it has correct container dimensions immediately.

## Swift Side Changes

### MainWindowController

Replaces the current single-WKWebView layout with NSSplitViewController:

```swift
final class MainWindowController: NSObject, NSSplitViewDelegate, WKNavigationDelegate {
    let window: NSWindow
    private var splitViewController: NSSplitViewController!
    private(set) var webView: WKWebView!
    private var sidebarViewModel: SidebarViewModel!

    // Terminal switching
    func switchTerminal(sessionId: String) {
        webView.evaluateJavaScript("__superset.showTerminal('\(sessionId.escaped)')")
    }

    // Called by SidebarViewModel
    func createAndShowTerminal(sessionId: String, cwd: String) {
        // 1. Create PTY (existing)
        // 2. evaluateJavaScript("__superset.initTerminal('id')")
        // 3. evaluateJavaScript("__superset.showTerminal('id')")
    }

    func destroyTerminal(sessionId: String) {
        sessionManager.destroySession(sessionId)
        webView.evaluateJavaScript("__superset.destroyTerminal('\(sessionId.escaped)')")
    }
}
```

### handleJSReady changes

On `ready` signal from JS, restore all workspaces from SQLite (not just active sessions from PTYSessionManager):

```
JS ready
  → Read all workspaces from SQLite
  → For each workspace: if PTY session exists, initTerminal + reconnect stream
  → For active workspace: showTerminal
```

This handles app restart: PTY sessions are gone, but workspace list persists. New PTY sessions are created for each workspace, and the active one is shown.

### NSSplitViewController Setup

```swift
let splitVC = NSSplitViewController()

// Sidebar (SwiftUI)
let sidebarItem = NSSplitViewItem(sidebarWithViewController:
    NSHostingController(rootView: SidebarView(viewModel: sidebarViewModel)))
sidebarItem.minimumThickness = 180
sidebarItem.maximumThickness = 350
sidebarItem.canCollapse = true

// Terminal (WKWebView)
let terminalVC = NSViewController()
terminalVC.view = webView
let terminalItem = NSSplitViewItem(contentListWithViewController: terminalVC)

splitVC.addSplitViewItem(sidebarItem)
splitVC.addSplitViewItem(terminalItem)

window.contentViewController = splitVC
```

### ControlMessageHandler changes

No changes needed — `createSession`, `resize`, `destroySession`, `ready` all still work. The `ready` handler in MainWindowController changes to restore from SQLite.

### SupersetSchemeHandler changes

No changes needed — it already supports multiple concurrent sessions (keyed by sessionId in `activeStreams`).

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Project path doesn't exist | Show alert, don't add project |
| PTY creation fails for workspace | Show error in sidebar (red icon), workspace exists but has no terminal |
| Delete last workspace in project | Confirmation dialog: "Delete project too?" |
| Delete active workspace | Switch to nearest sibling, or first workspace in any project |
| No workspaces at all | Show empty state in sidebar ("Add a project to get started") |
| SQLite migration fails | Log error, fall back to in-memory database |
| WebView crash | Existing recovery: reload, re-init all active terminals from PTYSessionManager |

## Constraints

- **macOS 15+** (same as Phase 1)
- **GRDB via SPM** — only external dependency
- **No git operations** — Phase 2b adds git status/branches
- **No sections/groups** — Phase 2b
- **No drag-and-drop** — Phase 2b
- **No keyboard shortcuts (⌘1-9)** — Phase 2b
- **No PR badges** — Phase 2b
- **Branch workspace only** — worktree creation is Phase 2b (table exists but unused)

## Build Integration

- Add GRDB dependency to Xcode project via SPM (or via `project.yml` for xcodegen)
- No changes to JS build pipeline (just code changes in existing files)

## Verification

### Happy Path

1. **Launch:** App opens with NSSplitView — sidebar left, terminal right
2. **Empty state:** Sidebar shows "Add a project to get started"
3. **Add project:** Click "+", select directory, project appears in sidebar with one workspace
4. **Terminal works:** New workspace has a working terminal in the selected directory
5. **Create workspace:** Click "+" on project, new workspace appears, terminal created
6. **Switch:** Click different workspace — terminal switches instantly, scrollback preserved
7. **Delete workspace:** Swipe delete — terminal destroyed, switches to another
8. **Persistence:** Quit and relaunch — projects/workspaces restored, terminals recreated

### Edge Cases

9. **Multiple projects:** Add 2+ projects, workspaces interleave correctly
10. **Sidebar resize:** Drag divider — terminal reflows via FitAddon
11. **Sidebar collapse:** Collapse sidebar — terminal fills window
12. **Delete active:** Delete the currently active workspace — switches to sibling
13. **Delete last in project:** Confirmation dialog, removes project from sidebar

## Reference Files

- `apps/desktop-swift/Sources/App/MainWindowController.swift` — current window setup to modify
- `apps/desktop-swift/Sources/App/SupersetApp.swift` — app delegate to modify
- `apps/desktop-swift/web-src/terminal-bridge.ts` — JS terminal management to extend
- `packages/local-db/src/schema/schema.ts` — reference SQLite schema
- `apps/desktop/src/renderer/screens/main/components/WorkspaceSidebar/` — Electron sidebar reference

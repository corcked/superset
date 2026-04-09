# Phase 2a: Multi-Terminal + SQLite + Native Sidebar — Design Spec

## Context

Phase 1 delivered a native macOS Swift app with a single terminal in a WKWebView. Phase 2a extends this with:

- Multiple concurrent terminal sessions, one visible at a time (CSS show/hide)
- SQLite database (GRDB) reading/writing the existing `packages/local-db` schema exactly
- Git worktree creation for isolated workspaces (`git worktree add`)
- Native SwiftUI sidebar via NSSplitView for project/workspace navigation
- Full lifecycle: add project, create/delete workspace, switch between terminals

This is Phase 2a of the roadmap. Phase 2b adds git status polling, PR badges, drag-and-drop, sections, and keyboard shortcuts.

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
├── NSSplitViewController
│   ├── SidebarSplitItem (NSHostingView wrapping SwiftUI)
│   │   └── SidebarView
│   │       ├── SidebarToolbar (+ project, + workspace buttons)
│   │       └── ProjectListView
│   │           └── ProjectRow (disclosure group)
│   │               └── WorkspaceRow (selectable, deletable)
│   └── TerminalSplitItem (WKWebView — unchanged from Phase 1)
├── PTYSessionManager (existing)
├── SupersetSchemeHandler (existing)
├── ControlMessageHandler (existing — ready handler changes)
└── DatabaseManager (new — GRDB, read/write only, no migrations)
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
  → GitWorktreeManager (git worktree add/remove)
  → PTYSessionManager (create/destroy PTY)
  → MainWindowController.switchTerminal(sessionId)
  → evaluateJavaScript("__superset.showTerminal(id)")
  → JS: CSS visibility toggle + FitAddon.fit()
```

## Database (GRDB + SQLite)

### Location

`~/.superset/local.db` — same file as `packages/local-db` uses. WAL mode for concurrent reads.

### Schema Compatibility

**Drizzle is the schema authority.** The Swift app does NOT run migrations. It reads/writes an already-migrated database created by the Electron app or host-service (which runs Drizzle migrations).

On open, the Swift app checks that the expected tables exist. If the database file is missing or the schema is too old, it shows a blocking alert: *"Database not found — please run Superset desktop at least once to initialize the database"* and exits gracefully. No in-memory fallback — silent data loss is not acceptable.

### Schema (exact match to packages/local-db)

All timestamps are `INTEGER` (Unix epoch milliseconds via `Date.now()`).

**projects**

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PK | UUID v4 |
| main_repo_path | TEXT NOT NULL | Absolute path to git repo |
| name | TEXT NOT NULL | Display name |
| color | TEXT NOT NULL | Sidebar accent color |
| tab_order | INTEGER | Sort position (nullable) |
| last_opened_at | INTEGER NOT NULL | Unix ms |
| created_at | INTEGER NOT NULL | Unix ms |
| default_branch | TEXT | |
| github_owner | TEXT | |
| (+ other columns) | | Mapped but unused in Phase 2a |

**worktrees**

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PK | UUID v4 |
| project_id | TEXT NOT NULL FK→projects | CASCADE delete |
| path | TEXT NOT NULL | Absolute worktree path |
| branch | TEXT NOT NULL | Branch checked out |
| base_branch | TEXT | Branch created from |
| created_at | INTEGER NOT NULL | Unix ms |
| created_by_superset | INTEGER NOT NULL DEFAULT 1 | Boolean |
| (git_status, github_status) | | JSON columns, mapped but unused in 2a |

**workspaces**

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PK | UUID v4 |
| project_id | TEXT NOT NULL FK→projects | CASCADE delete |
| worktree_id | TEXT FK→worktrees | CASCADE delete, NULL for branch type |
| type | TEXT NOT NULL | 'branch' or 'worktree' |
| branch | TEXT NOT NULL | Git branch name |
| name | TEXT NOT NULL | Display name |
| tab_order | INTEGER NOT NULL | Sort within project |
| created_at | INTEGER NOT NULL | Unix ms |
| updated_at | INTEGER NOT NULL | Unix ms |
| last_opened_at | INTEGER NOT NULL | Unix ms |
| is_unread | INTEGER DEFAULT 0 | Boolean |
| is_unnamed | INTEGER DEFAULT 0 | Boolean |
| deleting_at | INTEGER | Soft delete timestamp |
| port_base | INTEGER | |
| section_id | TEXT FK→workspace_sections | SET NULL |

**Constraint:** Partial unique index `workspaces_unique_branch_per_project` on `(project_id) WHERE type = 'branch'` — only one branch workspace per project.

**settings** (singleton, id=1)

| Column | Type | Notes |
|--------|------|-------|
| id | INTEGER PK DEFAULT 1 | |
| last_active_workspace_id | TEXT | **Source of truth for active workspace** |
| terminal_font_family | TEXT | |
| terminal_font_size | INTEGER | |
| (+ many other columns) | | Mapped as needed |

### Active Workspace

Active workspace is stored in `settings.last_active_workspace_id` — the same source of truth as the Electron app. The Swift app reads and writes this field. There is no `is_active` column on workspaces.

### GRDB Models

```swift
struct Project: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var name: String
    var mainRepoPath: String
    var color: String
    var tabOrder: Int?
    var lastOpenedAt: Int       // Unix ms
    var createdAt: Int          // Unix ms
    var defaultBranch: String?
    var githubOwner: String?
    // Other columns auto-ignored by GRDB if not mapped

    static let databaseTableName = "projects"
    static let workspaces = hasMany(Workspace.self)
}

struct Workspace: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var projectId: String
    var worktreeId: String?
    var type: String            // "branch" or "worktree"
    var branch: String
    var name: String
    var tabOrder: Int
    var createdAt: Int          // Unix ms
    var updatedAt: Int          // Unix ms
    var lastOpenedAt: Int       // Unix ms
    var isUnread: Bool?
    var isUnnamed: Bool?
    var deletingAt: Int?
    var sectionId: String?

    static let databaseTableName = "workspaces"
    static let project = belongsTo(Project.self)
}

struct Worktree: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var projectId: String
    var path: String
    var branch: String
    var baseBranch: String?
    var createdAt: Int          // Unix ms
    var createdBySuperset: Bool

    static let databaseTableName = "worktrees"
}

struct Settings: Codable, FetchableRecord, PersistableRecord {
    var id: Int
    var lastActiveWorkspaceId: String?
    var terminalFontFamily: String?
    var terminalFontSize: Int?

    static let databaseTableName = "settings"
}
```

### DatabaseManager

Singleton. Opens `~/.superset/local.db` in read/write mode, no migrations.

```swift
final class DatabaseManager {
    static let shared: DatabaseManager  // failable init — shows alert on failure

    // Read
    func allProjectsWithWorkspaces() -> [ProjectWithWorkspaces]
    func activeWorkspaceId() -> String?
    func workspace(id: String) -> Workspace?

    // Write
    func insertProject(_ project: Project)
    func insertWorktree(_ worktree: Worktree)
    func insertWorkspace(_ workspace: Workspace)
    func setActiveWorkspaceId(_ id: String)
    func updateWorkspaceLastOpened(id: String)
    func deleteWorkspace(id: String)
    func deleteWorktree(id: String)
    func deleteProject(id: String)  // CASCADE handles children

    // Reactive
    func observeProjectsWithWorkspaces() -> ValueObservation<[ProjectWithWorkspaces]>
    func observeActiveWorkspaceId() -> ValueObservation<String?>
}
```

## Git Worktree Management

Phase 2a creates real git worktrees for new workspaces. This is required because:
- The existing schema has a partial unique index allowing only one `type='branch'` workspace per project
- Multiple workspaces per project must be `type='worktree'` with actual worktree directories

### GitWorktreeManager

```swift
enum GitWorktreeManager {
    /// Creates a git worktree at the specified path and branch.
    /// Runs: git worktree add <path> -b <branch> [baseBranch]
    static func createWorktree(
        repoPath: String,
        worktreePath: String,
        branch: String,
        baseBranch: String?
    ) throws

    /// Removes a git worktree.
    /// Runs: git worktree remove <path> --force
    static func removeWorktree(repoPath: String, worktreePath: String) throws

    /// Lists existing worktrees for a repo.
    /// Runs: git worktree list --porcelain
    static func listWorktrees(repoPath: String) throws -> [WorktreeInfo]
}
```

Uses `Process` (Foundation) to run git commands. Worktree directory convention: `~/.superset/worktrees/<project-name>/<branch-name>/`.

### Create Workspace Flow (worktree type)

1. User clicks "+" on a project in sidebar
2. Prompt for branch name (text field)
3. `GitWorktreeManager.createWorktree(repoPath: project.mainRepoPath, worktreePath: computed, branch: name, baseBranch: project.defaultBranch)`
4. Insert `Worktree` row in SQLite
5. Insert `Workspace` row (type: "worktree", worktreeId: worktree.id)
6. Create PTY session with `cwd: worktree.path`
7. `initTerminal` + `showTerminal` in JS

### Delete Workspace Flow (worktree type)

1. Choose replacement active workspace (nearest sibling or first in any project)
2. Switch terminal in JS (`showTerminal` replacement)
3. Destroy PTY session
4. Destroy JS terminal (`destroyTerminal`)
5. Delete workspace row from SQLite
6. `GitWorktreeManager.removeWorktree`
7. Delete worktree row from SQLite

Branch-type workspaces cannot be deleted (they represent the main repo).

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
│                   └── WorkspaceRowView (name, type icon, active indicator)
├── Spacer
└── SidebarFooterView
    └── Button: "Add Project" (+ icon)
```

"New workspace" is per-project — a "+" button in the `ProjectHeaderView`.

### SidebarViewModel

```swift
@Observable
final class SidebarViewModel {
    var projects: [ProjectWithWorkspaces] = []
    var activeWorkspaceId: String?

    private let db = DatabaseManager.shared
    private let sessionManager = PTYSessionManager.shared
    weak var windowController: MainWindowController?

    func startObserving()          // Subscribe to ValueObservation

    // User actions
    func addProject()              // NSOpenPanel → insert project + branch workspace + PTY
    func createWorkspace(projectId: String, branchName: String)  // git worktree add → insert → PTY
    func selectWorkspace(id: String)  // Set active, lazy-create PTY if needed, switch terminal
    func deleteWorkspace(id: String)  // Ordered: switch → destroy PTY → destroy JS → delete DB → remove worktree
}
```

### WorkspaceRowView

Displays:
- Workspace name (bold if active)
- Type indicator: folder icon for branch, git-branch icon for worktree
- Blue highlight background when active
- Context menu: delete (worktree type only)
- Click to select

### Add Project Flow

1. User clicks "Add Project" in sidebar footer
2. `NSOpenPanel` opens (canChooseDirectories: true)
3. Validate: selected path contains `.git/` directory
4. Insert `Project` (name = directory name, mainRepoPath = selected path)
5. Insert default `Workspace` (type: "branch", branch: detected default branch or "main")
6. Create PTY session (cwd: project.mainRepoPath)
7. Set as active workspace
8. `initTerminal` + `showTerminal`

## Multi-Terminal in WKWebView

### JS Changes

**Container structure:**
```html
<div id="terminal-container" style="position:relative; width:100%; height:100%;">
  <div id="term-{id1}" style="position:absolute;inset:0;visibility:visible;"></div>
  <div id="term-{id2}" style="position:absolute;inset:0;visibility:hidden;"></div>
</div>
```

**Updated JS API (`window.__superset`):**

| Method | Purpose |
|--------|---------|
| `initTerminal(sessionId)` | Create div inside `#terminal-container`, init xterm, connect stream. Does NOT show. |
| `destroyTerminal(sessionId)` | Dispose xterm, remove div from DOM |
| `showTerminal(sessionId)` | Hide all divs, show target, fitAddon.fit(), requestResize, focus |
| `getActiveSessionId()` | Returns currently visible session ID or null |

**Why `visibility:hidden` not `display:none`:** `display:none` removes from layout — xterm.js canvas becomes 0×0. `visibility:hidden` keeps layout, so `fitAddon.fit()` works instantly on show.

**Scale target:** Up to 20 concurrent terminals in Phase 2a. ~40-60MB memory for 20 xterm instances — acceptable.

## Startup and Recovery

### App Launch (fresh start, no PTY sessions)

```
1. DatabaseManager opens ~/.superset/local.db (fail with alert if missing)
2. Read settings.last_active_workspace_id → activeWorkspaceId
3. Read all projects + workspaces
4. SidebarView renders from DB data
5. WebView loads → JS sends "ready"
6. handleJSReady:
   a. If activeWorkspaceId exists and workspace found:
      - Create PTY for active workspace only (lazy — others wait)
      - initTerminal(activeId) + showTerminal(activeId)
   b. If no active workspace: show empty state
```

**Lazy PTY creation:** Only the active workspace gets a PTY at launch. When the user clicks another workspace, `selectWorkspace` creates the PTY on demand. This avoids spawning N login shells at startup.

### Workspace Selection (lazy PTY)

```
selectWorkspace(id):
  1. Update settings.last_active_workspace_id in DB
  2. If PTYSessionManager has session for id:
     → evaluateJavaScript("__superset.showTerminal(id)")
  3. Else (first visit):
     → Create PTY session (cwd from workspace/worktree)
     → evaluateJavaScript("__superset.initTerminal(id)")
     → evaluateJavaScript("__superset.showTerminal(id)")
```

### WebView Crash Recovery (PTY sessions alive)

```
webViewWebContentProcessDidTerminate:
  1. invalidateAllStreams() (existing)
  2. webView.reload()

handleJSReady (after reload):
  1. For each session in PTYSessionManager.activeSessionIds():
     → initTerminal(sessionId)  // reconnects to existing PTY, replay buffer delivers history
  2. showTerminal(activeWorkspaceId)
```

This is distinct from app relaunch — PTY sessions survive WebView crash because they live in the Swift process.

## Deletion Ordering

Deleting a workspace follows a strict sequence to prevent state drift:

```
deleteWorkspace(id):
  1. Determine replacement: nearest sibling in same project, or first workspace in any project
  2. If id == activeWorkspaceId:
     a. selectWorkspace(replacementId)  // updates DB + switches terminal
  3. Destroy PTY: sessionManager.destroySession(id)
  4. Destroy JS terminal: evaluateJavaScript("__superset.destroyTerminal(id)")
  5. Delete workspace row from DB
  6. If type == "worktree":
     a. GitWorktreeManager.removeWorktree(...)
     b. Delete worktree row from DB
```

If step 3-6 fail after step 2, the user still sees a working terminal (the replacement). The stale DB row will be cleaned up on next delete attempt or can be ignored.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| DB file missing | Blocking alert, exit gracefully |
| DB schema too old | Blocking alert: "Please update Superset desktop" |
| Project path doesn't exist | Alert, don't add project |
| Project path not a git repo | Alert, don't add project |
| git worktree add fails | Alert with git error message, don't create workspace |
| PTY creation fails | Show error icon on workspace row, workspace exists but no terminal |
| Delete last workspace in project | Confirmation: "This will delete the project. Continue?" |
| Delete active workspace | Switch to replacement first (step 1-2 above) |
| No projects at all | Empty state: "Add a project to get started" |

## Constraints

- **macOS 15+** (same as Phase 1)
- **GRDB via SPM** — only new external dependency
- **Drizzle is schema authority** — Swift does not run migrations
- **Lazy PTY creation** — only active workspace gets PTY at launch
- **Up to 20 terminals** — beyond that, consider hibernation (Phase 2b+)
- **No sections/groups** — Phase 2b
- **No drag-and-drop** — Phase 2b
- **No keyboard shortcuts (⌘1-9)** — Phase 2b
- **No git status polling / PR badges** — Phase 2b

## Build Integration

- Add GRDB dependency to Xcode project via SPM (or `project.yml` for xcodegen)
- No changes to JS build pipeline (code changes only in existing `terminal-bridge.ts`)

## Verification

### Happy Path

1. **Launch:** App opens with NSSplitView — sidebar left, terminal right
2. **Empty state:** Sidebar shows "Add a project to get started" (if DB has no projects)
3. **Add project:** Click "+", select git repo directory, project appears with branch workspace
4. **Terminal works:** Active workspace terminal opens in the project directory
5. **Create workspace:** Click "+" on project header, enter branch name, worktree created, terminal opens
6. **Switch:** Click different workspace — terminal switches instantly, scrollback preserved
7. **Delete workspace:** Context menu delete on worktree workspace — terminal destroyed, worktree removed
8. **Persistence:** Quit and relaunch — projects/workspaces restored from DB, active terminal recreated

### Edge Cases

9. **Multiple projects:** Add 2+ projects, each with multiple workspaces
10. **Sidebar resize:** Drag divider — terminal reflows
11. **Sidebar collapse:** Collapse sidebar — terminal fills window
12. **Delete active:** Delete currently active workspace — switches to sibling
13. **Delete last worktree in project:** Only branch workspace remains
14. **Branch workspace undeletable:** No delete option in context menu for branch type
15. **Lazy PTY:** Switch to workspace that was never opened — PTY created on demand

### Compatibility

16. **Existing DB:** Launch with a real `~/.superset/local.db` from Electron — projects/workspaces appear correctly
17. **Active workspace shared:** Switch workspace in Swift, relaunch Electron — same workspace is active
18. **Worktree on disk:** Created worktrees exist at `~/.superset/worktrees/<project>/<branch>/`

### Recovery

19. **WebView crash:** Force-kill WebContent process — terminals reconnect with history
20. **App relaunch:** Quit and reopen — active workspace PTY recreated, others lazy

## Reference Files

- `apps/desktop-swift/Sources/App/MainWindowController.swift` — current window setup to modify
- `apps/desktop-swift/Sources/App/SupersetApp.swift` — app delegate to modify
- `apps/desktop-swift/web-src/terminal-bridge.ts` — JS terminal management to extend
- `packages/local-db/src/schema/schema.ts` — authoritative SQLite schema
- `apps/desktop/src/renderer/screens/main/components/WorkspaceSidebar/` — Electron sidebar reference

# Phase 2b-1: Git Status + Keyboard Shortcuts — Design Spec

## Context

Phase 2a delivered a native macOS Swift app with NSSplitView sidebar, multi-terminal, SQLite persistence, and git worktree creation. Phase 2b-1 adds:

- Git status display per workspace (branch, ahead/behind, changed files count)
- Hybrid polling: 30s for active workspace, cached values for others until activated
- Git status cached in `worktrees.git_status` JSON column for worktree workspaces; in-memory for branch workspaces
- Keyboard shortcuts: ⌘+1-9 (switch), ⌘+↑/↓ (prev/next), ⌘+Shift+W (delete workspace), ⌘+\ (toggle sidebar), ⌘+N (new workspace)

Phase 2b-2 (later) adds workspace sections, drag-and-drop, and PR badges.

## Git Status

### What's Displayed

Each workspace row in the sidebar shows (in addition to name and type icon):

- **Branch name** (already shown from Phase 2a)
- **Ahead/behind badges**: `↑N` (green) / `↓N` (orange) — commits ahead/behind the default branch on the remote
- **Changed files count**: `N files` badge (gray) — approximate count of locally modified/staged/untracked entries from `git status --porcelain` (counts entries, not unique files — acceptable approximation for a sidebar badge)
- All badges hidden until first status fetch completes (no flash of zeros)

### GitStatusInfo

```swift
struct GitStatusInfo: Codable {
    var branch: String
    var ahead: Int
    var behind: Int
    var changedFiles: Int      // approximate: entries from git status --porcelain
    var needsRebase: Bool
    var lastRefreshed: Int     // Unix ms
}
```

**Schema compatibility note:** The Electron app's `GitStatus` type defines `{ branch, needsRebase, ahead?, behind?, lastRefreshed }` without `changedFiles`. Swift adds `changedFiles` to its JSON payload. This is intentionally divergent — JSON parsing in both apps ignores unknown fields, so Electron safely reads Swift-written values (skipping `changedFiles`) and Swift safely reads Electron-written values (`changedFiles` decodes as 0 via default). The canonical typed contract is `GitStatusInfo` in Swift.

### Caching Strategy

**Worktree workspaces** (have `worktree_id`): cached in `worktrees.git_status` JSON column in SQLite. Survives app restart.

**Branch workspaces** (have `worktree_id = NULL`): cached in-memory in `GitStatusManager.branchStatusCache: [String: GitStatusInfo]` keyed by workspace ID. Does NOT persist to SQLite (no worktree row to write to). On app restart, branch workspace badges are empty until first refresh (~1-2s after activation).

### Polling Strategy

**Active workspace**: Immediate refresh on activation, then timer every 30 seconds.

**Other workspaces**: On sidebar startup, load cached `git_status` from DB for all worktrees (instant, zero git commands). No active git polling for non-active workspaces. Actual git refresh only happens when a workspace becomes active.

**At launch**: Only the active workspace triggers git commands. All others display cached DB values or empty badges.

### GitStatusManager

New singleton. Manages polling timer and executes git commands.

```swift
final class GitStatusManager {
    static let shared = GitStatusManager()

    private var activeWorkspaceId: String?
    private var activeProcess: Process?          // for cancellation
    private var timer: Timer?
    private let pollInterval: TimeInterval = 30.0
    private let fetchTimeout: TimeInterval = 10.0  // git fetch timeout
    private let lock = NSLock()                     // serialize git ops per workspace

    /// In-memory cache for branch workspace status (no worktree row in DB)
    var branchStatusCache: [String: GitStatusInfo] = [:]

    /// Start polling for a workspace. Cancels any in-flight git operation and stops previous timer.
    func startPolling(workspaceId: String, repoPath: String, worktreeId: String?)

    /// Stop polling and cancel in-flight operation.
    func stopPolling()

    /// Internal: run git commands, parse output, cache result.
    /// For worktree workspaces: writes to DB. For branch workspaces: writes to branchStatusCache.
    private func fetchAndCacheStatus(workspaceId: String, worktreeId: String?, repoPath: String)
}
```

### Git Commands Used

**Ahead/behind** (against remote default branch):
```bash
GIT_TERMINAL_PROMPT=0 git fetch origin <defaultBranch> --quiet
git rev-list --left-right --count origin/<defaultBranch>...HEAD
```
Returns: `<behind>\t<ahead>`

`GIT_TERMINAL_PROMPT=0` prevents interactive auth prompts from blocking the process. If `git fetch` fails (no network, auth required), skip ahead/behind — show only local status from previous cache or zeros.

**Fetch limits:**
- Timeout: 10 seconds (`Process.terminateAfter` or `DispatchWorkItem` cancel)
- Cancellation: when active workspace changes, `activeProcess?.terminate()` before starting new
- Serialization: `NSLock` ensures one git operation per workspace at a time
- No overlap: timer only fires if previous fetch completed

**Changed files count**:
```bash
git status --porcelain
```
Count non-empty lines. This is an approximate count — rename/copy entries may count differently than unique files. Acceptable for a sidebar badge.

**Current branch**:
```bash
git symbolic-ref --short HEAD
```

All commands run via `Process` in a background `DispatchQueue`, same pattern as `GitWorktreeManager`.

### Cache in SQLite

For worktree workspaces, `worktrees.git_status` stores JSON:
```json
{"branch":"feat/auth","ahead":2,"behind":0,"changedFiles":3,"needsRebase":false,"lastRefreshed":1712700000000}
```

`DatabaseManager` gets a new method:
```swift
func updateWorktreeGitStatus(worktreeId: String, statusJson: String) throws
```

Writes the raw JSON string to the `git_status` column. The existing `ValueObservation` picks up the change.

### Integration with SidebarViewModel

On workspace selection (`selectWorkspace`):
1. Determine `repoPath`: worktree → `worktree.path`, branch → `project.mainRepoPath`
2. Call `GitStatusManager.startPolling(workspaceId: id, repoPath: path, worktreeId: ws.worktreeId)`

On startup (`startObserving`):
1. Load cached `git_status` from DB for all worktrees (instant)
2. Start polling for the active workspace

### Data Model Updates

**Worktree** — add `gitStatus` field:
```swift
struct Worktree: ... {
    // existing fields...
    var gitStatus: String?  // raw JSON string from SQLite

    enum CodingKeys: String, CodingKey {
        // existing...
        case gitStatus = "git_status"
    }
}

extension Worktree {
    var parsedGitStatus: GitStatusInfo? {
        guard let json = gitStatus?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GitStatusInfo.self, from: json)
    }
}
```

**ProjectWithWorkspaces** — add worktrees for status lookup:
```swift
struct ProjectWithWorkspaces: Identifiable {
    let project: Project
    let workspaces: [Workspace]
    let worktrees: [Worktree]  // added for git status lookup
    var id: String { project.id }
}
```

### WorkspaceRowView Update

Show badges inline after workspace name:

```
[folder] feat/auth     ↑2 ↓0  3 files
```

- `↑N` in green when ahead > 0
- `↓N` in orange when behind > 0
- `N files` in gray when changedFiles > 0
- All hidden when no data yet or values are 0

Status is resolved by:
1. If workspace has `worktreeId` → find matching worktree → `parsedGitStatus`
2. If branch type → `GitStatusManager.branchStatusCache[workspaceId]`

## Keyboard Shortcuts

### Shortcut Map

| Shortcut | Action | Notes |
|----------|--------|-------|
| ⌘+1 through ⌘+9 | Switch to workspace N | Flat index across all projects, visual order |
| ⌘+↑ | Previous workspace | Wraps to last. Matches Electron behavior. |
| ⌘+↓ | Next workspace | Wraps to first. Matches Electron behavior. |
| ⌘+Shift+W | Delete active workspace | Only worktree type. ⌘+W is intentionally NOT intercepted — standard macOS "close window" behavior preserved. |
| ⌘+\ | Toggle sidebar | NSSplitViewItem.isCollapsed |
| ⌘+N | New workspace | Opens branch name sheet for active project |

**⌘+W note:** On macOS, ⌘+W is strongly associated with closing a tab/window. Mapping it to workspace deletion would violate user expectations. Instead, ⌘+Shift+W is used for the destructive "delete workspace" action, and ⌘+W retains its standard macOS behavior (close window).

### Implementation: KeyboardShortcutManager

Uses `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` to intercept key events.

```swift
final class KeyboardShortcutManager {
    private var monitor: Any?
    weak var sidebarViewModel: SidebarViewModel?
    weak var splitViewItem: NSSplitViewItem?

    func install()
    func uninstall()

    private func handleKeyDown(_ event: NSEvent) -> NSEvent?
}
```

### Scope Rules (when shortcuts are suppressed)

Shortcuts are **not consumed** (event passes through) when:
- First responder is an `NSTextField`, `NSSearchField`, or `NSTextView` (user is typing in a SwiftUI text input or sheet)
- A modal sheet is attached to the window (`window.attachedSheet != nil`)

Check: `NSApp.keyWindow?.firstResponder is NSTextInputClient` → skip shortcut handling, return event unchanged.

This prevents ⌘+N from triggering "new workspace" while typing a branch name in the sheet.

### Shortcut Logic

**⌘+1-9**: Build flat list via `projects.flatMap(\.workspaces)`. Index 0 = ⌘+1. Call `selectWorkspace(id:)`.

**⌘+↑/↓**: Find current active index in flat list, move ±1 with modulo wrapping.

**⌘+Shift+W**: Call `deleteWorkspace(id: activeWorkspaceId)`. SidebarViewModel guards against branch workspace deletion.

**⌘+\**: Toggle `splitViewItem.animator().isCollapsed`.

**⌘+N**: Set `sidebarViewModel.showNewWorkspaceSheet = true`. SwiftUI observes this and presents the sheet.

### Integration

`MainWindowController` creates `KeyboardShortcutManager`, wires it to `sidebarViewModel` and sidebar `NSSplitViewItem`. Calls `install()` after window setup.

Monitor returns `nil` for handled shortcuts (consumed), returns event unchanged for everything else (passes to terminal WebView).

## Error Handling

| Scenario | Behavior |
|----------|----------|
| `git fetch` fails (no network) | Skip ahead/behind update, keep cached values. Log warning. Local `git status` still works. |
| `git fetch` times out (>10s) | Terminate process. Skip ahead/behind. Log warning. |
| `git status` fails (not a repo) | Clear badges for that workspace. Log warning. |
| Worktree path doesn't exist on disk | Skip status fetch. Log warning. |
| `git_status` JSON decode fails | Return nil — badges hidden. No crash. |
| ⌘+Shift+W on branch workspace | No-op (guard in SidebarViewModel) |
| ⌘+N with no projects | No-op |
| ⌘+digit > workspace count | No-op |
| Shortcut while typing in text field | Event passes through (not consumed) |
| Shortcut while sheet is open | Event passes through (not consumed) |

## Constraints

- **macOS 15+**
- **No new dependencies** — git CLI via Process, NSEvent for shortcuts
- **Schema compatible** — `git_status` JSON superset of Electron's `GitStatus` type
- **30s poll interval** — configurable constant, not user-facing setting
- **10s git fetch timeout** — prevents hung processes
- **GIT_TERMINAL_PROMPT=0** — prevents interactive auth blocking

## Verification

### Git Status

1. **Active workspace shows status**: Select workspace → within 2s, badges appear
2. **Polling updates**: Make a commit in terminal → within 30s, changed files count updates
3. **Cached on startup**: Quit and relaunch → worktree workspaces show cached badges immediately
4. **Branch workspace**: Shows status from main repo path (in-memory, no DB cache)
5. **No network**: Disconnect wifi → ahead/behind show stale cached values, local changes still update
6. **Timeout**: Slow git server → fetch cancelled after 10s, local status still shows
7. **Workspace switch cancels**: Switch workspace mid-fetch → previous fetch terminated, new fetch starts

### Keyboard Shortcuts

8. **⌘+1-9**: Switch to Nth workspace in visual order
9. **⌘+↑/↓**: Navigate prev/next with wrap-around
10. **⌘+Shift+W**: Deletes active worktree workspace. No-op on branch workspace.
11. **⌘+\**: Sidebar collapses/expands, terminal fills/shrinks
12. **⌘+N**: Opens new workspace sheet for active project
13. **Terminal keys work**: All non-shortcut keys reach terminal
14. **Suppressed in text fields**: ⌘+N while typing branch name in sheet → no-op (text field gets event)
15. **⌘+W not intercepted**: ⌘+W closes window (standard macOS behavior)

### Compatibility

16. **Electron DB**: Launch with Electron-written `local.db` → cached git status loads correctly
17. **Swift-written status readable by Electron**: Switch workspace in Swift, relaunch Electron → status fields present (Electron ignores `changedFiles`)

## Reference Files

- `apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift` — add polling integration
- `apps/desktop-swift/Sources/Sidebar/WorkspaceRowView.swift` — add status badges
- `apps/desktop-swift/Sources/Database/Models.swift` — add gitStatus to Worktree
- `apps/desktop-swift/Sources/Database/DatabaseManager.swift` — add updateWorktreeGitStatus
- `apps/desktop-swift/Sources/Git/GitWorktreeManager.swift` — reference for Process pattern
- `apps/desktop-swift/Sources/App/MainWindowController.swift` — init keyboard manager
- `apps/desktop/src/renderer/screens/main/components/WorkspaceSidebar/WorkspaceListItem/` — Electron reference

# Phase 2b-1: Git Status + Keyboard Shortcuts — Design Spec

## Context

Phase 2a delivered a native macOS Swift app with NSSplitView sidebar, multi-terminal, SQLite persistence, and git worktree creation. Phase 2b-1 adds:

- Git status display per workspace (branch, ahead/behind, changed files count)
- Hybrid polling strategy: 30s for active workspace, lazy for others
- Git status cached in `worktrees.git_status` JSON column (compatible with Electron)
- Full keyboard shortcuts: ⌘+1-9 (workspace switching), ⌘+[/] (prev/next), ⌘+W (close), ⌘+\ (toggle sidebar), ⌘+N (new workspace)

Phase 2b-2 (later) adds workspace sections, drag-and-drop, and PR badges.

## Git Status

### What's Displayed

Each workspace row in the sidebar shows (in addition to name and type icon):

- **Branch name** (already shown from Phase 2a)
- **Ahead/behind badges**: `↑N` (green) / `↓N` (orange) — commits ahead/behind the default branch on the remote
- **Changed files count**: `M files` badge (gray) — number of locally modified/staged/untracked files
- All badges hidden until first status fetch completes (no flash of zeros)

### GitStatusInfo

```swift
struct GitStatusInfo: Codable {
    var branch: String
    var ahead: Int
    var behind: Int
    var changedFiles: Int      // staged + unstaged + untracked
    var needsRebase: Bool
    var lastRefreshed: Int     // Unix ms
}
```

Stored as JSON in `worktrees.git_status` column. This is the same column Electron uses — schema compatible.

### Polling Strategy

**Active workspace**: Timer fires every 30 seconds. Also refreshes on workspace activation (selection).

**Other workspaces**: Fetched once when first displayed (SidebarViewModel startup loads all worktrees that have cached `git_status` from DB). Refreshed on next activation.

**No FSEvents**: All status via `git` CLI commands (`git status --porcelain`, `git rev-list --left-right --count`). Simpler, proven approach.

### GitStatusManager

New singleton. Manages polling timer and executes git commands.

```swift
final class GitStatusManager {
    static let shared = GitStatusManager()

    private var activeWorkspaceId: String?
    private var timer: Timer?
    private let db = DatabaseManager.shared
    private let pollInterval: TimeInterval = 30.0

    /// Start polling for a workspace. Stops previous polling.
    func startPolling(workspaceId: String, repoPath: String)

    /// Stop polling.
    func stopPolling()

    /// Fetch git status once (used for lazy load on startup).
    func refreshStatus(worktreeId: String, repoPath: String) async

    /// Internal: run git commands, parse output, write to DB.
    private func fetchAndCacheStatus(worktreeId: String, repoPath: String)
}
```

### Git Commands Used

**Ahead/behind** (against remote default branch):
```bash
git rev-list --left-right --count origin/<defaultBranch>...HEAD
```
Returns: `<behind>\t<ahead>`

Requires `git fetch` first to update remote refs. Run `git fetch origin <defaultBranch> --quiet` before the rev-list.

**Changed files count**:
```bash
git status --porcelain
```
Count non-empty lines = changed files. Each line starts with status codes (M, A, D, ??, etc.).

**Current branch**:
```bash
git symbolic-ref --short HEAD
```

All commands run via `Process` in a background `DispatchQueue`, same pattern as `GitWorktreeManager`.

### Cache in SQLite

The `worktrees.git_status` column stores JSON:
```json
{"branch":"feat/auth","ahead":2,"behind":0,"changedFiles":3,"needsRebase":false,"lastRefreshed":1712700000000}
```

`DatabaseManager` gets a new method:
```swift
func updateWorktreeGitStatus(worktreeId: String, status: GitStatusInfo) throws
```

This writes the JSON string to the `git_status` column. The existing `ValueObservation` on worktrees picks up the change and updates the sidebar.

### Integration with SidebarViewModel

On workspace selection (`selectWorkspace`):
1. If the workspace is worktree type, start polling with `GitStatusManager.startPolling`
2. If branch type, start polling with the project's `mainRepoPath`

On startup (`startObserving`):
1. Load cached `git_status` from DB for all worktrees (instant, no git commands)
2. Start polling for the active workspace

### Worktree Model Update

Add `gitStatus` to the GRDB `Worktree` model:
```swift
struct Worktree: ... {
    // existing fields...
    var gitStatus: String?  // JSON string, decoded on read

    enum CodingKeys: String, CodingKey {
        // existing...
        case gitStatus = "git_status"
    }
}
```

Parse when needed:
```swift
extension Worktree {
    var parsedGitStatus: GitStatusInfo? {
        guard let json = gitStatus?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GitStatusInfo.self, from: json)
    }
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
- All hidden when no data (first load pending) or values are 0

## Keyboard Shortcuts

### Shortcut Map

| Shortcut | Action | Notes |
|----------|--------|-------|
| ⌘+1 through ⌘+9 | Switch to workspace N | Flat index across all projects, visual order |
| ⌘+[ | Previous workspace | Wraps to last |
| ⌘+] | Next workspace | Wraps to first |
| ⌘+W | Close/delete active workspace | Only worktree type, confirmation if needed |
| ⌘+\ | Toggle sidebar | NSSplitViewItem.isCollapsed |
| ⌘+N | New workspace | Opens branch name sheet for active project |

### Implementation: KeyboardShortcutManager

Uses `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` to intercept key events before they reach the WKWebView.

```swift
final class KeyboardShortcutManager {
    private var monitor: Any?
    weak var sidebarViewModel: SidebarViewModel?
    weak var splitViewItem: NSSplitViewItem?  // for sidebar toggle

    func install()    // addLocalMonitorForEvents
    func uninstall()  // removeMonitor

    private func handleKeyDown(_ event: NSEvent) -> NSEvent?
}
```

**⌘+1-9 logic**: Build a flat list of all workspaces in sidebar visual order (iterate `projects.flatMap(\.workspaces)`). Index 0 = ⌘+1, index 1 = ⌘+2, etc. Call `sidebarViewModel.selectWorkspace(id:)`.

**⌘+[/] logic**: Find current active workspace index in the flat list, move ±1 with wrapping.

**⌘+W logic**: Call `sidebarViewModel.deleteWorkspace(id: activeWorkspaceId)`. SidebarViewModel already handles the "can't delete branch workspace" guard.

**⌘+\ logic**: Toggle `splitViewItem.animator().isCollapsed`.

**⌘+N logic**: Need to expose "new workspace" action. SidebarViewModel gets a new method `showNewWorkspaceSheet()` that sets a published flag the SwiftUI view observes.

### Integration

`MainWindowController` creates `KeyboardShortcutManager` in init, wires it to `sidebarViewModel` and the sidebar `NSSplitViewItem`. Calls `install()` after window is ready.

The monitor returns `nil` (consuming the event) for handled shortcuts, or returns the event unchanged for unhandled keys (so they reach the terminal WebView).

**Important**: ⌘+1-9 conflicts with terminal apps that use these shortcuts. Since we're replacing Electron which had the same behavior, this is acceptable. The terminal gets all other key events.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| `git fetch` fails (no network) | Skip ahead/behind, show only local status. Log warning. |
| `git status` fails (not a repo) | Clear badges for that workspace. Log warning. |
| Worktree path doesn't exist | Skip status fetch for that workspace. |
| ⌘+W on branch workspace | No-op (SidebarViewModel guards this) |
| ⌘+N with no projects | No-op |
| ⌘+digit > workspace count | No-op |

## Constraints

- **macOS 15+**
- **No new dependencies** — git CLI via Process, NSEvent for shortcuts
- **Compatible with Electron** — same `git_status` JSON format in SQLite
- **30s poll interval** — configurable constant, not user-facing setting

## Verification

### Git Status

1. **Active workspace shows status**: Select workspace → within 1s, branch/ahead/behind/changed badges appear
2. **Polling updates**: Make a commit in the terminal → within 30s, changed files count updates
3. **Lazy load**: Other workspaces show cached status from DB on sidebar render
4. **No network**: Disconnect wifi → ahead/behind show stale cached values, local changes still update
5. **Branch workspace**: Shows status from main repo path

### Keyboard Shortcuts

6. **⌘+1-9**: Press ⌘+1 → switches to first workspace. ⌘+2 → second. Beyond count → no-op
7. **⌘+[/]**: Navigate prev/next with wrap-around
8. **⌘+W**: Closes active worktree workspace, switches to next. No-op on branch workspace
9. **⌘+\**: Sidebar collapses/expands, terminal fills/shrinks
10. **⌘+N**: Opens new workspace sheet for active project
11. **Terminal still gets keys**: Type in terminal, all non-shortcut keys work normally

## Reference Files

- `apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift` — add polling integration
- `apps/desktop-swift/Sources/Sidebar/WorkspaceRowView.swift` — add status badges
- `apps/desktop-swift/Sources/Database/Models.swift` — add gitStatus to Worktree
- `apps/desktop-swift/Sources/Database/DatabaseManager.swift` — add updateWorktreeGitStatus
- `apps/desktop-swift/Sources/Git/GitWorktreeManager.swift` — reference for Process pattern
- `apps/desktop-swift/Sources/App/MainWindowController.swift` — init keyboard manager
- `apps/desktop/src/renderer/screens/main/components/WorkspaceSidebar/WorkspaceListItem/` — Electron reference

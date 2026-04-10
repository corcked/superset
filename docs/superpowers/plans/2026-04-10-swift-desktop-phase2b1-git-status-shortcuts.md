# Phase 2b-1: Git Status + Keyboard Shortcuts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add git status badges (branch, ahead/behind, changed files) and keyboard shortcuts (⌘+1-9, ⌘+↑/↓, ⌘+Shift+W, ⌘+\, ⌘+N) to the native Swift desktop sidebar.

**Architecture:** `GitStatusManager` polls git CLI every 30s for the active workspace, caches results in SQLite (`worktrees.git_status` JSON) or in-memory (branch workspaces). `KeyboardShortcutManager` uses `NSEvent.addLocalMonitorForEvents` to intercept shortcuts before they reach the WKWebView, delegating actions to `SidebarViewModel`. WorkspaceRowView displays status badges.

**Tech Stack:** Swift 6, AppKit (NSEvent), SwiftUI, GRDB, git CLI via Process

**Spec:** `docs/superpowers/specs/2026-04-10-swift-desktop-phase2b1-git-status-shortcuts-design.md`

---

## File Map

```
apps/desktop-swift/Sources/
├── Database/
│   ├── Models.swift               # Task 0: add gitStatus to Worktree, worktrees to ProjectWithWorkspaces, GitStatusInfo struct
│   └── DatabaseManager.swift      # Task 0: add updateWorktreeGitStatus + fetch worktrees in observation
├── Git/
│   ├── GitWorktreeManager.swift   # (existing, no changes)
│   └── GitStatusManager.swift     # Task 1: new — polling, git CLI, caching
├── Sidebar/
│   ├── SidebarViewModel.swift     # Task 2: wire GitStatusManager on workspace switch
│   ├── WorkspaceRowView.swift     # Task 3: add ahead/behind + changed files badges
│   └── SidebarView.swift          # (no changes)
│   └── ProjectRowView.swift       # (no changes)
├── App/
│   ├── KeyboardShortcutManager.swift  # Task 4: new — NSEvent monitor, shortcut dispatch
│   └── MainWindowController.swift     # Task 5: init KeyboardShortcutManager, store sidebarItem ref
```

---

## Task 0: Update Data Models + DatabaseManager

**Purpose:** Add `gitStatus` field to Worktree, `GitStatusInfo` struct, worktrees to `ProjectWithWorkspaces`, and `updateWorktreeGitStatus` method.

**Files:**
- Modify: `apps/desktop-swift/Sources/Database/Models.swift`
- Modify: `apps/desktop-swift/Sources/Database/DatabaseManager.swift`

- [ ] **Step 1: Add GitStatusInfo and update Worktree model**

In `apps/desktop-swift/Sources/Database/Models.swift`, add `GitStatusInfo` struct before Worktree, add `gitStatus` field + computed property to Worktree, and add `worktrees` to `ProjectWithWorkspaces`:

```swift
// Add before Worktree struct:
struct GitStatusInfo: Codable {
    var branch: String = ""
    var ahead: Int = 0
    var behind: Int = 0
    var changedFiles: Int = 0
    var needsRebase: Bool = false
    var lastRefreshed: Int = 0
}

// In Worktree struct, add after createdBySuperset:
    var gitStatus: String?   // JSON string from SQLite

// In Worktree CodingKeys, add:
    case gitStatus = "git_status"

// Add extension after Worktree struct:
extension Worktree {
    var parsedGitStatus: GitStatusInfo? {
        guard let json = gitStatus?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GitStatusInfo.self, from: json)
    }
}

// Update ProjectWithWorkspaces:
struct ProjectWithWorkspaces: Identifiable {
    let project: Project
    let workspaces: [Workspace]
    let worktrees: [Worktree]
    var id: String { project.id }
}
```

- [ ] **Step 2: Update DatabaseManager**

In `apps/desktop-swift/Sources/Database/DatabaseManager.swift`:

Add a new write method:
```swift
func updateWorktreeGitStatus(worktreeId: String, statusJson: String) throws {
    try dbQueue.write { db in
        try db.execute(
            sql: "UPDATE worktrees SET git_status = ? WHERE id = ?",
            arguments: [statusJson, worktreeId]
        )
    }
}
```

Update `allProjectsWithWorkspaces()` and the `observeProjectsWithWorkspaces` observation to also fetch worktrees per project. In both places, change:
```swift
// Old:
return ProjectWithWorkspaces(project: project, workspaces: workspaces)

// New:
let worktrees = try Worktree
    .filter(Column("project_id") == project.id)
    .fetchAll(db)
return ProjectWithWorkspaces(project: project, workspaces: workspaces, worktrees: worktrees)
```

- [ ] **Step 3: Build and test**

```bash
cd apps/desktop-swift
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -3
xcodebuild test -project SupersetShell.xcodeproj -scheme SupersetShell 2>&1 | grep -E "(passed|failed)" | tail -5
```

Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add apps/desktop-swift/Sources/Database/
git commit -m "feat(desktop-swift): add GitStatusInfo model and worktree git_status support"
```

---

## Task 1: Implement GitStatusManager

**Purpose:** Singleton that polls git CLI for status, caches results in DB (worktree workspaces) or in-memory (branch workspaces).

**Files:**
- Create: `apps/desktop-swift/Sources/Git/GitStatusManager.swift`

- [ ] **Step 1: Write GitStatusManager**

Write `apps/desktop-swift/Sources/Git/GitStatusManager.swift`:

```swift
import Foundation
import os

final class GitStatusManager: @unchecked Sendable {
    static let shared = GitStatusManager()

    private var activeWorkspaceId: String?
    private var activeWorktreeId: String?
    private var activeRepoPath: String?
    private var activeDefaultBranch: String?
    private var activeProcess: Process?
    private var timer: Timer?
    private let pollInterval: TimeInterval = 30.0
    private let fetchTimeout: TimeInterval = 10.0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "sh.superset.gitstatus", qos: .utility)
    private let logger = Logger(subsystem: "sh.superset.shell", category: "GitStatus")

    /// In-memory cache for branch workspace status (no worktree row in DB)
    var branchStatusCache: [String: GitStatusInfo] = [:]

    /// Callback when status is updated (for triggering UI refresh of branch workspaces)
    var onBranchStatusUpdated: (() -> Void)?

    private init() {}

    /// Start polling for a workspace. Cancels previous polling.
    func startPolling(workspaceId: String, repoPath: String, worktreeId: String?, defaultBranch: String?) {
        lock.lock()
        // Cancel previous
        activeProcess?.terminate()
        timer?.invalidate()

        activeWorkspaceId = workspaceId
        activeWorktreeId = worktreeId
        activeRepoPath = repoPath
        activeDefaultBranch = defaultBranch
        lock.unlock()

        // Immediate refresh
        queue.async { [weak self] in
            self?.fetchAndCache()
        }

        // Schedule timer on main run loop
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: true) { [weak self] _ in
                self?.queue.async { self?.fetchAndCache() }
            }
        }
    }

    func stopPolling() {
        lock.lock()
        activeProcess?.terminate()
        timer?.invalidate()
        timer = nil
        activeWorkspaceId = nil
        lock.unlock()
    }

    // MARK: - Internal

    private func fetchAndCache() {
        lock.lock()
        guard let workspaceId = activeWorkspaceId,
              let repoPath = activeRepoPath else {
            lock.unlock()
            return
        }
        let worktreeId = activeWorktreeId
        let defaultBranch = activeDefaultBranch ?? "main"
        lock.unlock()

        let branch = (try? runGit(["symbolic-ref", "--short", "HEAD"], cwd: repoPath))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // git fetch (best effort, timeout 10s)
        let _ = try? runGitWithTimeout(["fetch", "origin", defaultBranch, "--quiet"], cwd: repoPath, timeout: fetchTimeout)

        // Ahead/behind
        var ahead = 0
        var behind = 0
        if let revList = try? runGit(["rev-list", "--left-right", "--count", "origin/\(defaultBranch)...HEAD"], cwd: repoPath) {
            let parts = revList.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            if parts.count == 2 {
                behind = Int(parts[0]) ?? 0
                ahead = Int(parts[1]) ?? 0
            }
        }

        // Changed files
        var changedFiles = 0
        if let status = try? runGit(["status", "--porcelain"], cwd: repoPath) {
            changedFiles = status.split(separator: "\n").count
        }

        let needsRebase = behind > 0

        let info = GitStatusInfo(
            branch: branch,
            ahead: ahead,
            behind: behind,
            changedFiles: changedFiles,
            needsRebase: needsRebase,
            lastRefreshed: Int(Date().timeIntervalSince1970 * 1000)
        )

        // Cache
        if let wtId = worktreeId {
            // Worktree workspace — write to DB
            if let json = try? JSONEncoder().encode(info),
               let jsonStr = String(data: json, encoding: .utf8) {
                try? DatabaseManager.shared.updateWorktreeGitStatus(worktreeId: wtId, statusJson: jsonStr)
            }
        } else {
            // Branch workspace — in-memory
            lock.lock()
            branchStatusCache[workspaceId] = info
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onBranchStatusUpdated?()
            }
        }

        logger.info("Git status for \(workspaceId): branch=\(branch) ahead=\(ahead) behind=\(behind) changed=\(changedFiles)")
    }

    // MARK: - Git execution

    private func runGit(_ args: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ["GIT_TERMINAL_PROMPT": "0"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        lock.lock()
        activeProcess = process
        lock.unlock()

        try process.run()
        process.waitUntilExit()

        lock.lock()
        if activeProcess === process { activeProcess = nil }
        lock.unlock()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GitWorktreeError.commandFailed(err)
        }

        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func runGitWithTimeout(_ args: [String], cwd: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ["GIT_TERMINAL_PROMPT": "0"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        lock.lock()
        activeProcess = process
        lock.unlock()

        try process.run()

        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            lock.lock()
            if activeProcess === process { activeProcess = nil }
            lock.unlock()
            throw GitWorktreeError.commandFailed("git fetch timed out after \(timeout)s")
        }

        lock.lock()
        if activeProcess === process { activeProcess = nil }
        lock.unlock()

        guard process.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GitWorktreeError.commandFailed(err)
        }

        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add apps/desktop-swift/Sources/Git/GitStatusManager.swift
git commit -m "feat(desktop-swift): implement GitStatusManager with polling and git CLI"
```

---

## Task 2: Wire GitStatusManager into SidebarViewModel

**Purpose:** Start/stop polling on workspace selection, expose branch status cache for UI.

**Files:**
- Modify: `apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift`

- [ ] **Step 1: Update SidebarViewModel**

Add to the class:

```swift
// New property
private let gitStatusManager = GitStatusManager.shared

// New published state for branch workspace status (triggers UI refresh)
var branchStatusGeneration: Int = 0
```

In `startObserving()`, after initial load, add:

```swift
// Wire branch status refresh
gitStatusManager.onBranchStatusUpdated = { [weak self] in
    self?.branchStatusGeneration += 1
}

// Start polling for active workspace
if let activeId = activeWorkspaceId {
    startGitPollingForWorkspace(id: activeId)
}
```

Add new method:

```swift
func startGitPollingForWorkspace(id: String) {
    guard let ws = try? db.workspace(id: id) else { return }
    let project = projects.first(where: { $0.project.id == ws.projectId })?.project
    guard let project else { return }

    let repoPath: String
    if ws.isWorktreeType, let wtId = ws.worktreeId, let wt = try? db.worktree(id: wtId) {
        repoPath = wt.path
    } else {
        repoPath = project.mainRepoPath
    }

    gitStatusManager.startPolling(
        workspaceId: id,
        repoPath: repoPath,
        worktreeId: ws.worktreeId,
        defaultBranch: project.defaultBranch
    )
}

/// Resolve git status for a workspace (from DB or in-memory cache)
func gitStatus(for workspace: Workspace) -> GitStatusInfo? {
    if workspace.isWorktreeType, let wtId = workspace.worktreeId {
        let wt = projects.flatMap(\.worktrees).first(where: { $0.id == wtId })
        return wt?.parsedGitStatus
    } else {
        // Branch workspace — in-memory cache
        _ = branchStatusGeneration // access to trigger SwiftUI refresh
        return gitStatusManager.branchStatusCache[workspace.id]
    }
}
```

In `selectWorkspace(id:)`, after setting `activeWorkspaceId`, add:

```swift
startGitPollingForWorkspace(id: id)
```

- [ ] **Step 2: Build and test**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift
git commit -m "feat(desktop-swift): wire GitStatusManager into SidebarViewModel for polling"
```

---

## Task 3: Add Git Status Badges to WorkspaceRowView

**Purpose:** Show ahead/behind and changed files count inline in workspace rows.

**Files:**
- Modify: `apps/desktop-swift/Sources/Sidebar/WorkspaceRowView.swift`
- Modify: `apps/desktop-swift/Sources/Sidebar/ProjectRowView.swift` (pass status through)
- Modify: `apps/desktop-swift/Sources/Sidebar/SidebarView.swift` (pass viewModel to rows)

- [ ] **Step 1: Update WorkspaceRowView to accept and display status**

Replace `apps/desktop-swift/Sources/Sidebar/WorkspaceRowView.swift`:

```swift
import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let isActive: Bool
    let gitStatus: GitStatusInfo?
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: workspace.isBranchType ? "folder.fill" : "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isActive ? .white : .secondary)
                    .frame(width: 16)
                Text(workspace.name)
                    .font(.callout)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? .white : .primary)
                    .lineLimit(1)
                Spacer()
                statusBadges
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Workspace", systemImage: "trash")
                }
            }
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private var statusBadges: some View {
        if let status = gitStatus {
            HStack(spacing: 4) {
                if status.ahead > 0 {
                    Text("↑\(status.ahead)")
                        .font(.caption2)
                        .foregroundStyle(isActive ? .white.opacity(0.8) : .green)
                }
                if status.behind > 0 {
                    Text("↓\(status.behind)")
                        .font(.caption2)
                        .foregroundStyle(isActive ? .white.opacity(0.8) : .orange)
                }
                if status.changedFiles > 0 {
                    Text("\(status.changedFiles)")
                        .font(.caption2)
                        .foregroundStyle(isActive ? .white.opacity(0.7) : .secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Update ProjectRowView to pass git status**

In `apps/desktop-swift/Sources/Sidebar/ProjectRowView.swift`, add a new parameter and pass it through:

Add to struct properties:
```swift
let gitStatusForWorkspace: (Workspace) -> GitStatusInfo?
```

In the `ForEach(workspaces)` body, change `WorkspaceRowView` call:
```swift
WorkspaceRowView(
    workspace: workspace,
    isActive: workspace.id == activeWorkspaceId,
    gitStatus: gitStatusForWorkspace(workspace),
    onSelect: { onSelectWorkspace(workspace.id) },
    onDelete: workspace.isWorktreeType
        ? { onDeleteWorkspace(workspace.id) }
        : nil
)
```

- [ ] **Step 3: Update SidebarView to pass gitStatus resolver**

In `apps/desktop-swift/Sources/Sidebar/SidebarView.swift`, in the `ProjectRowView` creation, add:

```swift
gitStatusForWorkspace: { workspace in
    viewModel.gitStatus(for: workspace)
},
```

- [ ] **Step 4: Build and test**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add apps/desktop-swift/Sources/Sidebar/
git commit -m "feat(desktop-swift): add git status badges to workspace rows in sidebar"
```

---

## Task 4: Implement KeyboardShortcutManager

**Purpose:** NSEvent local monitor for ⌘+1-9, ⌘+↑/↓, ⌘+Shift+W, ⌘+\, ⌘+N. Suppressed during text input and sheets.

**Files:**
- Create: `apps/desktop-swift/Sources/App/KeyboardShortcutManager.swift`

- [ ] **Step 1: Write KeyboardShortcutManager**

Write `apps/desktop-swift/Sources/App/KeyboardShortcutManager.swift`:

```swift
import AppKit
import os

final class KeyboardShortcutManager {
    private var monitor: Any?
    weak var sidebarViewModel: SidebarViewModel?
    weak var sidebarSplitItem: NSSplitViewItem?
    private let logger = Logger(subsystem: "sh.superset.shell", category: "Shortcuts")

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Suppress during text input or modal sheets
        if isTextFieldFocused() || isSheetPresented() {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmd = flags == .command
        let isCmdShift = flags == [.command, .shift]

        guard isCmd || isCmdShift else { return event }

        // ⌘+1 through ⌘+9
        if isCmd, let digit = digitFromKeyCode(event.keyCode), digit >= 1, digit <= 9 {
            let index = digit - 1
            switchToWorkspaceAtIndex(index)
            return nil // consumed
        }

        switch event.keyCode {
        case 126 where isCmd:  // ⌘+↑ (up arrow)
            navigatePrevWorkspace()
            return nil
        case 125 where isCmd:  // ⌘+↓ (down arrow)
            navigateNextWorkspace()
            return nil
        case 13 where isCmdShift:  // ⌘+Shift+W
            deleteActiveWorkspace()
            return nil
        case 42 where isCmd:  // ⌘+\ (backslash)
            toggleSidebar()
            return nil
        case 45 where isCmd:  // ⌘+N
            newWorkspace()
            return nil
        default:
            return event
        }
    }

    // MARK: - Actions

    private func switchToWorkspaceAtIndex(_ index: Int) {
        guard let vm = sidebarViewModel else { return }
        let allWorkspaces = vm.projects.flatMap(\.workspaces)
        guard index < allWorkspaces.count else { return }
        vm.selectWorkspace(id: allWorkspaces[index].id)
    }

    private func navigatePrevWorkspace() {
        guard let vm = sidebarViewModel, let activeId = vm.activeWorkspaceId else { return }
        let allWorkspaces = vm.projects.flatMap(\.workspaces)
        guard !allWorkspaces.isEmpty else { return }
        let currentIndex = allWorkspaces.firstIndex(where: { $0.id == activeId }) ?? 0
        let prevIndex = (currentIndex - 1 + allWorkspaces.count) % allWorkspaces.count
        vm.selectWorkspace(id: allWorkspaces[prevIndex].id)
    }

    private func navigateNextWorkspace() {
        guard let vm = sidebarViewModel, let activeId = vm.activeWorkspaceId else { return }
        let allWorkspaces = vm.projects.flatMap(\.workspaces)
        guard !allWorkspaces.isEmpty else { return }
        let currentIndex = allWorkspaces.firstIndex(where: { $0.id == activeId }) ?? 0
        let nextIndex = (currentIndex + 1) % allWorkspaces.count
        vm.selectWorkspace(id: allWorkspaces[nextIndex].id)
    }

    private func deleteActiveWorkspace() {
        guard let vm = sidebarViewModel, let activeId = vm.activeWorkspaceId else { return }
        vm.deleteWorkspace(id: activeId)
    }

    private func toggleSidebar() {
        guard let item = sidebarSplitItem else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            item.animator().isCollapsed = !item.isCollapsed
        }
    }

    private func newWorkspace() {
        guard let vm = sidebarViewModel else { return }
        vm.showNewWorkspaceSheet = true
    }

    // MARK: - Helpers

    private func isTextFieldFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func isSheetPresented() -> Bool {
        NSApp.keyWindow?.attachedSheet != nil
    }

    /// Map key codes to digits 1-9 (top row number keys)
    private func digitFromKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1   // 1
        case 19: return 2   // 2
        case 20: return 3   // 3
        case 21: return 4   // 4
        case 23: return 5   // 5
        case 22: return 6   // 6
        case 26: return 7   // 7
        case 28: return 8   // 8
        case 25: return 9   // 9
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Add showNewWorkspaceSheet to SidebarViewModel**

In `apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift`, add property:

```swift
var showNewWorkspaceSheet = false
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add apps/desktop-swift/Sources/App/KeyboardShortcutManager.swift apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift
git commit -m "feat(desktop-swift): implement KeyboardShortcutManager with workspace shortcuts"
```

---

## Task 5: Wire KeyboardShortcutManager into MainWindowController

**Purpose:** Create and install the keyboard manager, passing it references to SidebarViewModel and the sidebar NSSplitViewItem.

**Files:**
- Modify: `apps/desktop-swift/Sources/App/MainWindowController.swift`

- [ ] **Step 1: Add KeyboardShortcutManager to MainWindowController**

In `apps/desktop-swift/Sources/App/MainWindowController.swift`:

Add property:
```swift
private let keyboardManager = KeyboardShortcutManager()
private var sidebarSplitItem: NSSplitViewItem?
```

In `setupSplitView()`, after creating `sidebarItem`, store a reference:
```swift
self.sidebarSplitItem = sidebarItem
```

At the end of `init(db:)`, after `sidebarViewModel.startObserving()`, add:
```swift
keyboardManager.sidebarViewModel = sidebarViewModel
keyboardManager.sidebarSplitItem = sidebarSplitItem
keyboardManager.install()
```

- [ ] **Step 2: Build and test**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -3
xcodebuild test -project SupersetShell.xcodeproj -scheme SupersetShell 2>&1 | grep -E "(passed|failed)" | tail -5
```

Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add apps/desktop-swift/Sources/App/MainWindowController.swift
git commit -m "feat(desktop-swift): wire KeyboardShortcutManager into MainWindowController"
```

---

## Task 6: E2E Verification

**Purpose:** Full build, launch, verify git status and shortcuts.

- [ ] **Step 1: Full build**

```bash
cd apps/desktop-swift
bun run build:web
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -3
xcodebuild test -project SupersetShell.xcodeproj -scheme SupersetShell 2>&1 | grep -E "(passed|failed)" | tail -5
```

- [ ] **Step 2: Launch and verify manually**

Open the built app. Verify:

**Git Status:**
- Active workspace shows ahead/behind and changed files badges within ~2s
- Make a change in the terminal (`touch testfile`) → within 30s, changed files count increases
- Switch to another workspace → status refreshes for new active workspace

**Keyboard Shortcuts:**
- ⌘+1 switches to first workspace
- ⌘+↑/↓ navigates between workspaces
- ⌘+\ toggles sidebar
- ⌘+N opens new workspace sheet
- ⌘+Shift+W deletes worktree workspace (no-op on branch)
- Type in terminal — all regular keys still work

- [ ] **Step 3: Commit**

```bash
git add -A apps/desktop-swift/
git commit -m "feat(desktop-swift): Phase 2b-1 complete — git status badges + keyboard shortcuts"
```

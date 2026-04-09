# Phase 2a: Multi-Terminal + SQLite + Native Sidebar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Phase 1 single-terminal Swift app with multiple terminals, SQLite persistence (GRDB), git worktree creation, and a native SwiftUI sidebar — enabling full project/workspace lifecycle.

**Architecture:** NSSplitViewController splits the window: SwiftUI sidebar (left) reads projects/workspaces from SQLite via GRDB ValueObservation; WKWebView (right) hosts multiple xterm.js instances with CSS visibility switching. PTY sessions are created lazily on workspace selection. Git worktrees provide isolation for additional workspaces.

**Tech Stack:** Swift 6, AppKit (NSSplitViewController), SwiftUI, GRDB (SQLite), WebKit (WKWebView), xterm.js

**Spec:** `docs/superpowers/specs/2026-04-09-swift-desktop-phase2a-multi-terminal-design.md`

---

## File Map

```
apps/desktop-swift/
├── Sources/
│   ├── App/
│   │   ├── SupersetApp.swift              # Task 5: update to use DatabaseManager + sidebar
│   │   └── MainWindowController.swift     # Task 5: NSSplitViewController, terminal switching
│   ├── Database/
│   │   ├── Models.swift                   # Task 1: GRDB record types (Project, Workspace, etc.)
│   │   └── DatabaseManager.swift          # Task 2: singleton, open DB, CRUD, ValueObservation
│   ├── Git/
│   │   └── GitWorktreeManager.swift       # Task 3: git worktree add/remove via Process
│   ├── Sidebar/
│   │   ├── SidebarViewModel.swift         # Task 4: @Observable, orchestrates DB + PTY + JS
│   │   ├── SidebarView.swift              # Task 6: main sidebar SwiftUI view
│   │   ├── ProjectRowView.swift           # Task 6: project disclosure group
│   │   └── WorkspaceRowView.swift         # Task 6: workspace list item
│   ├── PTY/ (existing, no changes)
│   └── Bridge/ (existing, no changes)
├── web-src/
│   └── terminal-bridge.ts                 # Task 7: multi-terminal show/hide
└── project.yml                            # Task 0: add GRDB dependency
```

---

## Task 0: Add GRDB Dependency

**Purpose:** Add GRDB to the Xcode project via xcodegen so all subsequent tasks can import it.

**Files:**
- Modify: `apps/desktop-swift/project.yml`

- [ ] **Step 1: Update project.yml to add GRDB SPM package**

Edit `apps/desktop-swift/project.yml` — add `packages` at the top level and a dependency on the target:

```yaml
name: SupersetShell
options:
  bundleIdPrefix: sh.superset
  deploymentTarget:
    macOS: "15.0"
  xcodeVersion: "16.0"
packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift
    from: "7.4.1"
settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "15.0"
    PRODUCT_BUNDLE_IDENTIFIER: sh.superset.shell
    PRODUCT_NAME: SupersetShell
    INFOPLIST_KEY_CFBundleDisplayName: Superset
    INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.developer-tools
targets:
  SupersetShell:
    type: application
    platform: macOS
    sources:
      - Sources
      - path: Resources/WebContent
        type: folder
        buildPhase: resources
    dependencies:
      - package: GRDB
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: ""
        ENABLE_APP_SANDBOX: false
        GENERATE_INFOPLIST_FILE: true
    preBuildScripts:
      - name: Build Web Content
        script: |
          cd "$SRCROOT"
          if command -v bun &> /dev/null; then
            bun run build:web
          else
            echo "warning: bun not found, skipping web content build"
          fi
        basedOnDependencyAnalysis: false
  SupersetShellTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests
    dependencies:
      - target: SupersetShell
      - package: GRDB
    settings:
      base:
        GENERATE_INFOPLIST_FILE: true
        PRODUCT_MODULE_NAME: SupersetShellTests
```

- [ ] **Step 2: Regenerate Xcode project and resolve packages**

```bash
cd apps/desktop-swift
xcodegen generate
xcodebuild -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug -resolvePackageDependencies
```

- [ ] **Step 3: Verify build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add apps/desktop-swift/project.yml apps/desktop-swift/SupersetShell.xcodeproj
git commit -m "feat(desktop-swift): add GRDB dependency for SQLite database access"
```

---

## Task 1: Implement GRDB Models

**Purpose:** Define Swift record types that map exactly to the existing `packages/local-db` SQLite schema. These are pure data types with no business logic.

**Files:**
- Create: `apps/desktop-swift/Sources/Database/Models.swift`

- [ ] **Step 1: Create Database directory**

```bash
mkdir -p apps/desktop-swift/Sources/Database
```

- [ ] **Step 2: Write Models.swift**

Write `apps/desktop-swift/Sources/Database/Models.swift`:

```swift
import Foundation
import GRDB

// MARK: - Project

struct Project: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var mainRepoPath: String
    var name: String
    var color: String
    var tabOrder: Int?
    var lastOpenedAt: Int
    var createdAt: Int
    var defaultBranch: String?
    var githubOwner: String?

    static let databaseTableName = "projects"

    static let workspaces = hasMany(Workspace.self, using: ForeignKey(["projectId"]))
    static let worktrees = hasMany(Worktree.self, using: ForeignKey(["projectId"]))

    enum CodingKeys: String, CodingKey {
        case id
        case mainRepoPath = "main_repo_path"
        case name
        case color
        case tabOrder = "tab_order"
        case lastOpenedAt = "last_opened_at"
        case createdAt = "created_at"
        case defaultBranch = "default_branch"
        case githubOwner = "github_owner"
    }
}

// MARK: - Worktree

struct Worktree: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var projectId: String
    var path: String
    var branch: String
    var baseBranch: String?
    var createdAt: Int
    var createdBySuperset: Bool

    static let databaseTableName = "worktrees"

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case path
        case branch
        case baseBranch = "base_branch"
        case createdAt = "created_at"
        case createdBySuperset = "created_by_superset"
    }
}

// MARK: - Workspace

struct Workspace: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var projectId: String
    var worktreeId: String?
    var type: String
    var branch: String
    var name: String
    var tabOrder: Int
    var createdAt: Int
    var updatedAt: Int
    var lastOpenedAt: Int
    var isUnread: Bool?
    var isUnnamed: Bool?
    var deletingAt: Int?
    var sectionId: String?

    static let databaseTableName = "workspaces"

    static let project = belongsTo(Project.self, using: ForeignKey(["projectId"]))
    static let worktree = belongsTo(Worktree.self, using: ForeignKey(["worktreeId"]))

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case worktreeId = "worktree_id"
        case type
        case branch
        case name
        case tabOrder = "tab_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastOpenedAt = "last_opened_at"
        case isUnread = "is_unread"
        case isUnnamed = "is_unnamed"
        case deletingAt = "deleting_at"
        case sectionId = "section_id"
    }

    var isBranchType: Bool { type == "branch" }
    var isWorktreeType: Bool { type == "worktree" }
}

// MARK: - Settings

struct AppSettings: Codable, FetchableRecord, PersistableRecord {
    var id: Int
    var lastActiveWorkspaceId: String?
    var terminalFontFamily: String?
    var terminalFontSize: Int?

    static let databaseTableName = "settings"

    enum CodingKeys: String, CodingKey {
        case id
        case lastActiveWorkspaceId = "last_active_workspace_id"
        case terminalFontFamily = "terminal_font_family"
        case terminalFontSize = "terminal_font_size"
    }
}

// MARK: - Aggregates

struct ProjectWithWorkspaces: Identifiable {
    let project: Project
    let workspaces: [Workspace]
    var id: String { project.id }
}
```

- [ ] **Step 3: Verify build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add apps/desktop-swift/Sources/Database/Models.swift
git commit -m "feat(desktop-swift): add GRDB models matching local-db schema"
```

---

## Task 2: Implement DatabaseManager

**Purpose:** Singleton that opens `~/.superset/local.db`, provides CRUD methods and reactive observation. No migrations — fails fast if DB is missing.

**Files:**
- Create: `apps/desktop-swift/Sources/Database/DatabaseManager.swift`

- [ ] **Step 1: Write DatabaseManager**

Write `apps/desktop-swift/Sources/Database/DatabaseManager.swift`:

```swift
import Foundation
import GRDB
import os

final class DatabaseManager: @unchecked Sendable {
    static var shared: DatabaseManager!

    let dbQueue: DatabaseQueue
    private let logger = Logger(subsystem: "sh.superset.shell", category: "Database")

    /// Initialize with path to existing SQLite database.
    /// Returns nil if database doesn't exist or is unreadable.
    init?(path: String) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            logger.error("Database file not found at \(path)")
            return nil
        }

        do {
            var config = Configuration()
            config.foreignKeysEnabled = true
            config.readonly = false
            dbQueue = try DatabaseQueue(path: path, configuration: config)

            // Verify expected tables exist
            try dbQueue.read { db in
                let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
                let required: Set<String> = ["projects", "workspaces", "worktrees", "settings"]
                let missing = required.subtracting(tables)
                if !missing.isEmpty {
                    throw DatabaseError(message: "Missing tables: \(missing.sorted().joined(separator: ", "))")
                }
            }

            logger.info("Database opened at \(path)")
        } catch {
            logger.error("Failed to open database: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Read

    func allProjectsWithWorkspaces() throws -> [ProjectWithWorkspaces] {
        try dbQueue.read { db in
            let projects = try Project
                .order(Column("tab_order").asc, Column("last_opened_at").desc)
                .fetchAll(db)

            return try projects.map { project in
                let workspaces = try Workspace
                    .filter(Column("project_id") == project.id)
                    .filter(Column("deleting_at") == nil)
                    .order(Column("tab_order").asc)
                    .fetchAll(db)
                return ProjectWithWorkspaces(project: project, workspaces: workspaces)
            }
        }
    }

    func activeWorkspaceId() throws -> String? {
        try dbQueue.read { db in
            try AppSettings.fetchOne(db, key: 1)?.lastActiveWorkspaceId
        }
    }

    func workspace(id: String) throws -> Workspace? {
        try dbQueue.read { db in
            try Workspace.fetchOne(db, key: id)
        }
    }

    func worktree(id: String) throws -> Worktree? {
        try dbQueue.read { db in
            try Worktree.fetchOne(db, key: id)
        }
    }

    func project(id: String) throws -> Project? {
        try dbQueue.read { db in
            try Project.fetchOne(db, key: id)
        }
    }

    /// Resolve the working directory for a workspace.
    /// Branch type → project's mainRepoPath. Worktree type → worktree's path.
    func workspaceCwd(workspace: Workspace) throws -> String {
        if workspace.isWorktreeType, let wtId = workspace.worktreeId {
            if let wt = try worktree(id: wtId) {
                return wt.path
            }
        }
        if let proj = try project(id: workspace.projectId) {
            return proj.mainRepoPath
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: - Write

    func insertProject(_ project: Project) throws {
        try dbQueue.write { db in
            try project.insert(db)
        }
    }

    func insertWorktree(_ worktree: Worktree) throws {
        try dbQueue.write { db in
            try worktree.insert(db)
        }
    }

    func insertWorkspace(_ workspace: Workspace) throws {
        try dbQueue.write { db in
            try workspace.insert(db)
        }
    }

    func setActiveWorkspaceId(_ id: String?) throws {
        try dbQueue.write { db in
            if var settings = try AppSettings.fetchOne(db, key: 1) {
                settings.lastActiveWorkspaceId = id
                try settings.update(db)
            } else {
                let settings = AppSettings(
                    id: 1,
                    lastActiveWorkspaceId: id,
                    terminalFontFamily: nil,
                    terminalFontSize: nil
                )
                try settings.insert(db)
            }
        }
    }

    func updateWorkspaceLastOpened(id: String) throws {
        try dbQueue.write { db in
            if var ws = try Workspace.fetchOne(db, key: id) {
                ws.lastOpenedAt = Int(Date().timeIntervalSince1970 * 1000)
                ws.updatedAt = ws.lastOpenedAt
                try ws.update(db)
            }
        }
    }

    func deleteWorkspace(id: String) throws {
        try dbQueue.write { db in
            _ = try Workspace.deleteOne(db, key: id)
        }
    }

    func deleteWorktree(id: String) throws {
        try dbQueue.write { db in
            _ = try Worktree.deleteOne(db, key: id)
        }
    }

    func deleteProject(id: String) throws {
        try dbQueue.write { db in
            _ = try Project.deleteOne(db, key: id)
            // CASCADE handles workspaces and worktrees
        }
    }

    // MARK: - Reactive

    func observeProjectsWithWorkspaces(
        onChange: @escaping @Sendable ([ProjectWithWorkspaces]) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db -> [ProjectWithWorkspaces] in
            let projects = try Project
                .order(Column("tab_order").asc, Column("last_opened_at").desc)
                .fetchAll(db)

            return try projects.map { project in
                let workspaces = try Workspace
                    .filter(Column("project_id") == project.id)
                    .filter(Column("deleting_at") == nil)
                    .order(Column("tab_order").asc)
                    .fetchAll(db)
                return ProjectWithWorkspaces(project: project, workspaces: workspaces)
            }
        }

        return observation.start(in: dbQueue, onError: { error in
            os_log(.error, "DB observation error: %{public}@", error.localizedDescription)
        }, onChange: onChange)
    }

    func observeActiveWorkspaceId(
        onChange: @escaping @Sendable (String?) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db -> String? in
            try AppSettings.fetchOne(db, key: 1)?.lastActiveWorkspaceId
        }

        return observation.start(in: dbQueue, onError: { error in
            os_log(.error, "DB observation error: %{public}@", error.localizedDescription)
        }, onChange: onChange)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add apps/desktop-swift/Sources/Database/DatabaseManager.swift
git commit -m "feat(desktop-swift): implement DatabaseManager with GRDB read/write and observation"
```

---

## Task 3: Implement GitWorktreeManager

**Purpose:** Create and remove git worktrees via `Process` (Foundation). Pure utility — no database or UI dependencies.

**Files:**
- Create: `apps/desktop-swift/Sources/Git/GitWorktreeManager.swift`

- [ ] **Step 1: Create Git directory**

```bash
mkdir -p apps/desktop-swift/Sources/Git
```

- [ ] **Step 2: Write GitWorktreeManager**

Write `apps/desktop-swift/Sources/Git/GitWorktreeManager.swift`:

```swift
import Foundation
import os

enum GitWorktreeError: Error, LocalizedError {
    case gitNotFound
    case commandFailed(String)
    case notAGitRepo(String)

    var errorDescription: String? {
        switch self {
        case .gitNotFound: return "git not found in PATH"
        case .commandFailed(let msg): return "git error: \(msg)"
        case .notAGitRepo(let path): return "\(path) is not a git repository"
        }
    }
}

enum GitWorktreeManager {
    private static let logger = Logger(subsystem: "sh.superset.shell", category: "Git")

    /// The base directory for worktrees created by the Swift app.
    static var worktreeBaseDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.superset/worktrees"
    }

    /// Compute the worktree directory path for a given project and branch.
    static func worktreePath(projectName: String, branch: String) -> String {
        let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
        return "\(worktreeBaseDir)/\(projectName)/\(safeBranch)"
    }

    /// Validates that a path is a git repository.
    static func isGitRepo(path: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(path)/.git")
    }

    /// Detects the default branch of a git repository.
    static func detectDefaultBranch(repoPath: String) throws -> String {
        let output = try runGit(args: ["symbolic-ref", "--short", "HEAD"], cwd: repoPath)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a git worktree.
    /// Runs: git worktree add <path> -b <branch> [baseBranch]
    static func createWorktree(
        repoPath: String,
        worktreePath: String,
        branch: String,
        baseBranch: String?
    ) throws {
        // Ensure parent directory exists
        let parent = (worktreePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        var args = ["worktree", "add", worktreePath, "-b", branch]
        if let base = baseBranch {
            args.append(base)
        }

        let output = try runGit(args: args, cwd: repoPath)
        logger.info("Created worktree at \(worktreePath): \(output)")
    }

    /// Removes a git worktree.
    /// Runs: git worktree remove <path> --force
    static func removeWorktree(repoPath: String, worktreePath: String) throws {
        let output = try runGit(args: ["worktree", "remove", worktreePath, "--force"], cwd: repoPath)
        logger.info("Removed worktree at \(worktreePath): \(output)")
    }

    // MARK: - Private

    private static func runGit(args: [String], cwd: String) throws -> String {
        let gitPath = "/usr/bin/git"
        guard FileManager.default.fileExists(atPath: gitPath) else {
            throw GitWorktreeError.gitNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw GitWorktreeError.commandFailed(errStr.isEmpty ? outStr : errStr)
        }

        return outStr
    }
}
```

- [ ] **Step 3: Verify build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add apps/desktop-swift/Sources/Git/GitWorktreeManager.swift
git commit -m "feat(desktop-swift): implement GitWorktreeManager for worktree create/remove"
```

---

## Task 4: Implement SidebarViewModel

**Purpose:** The orchestration layer between sidebar UI, database, PTY sessions, git worktrees, and terminal switching. This is the central coordinator.

**Files:**
- Create: `apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift`

- [ ] **Step 1: Create Sidebar directory**

```bash
mkdir -p apps/desktop-swift/Sources/Sidebar
```

- [ ] **Step 2: Write SidebarViewModel**

Write `apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift`:

```swift
import AppKit
import Foundation
import GRDB
import os

@Observable
final class SidebarViewModel {
    var projects: [ProjectWithWorkspaces] = []
    var activeWorkspaceId: String?

    private let db: DatabaseManager
    private let sessionManager = PTYSessionManager.shared
    private var projectsObservation: AnyDatabaseCancellable?
    private var activeObservation: AnyDatabaseCancellable?
    private let logger = Logger(subsystem: "sh.superset.shell", category: "Sidebar")

    // Callback for terminal operations — set by MainWindowController
    var onCreateAndShowTerminal: ((String, String) -> Void)?   // (sessionId, cwd)
    var onShowTerminal: ((String) -> Void)?                     // (sessionId)
    var onDestroyTerminal: ((String) -> Void)?                  // (sessionId)

    init(db: DatabaseManager) {
        self.db = db
    }

    func startObserving() {
        projectsObservation = db.observeProjectsWithWorkspaces { [weak self] projects in
            DispatchQueue.main.async {
                self?.projects = projects
            }
        }

        activeObservation = db.observeActiveWorkspaceId { [weak self] id in
            DispatchQueue.main.async {
                self?.activeWorkspaceId = id
            }
        }

        // Initial load
        do {
            projects = try db.allProjectsWithWorkspaces()
            activeWorkspaceId = try db.activeWorkspaceId()
        } catch {
            logger.error("Failed initial load: \(error.localizedDescription)")
        }
    }

    // MARK: - Add Project

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path

        guard GitWorktreeManager.isGitRepo(path: path) else {
            showAlert(title: "Not a Git Repository", message: "\(path) does not contain a .git directory.")
            return
        }

        let projectName = url.lastPathComponent
        let now = Int(Date().timeIntervalSince1970 * 1000)

        let defaultBranch = (try? GitWorktreeManager.detectDefaultBranch(repoPath: path)) ?? "main"

        let project = Project(
            id: UUID().uuidString,
            mainRepoPath: path,
            name: projectName,
            color: "#6366f1",
            tabOrder: projects.count,
            lastOpenedAt: now,
            createdAt: now,
            defaultBranch: defaultBranch,
            githubOwner: nil
        )

        let workspace = Workspace(
            id: UUID().uuidString,
            projectId: project.id,
            worktreeId: nil,
            type: "branch",
            branch: defaultBranch,
            name: projectName,
            tabOrder: 0,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now,
            isUnread: false,
            isUnnamed: false,
            deletingAt: nil,
            sectionId: nil
        )

        do {
            try db.insertProject(project)
            try db.insertWorkspace(workspace)
            selectWorkspace(id: workspace.id)
            logger.info("Added project \(projectName) at \(path)")
        } catch {
            logger.error("Failed to add project: \(error.localizedDescription)")
            showAlert(title: "Error", message: "Failed to add project: \(error.localizedDescription)")
        }
    }

    // MARK: - Create Workspace (worktree)

    func createWorkspace(projectId: String, branchName: String) {
        guard let projWithWs = projects.first(where: { $0.project.id == projectId }) else { return }
        let project = projWithWs.project
        let now = Int(Date().timeIntervalSince1970 * 1000)

        let worktreePath = GitWorktreeManager.worktreePath(
            projectName: project.name,
            branch: branchName
        )

        do {
            try GitWorktreeManager.createWorktree(
                repoPath: project.mainRepoPath,
                worktreePath: worktreePath,
                branch: branchName,
                baseBranch: project.defaultBranch
            )
        } catch {
            logger.error("git worktree add failed: \(error.localizedDescription)")
            showAlert(title: "Git Error", message: error.localizedDescription)
            return
        }

        let worktree = Worktree(
            id: UUID().uuidString,
            projectId: project.id,
            path: worktreePath,
            branch: branchName,
            baseBranch: project.defaultBranch,
            createdAt: now,
            createdBySuperset: true
        )

        let workspace = Workspace(
            id: UUID().uuidString,
            projectId: project.id,
            worktreeId: worktree.id,
            type: "worktree",
            branch: branchName,
            name: branchName,
            tabOrder: projWithWs.workspaces.count,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now,
            isUnread: false,
            isUnnamed: false,
            deletingAt: nil,
            sectionId: nil
        )

        do {
            try db.insertWorktree(worktree)
            try db.insertWorkspace(workspace)
            selectWorkspace(id: workspace.id)
            logger.info("Created workspace \(branchName) for project \(project.name)")
        } catch {
            logger.error("Failed to create workspace: \(error.localizedDescription)")
            showAlert(title: "Error", message: error.localizedDescription)
        }
    }

    // MARK: - Select Workspace (lazy PTY)

    func selectWorkspace(id: String) {
        guard id != activeWorkspaceId else { return }

        do {
            try db.setActiveWorkspaceId(id)
            try db.updateWorkspaceLastOpened(id: id)
        } catch {
            logger.error("Failed to set active workspace: \(error.localizedDescription)")
        }

        activeWorkspaceId = id

        // If PTY already exists, just show it
        if sessionManager.session(for: id) != nil {
            onShowTerminal?(id)
            return
        }

        // Lazy create: first time visiting this workspace
        guard let ws = try? db.workspace(id: id) else { return }
        let cwd: String
        do {
            cwd = try db.workspaceCwd(workspace: ws)
        } catch {
            cwd = FileManager.default.homeDirectoryForCurrentUser.path
        }

        onCreateAndShowTerminal?(id, cwd)
    }

    // MARK: - Delete Workspace

    func deleteWorkspace(id: String) {
        guard let ws = try? db.workspace(id: id) else { return }
        guard ws.isWorktreeType else { return } // Cannot delete branch workspaces

        // Find replacement
        let allWorkspaces = projects.flatMap(\.workspaces).filter { $0.id != id }
        guard let replacement = allWorkspaces.first else {
            showAlert(title: "Cannot Delete", message: "This is the last workspace.")
            return
        }

        // Check if this is the last worktree in the project
        let projectWorkspaces = projects
            .first(where: { $0.project.id == ws.projectId })?
            .workspaces ?? []
        if projectWorkspaces.count == 1 {
            // Last workspace in project — ask to delete project
            // For now, just prevent deletion
            showAlert(title: "Cannot Delete", message: "Cannot delete the last workspace in a project.")
            return
        }

        // 1. Switch if active
        if id == activeWorkspaceId {
            selectWorkspace(id: replacement.id)
        }

        // 2. Destroy PTY
        sessionManager.destroySession(id)

        // 3. Destroy JS terminal
        onDestroyTerminal?(id)

        // 4. Delete from DB
        do {
            try db.deleteWorkspace(id: id)
        } catch {
            logger.error("Failed to delete workspace from DB: \(error.localizedDescription)")
        }

        // 5-6. Remove worktree from disk + DB
        if let wtId = ws.worktreeId {
            if let wt = try? db.worktree(id: wtId),
               let proj = try? db.project(id: ws.projectId) {
                try? GitWorktreeManager.removeWorktree(
                    repoPath: proj.mainRepoPath,
                    worktreePath: wt.path
                )
            }
            try? db.deleteWorktree(id: wtId)
        }

        logger.info("Deleted workspace \(id)")
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
```

- [ ] **Step 3: Verify build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add apps/desktop-swift/Sources/Sidebar/SidebarViewModel.swift
git commit -m "feat(desktop-swift): implement SidebarViewModel orchestrating DB, PTY, git, and terminal switching"
```

---

## Task 5: Refactor MainWindowController + SupersetApp for NSSplitView

**Purpose:** Replace the bare WKWebView layout with NSSplitViewController (sidebar + terminal). Update app delegate to use DatabaseManager.

**Files:**
- Modify: `apps/desktop-swift/Sources/App/MainWindowController.swift`
- Modify: `apps/desktop-swift/Sources/App/SupersetApp.swift`

- [ ] **Step 1: Rewrite MainWindowController**

Replace `apps/desktop-swift/Sources/App/MainWindowController.swift`:

```swift
import AppKit
import SwiftUI
import WebKit
import os

final class MainWindowController: NSObject, WKNavigationDelegate {

    let window: NSWindow
    private(set) var webView: WKWebView!
    private let schemeHandler = SupersetSchemeHandler()
    private var controlHandler: ControlMessageHandler!
    private let sessionManager = PTYSessionManager.shared
    private let db: DatabaseManager
    let sidebarViewModel: SidebarViewModel
    private let logger = Logger(subsystem: "sh.superset.shell", category: "Window")

    init(db: DatabaseManager) {
        self.db = db
        self.sidebarViewModel = SidebarViewModel(db: db)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Superset"
        window.center()
        window.setFrameAutosaveName("SupersetMainWindow")
        window.minSize = NSSize(width: 640, height: 480)

        setupSplitView()
        wireViewModel()
        sidebarViewModel.startObserving()
    }

    private func setupSplitView() {
        // Create WKWebView
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "superset")

        controlHandler = ControlMessageHandler(schemeHandler: schemeHandler, windowController: self)
        config.userContentController.add(controlHandler, name: "superset")

        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        // Create NSSplitViewController
        let splitVC = NSSplitViewController()

        // Sidebar (SwiftUI)
        let sidebarView = SidebarView(viewModel: sidebarViewModel)
        let sidebarHosting = NSHostingController(rootView: sidebarView)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
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
    }

    private func wireViewModel() {
        sidebarViewModel.onCreateAndShowTerminal = { [weak self] sessionId, cwd in
            self?.createAndShowTerminal(sessionId: sessionId, cwd: cwd)
        }
        sidebarViewModel.onShowTerminal = { [weak self] sessionId in
            self?.switchTerminal(sessionId: sessionId)
        }
        sidebarViewModel.onDestroyTerminal = { [weak self] sessionId in
            self?.destroyTerminal(sessionId: sessionId)
        }
    }

    func loadWebContent() {
        guard let resourceURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "WebContent"
        ) else {
            logger.fault("WebContent/index.html not found in app bundle")
            return
        }

        let directoryURL = resourceURL.deletingLastPathComponent()
        webView.loadFileURL(resourceURL, allowingReadAccessTo: directoryURL)
    }

    // MARK: - Terminal Operations

    func createAndShowTerminal(sessionId: String, cwd: String) {
        do {
            try sessionManager.createSession(
                sessionId: sessionId,
                cwd: cwd,
                onBatchReady: { [weak self] id, data in
                    DispatchQueue.main.async {
                        self?.schemeHandler.sendBatch(sessionId: id, data: data)
                    }
                },
                onExit: { [weak self] id, code, signal in
                    DispatchQueue.main.async {
                        self?.schemeHandler.finishStream(sessionId: id, exitCode: code, signal: signal)
                    }
                }
            )
        } catch {
            logger.error("Failed to create PTY session: \(error.localizedDescription)")
            return
        }

        let escaped = sessionId.jsEscaped
        webView.evaluateJavaScript("window.__superset?.initTerminal('\(escaped)')")
        webView.evaluateJavaScript("window.__superset?.showTerminal('\(escaped)')")
    }

    func switchTerminal(sessionId: String) {
        let escaped = sessionId.jsEscaped
        webView.evaluateJavaScript("window.__superset?.showTerminal('\(escaped)')")
    }

    func destroyTerminal(sessionId: String) {
        let escaped = sessionId.jsEscaped
        webView.evaluateJavaScript("window.__superset?.destroyTerminal('\(escaped)')")
    }

    // MARK: - WKNavigationDelegate

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.warning("WebContent process terminated — reloading")
        schemeHandler.invalidateAllStreams()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("WebView navigation finished")
    }

    /// Called by ControlMessageHandler when JS sends { action: "ready" }.
    func handleJSReady() {
        // Reconnect existing PTY sessions (WebView crash recovery)
        let existingIds = sessionManager.activeSessionIds()
        if !existingIds.isEmpty {
            logger.info("JS ready — reconnecting \(existingIds.count) existing PTY session(s)")
            for sessionId in existingIds {
                let escaped = sessionId.jsEscaped
                webView.evaluateJavaScript("window.__superset?.initTerminal('\(escaped)')")
            }
        }

        // Create PTY for active workspace (app launch — lazy)
        if let activeId = sidebarViewModel.activeWorkspaceId {
            if sessionManager.session(for: activeId) != nil {
                // Already reconnected above, just show
                switchTerminal(sessionId: activeId)
            } else {
                // Fresh launch — create PTY for active workspace
                if let ws = try? db.workspace(id: activeId) {
                    let cwd = (try? db.workspaceCwd(workspace: ws))
                        ?? FileManager.default.homeDirectoryForCurrentUser.path
                    createAndShowTerminal(sessionId: activeId, cwd: cwd)
                }
            }
        } else {
            logger.info("JS ready — no active workspace")
        }
    }
}

extension String {
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 2: Rewrite SupersetApp.swift**

Replace `apps/desktop-swift/Sources/App/SupersetApp.swift`:

```swift
import AppKit

@main
struct SupersetApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Open database — fail fast if missing
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".superset/local.db").path

        guard let db = DatabaseManager(path: dbPath) else {
            let alert = NSAlert()
            alert.messageText = "Database Not Found"
            alert.informativeText = "Could not open \(dbPath). Please run Superset desktop at least once to initialize the database."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        DatabaseManager.shared = db

        windowController = MainWindowController(db: db)
        windowController.loadWebContent()
        windowController.window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PTYSessionManager.shared.destroyAll()
    }
}
```

- [ ] **Step 3: Verify build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -10
```

Note: This will fail until SidebarView is created in Task 6. If you need it to compile now, create a placeholder:

```swift
// Temporary placeholder — apps/desktop-swift/Sources/Sidebar/SidebarView.swift
import SwiftUI
struct SidebarView: View {
    var viewModel: SidebarViewModel
    var body: some View { Text("Sidebar placeholder") }
}
```

- [ ] **Step 4: Commit**

```bash
git add apps/desktop-swift/Sources/App/MainWindowController.swift apps/desktop-swift/Sources/App/SupersetApp.swift apps/desktop-swift/Sources/Sidebar/SidebarView.swift
git commit -m "feat(desktop-swift): refactor window to NSSplitView with sidebar + terminal panes"
```

---

## Task 6: Implement SwiftUI Sidebar Views

**Purpose:** The actual SwiftUI views: SidebarView, ProjectRowView, WorkspaceRowView. Connected to SidebarViewModel.

**Files:**
- Create/replace: `apps/desktop-swift/Sources/Sidebar/SidebarView.swift`
- Create: `apps/desktop-swift/Sources/Sidebar/ProjectRowView.swift`
- Create: `apps/desktop-swift/Sources/Sidebar/WorkspaceRowView.swift`

- [ ] **Step 1: Write SidebarView**

Replace `apps/desktop-swift/Sources/Sidebar/SidebarView.swift`:

```swift
import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: SidebarViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.projects.isEmpty {
                emptyState
            } else {
                projectList
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 180)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Add a project to get started")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add Project") {
                viewModel.addProject()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.projects) { pww in
                    ProjectRowView(
                        project: pww.project,
                        workspaces: pww.workspaces,
                        activeWorkspaceId: viewModel.activeWorkspaceId,
                        onSelectWorkspace: { id in viewModel.selectWorkspace(id: id) },
                        onCreateWorkspace: { projectId, branch in
                            viewModel.createWorkspace(projectId: projectId, branchName: branch)
                        },
                        onDeleteWorkspace: { id in viewModel.deleteWorkspace(id: id) }
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var footerBar: some View {
        HStack {
            Button(action: { viewModel.addProject() }) {
                Label("Add Project", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Spacer()
        }
    }
}
```

- [ ] **Step 2: Write ProjectRowView**

Write `apps/desktop-swift/Sources/Sidebar/ProjectRowView.swift`:

```swift
import SwiftUI

struct ProjectRowView: View {
    let project: Project
    let workspaces: [Workspace]
    let activeWorkspaceId: String?
    let onSelectWorkspace: (String) -> Void
    let onCreateWorkspace: (String, String) -> Void
    let onDeleteWorkspace: (String) -> Void

    @State private var isExpanded = true
    @State private var showNewBranchSheet = false
    @State private var newBranchName = ""

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(workspaces) { workspace in
                WorkspaceRowView(
                    workspace: workspace,
                    isActive: workspace.id == activeWorkspaceId,
                    onSelect: { onSelectWorkspace(workspace.id) },
                    onDelete: workspace.isWorktreeType
                        ? { onDeleteWorkspace(workspace.id) }
                        : nil
                )
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: project.color) ?? .purple)
                    .frame(width: 8, height: 8)
                Text(project.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(workspaces.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(action: { showNewBranchSheet = true }) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New workspace")
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 8)
        .sheet(isPresented: $showNewBranchSheet) {
            newBranchSheet
        }
    }

    private var newBranchSheet: some View {
        VStack(spacing: 16) {
            Text("New Workspace")
                .font(.headline)
            TextField("Branch name", text: $newBranchName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
            HStack {
                Button("Cancel") { showNewBranchSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let branch = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !branch.isEmpty else { return }
                    onCreateWorkspace(project.id, branch)
                    newBranchName = ""
                    showNewBranchSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Color from hex

extension Color {
    init?(hex: String) {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }
        guard hexStr.count == 6, let rgb = UInt64(hexStr, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
```

- [ ] **Step 3: Write WorkspaceRowView**

Write `apps/desktop-swift/Sources/Sidebar/WorkspaceRowView.swift`:

```swift
import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let isActive: Bool
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
}
```

- [ ] **Step 4: Verify build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add apps/desktop-swift/Sources/Sidebar/SidebarView.swift apps/desktop-swift/Sources/Sidebar/ProjectRowView.swift apps/desktop-swift/Sources/Sidebar/WorkspaceRowView.swift
git commit -m "feat(desktop-swift): implement SwiftUI sidebar with project and workspace views"
```

---

## Task 7: Update terminal-bridge.ts for Multi-Terminal

**Purpose:** Change JS from single-terminal to multi-terminal: each terminal gets its own div, CSS visibility switching via `showTerminal`.

**Files:**
- Modify: `apps/desktop-swift/web-src/terminal-bridge.ts`

- [ ] **Step 1: Rewrite terminal-bridge.ts**

Replace `apps/desktop-swift/web-src/terminal-bridge.ts`:

```typescript
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

/**
 * Create a new terminal instance in a hidden div.
 * Does NOT show it — call showTerminal() after.
 */
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

/**
 * Show one terminal, hide all others.
 */
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
```

- [ ] **Step 2: Rebuild JS**

```bash
cd apps/desktop-swift
bun run build:web
```

Expected: Build complete.

- [ ] **Step 3: Full build**

```bash
xcodebuild build -project SupersetShell.xcodeproj -scheme SupersetShell -configuration Debug 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add apps/desktop-swift/web-src/terminal-bridge.ts
git commit -m "feat(desktop-swift): update terminal-bridge for multi-terminal with CSS visibility switching"
```

---

## Task 8: End-to-End Verification

**Purpose:** Build, run tests, launch app, and verify all spec requirements.

- [ ] **Step 1: Run all tests**

```bash
cd apps/desktop-swift
xcodebuild test -project SupersetShell.xcodeproj -scheme SupersetShell 2>&1 | grep -E "(passed|failed|Executed)" | tail -10
```

Expected: all existing tests pass (PTYSession + OutputBatcher).

- [ ] **Step 2: Ensure ~/.superset/local.db exists**

If you have the Electron app installed, it creates this file. Otherwise, create a test DB:

```bash
mkdir -p ~/.superset
sqlite3 ~/.superset/local.db "
CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, main_repo_path TEXT NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL, tab_order INTEGER, last_opened_at INTEGER NOT NULL, created_at INTEGER NOT NULL, default_branch TEXT, github_owner TEXT, config_toast_dismissed INTEGER, workspace_base_branch TEXT, branch_prefix_mode TEXT, branch_prefix_custom TEXT, worktree_base_dir TEXT, hide_image INTEGER, icon_url TEXT, neon_project_id TEXT, default_app TEXT);
CREATE TABLE IF NOT EXISTS worktrees (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, path TEXT NOT NULL, branch TEXT NOT NULL, base_branch TEXT, created_at INTEGER NOT NULL, git_status TEXT, github_status TEXT, created_by_superset INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS workspace_sections (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, name TEXT NOT NULL, tab_order INTEGER NOT NULL, is_collapsed INTEGER DEFAULT 0, color TEXT, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, worktree_id TEXT REFERENCES worktrees(id) ON DELETE CASCADE, type TEXT NOT NULL, branch TEXT NOT NULL, name TEXT NOT NULL, tab_order INTEGER NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, last_opened_at INTEGER NOT NULL, is_unread INTEGER DEFAULT 0, is_unnamed INTEGER DEFAULT 0, deleting_at INTEGER, port_base INTEGER, section_id TEXT REFERENCES workspace_sections(id) ON DELETE SET NULL);
CREATE UNIQUE INDEX IF NOT EXISTS workspaces_unique_branch_per_project ON workspaces(project_id) WHERE type = 'branch';
CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY DEFAULT 1, last_active_workspace_id TEXT, terminal_presets TEXT, terminal_presets_initialized INTEGER, agent_preset_overrides TEXT, agent_custom_definitions TEXT, selected_ringtone_id TEXT, active_organization_id TEXT, confirm_on_quit INTEGER, terminal_link_behavior TEXT, persist_terminal INTEGER DEFAULT 1, auto_apply_default_preset INTEGER, branch_prefix_mode TEXT, branch_prefix_custom TEXT, notification_sounds_muted INTEGER, notification_volume INTEGER, delete_local_branch INTEGER, file_open_mode TEXT, show_presets_bar INTEGER, use_compact_terminal_add_button INTEGER, terminal_font_family TEXT, terminal_font_size INTEGER, editor_font_family TEXT, editor_font_size INTEGER, show_resource_monitor INTEGER, worktree_base_dir TEXT, open_links_in_app INTEGER, default_editor TEXT);
INSERT OR IGNORE INTO settings (id) VALUES (1);
"
```

- [ ] **Step 3: Launch and verify manually**

```bash
open build/Debug/SupersetShell.app
```

Or find the built app in DerivedData and open it.

Verify:
- NSSplitView with sidebar (left) and terminal area (right)
- Sidebar shows empty state or existing projects from DB
- Click "Add Project" → NSOpenPanel → select a git repo
- Project appears with branch workspace
- Terminal opens in the project directory
- Click "+" on project → enter branch name → worktree created → new terminal
- Click between workspaces → terminals switch instantly
- Context menu delete on worktree workspace → workspace removed

- [ ] **Step 4: Commit final state**

```bash
git add -A apps/desktop-swift/
git commit -m "feat(desktop-swift): Phase 2a complete — multi-terminal, SQLite, native sidebar"
```

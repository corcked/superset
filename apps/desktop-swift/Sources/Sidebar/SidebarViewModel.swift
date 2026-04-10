import AppKit
import Foundation
import GRDB
import os

@MainActor
@Observable
final class SidebarViewModel {
    var projects: [ProjectWithWorkspaces] = []
    var activeWorkspaceId: String?

    private let db: DatabaseManager
    private let sessionManager = PTYSessionManager.shared
    private let gitStatusManager = GitStatusManager.shared
    private var projectsObservation: AnyDatabaseCancellable?
    private var activeObservation: AnyDatabaseCancellable?
    private let logger = Logger(subsystem: "sh.superset.shell", category: "Sidebar")

    var branchStatusGeneration: Int = 0
    var showNewWorkspaceSheet = false

    // Callbacks for terminal operations — set by MainWindowController
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

        // Wire branch status refresh
        gitStatusManager.onBranchStatusUpdated = { [weak self] in
            self?.branchStatusGeneration += 1
        }

        // Start polling for active workspace
        if let activeId = activeWorkspaceId {
            startGitPollingForWorkspace(id: activeId)
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
        startGitPollingForWorkspace(id: id)

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

    // MARK: - Git Status

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

    /// Resolve git status for a workspace (from DB worktrees or in-memory cache)
    func gitStatus(for workspace: Workspace) -> GitStatusInfo? {
        if workspace.isWorktreeType, let wtId = workspace.worktreeId {
            let wt = projects.flatMap(\.worktrees).first(where: { $0.id == wtId })
            return wt?.parsedGitStatus
        } else {
            _ = branchStatusGeneration // trigger SwiftUI refresh
            return gitStatusManager.branchStatusCache[workspace.id]
        }
    }

    // MARK: - Delete Workspace

    func deleteWorkspace(id: String) {
        guard let ws = try? db.workspace(id: id) else { return }
        guard ws.isWorktreeType else { return } // Cannot delete branch workspaces

        let allWorkspaces = projects.flatMap(\.workspaces).filter { $0.id != id }
        guard let replacement = allWorkspaces.first else {
            showAlert(title: "Cannot Delete", message: "This is the last workspace.")
            return
        }

        let projectWorkspaces = projects
            .first(where: { $0.project.id == ws.projectId })?
            .workspaces ?? []
        if projectWorkspaces.count == 1 {
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

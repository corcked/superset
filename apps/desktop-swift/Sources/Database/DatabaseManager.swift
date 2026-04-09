import Foundation
import GRDB

final class DatabaseManager: @unchecked Sendable {

    // MARK: - Shared Instance

    static var shared: DatabaseManager!

    // MARK: - Properties

    private let dbQueue: DatabaseQueue

    // MARK: - Init

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            var config = Configuration()
            config.foreignKeysEnabled = true
            let queue = try DatabaseQueue(path: path, configuration: config)

            // Verify required tables exist
            let requiredTables: Set<String> = ["projects", "workspaces", "worktrees", "settings"]
            let existingTables: Set<String> = try queue.read { db in
                let rows = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
                return Set(rows)
            }
            guard requiredTables.isSubset(of: existingTables) else {
                return nil
            }

            self.dbQueue = queue
        } catch {
            return nil
        }
    }

    // MARK: - Read Methods

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
            let settings = try AppSettings.fetchOne(db, key: 1)
            return settings?.lastActiveWorkspaceId
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

    func workspaceCwd(workspace ws: Workspace) throws -> String {
        if ws.isWorktreeType, let worktreeId = ws.worktreeId {
            if let wt = try worktree(id: worktreeId) {
                return wt.path
            }
        }
        if let proj = try project(id: ws.projectId) {
            return proj.mainRepoPath
        }
        return NSHomeDirectory()
    }

    // MARK: - Write Methods

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
            var settings = try AppSettings.fetchOne(db, key: 1) ?? AppSettings(
                id: 1,
                lastActiveWorkspaceId: nil,
                terminalFontFamily: nil,
                terminalFontSize: nil
            )
            settings.lastActiveWorkspaceId = id
            try settings.save(db)
        }
    }

    func updateWorkspaceLastOpened(id: String) throws {
        try dbQueue.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)
            try db.execute(
                sql: "UPDATE workspaces SET last_opened_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    func deleteWorkspace(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM workspaces WHERE id = ?", arguments: [id])
        }
    }

    func deleteWorktree(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM worktrees WHERE id = ?", arguments: [id])
        }
    }

    func deleteProject(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Reactive Observation

    func observeProjectsWithWorkspaces(
        onChange: @escaping ([ProjectWithWorkspaces]) -> Void
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

        return observation.start(in: dbQueue, onError: { _ in }, onChange: onChange)
    }

    func observeActiveWorkspaceId(
        onChange: @escaping (String?) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db -> String? in
            let settings = try AppSettings.fetchOne(db, key: 1)
            return settings?.lastActiveWorkspaceId
        }

        return observation.start(in: dbQueue, onError: { _ in }, onChange: onChange)
    }
}

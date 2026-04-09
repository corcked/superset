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

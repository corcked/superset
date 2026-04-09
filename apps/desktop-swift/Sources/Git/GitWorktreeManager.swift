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

    static var worktreeBaseDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.superset/worktrees"
    }

    static func worktreePath(projectName: String, branch: String) -> String {
        let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
        return "\(worktreeBaseDir)/\(projectName)/\(safeBranch)"
    }

    static func isGitRepo(path: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(path)/.git")
    }

    static func detectDefaultBranch(repoPath: String) throws -> String {
        let output = try runGit(args: ["symbolic-ref", "--short", "HEAD"], cwd: repoPath)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func createWorktree(
        repoPath: String,
        worktreePath: String,
        branch: String,
        baseBranch: String?
    ) throws {
        let parent = (worktreePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        var args = ["worktree", "add", worktreePath, "-b", branch]
        if let base = baseBranch {
            args.append(base)
        }

        let output = try runGit(args: args, cwd: repoPath)
        logger.info("Created worktree at \(worktreePath): \(output)")
    }

    static func removeWorktree(repoPath: String, worktreePath: String) throws {
        let output = try runGit(args: ["worktree", "remove", worktreePath, "--force"], cwd: repoPath)
        logger.info("Removed worktree at \(worktreePath): \(output)")
    }

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

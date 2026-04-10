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

    /// Callback when branch status is updated (triggers UI refresh)
    var onBranchStatusUpdated: (() -> Void)?

    private init() {}

    /// Start polling for a workspace. Cancels previous polling.
    func startPolling(workspaceId: String, repoPath: String, worktreeId: String?, defaultBranch: String?) {
        lock.lock()
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

        // git fetch (best effort, with timeout)
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

        let info = GitStatusInfo(
            branch: branch,
            ahead: ahead,
            behind: behind,
            changedFiles: changedFiles,
            needsRebase: behind > 0,
            lastRefreshed: Int(Date().timeIntervalSince1970 * 1000)
        )

        // Cache
        if let wtId = worktreeId {
            if let json = try? JSONEncoder().encode(info),
               let jsonStr = String(data: json, encoding: .utf8) {
                try? DatabaseManager.shared.updateWorktreeGitStatus(worktreeId: wtId, statusJson: jsonStr)
            }
        } else {
            lock.lock()
            branchStatusCache[workspaceId] = info
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onBranchStatusUpdated?()
            }
        }

        logger.info("Git status: branch=\(branch) ahead=\(ahead) behind=\(behind) changed=\(changedFiles)")
    }

    // MARK: - Git execution

    private func runGit(_ args: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }

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
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        lock.lock()
        activeProcess = process
        lock.unlock()

        try process.run()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            lock.lock()
            if activeProcess === process { activeProcess = nil }
            lock.unlock()
            throw GitWorktreeError.commandFailed("git timed out after \(timeout)s")
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

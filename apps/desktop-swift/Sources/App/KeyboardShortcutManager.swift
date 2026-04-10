import AppKit
import os

@MainActor
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
        // Don't intercept when typing in native text fields or sheets
        if isNativeTextFieldFocused() || isSheetPresented() {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmd = flags == .command
        let isCmdShift = flags == [.command, .shift]

        guard isCmd || isCmdShift else { return event }

        guard let chars = event.charactersIgnoringModifiers else { return event }

        // ⌘+1 through ⌘+9
        if isCmd, let digit = Int(chars), digit >= 1, digit <= 9 {
            switchToWorkspaceAtIndex(digit - 1)
            return nil
        }

        // Arrow keys (use keyCode since they have no useful character)
        if isCmd {
            switch event.keyCode {
            case 126:  // ↑
                navigatePrevWorkspace()
                return nil
            case 125:  // ↓
                navigateNextWorkspace()
                return nil
            default:
                break
            }
        }

        // Character-based shortcuts
        if isCmd {
            switch chars {
            case "\\":
                toggleSidebar()
                return nil
            case "n":
                newWorkspace()
                return nil
            default:
                break
            }
        }

        if isCmdShift, chars.lowercased() == "w" {
            deleteActiveWorkspace()
            return nil
        }

        return event
    }

    // MARK: - Actions

    private func switchToWorkspaceAtIndex(_ index: Int) {
        guard let vm = sidebarViewModel else { return }
        let allWorkspaces = vm.projects.flatMap(\.workspaces)
        guard index < allWorkspaces.count else { return }
        Task { @MainActor in
            vm.selectWorkspace(id: allWorkspaces[index].id)
        }
    }

    private func navigatePrevWorkspace() {
        guard let vm = sidebarViewModel, let activeId = vm.activeWorkspaceId else { return }
        let allWorkspaces = vm.projects.flatMap(\.workspaces)
        guard !allWorkspaces.isEmpty else { return }
        let currentIndex = allWorkspaces.firstIndex(where: { $0.id == activeId }) ?? 0
        let prevIndex = (currentIndex - 1 + allWorkspaces.count) % allWorkspaces.count
        Task { @MainActor in
            vm.selectWorkspace(id: allWorkspaces[prevIndex].id)
        }
    }

    private func navigateNextWorkspace() {
        guard let vm = sidebarViewModel, let activeId = vm.activeWorkspaceId else { return }
        let allWorkspaces = vm.projects.flatMap(\.workspaces)
        guard !allWorkspaces.isEmpty else { return }
        let currentIndex = allWorkspaces.firstIndex(where: { $0.id == activeId }) ?? 0
        let nextIndex = (currentIndex + 1) % allWorkspaces.count
        Task { @MainActor in
            vm.selectWorkspace(id: allWorkspaces[nextIndex].id)
        }
    }

    private func deleteActiveWorkspace() {
        guard let vm = sidebarViewModel, let activeId = vm.activeWorkspaceId else { return }
        Task { @MainActor in
            vm.deleteWorkspace(id: activeId)
        }
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
        Task { @MainActor in
            vm.showNewWorkspaceSheet = true
        }
    }

    // MARK: - Helpers

    private func isNativeTextFieldFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        // Only suppress shortcuts for native AppKit text inputs, NOT WKWebView internals
        let className = String(describing: type(of: responder))
        if className.hasPrefix("WK") { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func isSheetPresented() -> Bool {
        NSApp.keyWindow?.attachedSheet != nil
    }
}

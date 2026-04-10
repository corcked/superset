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
            switchToWorkspaceAtIndex(digit - 1)
            return nil
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

    private func isTextFieldFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func isSheetPresented() -> Bool {
        NSApp.keyWindow?.attachedSheet != nil
    }

    private func digitFromKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }
}

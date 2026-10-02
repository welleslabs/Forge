import SwiftUI
import AppKit
import SwiftTerm
import Darwin

// MARK: - Embedded Terminal Session
//
// Wraps SwiftTerm's `LocalProcessTerminalView` — a real xterm emulator — so the
// interactive scan wizard (arrow-key menus, colors, live redraws) renders exactly
// like a terminal, but stays inside the app's console pane. No Terminal.app popup.

struct TerminalSessionView: NSViewRepresentable {
    let launch: TerminalLaunch
    let onExit: (Int32?) -> Void
    /// Hand the view's `terminate()` back to the runner so Stop can kill the session.
    let registerTerminator: (@escaping () -> Void) -> Void

    /// Launch ids whose process has already been spawned. SwiftUI rebuilds this view when the
    /// console unmounts and remounts (navigating away from the page and back, or a parent re-render);
    /// without this, that rebuild would silently RE-RUN the scan even though the user never hit Run.
    private static var startedLaunchIDs: Set<UUID> = []

    func makeNSView(context: Context) -> FocusingTerminalView {
        let tv = FocusingTerminalView(frame: .zero)
        tv.processDelegate = context.coordinator

        // Theme to match the console surface.
        tv.nativeBackgroundColor = NSColor(red: 0.043, green: 0.050, blue: 0.066, alpha: 1)
        tv.nativeForegroundColor = NSColor(red: 0.86, green: 0.92, blue: 0.86, alpha: 1)
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Stop must kill the whole tree (bash → tmas → children), not just bash.
        // SwiftTerm's terminate() only SIGTERMs the direct child, and bash often keeps
        // running the script after tmas aborts. forkpty puts the child in its own
        // session/process group, so we signal the whole group (-pid) AND the bare pid,
        // and escalate to an uncatchable SIGKILL quickly so nothing can linger.
        registerTerminator { [weak tv] in
            guard let tv else { return }
            let pid = tv.process.shellPid
            if pid > 0 {
                kill(-pid, SIGINT)               // let the TUI exit cleanly if it can
                kill(pid, SIGINT)
            }
            tv.terminate()                       // SwiftTerm closes the PTY and reaps bash
            if pid > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    kill(-pid, SIGKILL)          // hard-kill the whole group
                    kill(pid, SIGKILL)           // and the leader directly, belt-and-suspenders
                }
            }
        }

        // Spawn the child process exactly ONCE per launch, so a view rebuild never re-runs the scan.
        if !Self.startedLaunchIDs.contains(launch.id) {
            Self.startedLaunchIDs.insert(launch.id)
            tv.startProcess(
                executable: launch.executable,
                args: launch.args,
                environment: Self.buildEnvironment(),
                currentDirectory: launch.workDir
            )
        }
        return tv
    }

    /// The console was removed (navigating away, or the launch cleared). Kill the session so it
    /// doesn't keep running orphaned — and so returning to this page never respawns it.
    static func dismantleNSView(_ nsView: FocusingTerminalView, coordinator: Coordinator) {
        let pid = nsView.process.shellPid
        if pid > 0 { kill(-pid, SIGINT); kill(pid, SIGINT) }
        nsView.terminate()
        if pid > 0 {
            let p = pid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { kill(-p, SIGKILL); kill(p, SIGKILL) }
        }
    }

    func updateNSView(_ nsView: FocusingTerminalView, context: Context) {
        // SwiftUI resets the window's first responder on its state updates, so reclaim
        // focus after each one — otherwise keystrokes stop reaching the terminal.
        nsView.claimFocusOnce()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    // MARK: Environment

    /// Build the interactive terminal's environment from the SAME enriched set the piped phases
    /// get (CredentialManager.enrichedEnvironment) — PATH, credentials, region, and the AI-scan
    /// mode/selection (FORGE_SCAN_*). This MUST stay a single source of truth: hand-maintaining a
    /// second copy here silently dropped FORGE_SCAN_* before, so the Run AI Scanner console always
    /// fell back to the full catalogue and the mode/selection UI had no effect. We keep only
    /// SwiftTerm's interactive TERM (xterm-256color) instead of the piped "dumb".
    private static func buildEnvironment() -> [String] {
        var merged: [String: String] = [:]
        for entry in Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true) {
            if let eq = entry.firstIndex(of: "=") {
                merged[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        for (k, v) in CredentialManager.enrichedEnvironment() where k != "TERM" {
            merged[k] = v
        }
        return merged.map { "\($0.key)=\($0.value)" }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: (Int32?) -> Void
        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }

        func processTerminated(source: TerminalView, exitCode: Int32?) { onExit(exitCode) }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}

// MARK: - Focusing Terminal View
//
// SwiftTerm's view accepts first-responder status but nothing claims it at launch,
// and SwiftUI keeps resetting the window's first responder on its state updates — so
// a single makeFirstResponder gets clobbered and keystrokes never reach the wizard.
// We win the race by re-asserting focus several times right after the view attaches,
// and once more after every SwiftUI update (via claimFocusOnce from updateNSView).
final class FocusingTerminalView: LocalProcessTerminalView {
    private var claimTicks = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        claimTicks = 0
        tickFocus()
    }

    private func tickFocus() {
        guard let w = window else { return }
        if w.firstResponder !== self { w.makeFirstResponder(self) }
        claimTicks += 1
        if claimTicks < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.tickFocus()
            }
        }
    }

    /// Reclaim focus on the next runloop tick if something (SwiftUI) took it.
    func claimFocusOnce() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window, w.firstResponder !== self else { return }
            w.makeFirstResponder(self)
        }
    }
}

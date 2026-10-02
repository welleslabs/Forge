import Foundation
import AppKit
import Darwin
import Combine

// (LineType, ConsoleLine, and ConsoleBlock now live in ConsoleStore.swift.)

// MARK: - Terminal Launch
//
// Describes an interactive session to run inside the embedded SwiftTerm view.
// The console swaps its line list for a real terminal emulator when this is set.
struct TerminalLaunch: Identifiable, Equatable, Sendable {
    let id = UUID()
    let executable: String
    let args: [String]
    let workDir: String
    let label: String
    static func == (l: TerminalLaunch, r: TerminalLaunch) -> Bool { l.id == r.id }
}

// MARK: - Demo Runner

@MainActor
final class DemoRunner: ObservableObject {
    /// Console output + line grouping live in their own store; the runner owns it and
    /// re-publishes its changes (see init) so views observing the runner still refresh.
    let console = ConsoleStore()
    private var cancellables = Set<AnyCancellable>()

    /// View-facing forwarders so existing call sites keep using `runner.lines` etc.
    var lines: [ConsoleLine] { console.lines }
    var lineRevision: Int { console.lineRevision }
    var consoleBlocks: [ConsoleBlock] { console.consoleBlocks }

    @Published var isRunning = false
    @Published var currentLabel: String? = nil
    @Published var alert: AlertInfo? = nil

    /// true when /etc/sudoers.d/trenddemo-launcher exists (NOPASSWD entry written).
    @Published var adminReady: Bool = FileManager.default.fileExists(atPath: "/etc/sudoers.d/trenddemo-launcher")
    @Published var adminPriming: Bool = false

    private var process: Process?
    private var bgProcess: Process?
    @Published var isInteractive: Bool = false
    @Published private(set) var isRunningAll = false
    /// True while a "Run All Attacks" sequence is firing payloads through the proxy.
    @Published private(set) var isRunningAttacks = false
    /// True once a "Run Setup" sequence has completed successfully; cleared by Teardown.
    /// The lab infrastructure (Ollama, ngrok, tmas) is shared, so this is global.
    @Published var labReady = false

    /// Environment setup/teardown progress. While a batch runs, the verbose per-line output
    /// is captured (not streamed) and the UI shows a progress bar instead — "just a
    /// completion bar". nil when no batch is running.
    @Published var batchProgress: Double? = nil     // 0…1 while a setup/teardown/scan runs
    @Published var batchLabel: String = ""
    @Published var batchElapsed: String = ""         // "m:ss" heartbeat — visible proof it's still going
    private var progressTimer: Timer?
    private var progressFloor: Double = 0            // hard lower bound from real events (phases/units done)
    private var progressTarget: Double = 0.92        // where the smooth creep is currently heading
    private var batchUnitsTotal = 0                  // work units in the batch (0 = a scan, not a batch)
    private var batchUnitsDone = 0
    private var batchAllUnits = false                // true when every queued phase counts as a unit
    private var currentIsUnit = false                // is the running phase a work unit?
    private var batchStart: Date?
    private var quietBatch = false                   // capture subprocess output instead of streaming it
    private var quietTail: [String] = []             // rolling tail of the current step, revealed on failure
    /// Whether the local model server (Ollama on :11434) is reachable. Polled so the attack
    /// Run buttons disable themselves when there's no model to send prompts to.
    @Published var modelRunning = false
    /// True while the app is auto-starting the local model server on launch, so the UI can
    /// show "Starting model…" instead of the "model isn't running" warning.
    @Published var modelStarting = false
    private var modelTimer: Timer?
    /// Guards the launch-time model auto-start so it's attempted at most once per session.
    private var didAutoStartModel = false
    /// Non-nil while an interactive scan runs in the embedded SwiftTerm view.
    @Published var terminalLaunch: TerminalLaunch? = nil
    private var scanWatchdog: Timer?   // polls lab.sh's completion sentinel as a backup exit signal
    /// Installed by the embedded terminal view so stop() can kill the live session.
    var terminateTerminal: (() -> Void)?
    private var phaseQueue: [(DemoPhase, String, String, String)] = []
    /// True while the current phaseQueue is a teardown run, so its completion clears
    /// labReady instead of setting it (the queue is shared with setup).
    private var runningTeardown = false

    /// Which environment components are actually installed, persisted across launches so Quick
    /// Teardown removes only what was set up — not every component the lab could ever install.
    static let installedComponentsKey = "installedComponentIDs"
    private var pendingSetupComponentIDs: [String] = []       // set in runEnvironmentSetup, committed on success
    private var pendingTeardownComponentIDs: [String] = []    // set in runEnvironmentTeardown, committed on success
    private var nukeInProgress = false
    private var attackQueue: [GuardAttack] = []
    private var attackIndex = 0     // 1-based position within a Run-All sequence (for the card header)
    private var attackTotal = 0     // total attacks in the current Run-All sequence
    private var ptyMasterFD: Int32 = -1

    /// The scan wizard's target endpoint, derived from the ngrok tunnel URL that
    /// `setup` saves to ~/.trend-lab/tunnel-url. Surfaced on the scan card as the
    /// suggested answer for Prompt 2 ("target OpenAI API endpoint"). nil until setup runs.
    /// Stored (not computed) so SwiftUI body evaluations don't hit the disk; refreshed
    /// once at launch and after each setup completes via `refreshWizardEndpoint()`.
    @Published private(set) var wizardEndpoint: String? = nil

    /// Re-read ~/.trend-lab/tunnel-url and cache the wizard endpoint.
    func refreshWizardEndpoint() {
        let f = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".trend-lab/tunnel-url")
        guard let raw = try? String(contentsOf: f, encoding: .utf8) else { wizardEndpoint = nil; return }
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        wizardEndpoint = url.isEmpty ? nil : url + "/v1"
    }

    private static let sudoersFile = "/etc/sudoers.d/trenddemo-launcher"

    init() {
        // Console output is observed directly by ConsoleView (via `runner.console`), so the
        // runner intentionally does NOT re-broadcast per-line console changes — doing so
        // re-rendered every view observing `runner` on each streamed line (a render storm
        // during setup and scans).
    }

    // MARK: - Admin Access

    /// Uses the native macOS admin dialog (once) to write a NOPASSWD sudoers entry.
    /// After this succeeds, every sudo call in scripts works silently forever.
    func setupAdminAccess() {
        guard !adminPriming else { return }
        adminPriming = true
        let username = ProcessInfo.processInfo.userName
        // Allow only safe characters to prevent injection via username.
        let safeUser = username.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let file = Self.sudoersFile
        let entry = "\(safeUser) ALL=(ALL) NOPASSWD: ALL"
        let cmd = "echo '\(entry)' > '\(file)' && chmod 440 '\(file)' && /usr/sbin/visudo -c -f '\(file)' || rm -f '\(file)'"
        Task.detached {
            let err = Self.runAdminAppleScript(shell: cmd)
            let exists = FileManager.default.fileExists(atPath: file)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.adminPriming = false
                self.adminReady = exists
                if exists {
                    self.appendLine("✓ Admin access granted — sudo runs silently in all scripts.", type: .success)
                } else {
                    self.appendLine("✗ Could not set up admin access.\(err.isEmpty ? "" : " (\(err))")", type: .stderr)
                }
            }
        }
    }

    /// Removes the sudoers entry (requires another admin auth dialog).
    func revokeAdminAccess() {
        let file = Self.sudoersFile
        Task.detached {
            _ = Self.runAdminAppleScript(shell: "rm -f '\(file)'")
            let exists = FileManager.default.fileExists(atPath: file)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.adminReady = exists
                self.appendLine(exists ? "! Could not revoke admin access." : "✓ Admin access revoked.",
                                type: exists ? .warning : .system)
            }
        }
    }

    /// Run a shell command with administrator privileges via Apple's `osascript` binary
    /// (a subprocess, not in-process NSAppleScript). osascript is Apple-signed and reliably
    /// presents the macOS auth dialog even when this app was launched detached from a shell
    /// (e.g. a debug build) — which in-process NSAppleScript cannot. Returns "" on success,
    /// otherwise the error text (e.g. a user cancellation) for the console.
    nonisolated static func runAdminAppleScript(shell: String) -> String {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do {
            try p.run()
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return "" }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "osascript exit \(p.terminationStatus)"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Public API

    /// Run a script, stream output to the in-app console.
    /// Set `interactive` for TUI tools that need a real PTY (arrow-key menus).
    func run(relativePath: String, args: [String] = [], basePath: String,
             label: String? = nil, interactive: Bool = false) {
        let scriptURL = URL(fileURLWithPath: basePath).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            appendLine("Script not found: \(scriptURL.path)", type: .stderr)
            return
        }
        let ext = scriptURL.pathExtension.lowercased()
        switch ext {
        case "sh":
            startProcess(
                executable: "/bin/bash",
                args: [scriptURL.path] + args,
                workDir: scriptURL.deletingLastPathComponent().path,
                label: label ?? scriptURL.lastPathComponent,
                interactive: interactive
            )
        case "py":
            startProcess(
                executable: "/usr/bin/env",
                args: ["python3", scriptURL.path] + args,
                workDir: scriptURL.deletingLastPathComponent().path,
                label: label ?? scriptURL.lastPathComponent,
                interactive: interactive
            )
        case "ps1":
            startProcess(
                executable: "/usr/bin/env",
                args: ["pwsh", "-File", scriptURL.path] + args,
                workDir: scriptURL.deletingLastPathComponent().path,
                label: label ?? scriptURL.lastPathComponent,
                interactive: interactive
            )
        default:
            appendLine("Unknown script type: \(ext)", type: .stderr)
        }
    }

    /// Run a script that needs sudo access.
    ///
    /// Scripts run as the current user. Any sudo calls inside them work silently
    /// because the NOPASSWD sudoers entry grants passwordless sudo for this user.
    /// Homebrew and tools that refuse to run as root are unaffected since the
    /// process itself runs as the normal user.
    func runPrivileged(relativePath: String, args: [String] = [], basePath: String, label: String) {
        guard !isRunning else {
            appendLine("A process is already running. Stop it first.", type: .warning)
            return
        }
        guard adminReady else {
            appendLine("This step needs admin access, which isn't set up on this Mac.", type: .warning)
            return
        }
        run(relativePath: relativePath, args: args, basePath: basePath, label: label)
    }

    /// Single entry point for running a phase's action. Centralizes the dispatch so
    /// the UI never has to branch on PhaseAction.
    func execute(_ phase: DemoPhase, basePath: String, ngrokToken: String, visionOneAPIKey: String) {
        if phase.isDestructive { labReady = false }   // teardown tears the lab down
        // Fresh screen for each new standalone run (batches clear once at their own start).
        if !isRunningAll && !isRunningAttacks { clear() }
        switch phase.action {
        case .console(let path, let args):
            if phase.requiresAdmin {
                runPrivileged(relativePath: path, args: args, basePath: basePath, label: phase.name)
            } else {
                run(relativePath: path, args: args, basePath: basePath, label: phase.name)
            }

        case .interactiveConsole(let path, let args):
            if phase.requiresAdmin && !adminReady {
                appendLine("This step needs admin access, which isn't set up on this Mac.", type: .warning)
                return
            }
            guard !isRunning else {
                appendLine("A process is already running. Stop it first.", type: .warning)
                return
            }
            let scriptURL = URL(fileURLWithPath: basePath).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                appendLine("Script not found: \(scriptURL.path)", type: .stderr)
                return
            }
            launchTerminal(executable: "/bin/bash",
                           args: [scriptURL.path] + args,
                           workDir: scriptURL.deletingLastPathComponent().path,
                           label: phase.name)

        case .background(let path, let args):
            Task { await runBackground(relativePath: path, args: args, basePath: basePath, label: phase.name) }

        case .openDocument(let path):
            openDocument(relativePath: path, basePath: basePath)

        case .configureAndRun(let path, let args):
            // Stage credentials (async, off-main) before launching the script.
            Task {
                await configureCredentials(ngrokToken: ngrokToken, visionOneAPIKey: visionOneAPIKey, basePath: basePath)
                if phase.requiresAdmin {
                    runPrivileged(relativePath: path, args: args, basePath: basePath, label: phase.name)
                } else {
                    run(relativePath: path, args: args, basePath: basePath, label: phase.name)
                }
            }
        }
    }

    /// Start a background process (server) — doesn't terminate automatically.
    func runBackground(relativePath: String, args: [String] = [], basePath: String, label: String) async {
        let scriptURL = URL(fileURLWithPath: basePath).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            appendLine("Script not found: \(scriptURL.path)", type: .stderr)
            return
        }
        if bgProcess?.isRunning == true {
            appendLine("Stopping previous background process...", type: .system)
            bgProcess?.interrupt()
            bgProcess = nil
            // Give the old process a moment to die without blocking the main thread.
            try? await Task.sleep(for: .milliseconds(500))
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", scriptURL.path] + args
        p.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        p.environment = CredentialManager.enrichedEnvironment()

        let pipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = errPipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.console.processOutput(text, isError: false) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.console.processOutput(text, isError: true) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.appendLine("\(label) exited (code \(proc.terminationStatus))",
                                 type: proc.terminationStatus == 0 ? .success : .stderr)
            }
        }

        appendLine("Starting \(label) (background)...", type: .system)
        do {
            try p.run()
            bgProcess = p
            appendLine("\(label) started (PID \(p.processIdentifier))", type: .success)
        } catch {
            appendLine("Failed to start: \(error.localizedDescription)", type: .stderr)
        }
    }

    // MARK: - Environment (multi-product) setup & teardown

    /// Set up the de-duplicated union of environment components for the products the
    /// user chose to include. Each component runs its own `configureAndRun` setup step
    /// (writing that component's own credentials), optionally followed by a status check.
    /// Drives the single "Set Up Environment" button on the Environment screen.
    ///
    /// The `--products` flag is scoped PER COMPONENT: each script receives only the
    /// slugs of selected products that component actually serves. This matters — the
    /// scanner's lab.sh treats a CSV with no slugs it recognizes as "install the full
    /// lab", so it must never see another lab's slug.
    func runEnvironmentSetup(_ components: [EnvironmentComponent],
                             selectedProducts: [DemoProject], basePath: String) {
        guard !isRunning else {
            appendLine("A process is already running — stop it first.", type: .warning)
            return
        }
        guard !components.isEmpty else {
            appendLine("Pick at least one product to include in the environment.", type: .system)
            return
        }

        var queue: [(DemoPhase, String, String, String)] = []
        var queuedComponentIDs: [String] = []
        for c in components {
            // Only the selected products THIS component serves.
            let scoped = selectedProducts.filter { c.neededBy.contains($0.name) }
            guard !scoped.isEmpty else { continue }
            let slugs = scoped.map(\.envSlug).filter { !$0.isEmpty }.sorted()
            let productFlag = slugs.isEmpty ? [] : ["--products", slugs.joined(separator: ",")]
            // The full scanner lab (ngrok tunnel + tmas CLI) is what needs the stored
            // keys; admin is opportunistic (helps a first-time Homebrew install) but
            // never blocks — see EnvironmentView.needsCreds.
            let installs = scoped.reduce(into: Set<String>()) { $0.formUnion($1.envInstalls) }
            let fullLab = !installs.isDisjoint(with: ["tmas"])

            let vk = UserDefaults.standard.string(forKey: c.visionOneKeyDefaults ?? "visionOneAPIKey") ?? ""
            let nk = UserDefaults.standard.string(forKey: c.ngrokKeyDefaults ?? "ngrokToken") ?? ""
            let setup = DemoPhase(
                name: c.title, description: c.detail, sfSymbol: c.sfSymbol, color: .indigo,
                action: .configureAndRun(relativePath: c.relativePath, args: c.setupArgs + productFlag),
                requiresCredentials: fullLab && c.requiresCredentials,
                requiresAdmin: (fullLab || adminReady) && c.requiresAdmin, role: .setup)
            queue.append((setup, basePath, nk, vk))
            queuedComponentIDs.append(c.id)
            if let statusArgs = c.statusArgs {
                let status = DemoPhase(
                    name: "\(c.title) — Status", description: "Verify the components are running.",
                    sfSymbol: "chart.bar.fill", color: .green,
                    action: .console(relativePath: c.relativePath, args: statusArgs + productFlag), role: .setup)
                queue.append((status, basePath, nk, vk))
            }
        }
        pendingSetupComponentIDs = queuedComponentIDs
        phaseQueue = queue
        isRunningAll = true
        runningTeardown = false
        clear()
        // Quiet, progress-bar mode: capture the verbose install/build output instead of
        // streaming it; show one milestone per component and a progress bar.
        quietBatch = true; quietTail = []; batchLabel = "Preparing…"
        let cfg = queue.filter {
            if case .configureAndRun = $0.0.action { return true } else { return false }
        }.count
        batchAllUnits = (cfg == 0)
        batchUnitsTotal = batchAllUnits ? queue.count : cfg
        batchUnitsDone = 0; progressFloor = 0; progressTarget = 0.03
        batchStart = Date(); batchElapsed = "0:00"
        startProgressTicker()
        appendLine("▶▶ Setting up the environment — \(components.count) component\(components.count == 1 ? "" : "s"). This can take a few minutes…", type: .system)
        dequeueNext()
    }

    /// Tear down the chosen environment components. `full` runs the deeper cleanup
    /// (remove the model, uninstall tooling) when a component defines one. Reuses the
    /// shared phase queue but flags itself so completion clears `labReady`.
    func runEnvironmentTeardown(_ components: [EnvironmentComponent], basePath: String, full: Bool) {
        guard !isRunning else {
            appendLine("A process is already running — stop it first.", type: .warning)
            return
        }
        pendingTeardownComponentIDs = components.map(\.id)
        var queue: [(DemoPhase, String, String, String)] = []
        for c in components {
            guard let args = full ? (c.fullTeardownArgs ?? c.teardownArgs) : c.teardownArgs else { continue }
            let phase = DemoPhase(
                name: "\(c.title) — Teardown", description: "", sfSymbol: "trash.fill", color: .red,
                action: .console(relativePath: c.relativePath, args: args), isDestructive: true, role: .teardown)
            queue.append((phase, basePath, "", ""))
        }
        guard !queue.isEmpty else {
            appendLine("Nothing to tear down.", type: .system)
            return
        }
        phaseQueue = queue
        isRunningAll = true
        runningTeardown = true
        if full { nukeInProgress = true }
        labReady = false
        clear()
        quietBatch = true; quietTail = []; batchLabel = "Tearing down…"
        let cfg = queue.filter {
            if case .configureAndRun = $0.0.action { return true } else { return false }
        }.count
        batchAllUnits = (cfg == 0)
        batchUnitsTotal = batchAllUnits ? queue.count : cfg
        batchUnitsDone = 0; progressFloor = 0; progressTarget = 0.03
        batchStart = Date(); batchElapsed = "0:00"
        startProgressTicker()
        appendLine("▶▶ Tearing down — \(queue.count) step\(queue.count == 1 ? "" : "s")\(full ? " (full)" : "")…", type: .system)
        dequeueNext()
    }

    /// Send one AI Guard attack payload. Two modes (set in Settings / the Attack Library):
    ///  • "api"   — POST the prompt to Trend's hosted applyGuardrails endpoint (cloud).
    ///  • "proxy" — POST an OpenAI request at the local tmguard proxy on 127.0.0.1:8443.
    /// Either way the response (decision + reasons / body) streams into the console.
    func runGuardAttack(category: String, prompt: String) {
        guard !isRunning else {
            appendLine("A process is already running. Stop it first.", type: .warning)
            return
        }
        // The mock enterprise is the model's standing context for every attack — sent silently
        // (never shown in the console), so the model already "knows" the data the attack targets.
        currentSystemPrompt = MockEnterprise.systemPrompt
        guardResponseAfterReply = false
        // AI Guard OFF — bypass the guardrail entirely and send the prompt straight to the
        // model, so the demo shows what happens unprotected.
        guard aiGuardEnabled else {
            runUnguarded(category: category, prompt: prompt)
            return
        }
        if aiGuardMode == "api" {
            runGuardAttackAPI(category: category, prompt: prompt)
        } else {
            runGuardAttackProxy(category: category, prompt: prompt)
        }
    }

    /// AI Guard OFF path — show the prompt, then call the model directly (no inspection).
    private func runUnguarded(category: String, prompt: String) {
        guardCancelled = false
        appendLine(category, type: .groupHeader)
        appendContextLine()
        appendLine("Prompt:  \(prompt)", type: .stdin, inGroup: true)
        appendLine("AI Guard OFF — sent straight to the model, no inspection.", type: .warning, inGroup: true)
        isRunning = true
        currentLabel = "Unguarded: \(category)"
        fetchModelReply(prompt: prompt)
    }

    /// Proxy mode — POST an OpenAI chat-completions request at the local tmguard proxy.
    /// A Block shows as HTTP 403 with a policy_block body; Redact shows [REDACTED] in the
    /// body; Allow/Alert return the model's answer.
    private func runGuardAttackProxy(category: String, prompt: String) {
        let endpoint = "http://127.0.0.1:8443/v1/chat/completions"
        // Pre-flight: is the proxy actually listening? If not, say so clearly instead
        // of letting curl fail with a cryptic "(7) Couldn't connect to server".
        guard isPortReachable(host: "127.0.0.1", port: 8443) else {
            warnProxyDown(port: 8443)
            if isRunningAttacks { isRunningAttacks = false; attackQueue.removeAll() }
            return
        }
        // Same loaded enterprise context the OFF path uses, so an Allowed prompt leaks the same
        // data. The system message is sent to the proxy but never shown in the console.
        var messages: [[String: String]] = [["role": "system", "content": MockEnterprise.systemPrompt]]
        messages.append(["role": "user", "content": prompt])
        let payload: [String: Any] = ["model": demoModelTag, "messages": messages, "max_tokens": 384]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            appendLine("Could not build the attack payload.", type: .stderr)
            return
        }
        // -i shows the response status/headers (so a 403 Block is visible); -sS keeps
        // curl quiet but still prints errors; no -f so HTTP 4xx bodies are shown.
        runGuardCurl(category: category, prompt: prompt, endpoint: endpoint,
                     args: ["-sS", "-i", "--max-time", "30", endpoint,
                            "-H", "Content-Type: application/json", "-d", json])
    }

    /// Hosted-API mode — POST the prompt to Trend's cloud applyGuardrails endpoint with
    /// your Vision One API key. No local proxy, policy, or model required; the API returns
    /// {"action": …, "reasons": […]}. The key is passed via a 0600 curl config file (-K),
    /// never on the command line — so it stays out of argv and the on-screen console.
    private func runGuardAttackAPI(category: String, prompt: String) {
        let key = aiGuardKey
        guard !key.isEmpty else {
            appendLine("⚠️ Set your AI Guard Vision One API Key in Settings (⌘,) to use the hosted API.", type: .warning)
            if isRunningAttacks { isRunningAttacks = false; attackQueue.removeAll() }
            return
        }
        let endpoint = aiGuardAPIEndpoint()
        guard let data = try? JSONSerialization.data(withJSONObject: ["prompt": prompt]),
              let json = String(data: data, encoding: .utf8) else {
            appendLine("Could not build the attack payload.", type: .stderr)
            return
        }
        guard let cfg = CredentialManager.writeAuthConfig(key) else {
            appendLine("Could not stage the API credentials.", type: .stderr)
            if isRunningAttacks { isRunningAttacks = false; attackQueue.removeAll() }
            return
        }
        runGuardCurl(category: category, prompt: prompt, endpoint: endpoint,
                     args: ["-sS", "-i", "--max-time", "30", endpoint,
                            "-K", cfg,
                            "-H", "Content-Type: application/json",
                            "-H", "TMV1-Application-Name: trend-demo-launcher",
                            "-H", "TMV1-Request-Type: SimpleRequestGuardrails",
                            "-H", "Prefer: return=representation",
                            "-H", "Accept: application/json",
                            "-d", json])
    }

    // MARK: - Guard attack execution + decision rendering

    /// True between stop() and the next runGuardCurl — suppresses the auto-rendered
    /// decision for an attack the user explicitly cancelled.
    private var guardCancelled = false

    /// The mock-enterprise context loaded into the model for the running attack, so the model
    /// call — in AI Guard OFF mode, or after an Allow — already has the data the attack targets
    /// and leaks it. Set to MockEnterprise.systemPrompt for every attack (and custom prompt).
    private var currentSystemPrompt: String?

    /// Set after a hosted-API prompt is Allowed: the model's reply must still be inspected
    /// (output guardrails) before it's shown — that's where data-disclosure risks are caught.
    private var guardResponseAfterReply = false

    /// Previously printed the per-attack seeded context. The mock enterprise is now loaded into
    /// the model as hidden standing context (see MockEnterprise), so there's nothing attack-
    /// specific to show — intentionally a no-op, kept so both run paths can still call it.
    private func appendContextLine() {}

    /// Run one guard-attack curl, capture the FULL response, and render a clean,
    /// color-coded verdict instead of raw headers + JSON. Drives the Run All queue.
    private func runGuardCurl(category: String, prompt: String, endpoint: String, args: [String]) {
        guardCancelled = false
        appendLine(category, type: .groupHeader)
        appendContextLine()
        appendLine("Prompt:  \(prompt)", type: .stdin, inGroup: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.environment = CredentialManager.enrichedEnvironment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        do {
            try p.run()
            // Close the parent's copy of the write end so readDataToEndOfFile() below sees
            // EOF when curl exits (otherwise the read can block forever and no verdict shows).
            try? pipe.fileHandleForWriting.close()
            process = p
            isRunning = true
            currentLabel = "Attack: \(category)"
        } catch {
            appendLine("Failed to start curl: \(error.localizedDescription)", type: .stderr)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let raw = String(data: data, encoding: .utf8) ?? ""
            let status = p.terminationStatus
            DispatchQueue.main.async {
                self?.finishGuardCurl(prompt: prompt, endpoint: endpoint, status: status, raw: raw)
            }
        }
    }

    private func finishGuardCurl(prompt: String, endpoint: String, status: Int32, raw: String) {
        process = nil
        if guardCancelled { guardCancelled = false; finalizeGuardStep(); return }

        // curl exits 0 for ANY HTTP response (including a 403 Block). A non-zero exit is a
        // real transport failure — the endpoint wasn't reachable.
        guard status == 0 else {
            let target = aiGuardMode == "api" ? "the AI Guard API" : "the proxy on 127.0.0.1:8443"
            appendLine("✗ Couldn't reach \(target) (curl exit \(status)).", type: .stderr)
            if isRunningAttacks {
                isRunningAttacks = false
                attackQueue.removeAll()
                appendLine("✗ Run All Attacks stopped.", type: .stderr)
            }
            finalizeGuardStep()
            return
        }

        let action = renderGuardDecision(raw: raw)

        // In hosted-API mode an Allow/Alert means the prompt is cleared to reach the model —
        // so fetch the model's real reply (the chosen demo behavior). Block/Redact never reach it.
        if aiGuardMode == "api" {
            if action == "Allow" || action == "Alert" {
                appendLine("↳ prompt cleared — inspecting the model's response…", type: .system, inGroup: true)
                guardResponseAfterReply = true       // step 2: inspect the OUTPUT (PII, harmful content)
                fetchModelReply(prompt: prompt)       // finalizes after the response guard completes
                return
            } else if action == "Block" || action == "Redact" {
                appendLine("↳ blocked at the guardrail — the model never saw this prompt.", type: .system, inGroup: true)
            }
        }
        finalizeGuardStep()
    }

    /// End one attack step: drop the running flag and, if a Run All sweep is active, advance.
    private func finalizeGuardStep() {
        isRunning = false
        currentLabel = nil
        if isRunningAttacks {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.dequeueNextAttack()
            }
        }
    }

    /// After an allowed prompt clears the guardrail, call local Ollama and show the model's
    /// reply — so the demo reads as a real conversation (benign → reply, attack → blocked).
    private func fetchModelReply(prompt: String) {
        guard isPortReachable(host: "127.0.0.1", port: 11434) else {
            appendLine("↳ (model not running — start it in Environment ▸ Set Up Environment, then re-run)", type: .system, inGroup: true)
            finalizeGuardStep()
            return
        }
        var messages: [[String: String]] = []
        if let sys = currentSystemPrompt, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": prompt])
        let payload: [String: Any] = [
            "model": demoModelTag,
            "messages": messages,
            "stream": false,
            // Bound the reply. The model has a 100-row directory in context and is told to
            // comply, so without a cap a "dump everything" leak runs to hundreds of lines (or
            // loops to the timeout) and floods the console. A short, representative leak is all
            // the demo needs to show the data escaping.
            "max_tokens": 384
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            finalizeGuardStep(); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-sS", "--max-time", "60", "http://127.0.0.1:11434/v1/chat/completions",
                       "-H", "Content-Type: application/json", "-d", json]
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.environment = CredentialManager.enrichedEnvironment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        do {
            try p.run()
            try? pipe.fileHandleForWriting.close()
            process = p
        } catch {
            appendLine("↳ (couldn't call the model: \(error.localizedDescription))", type: .stderr, inGroup: true)
            finalizeGuardStep(); return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let raw = String(data: d, encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.finishModelReply(raw: raw) }
        }
    }

    private func finishModelReply(raw: String) {
        process = nil
        if guardCancelled { guardCancelled = false; finalizeGuardStep(); return }
        let (_, body) = parseHTTPResponse(raw)
        // The model's actual reply, shown verbatim — nothing canned. If the model declined or
        // returned nothing, we say so truthfully rather than substituting a fabricated leak.
        guard let reply = extractChatReply(body), !reply.isEmpty else {
            appendLine("↳ (the model returned no reply)", type: .system, inGroup: true)
            finalizeGuardStep()
            return
        }

        // Hosted-API mode, step 2: inspect the model's real RESPONSE through AI Guard before
        // showing it. A benign prompt can still produce a reply that leaks PII — output
        // inspection is where that's caught. guardModelResponse renders + finalizes.
        if guardResponseAfterReply {
            guardResponseAfterReply = false
            guardModelResponse(reply)
            return
        }

        appendModelReply(reply)
        finalizeGuardStep()
    }

    /// Hosted-API mode, step 2: send the model's response to AI Guard (request type
    /// OpenAIChatCompletionResponseV1) to catch OUTPUT-side risks — chiefly sensitive-data
    /// disclosure (SSNs, cards) that a clean prompt sails past on the input check. Renders the
    /// verdict, only shows the reply if it's cleared, and finalizes the step.
    private func guardModelResponse(_ reply: String) {
        let key = aiGuardKey
        guard !key.isEmpty else { appendModelReply(reply); finalizeGuardStep(); return }
        // Wrap the raw reply in the OpenAI chat-completion response shape the API expects.
        let wrapper: [String: Any] = [
            "id": "chatcmpl-demo", "object": "chat.completion", "created": 0, "model": demoModelTag,
            "choices": [["index": 0, "finish_reason": "stop",
                         "message": ["role": "assistant", "content": reply, "refusal": NSNull()]]],
            "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper) else {
            appendModelReply(reply); finalizeGuardStep(); return
        }
        let endpoint = aiGuardAPIEndpoint()
        Task { [weak self] in
            guard let self else { return }
            let (code, respBody) = await self.postGuardResponse(endpoint: endpoint, key: key, body: data)
            await MainActor.run {
                self.renderResponseGuard(code: code, body: respBody, reply: reply)
                self.finalizeGuardStep()
            }
        }
    }

    /// POST the model's response to applyGuardrails for OUTPUT inspection. URLSession (not curl)
    /// so the key rides an in-process Authorization header — never on argv or the on-screen console.
    nonisolated private func postGuardResponse(endpoint: String, key: String, body: Data) async -> (code: Int, body: String) {
        guard let url = URL(string: endpoint) else { return (0, "") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("trend-demo-launcher", forHTTPHeaderField: "TMV1-Application-Name")
        req.setValue("OpenAIChatCompletionResponseV1", forHTTPHeaderField: "TMV1-Request-Type")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (0, "")
        }
    }

    /// Render the OUTPUT verdict. Block/Redact = AI Guard caught a leak in the reply, so the
    /// reply is withheld. Allow = output is clean, shown as-is.
    private func renderResponseGuard(code: Int, body: String, reply: String) {
        let (action, reason) = guardDecision(code: code, body: body)
        if action == "Block" || action == "Redact" {
            appendLine("🛑  RESPONSE BLOCKED — AI Guard flagged the model's reply", type: .stderr, inGroup: true)
            if let reason, !reason.isEmpty {
                appendLine("↳ \(reason)", type: .system, inGroup: true)
            }
            appendLine("↳ the app withholds the reply on a Block verdict — the data isn't shown.", type: .system, inGroup: true)
        } else if action == "Unknown" {
            appendLine("↳ (couldn't inspect the response — showing it unguarded)", type: .warning, inGroup: true)
            appendModelReply(reply)
        } else {
            appendModelReply(reply)   // output cleared — safe to show
        }
    }

    /// Render the model's reply as part of the attack group: every line carries the group
    /// spine and is capped so a long dump (e.g. a code block) doesn't flood the console.
    private func appendModelReply(_ reply: String) {
        // Hard-cap what we render. Even with max_tokens set, a leak can be long, and pushing
        // hundreds of lines into the console one-by-one bogs the UI down — so show the first
        // chunk and summarize the rest. This is purely a display guard; the leak still happened.
        let maxRows = 16
        let allRows = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rows = Array(allRows.prefix(maxRows))
        // A clear boundary line so the prompt (above) and the model's output (below) are never
        // mistaken for one another — the whole indented block that follows is one single reply.
        appendLine("💬 Model reply ↓ (everything below is the model's single response)", type: .system, inGroup: true)
        for row in rows {
            appendLine("   \(row)", type: .stdout, inGroup: true)
        }
        if allRows.count > maxRows {
            appendLine("   … (+\(allRows.count - maxRows) more lines — leak truncated for display)", type: .system, inGroup: true)
        }
    }

    /// Pull choices[0].message.content out of an OpenAI-compatible chat-completion body.
    private func extractChatReply(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Split a raw `curl -i` response into (last HTTP status code, body). Handles a
    /// 100-Continue preamble by taking the final status line and the final header/body split.
    private func parseHTTPResponse(_ raw: String) -> (code: Int, body: String) {
        let norm = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var code = 0
        for line in norm.split(separator: "\n") where line.hasPrefix("HTTP/") {
            let parts = line.split(separator: " ")
            if parts.count >= 2, let c = Int(parts[1]) { code = c }
        }
        if let r = norm.range(of: "\n\n", options: .backwards) {
            return (code, String(norm[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (code, norm.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    /// Derive (action, short human reason) from the response. The hosted API returns
    /// {"action": …, "reasons": ["Prompt attack detected", …], "harmfulContent":[{category,
    /// hasPolicyViolation, …}]}. The proxy signals Block via HTTP 403 / policy_block and
    /// Redact via a [REDACTED] body (Allow vs Alert is only distinguishable in Vision One).
    private func guardDecision(code: Int, body: String) -> (action: String, reason: String?) {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let action = obj["action"] as? String {
                var parts: [String] = []
                if let reasons = obj["reasons"] as? [Any] {
                    parts += reasons.compactMap {
                        ($0 as? String) ?? (($0 as? [String: Any])?["description"] as? String)
                    }
                }
                if parts.isEmpty, let harmful = obj["harmfulContent"] as? [[String: Any]] {
                    let violated = harmful
                        .filter { ($0["hasPolicyViolation"] as? Bool) == true }
                        .compactMap { $0["category"] as? String }
                    if !violated.isEmpty { parts.append(violated.joined(separator: ", ")) }
                }
                let reason = parts.isEmpty ? nil : truncate(parts.joined(separator: " · "), 160)
                return (action, reason)
            }
            if let err = obj["error"] as? [String: Any] {
                let d = [err["code"] as? String, err["category"] as? String]
                    .compactMap { $0 }.joined(separator: " · ")
                return ("Block", d.isEmpty ? nil : d)
            }
        }
        if code == 403 { return ("Block", "policy_block") }
        if body.contains("[REDACTED]") { return ("Redact", nil) }
        if code == 200 { return ("Allow", nil) }
        return ("Unknown", nil)
    }

    /// Render the verdict — the prompt is already shown above. No raw JSON, so the console
    /// stays demo-readable: a color-coded action + a short reason. Returns the action so the
    /// caller can decide whether to fetch a model reply. In proxy mode the model's reply is
    /// already in the response body, so show it here.
    @discardableResult
    private func renderGuardDecision(raw: String) -> String {
        let (code, body) = parseHTTPResponse(raw)
        let (action, reason) = guardDecision(code: code, body: body)

        let icon: String, type: LineType
        switch action {
        case "Block":  icon = "🛑"; type = .stderr
        case "Redact": icon = "✂️"; type = .warning
        case "Alert":  icon = "⚠️"; type = .warning
        case "Allow":  icon = "✅"; type = .success
        default:       icon = "•";  type = .stdout
        }
        let head = "\(icon)  \(action.uppercased())"
        appendLine(head, type: type, inGroup: true)

        if let reason = reason, !reason.isEmpty {
            appendLine("↳ \(reason)", type: .system, inGroup: true)
        }
        // Proxy mode: the response body IS the model's chat completion — surface its reply.
        if aiGuardMode != "api", action == "Allow" || action == "Alert" {
            if let reply = extractChatReply(body) {
                appendModelReply(reply)
            } else {
                appendLine("↳ forwarded to the model (Allow vs Alert is recorded in Vision One ▸ Activity)", type: .system, inGroup: true)
            }
        }
        return action
    }

    /// Fire the whole attack library through the proxy, one payload after another.
    /// Each request runs to completion before the next; a failed request (e.g. the
    /// proxy isn't running) stops the run rather than spamming connection errors.
    func runAllGuardAttacks(_ attacks: [GuardAttack]) {
        guard !isRunning else {
            appendLine("A process is already running. Stop it first.", type: .warning)
            return
        }
        guard !attacks.isEmpty else { return }
        if !aiGuardEnabled {
            guard isPortReachable(host: "127.0.0.1", port: 11434) else {
                appendLine("⚠️ Ollama isn't running on 127.0.0.1:11434 — run AI Scanner ▸ Setup Environment (needed to send prompts to the model with AI Guard off).", type: .warning)
                return
            }
        } else if aiGuardMode == "api" {
            guard !aiGuardKey.isEmpty else {
                appendLine("⚠️ Set your AI Guard Vision One API Key in Settings (⌘,) to use the hosted API.", type: .warning)
                return
            }
        } else {
            guard isPortReachable(host: "127.0.0.1", port: 8443) else {
                warnProxyDown(port: 8443)
                return
            }
        }
        attackQueue = attacks
        attackTotal = attacks.count
        attackIndex = 0
        isRunningAttacks = true
        clear()
        let via = !aiGuardEnabled ? "straight to the model (AI Guard OFF)"
                : aiGuardMode == "api" ? "the hosted AI Guard API" : "the local proxy"
        appendLine("▶▶ Run All Attacks — \(attacks.count) payloads through \(via)", type: .system)
        dequeueNextAttack()
    }

    private func dequeueNextAttack() {
        guard !attackQueue.isEmpty else {
            isRunningAttacks = false
            appendLine("✓ All attacks sent — review the decisions above and in Vision One.", type: .success)
            return
        }
        attackIndex += 1
        runAttack(attackQueue.removeFirst())
    }

    /// Run an attack with a freshly-generated, clean prompt (same family, new wording each
    /// time). The data it targets is already loaded into the model (see MockEnterprise).
    func runAttack(_ attack: GuardAttack) {
        if !isRunningAttacks && !isRunningAll { clear() }   // fresh screen for a single attack
        let prompt = uniqueGenerated(for: attack)
        // In a Run-All sequence, number the card header so each attack is easy to tell apart.
        let label = (isRunningAttacks && attackTotal > 1)
            ? "Attack \(attackIndex) of \(attackTotal)  ·  \(attack.category)"
            : attack.category
        runGuardAttack(category: label, prompt: prompt)
    }

    /// Every prompt ever generated this session — used so the same one is never sent twice.
    private var usedPrompts: Set<String> = []

    /// Generate a fresh attack prompt of the attack's family, never one already used this
    /// session. Uniqueness is keyed on the prompt text (the data it targets now lives in the
    /// model's loaded enterprise context, not in the prompt).
    private func uniqueGenerated(for attack: GuardAttack) -> String {
        for _ in 0..<50 {
            let p = attack.kind.generate()
            if usedPrompts.insert(p).inserted { return p }
        }
        var p = attack.kind.generate()
        while !usedPrompts.insert(p).inserted { p += " " }   // guarantee uniqueness
        return p
    }

    private func warnProxyDown(port: UInt16) {
        appendLine("⚠️ AI Guard proxy isn't running on 127.0.0.1:\(port).", type: .warning)
        appendLine("   Run \"Start AI Guard Proxy\" (or \"Run Setup\") in Environment first, then try again.", type: .system)
    }

    /// Start polling whether the local model is up, so the Run buttons can gate on it.
    /// Cheap on localhost — a refused/accepted connect returns in ~milliseconds.
    func startModelMonitor() {
        refreshWizardEndpoint()   // populate the wizard endpoint if the lab is already up
        refreshModelRunning()
        autoStartModelIfNeeded()  // bring the model back up if it's installed but the server is down
        modelTimer?.invalidate()
        // Poll every 10s (not 3s): the model keeps alive for 30m, so tighter polling just
        // spawns needless URLSession probes. State only re-renders on an actual change.
        modelTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refreshModelRunning()
        }
    }

    nonisolated private func refreshModelRunning() {
        Task { [weak self] in
            guard let self else { return }
            let up = await self.isModelAvailable()
            await MainActor.run {
                if self.modelRunning != up { self.modelRunning = up }
            }
        }
    }

    /// On launch, if the lab is installed (Ollama present + a model already downloaded) but the
    /// server is down, start `ollama serve` ourselves — so reopening the app "just works" without
    /// re-running Set Up Environment. Attempted at most once per session; a no-op if the server is
    /// already up or no model was ever downloaded (that case genuinely needs full setup).
    func autoStartModelIfNeeded() {
        guard !didAutoStartModel else { return }
        didAutoStartModel = true
        Task.detached { [weak self] in
            guard let self else { return }
            // Already serving? Flip to ready now and warm the cache in the background, so a
            // first attack after a long idle is still snappy.
            if await self.isModelAvailable() {
                await MainActor.run { self.modelRunning = true }
                await self.warmUpModel()
                return
            }
            guard self.ollamaBinaryPath() != nil, self.isModelDownloadedOnDisk() else { return }
            await MainActor.run { self.modelStarting = true }
            self.spawnOllamaServe()
            // Wait for the server to accept connections.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.isPortReachable(host: "127.0.0.1", port: 11434) { break }
            }
            // Prime the model: load it into memory AND warm the big enterprise system-prompt
            // cache, so the FIRST attack reuses the cached prefix (~0.3s) instead of paying the
            // ~4s cold prompt-eval. Held behind "Starting model…" so the cost is hidden.
            await self.warmUpModel()
            let up = await self.isModelAvailable()
            await MainActor.run {
                self.modelStarting = false
                self.modelRunning = up
            }
        }
    }

    /// Load the model and warm the enterprise system-prompt cache with a 1-token request. The
    /// big system prompt (~2.8k tokens) is evaluated once here; Ollama then reuses that cached
    /// prefix on every later attack (measured ~0.3s warm vs ~4s cold). No-op-cheap if warm.
    nonisolated private func warmUpModel() async {
        let payload: [String: Any] = [
            "model": demoModelTag,
            "stream": false,
            "max_tokens": 1,
            "messages": [
                ["role": "system", "content": MockEnterprise.systemPrompt],
                ["role": "user", "content": "Ready?"]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 60
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Launch the Ollama server detached — same invocation as lab.sh's start_ollama, logging to
    /// the lab's log file. `bash -lc … &` backgrounds it and returns immediately, so the server
    /// outlives this short-lived helper process.
    nonisolated private func spawnOllamaServe() {
        let home = NSHomeDirectory()
        let script = "mkdir -p \"\(home)/.trend-lab\"; "
                   + "OLLAMA_HOST=0.0.0.0:11434 OLLAMA_ORIGINS=* OLLAMA_KEEP_ALIVE=30m "
                   + "nohup ollama serve > \"\(home)/.trend-lab/ollama.log\" 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", script]
        p.environment = CredentialManager.enrichedEnvironment()
        try? p.run()   // do not wait — bash backgrounds ollama and exits
    }

    /// The Ollama binary, if installed in a user-writable location we know about.
    nonisolated private func ollamaBinaryPath() -> String? {
        for path in ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                     "\(NSHomeDirectory())/.local/bin/ollama"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// True if at least one model has been pulled to disk (so the server has something to serve).
    /// Models live under ~/.ollama and survive both the server stopping and the app quitting.
    nonisolated private func isModelDownloadedOnDisk() -> Bool {
        let base = "\(NSHomeDirectory())/.ollama/models/manifests/registry.ollama.ai"
        return ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).isEmpty == false
    }

    /// True only when the lab is genuinely usable: Ollama is serving AND the demo model is
    /// actually pulled. A real probe of the machine — so the Environment status and the Run
    /// buttons reflect reality (after an app restart, or a nuke that left the server up but
    /// wiped the models), not whether someone clicked "Set Up" this session.
    /// Uses URLSession instead of spawning a `curl` subprocess every poll.
    nonisolated private func isModelAvailable() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        req.timeoutInterval = 2
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let body = String(data: data, encoding: .utf8) ?? ""
            let base = demoModelTag.split(separator: ":").first.map(String.init) ?? demoModelTag
            return body.contains(demoModelTag) || body.contains(base)
        } catch {
            return false
        }
    }

    /// Quick non-blocking TCP reachability check (≤ ~0.6 s). Used to tell whether the
    /// AI Guard proxy is up before firing an attack, so we can show a clear message
    /// rather than a raw curl connection error.
    nonisolated private func isPortReachable(host: String, port: UInt16, timeout: TimeInterval = 0.6) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }            // connected immediately
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, nfds_t(1), Int32(timeout * 1000)) > 0,
              (pfd.revents & Int16(POLLOUT)) != 0 else { return false }

        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return soErr == 0
    }

    /// Stop the running foreground process.
    func stop() {
        guardCancelled = true   // suppress the auto-rendered verdict for a cancelled attack
        process?.interrupt()
        if terminalLaunch != nil {
            // User stopped the interactive scan. Signal the whole process tree, then
            // return to a clean console immediately — so tmas's raw "user aborted" text
            // (just its way of reporting a cancel) isn't left on screen looking like a
            // failure. A natural completion keeps the terminal + Close button instead.
            scanWatchdog?.invalidate(); scanWatchdog = nil
            terminateTerminal?()
            terminateTerminal = nil
            terminalLaunch    = nil
            isRunning         = false
            currentLabel      = nil
            appendLine("⏹ Scan stopped.", type: .system)
        } else {
            terminateTerminal?()
        }
        if isRunningAll {
            isRunningAll = false
            phaseQueue.removeAll()
            appendLine("⏹ Run All cancelled.", type: .system)
        }
        if isRunningAttacks {
            isRunningAttacks = false
            attackQueue.removeAll()
            appendLine("⏹ Run All Attacks cancelled.", type: .system)
        }
    }

    // MARK: - Embedded Terminal Session

    /// Launch an interactive session inside the embedded SwiftTerm view. The actual
    /// process is owned by the terminal view; we just track UI state here.
    func launchTerminal(executable: String, args: [String], workDir: String, label: String) {
        isRunning     = true
        isInteractive = false   // the SwiftTerm view handles its own keyboard input
        currentLabel  = label
        appendLine("▶ \(label) — interactive terminal session", type: .system)
        terminalLaunch = TerminalLaunch(executable: executable, args: args,
                                        workDir: workDir, label: label)
        startScanCompletionWatchdog()
    }

    /// Belt-and-suspenders completion detection for the interactive scan. The terminal's own exit
    /// callback (processTerminated) is the primary signal, but if it's late or missed — a known PTY
    /// edge case — the run would look stuck as "running" forever. So we also watch for the sentinel
    /// lab.sh writes the instant the scan fully finishes, and finalize the UI from that.
    private func startScanCompletionWatchdog() {
        scanWatchdog?.invalidate()
        let sentinel = "\(NSHomeDirectory())/.trend-lab/scan-complete"
        let launchedAt = Date()
        scanWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.isRunning, self.terminalLaunch != nil else { timer.invalidate(); return }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: sentinel),
                  let modified = attrs[.modificationDate] as? Date,
                  modified >= launchedAt.addingTimeInterval(-2) else { return }   // ignore a stale sentinel
            timer.invalidate()
            self.scanWatchdog = nil
            // Let the final lines flush, then leave the running state (keep the terminal on screen
            // showing results until the user closes it).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if self.isRunning { self.terminalDidExit(code: 0) }
            }
        }
    }

    /// Called by the terminal view when its child process exits. The terminal stays
    /// on screen showing the final output until the user closes it.
    func terminalDidExit(code: Int32?) {
        // If stop() already tore down the session — or the watchdog already finalized — ignore this
        // (possibly late/duplicate) exit callback.
        guard terminalLaunch != nil, isRunning else { return }
        scanWatchdog?.invalidate(); scanWatchdog = nil
        let c = code ?? 0
        appendLine(c == 0 ? "✓ Terminal session ended." : "✗ Terminal exited (code \(c)).",
                   type: c == 0 ? .success : .stderr)
        isRunning        = false
        currentLabel     = nil
        terminateTerminal = nil
    }

    /// Dismiss the embedded terminal and return to the line console.
    func closeTerminal() {
        scanWatchdog?.invalidate(); scanWatchdog = nil
        terminateTerminal?()
        terminalLaunch    = nil
        terminateTerminal = nil
        if isRunning { isRunning = false; currentLabel = nil }
    }

    /// Stop background server process.
    func stopBackground() {
        guard bgProcess?.isRunning == true else { return }
        bgProcess?.interrupt()
        bgProcess = nil
        appendLine("Background server stopped.", type: .system)
    }

    /// Clear the console.
    func clear() {
        console.clear()
        currentLabel = nil
        isInteractive = false
    }

    /// Route subprocess output: stream to the console normally, or — during a quiet
    /// setup/teardown batch — capture only a rolling tail (revealed if the step fails) so
    /// the screen stays a clean progress bar instead of a wall of build/install log lines.
    private func ingestOutput(_ rawText: String, isError: Bool) {
        var text = rawText
        // Control markers drive the progress bar and are never shown:
        //   @@STATUS <label>        — a scan's current step label (no real fraction)
        //   @@STEP <n> <total> <l>  — a real phase boundary from lab.sh (anchors the bar)
        if text.contains("@@STATUS") || text.contains("@@STEP") {
            var kept: [Substring] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("@@STATUS ") { handleStatus(line) }
                else if line.hasPrefix("@@STEP ") { handleStep(line) }
                else { kept.append(line) }
            }
            text = kept.joined(separator: "\n")
            if text.isEmpty { return }
        }
        guard quietBatch else {
            console.processOutput(text, isError: isError)
            return
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            quietTail.append(String(line))
        }
        if quietTail.count > 80 { quietTail.removeFirst(quietTail.count - 80) }
    }

    private func handleStatus(_ line: Substring) {
        batchLabel = String(line.dropFirst("@@STATUS ".count))
        if progressTimer == nil { startProgressTicker() }   // first status → begin the smooth fill
    }

    /// "@@STEP n total label" — a real phase boundary announced by lab.sh. Anchors the bar to
    /// actual work: floor = phases already done, creep target = this phase's end, label = what's
    /// happening now. This is what keeps a long step (e.g. the model pull) reading as active and
    /// stops the bar from parking at a meaningless ceiling.
    private func handleStep(_ line: Substring) {
        let parts = line.dropFirst("@@STEP ".count).split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let n = Int(parts[0]), let total = Int(parts[1]), total > 0 else { return }
        if parts.count >= 3 { batchLabel = String(parts[2]) }
        let units = Double(max(batchUnitsTotal, 1))
        let base  = Double(batchUnitsDone)
        progressFloor  = min(0.98, (base + Double(n - 1) / Double(total)) / units)
        progressTarget = min(0.98, (base + Double(n)     / Double(total)) / units)
        if let p = batchProgress, p < progressFloor { batchProgress = progressFloor }
        if progressTimer == nil { startProgressTicker() }
    }

    /// Smooth, time-based fill. The bar creeps toward a ceiling continuously (~1% at a time,
    /// easing as it nears the top) so it reflects overall completion instead of jumping at each
    /// task boundary. Actual completion snaps it to 100% (see `completeProgress`).
    /// Smooth fill that eases toward `progressTarget` (a real phase boundary) but never drops
    /// below `progressFloor`, and always keeps a small forward creep so it never looks frozen.
    /// Also refreshes the `m:ss` elapsed heartbeat every tick.
    private func startProgressTicker() {
        if batchProgress == nil { batchProgress = 0.0 }
        if batchStart == nil { batchStart = Date() }
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let start = self.batchStart {
                let s = Int(Date().timeIntervalSince(start))
                self.batchElapsed = String(format: "%d:%02d", s / 60, s % 60)
            }
            guard var p = self.batchProgress else { return }
            if p < self.progressFloor { p = self.progressFloor }               // snap up to real progress
            if p < self.progressTarget {                                       // ease toward the boundary
                p = min(self.progressTarget, p + max(0.0012, (self.progressTarget - p) * 0.03))
            }
            self.batchProgress = p
        }
    }

    private func resetProgressState() {
        progressTimer?.invalidate(); progressTimer = nil
        progressFloor = 0; progressTarget = 0.92
        batchUnitsTotal = 0; batchUnitsDone = 0
        batchAllUnits = false; currentIsUnit = false
        batchStart = nil
    }

    /// Abort / failure: stop the fill and hide the bar immediately.
    private func endQuietBatch() {
        resetProgressState()
        quietBatch = false
        batchProgress = nil
        batchLabel = ""
        batchElapsed = ""
        quietTail = []
    }

    /// Success: snap the bar to 100%, then fade it out a beat later.
    private func completeProgress() {
        progressTimer?.invalidate(); progressTimer = nil
        quietBatch = false
        quietTail = []
        progressFloor = 1.0; progressTarget = 1.0
        batchProgress = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.batchProgress == 1.0 else { return }
            self.resetProgressState()
            self.batchProgress = nil
            self.batchLabel = ""
            self.batchElapsed = ""
        }
    }

    private func phaseCountsAsUnit(_ phase: DemoPhase) -> Bool {
        if batchAllUnits { return true }
        if case .configureAndRun = phase.action { return true }
        return false
    }

    /// Write the Vision One API key to its expected config location, then report progress to
    /// the console. The file I/O lives in CredentialManager. (No tunnel or extra token exists,
    /// so the key is the only thing to pre-configure.)
    func configureCredentials(ngrokToken: String, visionOneAPIKey: String, basePath: String) async {
        _ = (ngrokToken, basePath)   // retained in the signature; unused (no tunnel/token needed)
        // Only write the TMAS key file when we actually have a key — an AI Guard-only
        // setup passes none (it never runs tmas), so don't drop an empty key on disk.
        if !visionOneAPIKey.isEmpty {
            if let err = CredentialManager.writeTMASKey(visionOneAPIKey) {
                appendLine("✗ Could not write ~/.tmas/.env: \(err)", type: .stderr)
            } else {
                appendLine("✓ Vision One API key written to ~/.tmas/.env", type: .success)
            }
        }
    }

    // MARK: - Interactive Input

    /// Send raw bytes directly to the PTY master (stdin of the running process).
    func sendRawInput(_ data: Data) {
        let fd = ptyMasterFD
        guard fd >= 0 else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = Darwin.write(fd, base, data.count)
        }
    }

    /// Echo text to the console, then send it as a line of stdin to the process.
    func sendInput(_ text: String) {
        appendLine("> \(text)", type: .stdin)
        sendRawInput((text + "\r").data(using: .utf8) ?? Data())
    }

    /// Open a file with the default macOS application.
    func openDocument(relativePath: String, basePath: String) {
        let url = URL(fileURLWithPath: basePath).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert = AlertInfo(title: "File Not Found",
                              message: "Could not locate:\n\(url.path)\n\nCheck Settings → Projects Folder.")
            return
        }
        NSWorkspace.shared.open(url)
        appendLine("Opened: \(url.lastPathComponent)", type: .system)
    }

    // MARK: - Private: Process Execution

    private func dequeueNext() {
        guard !phaseQueue.isEmpty else {
            isRunningAll = false
            completeProgress()   // batch done → fill the bar to 100%, then fade; resume streaming
            if runningTeardown {
                runningTeardown = false
                labReady = false
                // Update the installed-components record: a full nuke clears it entirely; a
                // quick teardown removes just the components it targeted.
                var installed = Set(UserDefaults.standard.stringArray(forKey: Self.installedComponentsKey) ?? [])
                if nukeInProgress { installed.removeAll() } else { installed.subtract(pendingTeardownComponentIDs) }
                UserDefaults.standard.set(Array(installed), forKey: Self.installedComponentsKey)
                pendingTeardownComponentIDs = []
                // A full nuke may have removed the admin-access grant — re-read it so
                // Settings reflects reality without needing a restart.
                adminReady = FileManager.default.fileExists(atPath: "/etc/sudoers.d/trenddemo-launcher")
                if nukeInProgress {
                    nukeInProgress = false
                    clearAppSettings()
                    appendLine("✓ All settings cleared.", type: .system)
                }
                appendLine("✓ Teardown complete.", type: .success)
            } else {
                labReady = true   // setup sequence finished cleanly → lab is ready
                // Remember exactly what was set up so a later Quick Teardown targets only these.
                var installed = Set(UserDefaults.standard.stringArray(forKey: Self.installedComponentsKey) ?? [])
                installed.formUnion(pendingSetupComponentIDs)
                UserDefaults.standard.set(Array(installed), forKey: Self.installedComponentsKey)
                pendingSetupComponentIDs = []
                refreshWizardEndpoint()   // capture the fresh ngrok tunnel URL
                appendLine("✓ Setup complete — lab is ready.", type: .success)
            }
            return
        }
        let next = phaseQueue.removeFirst()
        currentIsUnit = phaseCountsAsUnit(next.0)
        execute(next.0, basePath: next.1, ngrokToken: next.2, visionOneAPIKey: next.3)
    }

    private func startProcess(executable: String, args: [String], workDir: String, label: String,
                             interactive: Bool = false) {
        guard !isRunning else {
            appendLine("A process is already running. Stop it first.", type: .warning)
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)

        var env = CredentialManager.enrichedEnvironment()
        var allocatedMasterFD: Int32 = -1
        var allocatedSlaveFD:  Int32 = -1   // tracked so parent can close its copy after fork

        // Only interactive phases (the TUI scan wizard) get a real PTY so arrow-key
        // menus work. Everything else uses pipes — they stream output reliably and
        // never block on TTY-gated prompts or emit curses redraw noise.
        if interactive {
            let rawMaster = posix_openpt(O_RDWR | O_NOCTTY)
            if rawMaster >= 0 && grantpt(rawMaster) == 0 && unlockpt(rawMaster) == 0,
               let slavePtr = ptsname(rawMaster) {
                let slaveFD = open(String(cString: slavePtr), O_RDWR)
                if slaveFD >= 0 {
                    // Turn off PTY echo so we control what's displayed.
                    var tios = termios()
                    tcgetattr(slaveFD, &tios)
                    tios.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ECHOE) | tcflag_t(ECHOK) | tcflag_t(ECHONL))
                    tcsetattr(slaveFD, TCSANOW, &tios)
                    // Give the TUI a wide pseudo-window.
                    var ws = winsize(ws_row: 50, ws_col: 220, ws_xpixel: 0, ws_ypixel: 0)
                    withUnsafeMutablePointer(to: &ws) { _ = ioctl(rawMaster, TIOCSWINSZ, $0) }

                    env["TERM"] = "xterm-256color"
                    p.environment = env

                    // closeOnDealloc: false — we close slaveFD explicitly after p.run()
                    // so the parent doesn't keep the slave side open (which would block EIO).
                    let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
                    p.standardInput  = slaveHandle
                    p.standardOutput = slaveHandle
                    p.standardError  = slaveHandle
                    allocatedMasterFD = rawMaster
                    allocatedSlaveFD  = slaveFD
                } else {
                    Darwin.close(rawMaster)
                }
            } else if rawMaster >= 0 {
                Darwin.close(rawMaster)
            }
        }

        // Default path (and PTY fallback): named pipes.
        if allocatedMasterFD < 0 {
            p.environment = env
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            p.standardOutput = stdoutPipe
            p.standardError  = stderrPipe
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.ingestOutput(text, isError: false) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.ingestOutput(text, isError: true) }
            }
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning     = false
                self.isInteractive = false
                let finishedLabel  = self.currentLabel
                self.currentLabel  = nil
                let status = proc.terminationStatus

                // Quiet setup/teardown batch: no generic per-phase line. The bar fills smoothly
                // on a timer (not per component); we just log one ✓ milestone per component and
                // reveal captured output only on failure.
                if self.quietBatch {
                    if status == 0 {
                        if self.currentIsUnit {   // a real work unit finished → advance the floor
                            self.batchUnitsDone += 1
                            let units = Double(max(self.batchUnitsTotal, 1))
                            self.progressFloor  = min(0.98, Double(self.batchUnitsDone) / units)
                            self.progressTarget = min(0.98, self.progressFloor + (1.0 / units) * 0.85)
                        }
                        if let finishedLabel { self.appendLine("✓ \(finishedLabel)", type: .success) }
                        self.quietTail = []
                        self.dequeueNext()   // advances; completes the bar when the queue empties
                    } else {
                        self.appendLine("✗ \(finishedLabel ?? "Step") failed (exit \(status)). Recent output:", type: .stderr)
                        for ln in self.quietTail.suffix(40) { self.console.processOutput(ln + "\n", isError: true) }
                        self.isRunningAll = false
                        self.phaseQueue.removeAll()
                        self.endQuietBatch()
                    }
                    return
                }

                // A single progress-bar run (e.g. a live scan) prints its own summary, so finish
                // the bar (100% on success, hide on failure) and skip the generic completion line.
                let wasProgress = self.batchProgress != nil
                if wasProgress {
                    if status == 0 { self.completeProgress() } else { self.endQuietBatch() }
                }
                if !wasProgress {
                    self.appendLine(
                        status == 0 ? "✓ Completed successfully." : "✗ Exited with code \(status).",
                        type: status == 0 ? .success : .stderr
                    )
                }
                if self.isRunningAll == true {
                    if status == 0 {
                        self.dequeueNext()
                    } else {
                        self.isRunningAll = false
                        self.phaseQueue.removeAll()
                        self.appendLine("✗ Run All stopped — phase failed.", type: .stderr)
                    }
                } else if self.isRunningAttacks == true {
                    // curl exits 0 even for an HTTP 403 Block (that's a real decision),
                    // so a non-zero exit means the request itself failed (proxy down).
                    if status == 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            self?.dequeueNextAttack()
                        }
                    } else {
                        self.isRunningAttacks = false
                        self.attackQueue.removeAll()
                        let hint = self.aiGuardMode == "api"
                            ? "couldn't reach the AI Guard API — check your network."
                            : "couldn't reach the proxy. Run \"Start AI Guard Proxy\" in Environment first."
                        self.appendLine("✗ Run All Attacks stopped — \(hint)", type: .stderr)
                    }
                }
            }
        }

        if !quietBatch { appendLine("▶ \(label) \(args.joined(separator: " "))", type: .system) }
        do {
            try p.run()
            // Close the parent's copy of the slave FD now that the child has inherited it.
            // Keeping it open would prevent the read loop from ever seeing EIO.
            if allocatedSlaveFD >= 0 { Darwin.close(allocatedSlaveFD) }

            process      = p
            isRunning    = true
            currentLabel = label
            if quietBatch { batchLabel = label }

            if allocatedMasterFD >= 0 {
                ptyMasterFD   = allocatedMasterFD
                isInteractive = true
                let capFD = allocatedMasterFD
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = Darwin.read(capFD, &buf, buf.count)
                        if n <= 0 { break }
                        let data = Data(buf[0..<Int(n)])
                        let text = String(data: data, encoding: .utf8)
                            ?? String(data: data, encoding: .isoLatin1) ?? ""
                        DispatchQueue.main.async { self?.console.processOutput(text, isError: false) }
                    }
                    Darwin.close(capFD)
                    DispatchQueue.main.async { [weak self] in
                        if self?.ptyMasterFD == capFD { self?.ptyMasterFD = -1 }
                    }
                }
            }
        } catch {
            appendLine("Failed to start process: \(error.localizedDescription)", type: .stderr)
            if allocatedMasterFD >= 0 { Darwin.close(allocatedMasterFD) }
        }
    }

    // MARK: - Private: Output Processing

    /// Append one console line. Thin forwarder to the ConsoleStore so the runner's many
    /// call sites stay unchanged after the split.
    private func appendLine(_ text: String, type: LineType, inGroup: Bool = false) {
        console.append(text, type: type, inGroup: inGroup)
    }

    // MARK: - Private: Helpers

    private func clearAppSettings() {
        AppSettings.clearAll()
    }

    // MARK: - Private: AI Guard mode

    /// "api" (hosted applyGuardrails) or "proxy" (local tmguard). Defaults to the
    /// hosted API — it works with just the Vision One key, no download/policy/proxy.
    /// AI Guard always runs through the hosted applyGuardrails API (proxy mode was removed).
    private var aiGuardMode: String { "api" }

    /// When false, attacks bypass AI Guard entirely and hit the model directly — the demo
    /// "off" state showing what happens with no guardrail. Defaults to on.
    private var aiGuardEnabled: Bool { AppSettings.aiGuardEnabled }

    /// The Vision One API key used as the hosted API's Bearer token.
    private var aiGuardKey: String { AppSettings.aiGuardKey }

    /// Hosted applyGuardrails endpoint for the configured Vision One region.
    private func aiGuardAPIEndpoint() -> String {
        aiGuardApplyGuardrailsEndpoint(forRegion: AppSettings.aiGuardRegion)
    }

    // (writeAuthConfig and enrichedEnvironment moved to CredentialManager.)
}

// MARK: - Alert Info

struct AlertInfo: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

import SwiftUI
import AppKit

struct DemoShowcaseView: View {
    let phase: DemoPhase
    let basePath: String
    let ngrokToken: String
    let visionOneAPIKey: String
    @EnvironmentObject var runner: DemoRunner
    @AppStorage(FontScale.key) private var uiScale: Double = 1.0
    @AppStorage(AppSettings.Keys.demoId) private var demoIdRaw: String = ""
    // AI Scanner "choose what to run" state. Persists across launches; injected into lab.sh
    // as FORGE_SCAN_MODE + FORGE_SCAN_* on the next run. Defaults to guided + the Fast preset.
    @AppStorage(AppSettings.Keys.scanMode) private var scanMode: String = "guided"
    @AppStorage(AppSettings.Keys.scanObjectives) private var objectivesCSV: String = AppSettings.defaultScanObjectives
    @AppStorage(AppSettings.Keys.scanTechniques) private var techniquesCSV: String = AppSettings.defaultScanTechniques
    @AppStorage(AppSettings.Keys.scanModifiers)  private var modifiersCSV:  String = AppSettings.defaultScanModifiers
    @AppStorage(AppSettings.Keys.scanTarget)     private var scanTarget:    String = AppSettings.defaultScanTarget

    /// The AI-scan "model group name" the SE enters, suffixed with this deployment's id so
    /// teammates sharing a tenant don't land in the same group. Matches what lab.sh stashes
    /// (both read FORGE_DEMO_ID / demoId).
    private var modelGroupName: String {
        let id = demoIdRaw.trimmingCharacters(in: .whitespaces).isEmpty
            ? AppSettings.defaultDemoId : AppSettings.sanitizeDemoId(demoIdRaw)
        return "Ollama Llama3 Lab \(id)"
    }

    private var isThisRunning: Bool { runner.isRunning && runner.currentLabel == phase.name }
    // AI Scanner uploads findings via the Vision One key and scans the local model directly —
    // no tunnel or extra token — so the only credential that gates a run is the Vision One key.
    private var credentialsMissing: Bool {
        phase.requiresCredentials && visionOneAPIKey.isEmpty
    }
    private var adminBlocked: Bool { phase.requiresAdmin && !runner.adminReady }
    private var objectiveCount: Int { selectionCount(objectivesCSV) }
    private var isDisabled: Bool {
        credentialsMissing || adminBlocked || !runner.modelRunning
            || (runner.isRunning && !isThisRunning)
            || (scanMode == "guided" && objectiveCount == 0)   // nothing selected → nothing to scan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header — icon + title/subtitle + the Run/Stop button on the right, mirroring
            // AI Guard's "Attack Library" header (where "Run All" lives).
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surfaceHi)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1))
                        .frame(width: 40, height: 40)
                    Image(systemName: phase.sfSymbol)
                        .resizable().scaledToFit()
                        .frame(width: 18 * CGFloat(uiScale), height: 18 * CGFloat(uiScale))
                        .foregroundStyle(Theme.textSec)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(phase.name)
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                    Text(phase.description)
                        .scaledFont(12.5)
                        .foregroundStyle(Theme.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isThisRunning {
                    Button { runner.stop() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill").scaledFont(12, weight: .semibold)
                            Text("Stop")
                        }
                    }
                    .buttonStyle(PhaseActionButtonStyle(primary: true, disabled: false, destructive: true))
                } else {
                    Button { triggerPhase() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").scaledFont(12, weight: .semibold)
                            Text("Run")
                        }
                    }
                    .buttonStyle(PhaseActionButtonStyle(primary: true, disabled: isDisabled))
                    .disabled(isDisabled)
                }
            }

            // Status line directly under the header (same placement as AI Guard).
            if isThisRunning {
                HStack(spacing: 8) {
                    BrandSpinner(size: 13, lineWidth: 2)
                    Text("Running in the console below — results stream live")
                        .scaledFont(12, weight: .medium).foregroundStyle(Theme.textSec)
                }
            } else if credentialsMissing {
                Label("Set credentials in Settings (⌘,) to run the scan", systemImage: "key.fill")
                    .scaledFont(12, weight: .medium).foregroundStyle(LabStatus.amber)
            } else if runner.modelStarting {
                Label("Starting model…", systemImage: "bolt.fill")
                    .scaledFont(12, weight: .medium).foregroundStyle(Theme.textSec)
            } else if !runner.modelRunning {
                Label("Model isn't running — open Environment and set it up before the scan", systemImage: "bolt.slash.fill")
                    .scaledFont(12, weight: .medium).foregroundStyle(LabStatus.amber)
            }

            if !phase.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(phase.highlights, id: \.self) { h in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "checkmark.circle")
                                .scaledFont(12.5)
                                .foregroundStyle(Theme.textSec)
                                .padding(.top, 1)
                            Text(h)
                                .scaledFont(12.5)
                                .foregroundStyle(Theme.textSec)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.tint(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke, lineWidth: 1))
            }

            // "Choose what to run" — the customer watches this. Guided drives a reliable
            // config-mode scan from the in-app selection; Wizard launches tmas's own tool live.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3")
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(Theme.accent)
                    Text("Choose what to run")
                        .scaledFont(13.5, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                }

                Picker("Mode", selection: $scanMode) {
                    Text("Guided selector").tag("guided")
                    Text("tmas wizard").tag("wizard")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isThisRunning)

                if scanMode == "guided" {
                    guidedSelector
                    Divider().overlay(Theme.stroke)
                    WizardAnswerRow(label: "Model group in Vision One", value: modelGroupName, copyable: true)
                    WizardAnswerRow(label: "Target", value: "http://localhost:11434", muted: true)
                } else {
                    wizardInfo
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.accent.opacity(0.30), lineWidth: 1))
        }
        .padding(16)
        .softCard(highlighted: isThisRunning)
    }

    private func triggerPhase() {
        runner.execute(phase, basePath: basePath, ngrokToken: ngrokToken, visionOneAPIKey: visionOneAPIKey)
    }

    // MARK: - Choose-what-to-run

    /// Guided mode: presets + per-objective/technique/modifier toggles + a live count. Exactly
    /// what's ticked here is what runs, at a safe concurrency — so the customer watches us choose.
    @ViewBuilder private var guidedSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Preset:").scaledFont(12, weight: .medium).foregroundStyle(Theme.textSec)
                Button("Fast") { applyPreset(fast: true) }
                    .buttonStyle(.plain).scaledFont(12, weight: .semibold).foregroundStyle(Theme.accent)
                    .help("The data-leak battery only — ~10 High findings plus leaked secrets, PII, tool schemas, and working exploit code, in ~3 minutes. Quick and rich; run it live during the meeting.")
                Text("·").scaledFont(12).foregroundStyle(Theme.textSec)
                Button("Full") { applyPreset(fast: false) }
                    .buttonStyle(.plain).scaledFont(12, weight: .semibold).foregroundStyle(Theme.accent)
                    .help("The data-leak battery FIRST (High findings, up front), then the ENTIRE built-in matrix — all 9 objectives × all 5 techniques. Long and exhaustive (thousands of attacks); run it before the meeting.")
                Spacer(minLength: 0)
            }
            if scanTarget == "loaded" {
                // Fast — the fixed data-leak battery. No per-objective knobs (the battery is a
                // curated set), so we show just its description instead of the toggle grid.
                Text(targetBlurb)
                    .scaledFont(11.5).foregroundStyle(Theme.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                scanSection("Attack objectives — the goals we probe for", ScanCatalog.objectives, $objectivesCSV)
                scanSection("Techniques — how each attack is framed", ScanCatalog.techniques, $techniquesCSV)
                scanSection("Modifiers — extra obfuscation (optional)", ScanCatalog.modifiers, $modifiersCSV)
                HStack(spacing: 6) {
                    Image(systemName: "number").scaledFont(11).foregroundStyle(Theme.textSec)
                    Text(selectionSummary).scaledFont(12, weight: .medium).foregroundStyle(Theme.textPri)
                }
                .padding(.top, 1)
                Text(targetBlurb)
                    .scaledFont(11).foregroundStyle(Theme.textSec)
                    .fixedSize(horizontal: false, vertical: true)
                // Deep/broad hint — only for a MANUAL permissive/hardened selection. Full (its own
                // target) leads with the High battery, so the "narrow for High" nudge doesn't apply.
                if scanTarget != "full", scanTarget != "hardened", objectiveCount > 0 {
                    let deep = objectiveCount <= 3
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: deep ? "flame.fill" : "gauge.with.dots.needle.33percent")
                            .scaledFont(10).foregroundStyle(deep ? LabStatus.amber : Theme.textTer).padding(.top, 2)
                        Text(deep
                             ? "Deep scan (\(objectiveCount) objectives): complete replies, single-stream — the judge can reach High/Critical. Keep the list short so it stays quick."
                             : "Broad scan (\(objectiveCount) objectives): replies capped short for speed across the catalogue — expect mostly Medium.")
                            .scaledFont(11).foregroundStyle(Theme.textTer)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if objectiveCount == 0 {
                    Text("Select at least one objective to run.")
                        .scaledFont(11.5).foregroundStyle(LabStatus.amber)
                }
            }
        }
    }

    /// Wizard mode: launches tmas's real interactive tool live, with the honest caveat that its
    /// concurrency can't be pinned (Trend's CLI has no such option), so keep the live selection modest.
    @ViewBuilder private var wizardInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launches Trend's own interactive scan wizard in the console below — the customer sees exactly how a scan is configured in the product. Arrow keys move · Space toggles · Enter confirms.")
                .scaledFont(12.5).foregroundStyle(Theme.textPri)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                    .scaledFont(11).foregroundStyle(LabStatus.amber).padding(.top, 2)
                Text("The wizard runs at tmas's built-in concurrency (its CLI has no option to change it in interactive mode), so keep the live selection modest for a snappy run. For the full battery, use the Guided selector — it runs at a safe concurrency.")
                    .scaledFont(12).foregroundStyle(Theme.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Answer the prompts in this order:")
                .scaledFont(12, weight: .semibold).foregroundStyle(Theme.textPri)
                .padding(.top, 2)
            WizardAnswerRow(label: "1 · Model group name", value: modelGroupName, copyable: true)
            WizardAnswerRow(label: "2 · Target endpoint", value: "http://localhost:11434/v1", copyable: true)
            WizardAnswerRow(label: "3 · Target API key", value: "ollama", copyable: true)
        }
    }

    /// One titled group of tappable checkboxes bound to a CSV selection string.
    @ViewBuilder private func scanSection(_ title: String, _ items: [String], _ csv: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).scaledFont(11.5, weight: .semibold).foregroundStyle(Theme.textSec)
            ForEach(items, id: \.self) { item in
                Button {
                    csv.wrappedValue = toggled(item, in: csv.wrappedValue, catalog: items)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected(item, in: csv.wrappedValue) ? "checkmark.square.fill" : "square")
                            .scaledFont(13)
                            .foregroundStyle(isSelected(item, in: csv.wrappedValue) ? Theme.accent : Theme.textSec)
                        Text(item).scaledFont(12.5).foregroundStyle(Theme.textPri)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isThisRunning)
            }
        }
    }

    // Selection helpers — CSV is the persisted form; emitted order follows the catalogue.
    private func selectionCount(_ csv: String) -> Int {
        csv.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
    private var selectionSummary: String {
        let o = selectionCount(objectivesCSV), t = selectionCount(techniquesCSV), m = selectionCount(modifiersCSV)
        return "\(o) objective\(o == 1 ? "" : "s") · \(t) technique\(t == 1 ? "" : "s") · \(m) modifier\(m == 1 ? "" : "s")"
    }
    private func isSelected(_ item: String, in csv: String) -> Bool {
        csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(item)
    }
    private func toggled(_ item: String, in csv: String, catalog: [String]) -> String {
        var set = Set(csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if set.contains(item) { set.remove(item) } else { set.insert(item) }
        return catalog.filter { set.contains($0) }.joined(separator: ",")
    }
    /// One-line description of the current target, shown under the selection.
    private var targetBlurb: String {
        switch scanTarget {
        case "loaded":
            return "Fast — the data-leak battery only: ~10 High findings plus the leaked SYNTHETIC secrets, customer PII, tool schemas, and working exploit code, in ~3 minutes. Quick and rich — ideal to run live during the meeting."
        case "full":
            return "Full — the data-leak battery FIRST (the High findings, up front), then the ENTIRE built-in matrix: all 9 objectives × all 5 techniques against a permissive target, the broad Medium spread. Long and exhaustive (thousands of attacks) — run it before the meeting."
        case "hardened":
            return "Target: a hardened CS-assistant that refuses off-limits requests — a realistic audit (expect a low success rate)."
        default:
            return "Target: a permissive assistant that never refuses — attacks land, so you see the full range of findings and severities."
        }
    }

    private func applyPreset(fast: Bool) {
        if fast {
            // Fast (during the meeting): the data-leak battery ONLY — ~10 High findings + leaked
            // secrets/PII/tool-schemas/exploit-code, ~3 min. No built-in matrix. The objective
            // toggles don't apply (the battery is a fixed, curated set), so clear them; lab.sh's
            // "loaded" target runs the battery as the sole pass.
            objectivesCSV = ""
            techniquesCSV = ""
            modifiersCSV  = ""
            scanTarget    = "loaded"
        } else {
            // Full (before the meeting): lab.sh runs the data-leak battery FIRST (High findings, up
            // front — the proven path), then the ENTIRE built-in matrix — all 9 objectives × all 5
            // techniques against a permissive target, the broad Medium spread. Long and exhaustive
            // (thousands of attacks); runtime is not a concern here. NO obfuscation modifiers (Base64
            // makes prompts that blow tmas's per-request deadline). The "full" target drives both.
            objectivesCSV = ScanCatalog.objectives.joined(separator: ",")
            techniquesCSV = ScanCatalog.techniques.joined(separator: ",")
            modifiersCSV  = ""
            scanTarget    = "full"
        }
    }
}

/// Attack catalogue mirrored from AI Scanner/lab.sh (obj_desc) and aiscan-config.yaml. These
/// names MUST match lab.sh exactly — the app sends them as CSV and lab.sh looks up each
/// objective's description by name to build the scan config.
private enum ScanCatalog {
    static let objectives = [
        "Sensitive Data Disclosure", "System Prompt Leakage", "Malicious Code Generation",
        "Discover ML Model Family", "Generate Hallucinated Software Entities",
        "Agent Tool Definition Leakage", "Indirect Prompt Injection",
        "Resource Exhaustion via Prompt", "Harmful Content Generation",
    ]
    static let techniques = [
        "Ignore all previous instructions", "DAN (Do anything now)", "Encrypt the response",
        "Payload splitting", "Sockpuppet (Output prefix injection)",
    ]
    static let modifiers = ["Base64 Encoding", "Best-of-N Scrambling"]
}

/// One row in the scan-profile card — a label, its value, and an optional copy button.
/// (Originally held the tmas-wizard answers; reused now for the model-group / target info.)
private struct WizardAnswerRow: View {
    let label: String
    let value: String
    var copyable: Bool = false
    var muted: Bool = false
    @AppStorage(FontScale.key) private var uiScale: Double = 1.0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .scaledFont(12, weight: .medium)
                .foregroundStyle(Theme.textSec)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 200 * CGFloat(uiScale), alignment: .leading)
            Text(value)
                .scaledFont(12.5, design: .monospaced)
                .foregroundStyle(muted ? Theme.textTer : Theme.textPri)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            // Inline, right beside the value it copies — not stranded at the far edge.
            if copyable {
                CopyButton(text: value)
            }
            Spacer(minLength: 6)
        }
        // Uniform row height so the copy button (taller than a plain text line) doesn't
        // create uneven vertical gaps between rows.
        .frame(minHeight: 22 * CGFloat(uiScale))
    }
}

// MARK: - Attack Library (run lab-guide payloads against the hosted AI Guard API)

struct GuardAttacksView: View {
    let attacks: [GuardAttack]
    @EnvironmentObject var runner: DemoRunner
    private let guardMode = "api"
    @AppStorage("aiGuardEnabled") private var guardEnabled: Bool = true
    @AppStorage(FontScale.key) private var uiScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surfaceHi)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1))
                        .frame(width: 40, height: 40)
                    Image(systemName: "bolt.shield")
                        .resizable().scaledToFit()
                        .frame(width: 18 * CGFloat(uiScale), height: 18 * CGFloat(uiScale))
                        .foregroundStyle(Theme.textSec)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Attack Library")
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                    Text(guardMode == "api"
                         ? "The OWASP LLM Top 10 (2025), one payload per category. Run fires each at Trend's hosted AI Guard API and shows AI Guard's live verdict."
                         : "The OWASP LLM Top 10 (2025), one payload per category. Run sends each through your local proxy and shows the live decision in the console.")
                        .scaledFont(12.5)
                        .foregroundStyle(Theme.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // AI Guard ON/OFF — the demo's centerpiece. OFF sends prompts straight to
                // the model so you can show the same attack succeeding without protection.
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { guardEnabled.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: guardEnabled ? "checkmark.shield.fill" : "shield.slash.fill")
                            .scaledFont(12, weight: .semibold)
                        Text(guardEnabled ? "AI Guard On" : "AI Guard Off")
                            .scaledFont(12.5, weight: .medium)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6.5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(guardEnabled ? LabStatus.green : LabStatus.red))
                }
                .buttonStyle(.plain)
                .disabled(runner.isRunning)
                .help(guardEnabled
                      ? "AI Guard is protecting the model — click to bypass it"
                      : "AI Guard is off — prompts go straight to the model. Click to re-enable.")

                Button {
                    runner.runAllGuardAttacks(attacks)
                } label: {
                    HStack(spacing: 5) {
                        if runner.isRunningAttacks {
                            BrandSpinner(size: 11, lineWidth: 1.8, colors: [.white, .white.opacity(0.4)])
                            Text("Running…")
                        } else {
                            Image(systemName: "forward.fill").scaledFont(9, weight: .semibold)
                            Text("Run All")
                        }
                    }
                }
                .buttonStyle(PhaseActionButtonStyle(primary: true,
                                                    disabled: runner.isRunning || !runner.modelRunning))
                .disabled(runner.isRunning || !runner.modelRunning)
                .help(runner.modelRunning ? "Send every payload through AI Guard in sequence"
                                          : "Start the model in Environment first")
            }

            if runner.modelStarting {
                Label("Starting model…", systemImage: "bolt.fill")
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Theme.textSec)
            } else if !runner.modelRunning {
                Label("Model isn't running — open Environment and set it up before running attacks.",
                      systemImage: "bolt.slash.fill")
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(LabStatus.amber)
            } else if !guardEnabled {
                Label("AI Guard is off — attacks reach the model unprotected.",
                      systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(LabStatus.amber)
            }

            ForEach(attacks) { attack in
                AttackRow(attack: attack)
            }
        }
        .padding(16)
        .softCard()
    }
}

private struct AttackRow: View {
    let attack: GuardAttack
    @EnvironmentObject var runner: DemoRunner
    private let guardMode = "api"
    @AppStorage("aiGuardRegion") private var guardRegion: String = "us"

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(attack.category)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.textPri)
                Spacer(minLength: 8)
                CopyButton(help: "Copy the curl command") { curlCommand }
                Button {
                    runner.runAttack(attack)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").scaledFont(9, weight: .semibold)
                        Text("Run")
                    }
                }
                .buttonStyle(PhaseActionButtonStyle(primary: true,
                                                    disabled: runner.isRunning || runner.isRunningAttacks || !runner.modelRunning))
                .disabled(runner.isRunning || runner.isRunningAttacks || !runner.modelRunning)
                .help(runner.modelRunning ? "" : "Start the model in Environment first")
            }

            Text("e.g.  \(attack.prompt)")
                .scaledFont(12, design: .monospaced)
                .foregroundStyle(Theme.textSec)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.tint(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    /// The equivalent curl for this attack — what the Copy button puts on the clipboard.
    private var curlCommand: String {
        if guardMode == "api" {
            // Hosted API — references $V1_API_KEY rather than embedding the key in the clipboard.
            let json = (try? JSONSerialization.data(withJSONObject: ["prompt": attack.prompt]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let safe = json.replacingOccurrences(of: "'", with: "'\\''")
            let host = aiGuardHost(forRegion: guardRegion)
            return "curl -i https://\(host)/v3.0/aiSecurity/applyGuardrails"
                 + " -H \"Authorization: Bearer $V1_API_KEY\""
                 + " -H 'Content-Type: application/json'"
                 + " -H 'TMV1-Application-Name: trend-demo-launcher'"
                 + " -H 'TMV1-Request-Type: SimpleRequestGuardrails'"
                 + " -d '\(safe)'"
        } else {
            let payload: [String: Any] = ["model": demoModelTag,
                                          "messages": [["role": "user", "content": attack.prompt]]]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let safe = json.replacingOccurrences(of: "'", with: "'\\''")
            return "curl -i http://127.0.0.1:8443/v1/chat/completions -H 'Content-Type: application/json' -d '\(safe)'"
        }
    }
}

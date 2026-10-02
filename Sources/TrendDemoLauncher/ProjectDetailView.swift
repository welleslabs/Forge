import SwiftUI
import AppKit

struct ProjectDetailView: View {
    let project: DemoProject
    @AppStorage("projectsBasePath") private var basePath: String = defaultProjectsPath()
    @EnvironmentObject var runner: DemoRunner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ProjectHeroView(project: project)

                // Hairline rule between the page header and its content.
                Divider().overlay(Theme.stroke)
                    .padding(.horizontal, 28)

                Text(project.description)
                    .scaledFont(13)
                    .foregroundStyle(Theme.textSec)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                if project.comingSoon {
                    ComingSoonView(project: project)
                        .padding(.horizontal, 28)
                } else {
                    LabModeBanner(project: project)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                    if project.supportsLive {
                        LiveProcessCard(project: project)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 14)
                    }
                    // Live scan progress — a bar instead of the verbose tmas output.
                    if let progress = runner.batchProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(runner.batchLabel.isEmpty ? "Scanning…" : runner.batchLabel)
                                    .scaledFont(12, weight: .medium)
                                    .foregroundStyle(Theme.textSec)
                                Spacer()
                                Text(runner.batchElapsed.isEmpty
                                     ? "\(Int((progress * 100).rounded()))%"
                                     : "\(runner.batchElapsed) · \(Int((progress * 100).rounded()))%")
                                    .scaledFont(11, weight: .medium, design: .monospaced)
                                    .foregroundStyle(Theme.textTer)
                            }
                            ProgressView(value: progress)
                                .tint(Theme.accent)
                                .animation(.linear(duration: 0.15), value: progress)
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                    }
                    PhasesView(project: project, basePath: basePath)
                        .padding(.horizontal, 28)
                }

                Spacer(minLength: 28)
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: InstructionsHeightKey.self, value: g.size.height)
            })
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Hero Header

struct ProjectHeroView: View {
    let project: DemoProject
    @AppStorage("visionOneAPIKey") private var visionOneKey: String = ""
    @AppStorage("ngrokToken")      private var ngrokToken:   String = ""
    private let guardMode = "api"

    private var configured: Bool {
        projectIsConfigured(project, visionOneKey: visionOneKey, ngrokToken: ngrokToken, guardMode: guardMode)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            BrandMark(kind: project.mark, size: 56, dimmed: project.comingSoon)

            VStack(alignment: .leading, spacing: 5) {
                Text(project.eyebrow)
                    .scaledFont(12.5)
                    .foregroundStyle(Theme.textTer)

                // Product name with its configured status alongside.
                HStack(spacing: 10) {
                    Text(project.name)
                        .scaledFont(26, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                    if project.comingSoon {
                        Text("Coming soon")
                            .scaledFont(12)
                            .foregroundStyle(Theme.textTer)
                    } else {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(configured ? LabStatus.green : LabStatus.red)
                                .frame(width: 6, height: 6)
                            Text(configured ? "Configured" : "Not configured")
                                .scaledFont(12)
                                .foregroundStyle(Theme.textSec)
                        }
                    }
                }

                Text(project.tagline)
                    .scaledFont(13)
                    .foregroundStyle(Theme.textSec)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 16)
    }
}

// MARK: - Lab Mode Banner

/// Only shown in Live mode: tells the user, per lab, whether this lab is actually
/// running against Vision One or transparently staying on mock data (because it has
/// no live path, or no API key is set).
private struct LabModeBanner: View {
    let project: DemoProject
    @AppStorage(AppSettings.Keys.labMode) private var labMode = "mock"
    @AppStorage(AppSettings.Keys.v1ApiKey) private var v1Key = ""
    @AppStorage(AppSettings.Keys.visionOneAPIKey) private var visionOneKey = ""
    @AppStorage(AppSettings.Keys.aiGuardVisionOneAPIKey) private var aiGuardKey = ""
    @AppStorage(AppSettings.Keys.codeContainerVisionOneAPIKey) private var codeContainerKey = ""

    // Include Code & Container's own key — it's the live lab today, so the banner must
    // recognize its key or it wrongly says "no key set" when only that key is present.
    private var hasKey: Bool {
        !v1Key.isEmpty || !visionOneKey.isEmpty || !aiGuardKey.isEmpty || !codeContainerKey.isEmpty
    }

    var body: some View {
        if labMode == "live" {
            let hasLivePath = project.supportsLive || project.interactiveLive
            let live = hasLivePath && hasKey
            HStack(spacing: 8) {
                Image(systemName: live ? "dot.radiowaves.left.and.right" : "shippingbox")
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(live ? Theme.accent : LabStatus.amber)
                Text(live
                     ? (project.interactiveLive
                        ? "Live mode — Run this lab to scan your local model for real; results appear in your Vision One tenant, not sample data."
                        : "Live mode — this lab runs against your Trend Vision One tenant.")
                     : hasLivePath
                       ? "Live mode is on, but no Vision One API key is set — add a key in Settings (⌘,) to run live."
                       : "Live mode is on, but this lab has no live path yet — it runs on sample data.")
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Theme.textSec)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.tint(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke, lineWidth: 1))
        }
    }
}

// MARK: - Live Process Card

/// Shows how a live lab populates the customer's Vision One, and links straight to
/// the console. Makes the "watch it appear in Vision One" story explicit on screen.
private struct LiveProcessCard: View {
    let project: DemoProject
    @AppStorage(AppSettings.Keys.labMode) private var labMode = "mock"
    @AppStorage(AppSettings.Keys.v1Region) private var region = "us"

    private var isCodeScan: Bool { project.mark == .codeScan }

    private var steps: [(String, String)] {
        if isCodeScan {
            return [
                ("doc.text.magnifyingglass", "tmas scans the app's source and dependencies"),
                ("magnifyingglass", "Vulnerable packages, hardcoded secrets & malware"),
                ("arrow.up.forward.app", "Findings upload to your Vision One tenant"),
                ("checkmark.seal", "Show them live in Code Security → CI/CD Artifacts"),
            ]
        }
        return [
            ("shippingbox", "tmas builds the app into an image, then scans it"),
            ("magnifyingglass", "OS + dependency CVEs, malware & embedded secrets"),
            ("arrow.up.forward.app", "Findings upload to your Vision One tenant"),
            ("checkmark.seal", "Show them live in Container Security"),
        ]
    }

    private var consoleHint: String {
        isCodeScan
        ? "Open your Vision One console (\(region.uppercased())) — then go to Cloud Security → Code Security → CI/CD Artifacts"
        : "Open your Vision One console (\(region.uppercased())) — then go to Cloud Security → Container Security → Log → Container Image Scanning"
    }

    private var consoleURL: URL? { URL(string: (V1Region(rawValue: region) ?? .us).consoleURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(Theme.accent)
                Text("How the live demo populates Vision One")
                    .scaledFont(13.5, weight: .semibold)
                    .foregroundStyle(Theme.textPri)
                Spacer(minLength: 8)
                if let url = consoleURL {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Text("View in Vision One")
                            Image(systemName: "arrow.up.right")
                        }
                        .scaledFont(12, weight: .medium)
                    }
                    .buttonStyle(PhaseActionButtonStyle(primary: true, disabled: false))
                    .help(consoleHint)
                }
            }
            // Numbered pipeline steps.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 10) {
                        Text("\(i + 1)")
                            .scaledFont(11, weight: .semibold)
                            .foregroundStyle(Theme.textSec)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.tint(0.06)))
                            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                        Image(systemName: step.0)
                            .scaledFont(12)
                            .foregroundStyle(Theme.textSec)
                            .frame(width: 18)
                        Text(step.1)
                            .scaledFont(12.5)
                            .foregroundStyle(Theme.textSec)
                        Spacer(minLength: 0)
                    }
                }
            }
            Text(labMode == "live"
                 ? "Live mode is on — running a scan uploads real findings to your tenant. Flip to the console to show the customer."
                 : "You're in Mock mode (offline). Switch Lab data mode to Live in Settings to populate your Vision One tenant.")
                .scaledFont(11.5)
                .foregroundStyle(Theme.textTer)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard()
    }
}

// MARK: - Phases

struct PhasesView: View {
    let project: DemoProject
    let basePath: String
    @EnvironmentObject var runner: DemoRunner
    /// A destructive phase awaiting user confirmation (drives the dialog below).
    @State private var pendingDestructive: DemoPhase?

    // Each product drives its OWN credentials: read the values from the UserDefaults
    // keys this project declares, so AI Guard's setup uses AI Guard's keys (not AI
    // Scanner's). Falls back to the shared keys when a product doesn't specify.
    private var visionOneAPIKey: String {
        UserDefaults.standard.string(forKey: project.visionOneKeyDefaults ?? "visionOneAPIKey") ?? ""
    }
    private var ngrokToken: String {
        UserDefaults.standard.string(forKey: project.ngrokKeyDefaults ?? "ngrokToken") ?? ""
    }

    private var labGuide: DemoPhase? { project.phases.first { $0.role == .labGuide } }
    private var demoPhases: [DemoPhase] { project.phases.filter { $0.role == .demo } }
    private var standalonePhases: [DemoPhase] { project.phases.filter { $0.role == .standalone } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text("Demo Workflow")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(Theme.textPri)
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
            .padding(.bottom, 2)

            // 1 — Lab guide, pinned to the very top of the list.
            if let guide = labGuide {
                LabGuideCard(phase: guide) { executePhase(guide) }
            }

            // 2 — Prerequisites for the whole workflow.
            if !project.prerequisites.isEmpty {
                PrerequisitesCard(items: project.prerequisites)
            }

            // 2b — Attack library: example payloads from the lab guide, run live
            // against the hosted AI Guard API. Environment setup lives on the shared
            // Environment screen in the sidebar.
            if !project.attacks.isEmpty {
                GuardAttacksView(attacks: project.attacks)
            }

            // 3 — The demo itself: a rich, explanatory showcase card.
            ForEach(demoPhases) { phase in
                DemoShowcaseView(
                    phase: phase,
                    basePath: basePath, ngrokToken: ngrokToken, visionOneAPIKey: visionOneAPIKey
                )
            }

            // 4 — Any standalone phases that don't fit the setup/demo/teardown model.
            ForEach(Array(standalonePhases.enumerated()), id: \.element.id) { index, phase in
                PhaseCardView(
                    phase: phase, stepNumber: index + 1,
                    basePath: basePath, ngrokToken: ngrokToken,
                    visionOneAPIKey: visionOneAPIKey,
                    requestDestructive: { pendingDestructive = $0 }
                )
            }
        }
        .confirmationDialog(
            "Run \(pendingDestructive?.name ?? "this step")?",
            isPresented: Binding(get: { pendingDestructive != nil },
                                 set: { if !$0 { pendingDestructive = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingDestructive?.name ?? "Run", role: .destructive) {
                if let phase = pendingDestructive { executePhase(phase) }
                pendingDestructive = nil
            }
            Button("Cancel", role: .cancel) { pendingDestructive = nil }
        } message: {
            Text(pendingDestructive?.description ?? "")
        }
    }

    private func executePhase(_ phase: DemoPhase) {
        runner.execute(phase, basePath: basePath, ngrokToken: ngrokToken, visionOneAPIKey: visionOneAPIKey)
    }
}

// MARK: - Prerequisites Card

private struct PrerequisitesCard: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(Theme.textSec)
                Text("Prerequisites")
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.textPri)
                Text("before you begin")
                    .scaledFont(12)
                    .foregroundStyle(Theme.textTer)
            }
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "circle.fill")
                        .scaledFont(4)
                        .foregroundStyle(Theme.textTer)
                        .padding(.top, 6)
                    Text(item)
                        .scaledFont(12.5)
                        .foregroundStyle(Theme.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard()
    }
}

// MARK: - Lab Guide Card

private struct LabGuideCard: View {
    let phase: DemoPhase
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surfaceHi)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1))
                    .frame(width: 40, height: 40)
                Image(systemName: phase.sfSymbol)
                    .scaledFont(16, weight: .medium)
                    .foregroundStyle(Theme.textSec)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(phase.name)
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                    StatusPill(text: "Start here", color: Theme.accent)
                }
                Text(phase.description)
                    .scaledFont(12.5)
                    .foregroundStyle(Theme.textSec)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Button(action: onOpen) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right").scaledFont(10, weight: .semibold)
                    Text("Open Guide")
                }
            }
            .buttonStyle(PhaseActionButtonStyle(primary: true, disabled: false))
        }
        .padding(15)
        .softCard()
    }
}

// MARK: - Phase Card

struct PhaseCardView: View {
    let phase: DemoPhase
    let stepNumber: Int
    let basePath: String
    let ngrokToken: String
    let visionOneAPIKey: String
    /// Destructive phases hand themselves to the parent, which owns the confirm dialog.
    let requestDestructive: (DemoPhase) -> Void
    @EnvironmentObject var runner: DemoRunner
    @State private var hovering = false

    private var isThisRunning: Bool {
        runner.isRunning && runner.currentLabel == phase.name
    }
    private var credentialsMissing: Bool {
        phase.requiresCredentials && visionOneAPIKey.isEmpty
    }
    private var adminBlocked: Bool {
        phase.requiresAdmin && !runner.adminReady
    }
    private var accentColor: Color {
        phase.isDestructive ? LabStatus.red : Theme.accent
    }
    private var isPrimaryAction: Bool {
        switch phase.action {
        case .console, .configureAndRun, .interactiveConsole, .background: return true
        case .openDocument: return false
        }
    }
    private var actionLabel: String {
        switch phase.action {
        case .openDocument:   return "Open"
        case .background:     return "Start"
        case .console, .configureAndRun, .interactiveConsole:
            return isThisRunning ? "Running" : "Run"
        }
    }
    private var actionIcon: String {
        switch phase.action {
        case .openDocument: return "arrow.up.right"
        default:            return "play.fill"
        }
    }
    private var isDisabled: Bool { credentialsMissing || isThisRunning || adminBlocked }

    var body: some View {
        HStack(spacing: 0) {
            // Accent rail
            accentColor
                .frame(width: 3)
                .opacity(isThisRunning ? 1 : 0.45)

            HStack(spacing: 14) {
                // Step number
                Text("\(stepNumber)")
                    .scaledFont(12.5, weight: .semibold)
                    .foregroundStyle(Theme.textSec)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.tint(0.06)))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))

                // Phase icon tile
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.surfaceHi)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1))
                        .frame(width: 36, height: 36)
                    Image(systemName: phase.sfSymbol)
                        .scaledFont(14, weight: .medium)
                        .foregroundStyle(Theme.textSec)
                }

                // Text
                VStack(alignment: .leading, spacing: 3) {
                    Text(phase.name)
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                        .lineLimit(1)
                    Text(phase.description)
                        .scaledFont(12)
                        .foregroundStyle(Theme.textSec)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if credentialsMissing {
                        Label("Set credentials in Settings (⌘,)", systemImage: "key.fill")
                            .scaledFont(11.5, weight: .medium)
                            .foregroundStyle(LabStatus.amber)
                            .padding(.top, 1)
                    } else if adminBlocked {
                        Label("Admin access isn't set up on this Mac", systemImage: "lock.fill")
                            .scaledFont(11.5, weight: .medium)
                            .foregroundStyle(LabStatus.amber)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 10)

                if isThisRunning {
                    BrandSpinner(size: 16, lineWidth: 2)

                    Button {
                        runner.stop()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill")
                                .scaledFont(10, weight: .semibold)
                            Text("Stop")
                        }
                    }
                    .buttonStyle(PhaseActionButtonStyle(primary: true, disabled: false, destructive: true))
                } else {
                    // Action button
                    Button {
                        if phase.isDestructive { requestDestructive(phase) } else { triggerPhase() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: actionIcon)
                                .scaledFont(10, weight: .semibold)
                            Text(actionLabel)
                        }
                    }
                    .buttonStyle(PhaseActionButtonStyle(primary: isPrimaryAction,
                                                        disabled: isDisabled,
                                                        destructive: phase.isDestructive))
                    .disabled(isDisabled)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
        }
        .softCard(highlighted: isThisRunning || hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .animation(.easeInOut(duration: 0.2), value: isThisRunning)
    }

    private func triggerPhase() {
        runner.execute(phase, basePath: basePath, ngrokToken: ngrokToken, visionOneAPIKey: visionOneAPIKey)
    }
}


struct ComingSoonView: View {
    let project: DemoProject

    var body: some View {
        HStack(spacing: 16) {
            BrandMark(kind: project.mark, size: 48, dimmed: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("In Development")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(Theme.textSec)
                Text("Demo content for this product is on the way. Check back soon.")
                    .scaledFont(12.5)
                    .foregroundStyle(Theme.textTer)
            }
            Spacer()
        }
        .padding(18)
        .softCard()
    }
}

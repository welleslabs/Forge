import SwiftUI
import AppKit

struct HomeView: View {
    @Binding var selection: SidebarSelection?
    @AppStorage("visionOneAPIKey") private var visionOneKey: String = ""
    @AppStorage("ngrokToken")      private var ngrokToken:   String = ""
    @AppStorage(AppSettings.Keys.labMode) private var labMode = "mock"
    private let guardMode = "api"

    private var liveCount: Int { ProjectCatalog.all.filter { !$0.comingSoon }.count }

    /// The readiness hint shown on each product card. Mirrors the sidebar/Environment logic
    /// for the parts that matter in the catalog: a missing hard-required credential reads red;
    /// a live-capable lab with no API key is optional for Mock (amber) but blocks Live (red);
    /// everything else is ready. Transient model-running state is the Environment screen's
    /// concern, so it isn't reflected here — the card answers "do I have the keys," not "is
    /// the model up right now."
    private func homeStatus(_ p: DemoProject) -> (text: String, color: Color) {
        if !projectIsConfigured(p, visionOneKey: visionOneKey, ngrokToken: ngrokToken, guardMode: guardMode) {
            return ("Not configured", LabStatus.red)
        }
        if p.supportsLive && !projectHasLiveKey(p) {
            // Live uploads need the key; Mock doesn't — so the same missing key is a hard
            // block in Live and just a heads-up in Mock.
            return labMode == "live"
                ? ("Needs API key", LabStatus.red)
                : ("Live needs API key", LabStatus.amber)
        }
        if p.requiredCredentialKeys.isEmpty && !p.supportsLive {
            return ("No setup needed", LabStatus.green)
        }
        return ("Configured", LabStatus.green)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Page header — the sidebar already carries the Forge brand, so this
                // titles the screen rather than repeating the app name.
                VStack(alignment: .leading, spacing: 5) {
                    Text("Overview")
                        .scaledFont(26, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                    Text("Set up, run, and present your Trend Vision One demo labs — all from one place.")
                        .scaledFont(13)
                        .foregroundStyle(Theme.textSec)
                }

                Divider().overlay(Theme.stroke)

                // First-run guidance: the three steps from a clean Mac to a live demo,
                // with live status. Collapses to a one-line summary once the lab is up.
                GetStartedCard(selection: $selection)

                // The AI stack, development → deployment: every stage TrendAI covers,
                // with its products grouped underneath. Live demos run today; previews
                // show where the suite is going.
                VStack(alignment: .leading, spacing: 22) {
                    HomeSectionHeader("Secure your AI development lifecycle · \(liveCount) live demos")

                    ForEach(AIStage.allCases) { stage in
                        let items = ProjectCatalog.all.filter { $0.occupiesStage(stage) }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(stage.rawValue + 1)")
                                        .scaledFont(11, weight: .semibold)
                                        .foregroundStyle(Theme.textSec)
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(Theme.tint(0.06)))
                                        .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                                    Text(stage.title)
                                        .scaledFont(14, weight: .semibold)
                                        .foregroundStyle(Theme.textPri)
                                    Text(stage.blurb)
                                        .scaledFont(12)
                                        .foregroundStyle(Theme.textSec)
                                }
                                if stage == .runtime {
                                    // Mirror Vision One's Runtime sub-sections (AI infrastructure /
                                    // AI workload / AI application / AI data storage). Empty ones are skipped.
                                    ForEach(runtimeAreas, id: \.self) { area in
                                        let sub = ProjectCatalog.all.filter { $0.occupies(stage: .runtime, area: area) }
                                        if !sub.isEmpty {
                                            Text(area)
                                                .scaledFont(12, weight: .semibold)
                                                .foregroundStyle(Theme.textSec)
                                                .padding(.top, 2)
                                            productGrid(sub)
                                        }
                                    }
                                } else {
                                    productGrid(items)
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Vision One's Runtime sub-sections, in console order.
    private let runtimeAreas = ["AI infrastructure", "AI workload", "AI application", "AI data storage"]

    /// The card grid for a set of products — shared by the flat stages and the Runtime sub-sections.
    @ViewBuilder private func productGrid(_ items: [DemoProject]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
                  alignment: .leading, spacing: 14) {
            ForEach(items) { project in
                HomeProductCard(project: project, status: homeStatus(project)) {
                    selection = .project(project)
                }
            }
        }
    }
}

// MARK: - Get Started checklist

/// The setup path in one card: add credentials → set up the environment → run a demo.
/// Every row reflects live state and jumps to the right screen. Once the model is up
/// and at least one product is configured, the card collapses to a one-line status.
private struct GetStartedCard: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject var runner: DemoRunner
    @AppStorage("visionOneAPIKey")        private var visionOneKey: String = ""
    @AppStorage("ngrokToken")             private var ngrokToken:   String = ""
    @AppStorage("aiGuardVisionOneAPIKey") private var aiGuardKey:   String = ""

    /// Only the products that actually need credentials drive the checklist — the
    /// self-contained labs run with zero setup and would otherwise collapse the card
    /// or inflate the counts.
    private var credentialProducts: [DemoProject] {
        ProjectCatalog.all.filter { $0.isRunnable && !$0.requiredCredentialKeys.isEmpty }
    }
    private var configured: [DemoProject] {
        _ = aiGuardKey   // track AI Guard's own key so the card refreshes when it changes
        return credentialProducts.filter {
            projectIsConfigured($0, visionOneKey: visionOneKey, ngrokToken: ngrokToken, guardMode: "api")
        }
    }
    private var allConfigured: Bool { !credentialProducts.isEmpty && configured.count == credentialProducts.count }
    /// The minimal path is complete: the model is up and at least one model demo can run.
    private var labReady: Bool { runner.modelRunning && !configured.isEmpty }

    private var credentialsSubtitle: String {
        if allConfigured { return "All products configured." }
        if configured.isEmpty {
            return "Add each product's Vision One API key in Settings."
        }
        return "\(configured.count) of \(credentialProducts.count) products configured — add the remaining keys in Settings to demo everything."
    }
    private var environmentSubtitle: String {
        if runner.modelRunning { return "The local model is running." }
        if runner.isRunningAll || runner.modelStarting {
            return "Setting up now — progress streams in the console."
        }
        if configured.isEmpty { return "Configure at least one product first, then set up the shared lab." }
        return "One click on the Environment screen installs the shared local model."
    }
    private var demoSubtitle: String {
        if labReady, let first = configured.first {
            return "\(first.name) is ready — open it and press Run."
        }
        return "Once the lab is up, open a product and run its demo."
    }

    var body: some View {
        if labReady {
            // Collapsed: everything needed for a demo is in place.
            HStack(spacing: 8) {
                Image(systemName: allConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .scaledFont(13)
                    .foregroundStyle(allConfigured ? LabStatus.green : LabStatus.amber)
                Text(allConfigured
                     ? "Lab ready — every demo below can run."
                     : "Lab ready for \(configured.map(\.name).joined(separator: ", ")) — add the remaining keys in Settings to demo everything.")
                    .scaledFont(12.5, weight: .medium)
                    .foregroundStyle(Theme.textSec)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .softCard(radius: 10)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get started")
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                    Text("Three steps from a clean Mac to a live demo.")
                        .scaledFont(12)
                        .foregroundStyle(Theme.textSec)
                }
                .padding(.bottom, 8)

                GetStartedRow(number: 1,
                              done: allConfigured,
                              active: configured.isEmpty,
                              title: "Add credentials",
                              subtitle: credentialsSubtitle) { selection = .settings }
                Divider().overlay(Theme.stroke)
                GetStartedRow(number: 2,
                              done: runner.modelRunning,
                              active: !configured.isEmpty && !runner.modelRunning,
                              title: "Set up the environment",
                              subtitle: environmentSubtitle) { selection = .environment }
                Divider().overlay(Theme.stroke)
                GetStartedRow(number: 3,
                              done: false,
                              active: labReady,
                              title: "Run a demo",
                              subtitle: demoSubtitle) {
                    if let first = configured.first ?? credentialProducts.first {
                        selection = .project(first)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard()
        }
    }
}

/// One checklist row: a numbered (or checked) badge, title + live subtitle, and a
/// chevron — the whole row jumps to the screen where the step happens.
private struct GetStartedRow: View {
    let number: Int
    let done: Bool
    let active: Bool          // the current step — gets the accent badge
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(done ? LabStatus.green : (active ? Theme.accent : Theme.tint(0.06)))
                        .frame(width: 22, height: 22)
                    if done {
                        Image(systemName: "checkmark")
                            .scaledFont(10, weight: .semibold)
                            .foregroundStyle(.white)
                    } else {
                        Text("\(number)")
                            .scaledFont(12, weight: .semibold)
                            .foregroundStyle(active ? .white : Theme.textSec)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(done ? Theme.textSec : Theme.textPri)
                    Text(subtitle)
                        .scaledFont(12)
                        .foregroundStyle(Theme.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(10, weight: .semibold)
                    .foregroundStyle(Theme.textTer)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.tint(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct HomeSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 9) {
            Text(text)
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(Theme.textPri)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}

private struct HomeProductCard: View {
    let project: DemoProject
    let status: (text: String, color: Color)
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                BrandMark(kind: project.mark, size: 40, dimmed: project.comingSoon)

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.eyebrow)
                        .scaledFont(12)
                        .foregroundStyle(Theme.textTer)
                    Text(project.name)
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                    Text(project.tagline)
                        .scaledFont(12.5)
                        .foregroundStyle(Theme.textSec)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // Bottom row: open affordance (left) + configured status (right).
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Text(project.comingSoon ? "Preview" : "Open")
                            .scaledFont(12.5, weight: .medium)
                        Image(systemName: "arrow.right").scaledFont(10, weight: .semibold)
                    }
                    .foregroundStyle(Theme.accent)
                    Spacer()
                    if project.comingSoon {
                        Text("Coming soon")
                            .scaledFont(12)
                            .foregroundStyle(Theme.textTer)
                    } else {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(status.color)
                                .frame(width: 6, height: 6)
                            Text(status.text)
                                .scaledFont(12)
                                .foregroundStyle(Theme.textSec)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(project.comingSoon ? 0.72 : 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous)
                    .fill(hovering && !project.comingSoon ? Theme.surfaceHi : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous)
                    .stroke(hovering && !project.comingSoon ? Theme.strokeHi : Theme.stroke,
                            lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

// MARK: - Environment (shared lab setup)

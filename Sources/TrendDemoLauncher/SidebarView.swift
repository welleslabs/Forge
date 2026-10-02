import SwiftUI
import AppKit

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject var runner: DemoRunner
    // Observed so the Environment readiness dot refreshes the moment keys change in Settings.
    @AppStorage("visionOneAPIKey")        private var visionOneKey: String = ""
    @AppStorage("ngrokToken")             private var ngrokToken:   String = ""
    @AppStorage("aiGuardVisionOneAPIKey") private var aiGuardKey:   String = ""
    @AppStorage(AppSettings.Keys.labMode) private var labMode:      String = "mock"
    @AppStorage(AppSettings.Keys.codeContainerVisionOneAPIKey) private var codeContainerKey: String = ""
    @AppStorage("env.includedProducts") private var includedCSV: String = ""   // which labs the SE included in setup

    /// Per-product readiness dot for the Products list — same red/amber/green meaning as
    /// the Environment screen, scoped to one product. nil for coming-soon previews.
    private func productDot(_ p: DemoProject) -> (color: Color?, help: String) {
        _ = aiGuardKey; _ = codeContainerKey; _ = labMode   // refresh when keys/mode change
        guard p.isRunnable else { return (nil, "") }
        let st = LabStatus.state(p, modelRunning: runner.modelRunning,
                                 visionOneKey: visionOneKey, ngrokToken: ngrokToken, labMode: labMode)
        let needsLiveKey = p.supportsLive && !projectHasLiveKey(p)
        let help: String
        switch st {
        case .blocked:
            help = needsLiveKey
                ? "\(p.name): needs Vision One API Key — open Settings (⌘,)"
                : "\(p.name): not configured — add its key in Settings (⌘,)"
        case .attention:
            help = needsLiveKey
                ? "\(p.name): mock ready — add a Vision One API key for live scans"
                : "\(p.name): configured — run Set Up Environment"
        case .ready:
            help = "\(p.name): ready to demo"
        }
        return (LabStatus.color(for: st), help)
    }

    /// Readiness dot for the Environment row — spans every lab this screen provisions (the
    /// non-greyed products) and matches the Environment header pill: green only when every lab is
    /// BOTH configured (key in) AND ready (built/running); amber for a partial spread; red when none.
    private var labDot: (color: Color, help: String) {
        _ = aiGuardKey; _ = codeContainerKey; _ = labMode
        // Only the labs the SE included in setup — left-out products don't drag the dot down.
        let sel = includedEnvProducts(includedCSV: includedCSV, modelRunning: runner.modelRunning,
                                      visionOneKey: visionOneKey, ngrokToken: ngrokToken, labMode: labMode)
        guard !sel.isEmpty else { return (LabStatus.red, "No labs set up yet — open Environment to get started") }
        let states = sel.map {
            LabStatus.state($0, modelRunning: runner.modelRunning,
                            visionOneKey: visionOneKey, ngrokToken: ngrokToken, labMode: labMode)
        }
        let total = states.count
        let ready = states.filter { $0 == .ready }.count
        let color = LabStatus.rollupColor(forStates: states)
        let help = ready == total ? "All included labs ready"
                 : ready == 0 ? "Setup in progress — open Environment"
                 : "\(ready) of \(total) included labs ready"
        return (color, help)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand lockup doubles as the Home button (the Home row below is the
            // discoverable path; this stays clickable for muscle memory).
            Button {
                selection = .home
            } label: {
                AppWordmark()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Home — overview")
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // Home — the overview of every product.
                    Button {
                        selection = .home
                    } label: {
                        SidebarSystemRow(symbol: "house", title: "Home",
                                         isSelected: selection == .home)
                    }
                    .buttonStyle(.plain)

                    // Environment — the shared local lab, above the products it powers.
                    Button {
                        selection = .environment
                    } label: {
                        let dot = labDot
                        SidebarSystemRow(symbol: "cpu", title: "Environment",
                                         isSelected: selection == .environment,
                                         dotColor: dot.color, dotHelp: dot.help)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)

                    SidebarSectionLabel("Products")
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)

                    ForEach(ProjectCatalog.all) { project in
                        let dot = productDot(project)
                        Button {
                            selection = .project(project)
                        } label: {
                            ProjectRowView(project: project,
                                           isSelected: selection == .project(project),
                                           dotColor: dot.color, dotHelp: dot.help)
                        }
                        .buttonStyle(.plain)
                    }

                    SidebarSectionLabel("System")
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 2)

                    Button {
                        selection = .settings
                    } label: {
                        SidebarSystemRow(symbol: "gearshape", title: "Settings",
                                         isSelected: selection == .settings)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            // Footer — readiness across EVERY runnable demo, same red/amber/green meaning
            // as the per-product dots above. Clickable: it jumps to the Environment screen.
            Divider().overlay(Theme.stroke)
            let demos = ProjectCatalog.runnableProducts
            // One readiness pass; derive count/started/color from the same array.
            let demoStates = demos.map { LabStatus.state($0, modelRunning: runner.modelRunning,
                                                          visionOneKey: visionOneKey, ngrokToken: ngrokToken,
                                                          labMode: labMode) }
            let ready = demoStates.filter { $0 == .ready }.count
            let started = demoStates.filter { $0 != .blocked }.count
            let rollup = LabStatus.rollupColor(forStates: demoStates)
            Button {
                selection = .environment
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(rollup)
                        .frame(width: 7, height: 7)
                    Text(ready == demos.count ? "All demos ready"
                         : ready > 0 ? "\(ready) of \(demos.count) demos ready"
                         : started > 0 ? "Setup in progress"
                         : "Lab not set up")
                        .scaledFont(11.5, weight: .medium)
                        .foregroundStyle(Theme.textSec)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .scaledFont(9, weight: .semibold)
                        .foregroundStyle(Theme.textTer)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Environment")

            // Data-mode indicator — always visible so a presenter knows whether labs
            // are running on seeded mock data or the live Vision One tenant.
            Divider().overlay(Theme.stroke)
            HStack(spacing: 7) {
                Image(systemName: labMode == "live" ? "dot.radiowaves.left.and.right" : "shippingbox")
                    .scaledFont(10, weight: .medium)
                    .foregroundStyle(labMode == "live" ? Theme.accent : Theme.textTer)
                Text(labMode == "live" ? "Live · Vision One" : "Mock data")
                    .scaledFont(10.5, weight: .medium)
                    .foregroundStyle(Theme.textSec)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .help(labMode == "live"
                  ? "Supported labs run against your real Trend Vision One tenant. Change in Settings."
                  : "Labs run on seeded sample data, fully offline. Switch to Live in Settings.")
        }
        .background(Theme.bg1)
        .navigationTitle("")
    }
}

private struct SidebarSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .scaledFont(12, weight: .semibold)
            .foregroundStyle(Theme.textTer)
    }
}

/// A plain sidebar row — SF Symbol + label, with an optional trailing status dot.
/// Selection is the same quiet neutral fill for every row.
struct SidebarSystemRow: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    var dotColor: Color? = nil
    var dotHelp: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(13, weight: .medium)
                .foregroundStyle(Theme.textSec)
                .frame(width: 22)
            Text(title)
                .scaledFont(13, weight: .medium)
                .foregroundStyle(Theme.textPri)
            Spacer(minLength: 0)
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .help(dotHelp)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.tint(isSelected ? 0.08 : 0))
        )
        .contentShape(Rectangle())
    }
}

struct ProjectRowView: View {
    let project: DemoProject
    let isSelected: Bool
    /// Tri-state readiness dot (red / amber / green), matching the Environment row. nil
    /// for products with no lab environment (e.g. coming-soon / doc-only).
    var dotColor: Color? = nil
    var dotHelp: String = ""

    var body: some View {
        HStack(spacing: 9) {
            BrandMark(kind: project.mark, size: 26, dimmed: project.comingSoon)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(project.comingSoon ? Theme.textSec : Theme.textPri)
                if project.comingSoon {
                    Text("Coming soon")
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.textTer)
                }
            }
            Spacer(minLength: 0)
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .help(dotHelp)
            }
        }
        .opacity(project.comingSoon ? 0.65 : 1)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.tint(isSelected ? 0.08 : 0))
        )
        .contentShape(Rectangle())
    }
}

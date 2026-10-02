import SwiftUI

/// True when every credential key a project's setup requires has a non-empty value.
/// The two shared keys are passed in (the caller reads them via @AppStorage so the
/// configured pills update live); per-product keys are read straight from UserDefaults.
func projectIsConfigured(_ project: DemoProject,
                         visionOneKey: String, ngrokToken: String,
                         guardMode: String) -> Bool {
    // AI Guard in hosted-API mode (the default) needs only its own Vision One key —
    // no ngrok token, policy, or proxy download.
    if !project.attacks.isEmpty, guardMode == "api" {
        return !(UserDefaults.standard.string(forKey: "aiGuardVisionOneAPIKey") ?? "").isEmpty
    }
    let keys = project.requiredCredentialKeys
    guard !keys.isEmpty else { return true }
    return keys.allSatisfy { key in
        switch key {
        case "visionOneAPIKey": return !visionOneKey.isEmpty
        default: return !(UserDefaults.standard.string(forKey: key) ?? "").isEmpty
        }
    }
}

/// Shared traffic-light palette + readiness count for the lab, used by BOTH the sidebar
/// "Environment" dot and the Environment header pill so the two can never disagree.
/// A product counts as ready only when it's configured AND the shared model is running:
/// red = none ready, amber = some, green = all.
/// Whether a live-capable product's own (optional) API key is set. Its credentials are
/// optional for a mock run but required for a live scan, so readiness factors this in.
func projectHasLiveKey(_ project: DemoProject) -> Bool {
    let keys = project.credentials.map(\.key)
    guard !keys.isEmpty else { return false }
    // Each product needs its OWN Vision One key — no shared fallback. Without it, a live-capable
    // lab isn't live-ready (mock still works).
    return keys.allSatisfy { !(UserDefaults.standard.string(forKey: $0) ?? "").isEmpty }
}

/// The env products the SE has INCLUDED in setup (toggled on) — defaulting to the currently-ready
/// ones when nothing's been chosen explicitly (which is how the toggles seed themselves). The
/// Environment light scores only these, so products the SE left out (still needing a key) don't
/// hold the light down. Shared by the Environment header pill and the sidebar dot so they agree.
func includedEnvProducts(includedCSV: String, modelRunning: Bool,
                         visionOneKey: String, ngrokToken: String, labMode: String) -> [DemoProject] {
    let all = ProjectCatalog.productsWithEnvironment
    if includedCSV == "·none·" { return [] }
    if includedCSV.isEmpty {
        return all.filter {
            LabStatus.isReady($0, modelRunning: modelRunning, visionOneKey: visionOneKey,
                              ngrokToken: ngrokToken, labMode: labMode)
        }
    }
    let names = Set(includedCSV.split(separator: ",").map(String.init))
    return all.filter { names.contains($0.name) }
}

enum LabStatus {
    // Muted, desaturated status trio — legible without shouting.
    static let red   = Color(red: 0.80, green: 0.30, blue: 0.32)
    static let amber = Color(red: 0.80, green: 0.58, blue: 0.14)
    static let green = Color(red: 0.30, green: 0.66, blue: 0.42)

    // 3-state readiness (compared by value; avoids Color-equality pitfalls).
    enum State { case blocked, attention, ready }   // red, amber, green

    static func color(for s: State) -> Color {
        switch s { case .blocked: return red; case .attention: return amber; case .ready: return green }
    }

    static func color(ready: Int, total: Int) -> Color {
        if ready == 0    { return red }
        if ready < total { return amber }
        return green
    }

    /// Single source of truth for a product's readiness in the current mode:
    ///   blocked (red)     — missing required credentials, or Live is on and a live-capable
    ///                       lab has no API key (it can't run live).
    ///   attention (amber) — configured but not fully ready: the shared model is down, or
    ///                       Mock is on and a live-capable lab has no API key (mock still works).
    ///   ready (green)     — ready to demo in the current mode.
    static func state(_ p: DemoProject, modelRunning: Bool,
                      visionOneKey: String, ngrokToken: String, labMode: String) -> State {
        let configured = projectIsConfigured(p, visionOneKey: visionOneKey,
                                             ngrokToken: ngrokToken, guardMode: "api")
        if !configured { return .blocked }
        if p.usesSharedModel && !modelRunning { return .attention }
        if p.supportsLive && !projectHasLiveKey(p) {
            return labMode == "live" ? .blocked : .attention
        }
        return .ready
    }

    static func productColor(_ p: DemoProject, modelRunning: Bool,
                             visionOneKey: String, ngrokToken: String, labMode: String) -> Color {
        color(for: state(p, modelRunning: modelRunning, visionOneKey: visionOneKey,
                         ngrokToken: ngrokToken, labMode: labMode))
    }

    static func isReady(_ p: DemoProject, modelRunning: Bool,
                        visionOneKey: String, ngrokToken: String, labMode: String) -> Bool {
        guard p.isRunnable else { return false }
        return state(p, modelRunning: modelRunning, visionOneKey: visionOneKey,
                     ngrokToken: ngrokToken, labMode: labMode) == .ready
    }

    static func readyCount(in products: [DemoProject], modelRunning: Bool,
                           visionOneKey: String, ngrokToken: String, labMode: String) -> Int {
        products.filter {
            isReady($0, modelRunning: modelRunning, visionOneKey: visionOneKey,
                    ngrokToken: ngrokToken, labMode: labMode)
        }.count
    }

    /// Roll a precomputed state array into one dot: green only if all ready, red only if
    /// all blocked, amber otherwise. Callers that already mapped states should use this to
    /// avoid recomputing readiness (each state() does several UserDefaults reads).
    static func rollupColor(forStates states: [State]) -> Color {
        if states.isEmpty { return red }
        if states.allSatisfy({ $0 == .ready })   { return green }
        if states.allSatisfy({ $0 == .blocked }) { return red }
        return amber
    }

    /// Convenience: map + roll up in one call (for sites that don't already have states).
    static func rollupColor(in products: [DemoProject], modelRunning: Bool,
                            visionOneKey: String, ngrokToken: String, labMode: String) -> Color {
        rollupColor(forStates: products.map {
            state($0, modelRunning: modelRunning, visionOneKey: visionOneKey,
                  ngrokToken: ngrokToken, labMode: labMode)
        })
    }
}

// MARK: - Window Configurator

private final class WindowAccessView: NSView {
    private var zoomClickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        w.styleMask.formUnion([.resizable, .titled, .closable, .miniaturizable])
        w.minSize = NSSize(width: 960, height: 640)
        w.maxSize = NSSize(width: 99999, height: 99999)
        // Blend the title bar into the dark chrome and hide the title text.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = ""
        // Match the window chrome to the app's page color in both appearances, so there's
        // no mismatched band behind the content. These values mirror Theme.bg0 exactly.
        w.backgroundColor = NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.106, green: 0.106, blue: 0.110, alpha: 1)
                : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.930, alpha: 1)
        }
        installZoomOnDoubleClick(in: w)
    }

    /// The title bar is hidden, so double-clicking the top wouldn't zoom on its own.
    /// This window-level monitor catches a double left-click in the top ~30px band
    /// (clear of the traffic-light buttons) and zooms — independent of SwiftUI layout,
    /// which is why it works where a SwiftUI overlay strip can sit just below the band.
    private func installZoomOnDoubleClick(in w: NSWindow) {
        guard zoomClickMonitor == nil else { return }
        zoomClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak w] event in
            guard let w, event.window === w, event.clickCount == 2,
                  let content = w.contentView else { return event }
            let p = event.locationInWindow                 // origin bottom-left
            let inTopBand = p.y >= content.bounds.height - 30
            let clearOfTrafficLights = p.x > 85
            if inTopBand && clearOfTrafficLights {
                w.zoom(nil)
                return nil                                  // consume the double-click
            }
            return event
        }
    }

    deinit {
        if let m = zoomClickMonitor { NSEvent.removeMonitor(m) }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAccessView { WindowAccessView() }
    func updateNSView(_ v: WindowAccessView, context: Context) {}
}

// MARK: - Window Control Strip (drag + double-click-to-zoom)

/// A transparent strip across the top of the detail pane. Because the title bar is
/// hidden, this restores the two native behaviors that ride on it: drag to move the
/// window, and double-click to zoom (maximize). It spans only the detail pane's top
/// padding, so it stays clear of the traffic-light buttons over the sidebar.
private struct WindowControlStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class StripView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                window?.zoom(nil)                 // double-click → maximize / zoom
            } else {
                window?.performDrag(with: event)  // click-drag → move the window
            }
        }
    }
}

// MARK: - Sidebar Selection

enum SidebarSelection: Hashable {
    case home
    case environment
    case project(DemoProject)
    case settings
}

// MARK: - Root Content View

/// A page reports its natural content height so ContentView can size the console to fill the rest.
struct InstructionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ContentView: View {
    @EnvironmentObject var runner: DemoRunner
    @State private var selection: SidebarSelection? = .home
    @State private var consoleHeight: CGFloat = 300
    @State private var consoleUserSized = false    // set once the user drags the console — pauses auto-fit until they leave the page
    @State private var lastContentH: CGFloat = 0   // most recent page content height, so the Fit button can recompute on demand

    /// The console is for running phases — hide it on the overview/home screen.
    private var showsConsole: Bool {
        // A live run (interactive scan or any phase) pins the console to EVERY page — so its progress
        // stays visible wherever you navigate, and the running scan's terminal is never torn down
        // (which would kill it) just because you switched pages. Once the run finishes it reverts to
        // the per-page rule, so a completed scan stops following you around (the finished terminal
        // stays reviewable on its own page until you Close it).
        if runner.isRunning { return true }
        if case .home = selection { return false }
        if selection == nil { return false }
        return true
    }

    /// The console height that makes the page content fill the pane exactly — the auto-fit target.
    /// 32 ≈ drag handle (18) + console bottom padding (14); floor 80 keeps the console usable, and
    /// the cap keeps ≥140 of the page visible when the content is very short.
    private func fittedHeight(available: CGFloat, contentH: CGFloat) -> CGFloat {
        min(max(available - contentH - 32, 80), max(80, available - 140))
    }

    /// Stable per-page identity so the console auto-fits once when you land on a page.
    private var selectionKey: String {
        switch selection {
        case .home:                return "home"
        case .environment:         return "environment"
        case .project(let p):      return "project:\(p.name)"
        case .settings:            return "settings"
        case nil:                  return "none"
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 232, ideal: 248, max: 280)
        } detail: {
            ZStack {
                AppBackground()
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Group {
                            switch selection {
                            case .home:
                                HomeView(selection: $selection)
                            case .environment:
                                EnvironmentView(selection: $selection)
                            case .project(let project):
                                ProjectDetailView(project: project)
                            case .settings:
                                InlineSettingsView()
                            case nil:
                                EmptyStateView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if showsConsole {
                            ConsoleDragHandle(
                                height: $consoleHeight,
                                minH: 80,
                                maxH: geo.size.height - 120,
                                onManualResize: { consoleUserSized = true }
                            )

                            ConsoleView(runner: runner,
                                        console: runner.console,
                                        height: $consoleHeight,
                                        fullHeight: geo.size.height,
                                        onFit: {
                                            // Snap back to the auto-fitted position and resume tracking.
                                            consoleUserSized = false
                                            guard lastContentH > 1 else { return }
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                consoleHeight = fittedHeight(available: geo.size.height, contentH: lastContentH)
                                            }
                                        })
                                .frame(height: max(80, min(consoleHeight, geo.size.height - 120)))
                                .padding(.horizontal, 16)
                                .padding(.bottom, 14)
                                .id("scan-console")   // stable identity: never remount (and thus never kill) the terminal on navigation
                        }
                    }
                    // Grow the console to fit the interactive wizard when it launches.
                    // Deferred to the next runloop tick so the state write happens
                    // outside SwiftUI's current layout pass (avoids an AttributeGraph cycle).
                    .onChange(of: runner.terminalLaunch?.id) { _, id in
                        guard id != nil else { return }
                        let available = geo.size.height
                        DispatchQueue.main.async {
                            consoleUserSized = true   // the interactive terminal owns the size now
                            let target = max(440, available * 0.55)
                            withAnimation(.easeOut(duration: 0.25)) {
                                consoleHeight = min(target, available - 200)
                            }
                        }
                    }
                    // Landing on a new page re-enables auto-fit — a previous page's manual drag
                    // shouldn't carry over.
                    .onChange(of: selectionKey) { _, _ in consoleUserSized = false }
                    // Size the console to fill EXACTLY the space the page content leaves free — no
                    // more (which would push the content under a scrollbar), no less (a dead gap).
                    // Re-fits whenever the content height changes (e.g. as you tick objectives), so
                    // the scrollbar never appears while you're selecting — until the content alone is
                    // taller than the window, where a small console + scroll is unavoidable. A manual
                    // drag opts out until you leave the page.
                    .onPreferenceChange(InstructionsHeightKey.self) { contentH in
                        guard showsConsole, contentH > 1 else { return }
                        let available = geo.size.height
                        DispatchQueue.main.async {
                            lastContentH = contentH             // remembered so the Fit button can recompute
                            guard !consoleUserSized else { return }
                            consoleHeight = fittedHeight(available: available, contentH: contentH)
                        }
                    }
                }
            }
            // The title bar is hidden, but SwiftUI still reserves its ~50pt as top safe
            // area — which reads as a dead band above every page. Reclaim it; each page
            // supplies its own modest top padding (just clearing the drag strip below).
            .ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .top) {
                // Draggable strip across the top so the window can be moved and
                // double-clicked to zoom even though the title bar is hidden.
                WindowControlStrip()
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
        }
        .alert(item: $runner.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
        .background(WindowConfigurator())
        .onAppear { runner.startModelMonitor() }
    }
}

// MARK: - Sidebar

struct EnvironmentView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject var runner: DemoRunner
    @AppStorage("projectsBasePath")     private var basePath:    String = defaultProjectsPath()
    @AppStorage("env.includedProducts") private var includedCSV: String = ""
    // Bound so the configured state / warnings refresh live as you edit Settings.
    @AppStorage("visionOneAPIKey")        private var visionOneKey: String = ""
    @AppStorage("ngrokToken")             private var ngrokToken:   String = ""
    @AppStorage("aiGuardVisionOneAPIKey") private var aiGuardKey:   String = ""   // observed for live refresh
    @AppStorage(AppSettings.Keys.labMode) private var labMode:      String = "mock"
    @AppStorage(AppSettings.Keys.codeContainerVisionOneAPIKey) private var codeContainerKey: String = ""  // observed for live refresh
    @State private var confirmTeardown = false

    private let noneSentinel = "·none·"
    private var products: [DemoProject] { ProjectCatalog.productsWithEnvironment }

    /// Empty string = never chosen; sentinel = explicitly none; otherwise the saved CSV.
    /// On a fresh launch (never chosen) we do NOT pre-select everything — we start with only the
    /// products that are actually installed and ready to demo (the green ".ready" state). The SE
    /// toggles on anything else they want to include in a setup run. (The binding's `set` seeds
    /// from this set, so making a manual choice preserves the ready ones rather than dropping them.)
    private var includedNames: Set<String> {
        if includedCSV.isEmpty {
            return Set(products.filter { labState($0) == .ready }.map(\.name))
        }
        if includedCSV == noneSentinel { return [] }
        return Set(includedCSV.split(separator: ",").map(String.init))
    }
    private func isIncluded(_ p: DemoProject) -> Bool { includedNames.contains(p.name) }
    /// A product can only be included once its own credentials are set — AI Guard needs
    /// its Vision One key; AI Scanner needs the Vision One key + ngrok token.
    private func isConfigured(_ p: DemoProject) -> Bool {
        projectIsConfigured(p, visionOneKey: visionOneKey, ngrokToken: ngrokToken, guardMode: "api")
    }
    private func binding(for p: DemoProject) -> Binding<Bool> {
        Binding(
            get: { includedNames.contains(p.name) && isConfigured(p) },
            set: { on in
                var s = includedNames
                if on {
                    s.insert(p.name)
                    // Auto-enable any OTHER product whose environment is fully covered by
                    // p's (e.g. selecting AI Scanner also turns AI Guard on, since the
                    // scanner setup already installs everything AI Guard needs). One-way:
                    // turning a product off never cascades to others.
                    for q in products where q.name != p.name
                        && isConfigured(q)
                        && !q.envInstalls.isEmpty
                        && q.envInstalls.isSubset(of: p.envInstalls) {
                        s.insert(q.name)
                    }
                } else {
                    s.remove(p.name)   // deselect only this product
                }
                includedCSV = s.isEmpty ? noneSentinel : s.sorted().joined(separator: ",")
            }
        )
    }

    /// Products that are both toggled on AND configured — the ones that actually drive
    /// setup. Components, slugs, and all gating derive from this single source.
    private var selectedProducts: [DemoProject] {
        products.filter { includedNames.contains($0.name) && isConfigured($0) }
    }
    private var selectedComponents: [EnvironmentComponent] {
        ProjectCatalog.components(forProductNames: Set(selectedProducts.map(\.name)))
    }
    /// Teardown targets EVERYTHING the lab can install, regardless of which products are
    /// toggled on or configured — stopping/removing components needs no credentials, and
    /// a lab left running (e.g. from an earlier setup) must always be removable.
    private var teardownComponents: [EnvironmentComponent] {
        ProjectCatalog.environmentComponents
    }
    /// Quick Teardown removes only what was actually set up (recorded on the last successful
    /// setup and persisted across launches). Falls back to the components of currently-ready
    /// products when there's no record yet — e.g. a lab set up by an older build — so a real
    /// lab is never stranded. Full Teardown still targets everything as the catch-all.
    private var quickTeardownComponents: [EnvironmentComponent] {
        let ids = Set(UserDefaults.standard.stringArray(forKey: DemoRunner.installedComponentsKey) ?? [])
        let recorded = ProjectCatalog.environmentComponents.filter { ids.contains($0.id) }
        if !recorded.isEmpty { return recorded }
        return ProjectCatalog.components(forProductNames: Set(products.filter { labState($0) == .ready }.map(\.name)))
    }
    /// The union of capability tags the selected products install — the single source
    /// for credential gating and the "will install" list.
    private var selectedInstalls: Set<String> {
        selectedProducts.reduce(into: []) { $0.formUnion($1.envInstalls) }
    }

    // Credentials are only needed for the scanner lab (the tmas CLI); model-only or
    // self-contained selections need none. The only credential that gates setup is the
    // Vision One API key (used by tmas to upload findings).
    private var needsCreds: Bool {
        !selectedInstalls.isDisjoint(with: ["tmas"]) && visionOneKey.isEmpty
    }

    /// What setup will actually install, keyed on the same capability tags that scope
    /// the setup scripts — so the list is truthful for any product mix.
    private var installItems: [(symbol: String, title: String, detail: String)] {
        var items: [(symbol: String, title: String, detail: String)] = []
        if selectedInstalls.contains("model") {
            items.append((symbol: "shippingbox.fill",
                          title: "Homebrew",
                          detail: "macOS package manager — installed only if it isn't already present."))
            items.append((symbol: "cpu.fill",
                          title: "Ollama",
                          detail: "Local LLM runtime, served on 127.0.0.1:11434. Installed via Homebrew."))
            items.append((symbol: "brain",
                          title: "LLM model — \(demoModelTag)",
                          detail: "A capable uncensored model (~5 GB), pulled once with Ollama and reused by both demos — large enough that jailbreaks produce real, higher-severity findings. The AI Guard OFF demo leaks the seeded data; the scan surfaces the vulnerabilities."))
        }
        if selectedInstalls.contains("tmas") {
            items.append((symbol: "terminal.fill",
                          title: "tmas CLI",
                          detail: "Trend Micro's Artifact Scanner command-line tool — runs the AI scan. Installed to a user-writable folder (\(TMASInstallDir)) — no admin needed."))
        }
        if selectedInstalls.contains("container-scan") {
            items.append((symbol: "shippingbox.fill",
                          title: "Container runtime (Colima)",
                          detail: "A lightweight Docker daemon via Colima — installed only if none is present. No Docker Desktop required."))
            items.append((symbol: "terminal.fill",
                          title: "tmas CLI",
                          detail: "Trend Micro Artifact Scanner — runs the real container scan and uploads results to Vision One."))
            items.append((symbol: "cube.box.fill",
                          title: "App image",
                          detail: "The deliberately-vulnerable app built into a local image (forge-app) — the artifact the container image scan uploads to Vision One."))
        }
        return items
    }

    /// Where lab.sh installs the tmas CLI (mirrors its TMAS_BIN_DIR choice) — surfaced so
    /// the install list can name the exact, user-writable location.
    private var TMASInstallDir: String {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: "/opt/homebrew/bin") { return "/opt/homebrew/bin" }
        if fm.isWritableFile(atPath: "/usr/local/bin")    { return "/usr/local/bin" }
        return "~/.local/bin"
    }
    private var setupDisabled: Bool {
        runner.isRunning || needsCreds || selectedComponents.isEmpty
    }

    // MARK: Readiness

    /// Friendly display title for a credential key, from the product's own fields or the
    /// shared ngrok section.
    private func credentialTitle(_ key: String, in p: DemoProject) -> String {
        if let f = p.credentials.first(where: { $0.key == key }) { return f.title }
        if let f = SharedCredentials.ngrok.first(where: { $0.key == key }) { return f.title }
        return key
    }

    /// Exactly what a product still needs before it can run, derived from its own
    /// declared credential keys — so the row names the missing piece for ANY product,
    /// and keyless self-contained labs report nothing missing.
    private func missingRequirements(_ p: DemoProject) -> [String] {
        _ = (visionOneKey, ngrokToken, aiGuardKey)   // observed so the list refreshes live
        return p.requiredCredentialKeys
            .filter { (UserDefaults.standard.string(forKey: $0) ?? "").isEmpty }
            .map { credentialTitle($0, in: p) }
    }

    private func labState(_ p: DemoProject) -> LabStatus.State {
        LabStatus.state(p, modelRunning: runner.modelRunning, visionOneKey: visionOneKey,
                        ngrokToken: ngrokToken, labMode: labMode)
    }

    /// The status dot + subtitle shown under each product in the include list.
    private func readinessLabel(_ p: DemoProject) -> (text: String, color: Color) {
        let missing = missingRequirements(p)
        if !missing.isEmpty {
            // Red when nothing's in place yet; amber when only some pieces remain.
            let color = missing.count == p.requiredCredentialKeys.count ? LabStatus.red : LabStatus.amber
            return ("Needs \(missing.joined(separator: ", ")) — open Settings (⌘,)", color)
        }
        if p.usesSharedModel && !runner.modelRunning {
            return ("Configured — run Set Up Environment", LabStatus.amber)
        }
        // Live-capable, self-contained lab (Code & Container): the API key is optional for
        // mock but required for live — so it isn't "configured" green without a key.
        if p.supportsLive && !projectHasLiveKey(p) {
            // In live mode a missing key blocks exactly like any other lab that requires one
            // (e.g. AI Guard), so use the same wording + red. Mock needs no key → amber hint.
            return labMode == "live"
                ? ("Needs Vision One API Key — open Settings (⌘,)", LabStatus.red)
                : ("Mock ready — add a Vision One API key in Settings for live scans", LabStatus.amber)
        }
        if !p.usesSharedModel {
            return ("Self-contained — ready for mock and live", LabStatus.green)
        }
        return ("Ready to demo", LabStatus.green)
    }
    private var readyCount: Int {
        products.filter { labState($0) == .ready }.count
    }

    /// Header pill — shares the LabStatus traffic-light palette with the sidebar dot, so
    /// the two always agree, and shows partial progress (amber) rather than jumping to green.
    private var labStatus: (text: String, color: Color) {
        // Score only the products the SE included in setup — not the ones they left out. Green when
        // every INCLUDED product is ready (its key is in AND the environment is built/running).
        let sel = includedEnvProducts(includedCSV: includedCSV, modelRunning: runner.modelRunning,
                                      visionOneKey: visionOneKey, ngrokToken: ngrokToken, labMode: labMode)
        guard !sel.isEmpty else { return ("Not set up", LabStatus.red) }
        let states = sel.map { labState($0) }
        let total = states.count
        let ready = states.filter { $0 == .ready }.count
        let color = LabStatus.rollupColor(forStates: states)
        if ready == total { return ("Lab ready", color) }
        if ready == 0     { return ("Setup in progress", color) }
        return ("\(ready) of \(total) ready", color)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                // Header
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.surfaceHi)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.stroke, lineWidth: 1))
                            .frame(width: 56, height: 56)
                        Image(systemName: "cpu")
                            .scaledFont(24, weight: .medium)
                            .foregroundStyle(Theme.textSec)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 9) {
                            Text("Environment")
                                .scaledFont(26, weight: .semibold)
                                .foregroundStyle(Theme.textPri)
                            StatusPill(text: labStatus.text, color: labStatus.color)
                        }
                        Text("One screen spins every lab up and down: the shared local model that AI Scanner and AI Guard reuse, plus the seeded demo data the self-contained labs run on.")
                            .scaledFont(13)
                            .foregroundStyle(Theme.textSec)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                Divider().overlay(Theme.stroke)

                // Products to include
                VStack(alignment: .leading, spacing: 12) {
                    Text("Include in setup")
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(Theme.textTer)

                    ForEach(products) { p in
                        // Gate the toggle on the SAME state that drives the status dot, so a red
                        // "Needs API Key" row can't be toggled on (was using isConfigured, which
                        // ignores the optional-but-required-for-live key → the inconsistency).
                        // .blocked = missing a required key, or live mode with no key.
                        let configured = labState(p) != .blocked
                        let status = readinessLabel(p)
                        HStack(spacing: 12) {
                            BrandMark(kind: p.mark, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                    .scaledFont(13, weight: .semibold)
                                    .foregroundStyle(Theme.textPri)
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(status.color)
                                        .frame(width: 6, height: 6)
                                    Text(status.text)
                                        .scaledFont(12)
                                        .foregroundStyle(status.color)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: binding(for: p))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(Theme.accent)
                                .disabled(!configured)
                                .help(configured ? "" : "\(p.name) needs its credentials set in Settings (⌘,)")
                        }
                        .opacity(configured ? 1 : 0.6)
                        .padding(.vertical, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .softCard()

                // What will be installed (deduplicated union)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Will install")
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(Theme.textTer)
                    if installItems.isEmpty {
                        Text("No products selected — nothing to set up.")
                            .scaledFont(12.5)
                            .foregroundStyle(Theme.textSec)
                    } else {
                        ForEach(installItems, id: \.title) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.symbol)
                                    .scaledFont(13)
                                    .foregroundStyle(Theme.textSec)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .scaledFont(12.5, weight: .semibold)
                                        .foregroundStyle(Theme.textPri)
                                    Text(item.detail)
                                        .scaledFont(12)
                                        .foregroundStyle(Theme.textSec)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .softCard()

                // Prerequisite warnings — with a direct path to the fix.
                if needsCreds {
                    HStack(spacing: 10) {
                        Label("Set the Vision One API key before setup.", systemImage: "key.fill")
                            .scaledFont(12, weight: .medium)
                            .foregroundStyle(LabStatus.amber)
                        Button("Open Settings") { selection = .settings }
                            .buttonStyle(.link)
                            .scaledFont(12, weight: .medium)
                            .tint(Theme.accent)
                    }
                }

                // Actions
                HStack(spacing: 10) {
                    Button {
                        runner.runEnvironmentSetup(selectedComponents, selectedProducts: selectedProducts, basePath: basePath)
                    } label: {
                        HStack(spacing: 6) {
                            if runner.isRunningAll {
                                BrandSpinner(size: 12, lineWidth: 1.8, colors: [.white, .white.opacity(0.4)])
                                Text("Setting up…")
                            } else {
                                Image(systemName: "bolt.fill").scaledFont(10, weight: .bold)
                                Text("Set Up Environment")
                            }
                        }
                    }
                    .buttonStyle(PhaseActionButtonStyle(primary: true, disabled: setupDisabled))
                    .disabled(setupDisabled)

                    Button {
                        confirmTeardown = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash").scaledFont(10, weight: .semibold)
                            Text("Teardown")
                        }
                    }
                    .buttonStyle(PhaseActionButtonStyle(primary: false,
                                                        disabled: runner.isRunning,
                                                        destructive: true))
                    .disabled(runner.isRunning)

                    Spacer()

                    Text(runner.batchProgress == nil
                         ? "Output streams in the console below."
                         : "Setting up — full logs are hidden; the console shows each step and any errors.")
                        .scaledFont(12)
                        .foregroundStyle(Theme.textTer)
                }

                // A completion bar instead of the verbose install/build stream.
                if let progress = runner.batchProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(runner.batchLabel.isEmpty ? "Working…" : runner.batchLabel)
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
                    .padding(.top, 6)
                    .transition(.opacity)
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
        .confirmationDialog("Run Teardown?", isPresented: $confirmTeardown, titleVisibility: .visible) {
            Button("Quick Teardown", role: .destructive) {
                runner.runEnvironmentTeardown(quickTeardownComponents, basePath: basePath, full: false)
            }
            Button("Full Teardown — remove model, tools & configs", role: .destructive) {
                runner.runEnvironmentTeardown(teardownComponents, basePath: basePath, full: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Quick Teardown acts only on the labs you actually set up — it stops Ollama, clears runtime state, and removes the seeded demo lab data. The model and tools stay installed so the next demo starts fast.

            Full Teardown sweeps every lab the app can install (in case anything was left behind): it also deletes the local model (~5 GB), uninstalls Ollama, and removes the tmas CLI and saved configs.
            """)
        }
    }
}

// MARK: - Project Detail


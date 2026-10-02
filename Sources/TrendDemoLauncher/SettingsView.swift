import SwiftUI

// MARK: - Native plain text field (keyboard-reliable NSTextField wrapper)

struct NativePlainTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    /// Strip whitespace as you type/paste — for fields that never legitimately contain
    /// spaces (API keys, tokens). Off by default so the console prompt keeps its spaces.
    var trimsWhitespace: Bool = false
    @AppStorage(FontScale.key) private var uiScale: Double = 1.0   // re-applies font size on zoom change

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.font = NSFont.systemFont(ofSize: (13 * CGFloat(uiScale)).rounded())
        f.placeholderString = placeholder
        f.bezelStyle        = .roundedBezel
        f.isBordered        = true
        f.isBezeled         = true
        f.isEditable        = true
        f.isSelectable      = true
        f.isEnabled         = true
        f.focusRingType     = .default
        f.cell?.isScrollable = true
        f.cell?.wraps       = false
        f.delegate          = context.coordinator
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
        f.font                      = NSFont.systemFont(ofSize: (13 * CGFloat(uiScale)).rounded())
        f.placeholderString         = placeholder
        f.isEditable                = true
        f.isEnabled                 = true
        f.delegate                  = context.coordinator
        context.coordinator.binding  = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.trimsWhitespace = trimsWhitespace
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $text, onSubmit: onSubmit, trimsWhitespace: trimsWhitespace)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var binding: Binding<String>
        var onSubmit: (() -> Void)?
        var trimsWhitespace: Bool
        init(binding: Binding<String>, onSubmit: (() -> Void)?, trimsWhitespace: Bool) {
            self.binding  = binding
            self.onSubmit = onSubmit
            self.trimsWhitespace = trimsWhitespace
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // Key/token fields: strip whitespace from a paste immediately (they never
            // contain spaces). Plain fields (console prompt) keep spaces so you can type
            // freely, and only trim when editing ends.
            if trimsWhitespace {
                let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != field.stringValue { field.stringValue = trimmed }
                binding.wrappedValue = trimmed
            } else {
                binding.wrappedValue = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Strip stray leading/trailing whitespace (e.g. from a pasted key) once focus leaves.
            guard let field = obj.object as? NSTextField else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != field.stringValue { field.stringValue = trimmed }
            binding.wrappedValue = trimmed
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit?(); return true
            }
            return false
        }
    }
}

// MARK: - Native secure text field (⌘, Settings panel)

struct NativeSecureField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    @AppStorage(FontScale.key) private var uiScale: Double = 1.0   // re-applies font size on zoom change

    func makeNSView(context: Context) -> NSSecureTextField {
        let f = NSSecureTextField()
        f.font = NSFont.systemFont(ofSize: (13 * CGFloat(uiScale)).rounded())
        f.placeholderString = placeholder
        f.bezelStyle        = .roundedBezel
        f.isBordered        = true
        f.isBezeled         = true
        f.isEditable        = true
        f.isSelectable      = true
        f.isEnabled         = true
        f.focusRingType     = .default
        f.delegate          = context.coordinator
        return f
    }

    func updateNSView(_ f: NSSecureTextField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
        f.font                   = NSFont.systemFont(ofSize: (13 * CGFloat(uiScale)).rounded())
        f.placeholderString      = placeholder
        f.isEditable             = true
        f.isEnabled              = true
        f.delegate               = context.coordinator
        context.coordinator.binding  = $text
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $text, onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var binding:  Binding<String>
        var onSubmit: (() -> Void)?

        init(binding: Binding<String>, onSubmit: (() -> Void)?) {
            self.binding  = binding
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            // Don't trim per keystroke — that blocks typing a space mid-input. Trim on end.
            binding.wrappedValue = (obj.object as? NSTextField)?.stringValue ?? ""
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Strip stray leading/trailing whitespace (e.g. from a pasted key) once focus leaves.
            guard let field = obj.object as? NSTextField else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != field.stringValue { field.stringValue = trimmed }
            binding.wrappedValue = trimmed
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit?(); return true
            }
            return false
        }
    }
}

// MARK: - Settings panel (⌘,)

struct SettingsView: View {
    @AppStorage("projectsBasePath") private var basePath: String = defaultProjectsPath()
    @AppStorage(FontScale.key)      private var uiScale: Double = 1.0
    @EnvironmentObject var runner: DemoRunner

    var body: some View {
        // A content-sized layout (not a scrolling Form), so the ⌘, window grows to fit
        // everything at any interface zoom — no internal scrolling. Width scales with the
        // zoom level so fields don't get cramped when text is enlarged.
        VStack(alignment: .leading, spacing: 16) {

            // ── Appearance ─────────────────────────────────────────────
            AppearancePicker()

            // ── Lab data mode ──────────────────────────────────────────
            LabModePicker()

            // ── Trend Vision One API (live demos) ──────────────────────
            VisionOneAPICard()

            // ── Credentials ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Credentials", systemImage: "key.fill")
                        .scaledFont(13, weight: .semibold)
                    Spacer()
                    Text("Stored locally on this Mac only.")
                        .scaledFont(12).foregroundStyle(.secondary)
                }
                ForEach(ProjectCatalog.all.filter { !$0.credentials.isEmpty }) { project in
                    ProductCredentialsCard(project: project)
                }
            }

            // ── Projects Folder ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Label("Projects Folder", systemImage: "folder.fill")
                    .scaledFont(13, weight: .semibold)
                Text("The folder containing your demo project subfolders (AI Guard, AI Scanner, etc.).")
                    .scaledFont(12).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Path", text: $basePath)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(13, design: .monospaced)
                    Button("Choose…") { chooseFolder() }
                }
                if !FileManager.default.fileExists(atPath: basePath) {
                    Label("Folder not found at this path", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LabStatus.amber).scaledFont(12)
                } else {
                    Label("Folder found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(LabStatus.green).scaledFont(12)
                }
                HStack(spacing: 12) {
                    Button("Reset to default") { basePath = defaultProjectsPath() }
                        .buttonStyle(.link).scaledFont(12)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: basePath)])
                    }
                    .buttonStyle(.link).scaledFont(12)
                    .disabled(!FileManager.default.fileExists(atPath: basePath))
                }
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
            )
        }
        .padding(20)
        .frame(width: 480 * CGFloat(uiScale), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        if let path = pickProjectsFolder(startingAt: basePath) { basePath = path }
    }
}

/// The default demo-projects folder. The app has shipped under a couple of folder names,
/// so probe the known candidates and pick the first that actually contains the lab
/// script — a fresh install then works without the user re-pointing the path.
/// Cached: this was previously used as the non-autoclosure @AppStorage default in several
/// frequently-recreated views, so the disk probe ran on every one of their inits. Resolve
/// it once per launch.
func defaultProjectsPath() -> String { cachedDefaultProjectsPath }

private let cachedDefaultProjectsPath: String = {
    let desktop = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
    let candidates = ["Trend Demo Final", "Trend Demo Launcher"]
    for name in candidates {
        let root = desktop.appending(path: name)
        if FileManager.default.fileExists(atPath: root.appending(path: "AI Scanner/lab.sh").path) {
            return root.path
        }
    }
    return desktop.appending(path: candidates[0]).path
}()

/// Shared Projects-folder picker, used by both the Settings panel and the inline settings
/// sheet so the NSOpenPanel configuration lives in exactly one place. Returns the chosen
/// path, or nil if the user cancelled. `@MainActor` because NSOpenPanel is main-actor only.
@MainActor
func pickProjectsFolder(startingAt current: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories    = true
    panel.canChooseFiles          = false
    panel.allowsMultipleSelection = false
    panel.prompt                  = "Select Projects Folder"
    panel.directoryURL            = URL(fileURLWithPath: current)
    return panel.runModal() == .OK ? panel.url?.path : nil
}

// MARK: - Appearance toggle (Settings ▸ Appearance)

/// System / Light / Dark segmented control. Writes the preference to @AppStorage and applies
/// it immediately by overriding NSApp.appearance. Shared by the Settings window and the
/// in-app settings panel so both stay in sync.
struct AppearancePicker: View {
    @AppStorage(AppearanceMode.key) private var raw = AppearanceMode.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .scaledFont(13, weight: .semibold)
            Picker("Appearance", selection: $raw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Follows your Mac unless overridden. The console stays dark either way.")
                .scaledFont(11).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: raw) { _, newValue in
            (AppearanceMode(rawValue: newValue) ?? .system).apply()
        }
    }
}

// MARK: - Trend Vision One API (live demos)

/// Region codes the live REST/tmas calls understand, with their console URLs.
enum V1Region: String, CaseIterable, Identifiable {
    case us, eu, jp, sg, au, `in`, mea
    var id: String { rawValue }
    var title: String {
        switch self {
        case .us:  return "United States"
        case .eu:  return "Europe"
        case .jp:  return "Japan"
        case .sg:  return "Singapore"
        case .au:  return "Australia"
        case .in:  return "India"
        case .mea: return "Middle East & Africa"
        }
    }
    /// The Vision One console portal for this region.
    var consoleURL: String {
        switch self {
        case .us:  return "https://portal.xdr.trendmicro.com"
        case .eu:  return "https://portal.eu.xdr.trendmicro.com"
        case .jp:  return "https://portal.xdr.trendmicro.co.jp"
        case .sg:  return "https://portal.sg.xdr.trendmicro.com"
        case .au:  return "https://portal.au.xdr.trendmicro.com"
        case .in:  return "https://portal.in.xdr.trendmicro.com"
        case .mea: return "https://portal.mea.xdr.trendmicro.com"
        }
    }
    static func current() -> V1Region {
        V1Region(rawValue: UserDefaults.standard.string(forKey: AppSettings.Keys.v1Region) ?? "us") ?? .us
    }
}

/// The shared tenant region for live labs. API keys are entered per-product (in the
/// Credentials cards below), matching AI Scanner and AI Guard; only the region is shared.
struct VisionOneAPICard: View {
    @AppStorage(AppSettings.Keys.v1Region) private var region = "us"
    @AppStorage(AppSettings.Keys.demoId) private var demoId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Trend Vision One region", systemImage: "globe")
                .scaledFont(13, weight: .semibold)
            Picker("Tenant region", selection: $region) {
                ForEach(V1Region.allCases) { r in
                    Text("\(r.title)  (\(r.rawValue.uppercased()))").tag(r.rawValue)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300, alignment: .leading)
            Text("Where your tenant and keys live — used for live scans and “View in Vision One.” A mismatch returns a 403.")
                .scaledFont(11).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            Label("Demo label", systemImage: "tag")
                .scaledFont(13, weight: .semibold)
            TextField(AppSettings.defaultDemoId, text: $demoId)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300, alignment: .leading)
            Text("Prefixes everything uploaded to Vision One so demos don't collide in a shared tenant. Letters/numbers; blank uses this Mac's name (“\(AppSettings.defaultDemoId)”).")
                .scaledFont(11).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Lab data mode (Mock / Live)

/// Mock vs Live selector. Mock runs labs against seeded sample data (offline, always
/// works); Live runs the labs that support it against real Trend Vision One using your
/// stored API key. Shared by the Settings window and the in-app settings panel.
struct LabModePicker: View {
    @AppStorage(AppSettings.Keys.labMode)  private var mode = "mock"
    @AppStorage(AppSettings.Keys.v1ApiKey) private var v1Key = ""
    @AppStorage(AppSettings.Keys.visionOneAPIKey) private var visionOneKey = ""
    @AppStorage(AppSettings.Keys.aiGuardVisionOneAPIKey) private var aiGuardKey = ""
    @AppStorage(AppSettings.Keys.codeContainerVisionOneAPIKey) private var codeContainerKey = ""

    // Any key that enables a live lab counts — Code & Container is the live lab today and
    // uses its own key, so it must be included or Live falsely warns "no key set".
    private var hasKey: Bool {
        !v1Key.isEmpty || !visionOneKey.isEmpty || !aiGuardKey.isEmpty || !codeContainerKey.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Lab data mode", systemImage: "dot.radiowaves.left.and.right")
                .scaledFont(13, weight: .semibold)
            Picker("Lab data mode", selection: $mode) {
                Text("Mock").tag("mock")
                Text("Live").tag("live")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(mode == "live"
                 ? "Supported labs hit your real Vision One tenant (key below); the rest fall back to Mock."
                 : "Every lab runs on seeded sample data — offline, no tenant needed.")
                .scaledFont(11).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mode == "live" && !hasKey {
                Label("No Vision One API key set — live labs will fall back to Mock. Add a key below.",
                      systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(11, weight: .medium).foregroundStyle(LabStatus.amber)
            }
        }
    }
}

// MARK: - Inline Settings (main window detail panel)

struct InlineSettingsView: View {
    @AppStorage("projectsBasePath") private var basePath: String = defaultProjectsPath()
    @EnvironmentObject var runner: DemoRunner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Header
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.surfaceHi)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Theme.stroke, lineWidth: 1))
                            .frame(width: 56, height: 56)
                        Image(systemName: "gearshape.2.fill")
                            .scaledFont(24).foregroundStyle(Theme.textSec)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Settings")
                            .scaledFont(17, weight: .semibold).foregroundStyle(Theme.textPri)
                        Text("Credentials, region, and the projects folder")
                            .scaledFont(12).foregroundStyle(Theme.textSec)
                    }
                    Spacer()
                }
                .padding(.bottom, 2)

                // Appearance + data mode — two distinct settings kept together as a pair, with a
                // vertical divider between them so it's clear they're separate controls.
                HStack(alignment: .top, spacing: 20) {
                    AppearancePicker().frame(maxWidth: .infinity, alignment: .leading)
                    Divider().overlay(Theme.stroke)
                    LabModePicker().frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)   // let the divider span the taller column
                .settingsCardBG()

                // Trend Vision One — region + demo label.
                VisionOneAPICard().settingsCardBG()

                // Credentials — one card per product with a key slot.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Credentials", systemImage: "key.fill")
                            .scaledFont(13, weight: .semibold).foregroundStyle(Theme.textPri)
                        Spacer()
                        Text("Stored on this Mac — never leaves your machine.")
                            .scaledFont(11).foregroundStyle(.secondary)
                    }
                    ForEach(ProjectCatalog.all.filter { !$0.credentials.isEmpty }) { project in
                        ProductCredentialsCard(project: project)
                    }
                }

                // Projects folder.
                VStack(alignment: .leading, spacing: 8) {
                    Label("Projects folder", systemImage: "folder.fill")
                        .scaledFont(13, weight: .semibold).foregroundStyle(Theme.textPri)
                    HStack {
                        TextField("Path", text: $basePath)
                            .textFieldStyle(.roundedBorder)
                            .scaledFont(13, design: .monospaced)
                        Button("Choose…") { chooseFolder() }
                    }
                    if !FileManager.default.fileExists(atPath: basePath) {
                        Label("Folder not found at this path", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(LabStatus.amber).scaledFont(12)
                    } else {
                        Label("Folder found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(LabStatus.green).scaledFont(12)
                    }
                    HStack(spacing: 12) {
                        Button("Reset to default") { basePath = defaultProjectsPath() }
                            .buttonStyle(.link).scaledFont(12)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: basePath)])
                        }
                        .buttonStyle(.link).scaledFont(12)
                        .disabled(!FileManager.default.fileExists(atPath: basePath))
                    }
                    .padding(.top, 2)
                }
                .settingsCardBG()

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 20)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseFolder() {
        if let path = pickProjectsFolder(startingAt: basePath) { basePath = path }
    }
}

// MARK: - Settings card background

extension View {
    /// Uniform card container for a settings section — matches the credential / projects cards.
    func settingsCardBG() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

// MARK: - Credential Field (binds to a UserDefaults key at runtime)

struct CredentialFieldView: View {
    let field: CredentialField
    @AppStorage private var value: String

    init(field: CredentialField) {
        self.field = field
        _value = AppStorage(wrappedValue: "", field.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.title)
                .scaledFont(12).fontWeight(.medium)
            HStack(spacing: 6) {
                NativePlainTextField(placeholder: field.placeholder, text: $value, trimsWhitespace: true)
                    .frame(height: 22)
                if !value.isEmpty {
                    Button { value = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Clear")
                }
            }
            if !value.isEmpty {
                Label("Entered (\(value.count) chars)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(LabStatus.green).scaledFont(12)
            }
        }
    }
}

// MARK: - Per-Product Credentials Card

struct ProductCredentialsCard: View {
    let project: DemoProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandMark(kind: project.mark, size: 30, dimmed: project.comingSoon)
                HStack(spacing: 6) {
                    Text(project.name).scaledFont(13, weight: .semibold)
                        .foregroundStyle(Theme.textPri)
                    if project.comingSoon {
                        Text("Soon")
                            .scaledFont(10, weight: .medium)
                            .foregroundStyle(Theme.textTer)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.tint(0.06)))
                    }
                }
                Spacer()
            }
            ForEach(Array(project.credentials.enumerated()), id: \.element.id) { index, field in
                if index > 0 { Divider() }
                CredentialFieldView(field: field)
            }
        }
        .padding(16)
        .opacity(project.comingSoon ? 0.75 : 1)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Shared Credentials Card (e.g. ngrok, reused across products)

struct SharedCredentialsCard: View {
    let title: String
    let systemImage: String
    let fields: [CredentialField]
    var link: URL? = nil
    var linkLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surfaceHi)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1))
                        .frame(width: 30, height: 30)
                    Image(systemName: systemImage)
                        .scaledFont(14, weight: .medium).foregroundStyle(Theme.textSec)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).scaledFont(13, weight: .semibold).foregroundStyle(Theme.textPri)
                        Text("Shared")
                            .scaledFont(10, weight: .medium)
                            .foregroundStyle(Theme.textTer)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.tint(0.06)))
                    }
                    if let link {
                        Link(destination: link) {
                            HStack(spacing: 3) {
                                Text(linkLabel ?? link.host ?? "Open")
                                Image(systemName: "arrow.up.right")
                            }
                            .scaledFont(12, weight: .medium)
                            .foregroundStyle(Theme.accent)
                        }
                        .help("Open \(link.absoluteString)")
                    }
                }
                Spacer()
            }
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 { Divider() }
                CredentialFieldView(field: field)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}

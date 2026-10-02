import Foundation

// MARK: - App Settings
//
// Single source of truth for every persisted UserDefaults key. SwiftUI views read these
// via `@AppStorage(AppSettings.Keys.x)`; non-view code (DemoRunner) uses the typed
// accessors below instead of scattering `UserDefaults.standard.string(forKey:)` calls.
enum AppSettings {
    enum Keys {
        static let visionOneAPIKey        = "visionOneAPIKey"
        static let ngrokToken             = "ngrokToken"
        static let aiGuardVisionOneAPIKey = "aiGuardVisionOneAPIKey"
        static let aiGuardRegion          = "aiGuardRegion"
        static let aiGuardEnabled         = "aiGuardEnabled"
        static let aiGuardPolicyId        = "aiGuardPolicyId"
        static let projectsBasePath       = "projectsBasePath"
        static let includedProducts       = "env.includedProducts"
        static let uiScale                = "uiScale"
        static let appearance             = "appearanceMode"   // System / Light / Dark
        static let labMode                = "labMode"          // "mock" | "live"
        static let v1ApiKey               = "v1ApiKey"         // Automation Center token for live REST/tmas
        static let v1Region               = "v1Region"         // tenant region code (us, eu, jp, …)
        static let codeContainerVisionOneAPIKey = "codeContainerVisionOneAPIKey" // Container Security key
        static let demoId                 = "demoId"          // per-deployment label for tenant artifact names
        static let scanMode               = "aiScanMode"        // AI Scanner run mode: "guided" | "wizard"
        static let scanObjectives         = "aiScanObjectives"  // guided-mode selection: CSV of objective names
        static let scanTechniques         = "aiScanTechniques"  // guided-mode selection: CSV of technique names
        static let scanModifiers          = "aiScanModifiers"   // guided-mode selection: CSV of modifier names
        static let scanTarget             = "aiScanTarget"      // guided-mode target: "permissive" | "hardened"

        /// Everything a full ("nuke") teardown should wipe. (demoId is intentionally excluded —
        /// it's this deployment's identity label, not a credential, and should survive a teardown.)
        static let clearable = [
            visionOneAPIKey, ngrokToken,
            aiGuardVisionOneAPIKey, aiGuardRegion, aiGuardEnabled,
            projectsBasePath, includedProducts, uiScale,
            v1ApiKey, v1Region, codeContainerVisionOneAPIKey,
        ]
    }

    private static var ud: UserDefaults { .standard }

    // MARK: Typed accessors (non-SwiftUI reads)

    static var visionOneAPIKey: String { ud.string(forKey: Keys.visionOneAPIKey) ?? "" }
    static var ngrokToken: String { ud.string(forKey: Keys.ngrokToken) ?? "" }
    static var aiGuardKey: String { ud.string(forKey: Keys.aiGuardVisionOneAPIKey) ?? "" }
    static var aiGuardRegion: String { ud.string(forKey: Keys.aiGuardRegion) ?? "us" }
    /// AI Guard defaults to ON; only an explicit `false` disables it.
    static var aiGuardEnabled: Bool { ud.object(forKey: Keys.aiGuardEnabled) as? Bool ?? true }
    static var aiGuardPolicyId: String? {
        let v = ud.string(forKey: Keys.aiGuardPolicyId) ?? ""
        return v.isEmpty ? nil : v
    }
    /// Whether labs run against real Trend Vision One ("live") or seeded sample data
    /// ("mock"). Defaults to mock so the demo always works offline.
    static var labMode: String { ud.string(forKey: Keys.labMode) ?? "mock" }
    static var isLiveMode: Bool { labMode == "live" }

    /// The dedicated Automation Center token for live labs (CREM / Cloud Risk / AI Risk
    /// REST calls, and tmas when no AI Scanner key is set).
    static var v1ApiKey: String { ud.string(forKey: Keys.v1ApiKey) ?? "" }
    /// Tenant region code for the live REST host (us, eu, jp, sg, au, in, mea).
    /// Falls back to the AI Guard region, then US, for continuity.
    static var v1Region: String {
        let v = ud.string(forKey: Keys.v1Region) ?? ""
        if !v.isEmpty { return v }
        let g = ud.string(forKey: Keys.aiGuardRegion) ?? ""
        return g.isEmpty ? "us" : g
    }
    /// The key live REST labs authenticate with: the dedicated token if set, else the
    /// AI Scanner key, else the AI Guard key.
    static var liveAPIKey: String {
        for k in [v1ApiKey, visionOneAPIKey, aiGuardKey] where !k.isEmpty { return k }
        return ""
    }
    /// Code & Container Security's own Vision One key (Container Security scope).
    static var codeContainerKey: String { ud.string(forKey: Keys.codeContainerVisionOneAPIKey) ?? "" }

    /// A stable, per-deployment label included in the names of every artifact this app uploads
    /// to Vision One (Code Security / Container Image scans, the AI-scan model group). This keeps
    /// multiple SEs who share one tenant from overwriting or merging each other's demo data.
    /// Defaults to a sanitized machine name; editable in Settings. Injected into lab scripts as
    /// FORGE_DEMO_ID.
    static var demoId: String {
        let s = (ud.string(forKey: Keys.demoId) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? defaultDemoId : sanitizeDemoId(s)
    }
    /// Machine-name-derived fallback, computed once.
    static let defaultDemoId: String = {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let s = sanitizeDemoId(raw)
        return s.isEmpty ? "demo" : s
    }()
    /// Alphanumerics only, capped — safe as both a filesystem/artifact-name suffix and part of
    /// the AI-scan group name (which allows letters, numbers, and spaces only).
    static func sanitizeDemoId(_ raw: String) -> String {
        let alnum = raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(alnum.prefix(20)))
    }

    /// Default guided-mode selection — the "Fast" preset: high-success objectives + strong jailbreak
    /// techniques + best-of-N, against a permissive target. Lands hard, high success, runs in minutes.
    static let defaultScanObjectives = "Malicious Code Generation,Harmful Content Generation"
    static let defaultScanTechniques = "Ignore all previous instructions,DAN (Do anything now),Sockpuppet (Output prefix injection)"
    static let defaultScanModifiers  = "Best-of-N Scrambling"
    /// Target hardening, injected as FORGE_SCAN_TARGET. "permissive" (Fast) = a plain helpful assistant
    /// the uncensored model complies with → high success; "hardened" (Full) = the realistic
    /// CS-assistant that refuses → true audit.
    static let defaultScanTarget = "permissive"

    /// AI Scanner run mode, injected as FORGE_SCAN_MODE. "guided" (default) = the in-app selector
    /// drives a config-mode scan at a safe concurrency; "wizard" = launch tmas's own interactive tool.
    static var scanMode: String { ud.string(forKey: Keys.scanMode) == "wizard" ? "wizard" : "guided" }
    /// Guided-mode selection, injected as FORGE_SCAN_* CSVs. Falls back to the Fast preset when unset.
    static var scanObjectives: String { ud.string(forKey: Keys.scanObjectives) ?? defaultScanObjectives }
    static var scanTechniques: String { ud.string(forKey: Keys.scanTechniques) ?? defaultScanTechniques }
    static var scanModifiers:  String { ud.string(forKey: Keys.scanModifiers)  ?? defaultScanModifiers }
    static var scanTarget:     String { ud.string(forKey: Keys.scanTarget)     ?? defaultScanTarget }

    /// Remove all app settings (used after a full nuke teardown).
    static func clearAll() {
        Keys.clearable.forEach { ud.removeObject(forKey: $0) }
        ud.synchronize()
    }
}

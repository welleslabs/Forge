import Foundation

// MARK: - Credential Manager
//
// Stateless helpers for staging credentials and building the subprocess environment.
// Pulled out of DemoRunner so all credential/config file I/O lives in one place. Holds no
// observable state, so the runner just calls these directly (no ownership/forwarding).
enum CredentialManager {

    /// Process environment enriched with a sane PATH plus the configured tokens/keys, so
    /// spawned scripts and curl calls see the Vision One / AI Guard credentials.
    static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [extraPaths, env["PATH"] ?? ""].filter { !$0.isEmpty }.joined(separator: ":")
        env["TERM"] = "dumb"
        // Per-deployment label so tenant-facing artifact names are unique across SEs.
        env["FORGE_DEMO_ID"] = AppSettings.demoId
        // AI Scanner run mode + guided-mode selection (the objectives/techniques/modifiers the SE
        // picked in the app). lab.sh builds the scan config from these and runs at a safe concurrency.
        env["FORGE_SCAN_MODE"]       = AppSettings.scanMode
        env["FORGE_SCAN_OBJECTIVES"] = AppSettings.scanObjectives
        env["FORGE_SCAN_TECHNIQUES"] = AppSettings.scanTechniques
        env["FORGE_SCAN_MODIFIERS"]  = AppSettings.scanModifiers
        env["FORGE_SCAN_TARGET"]     = AppSettings.scanTarget
        // tmas prefers the AI Scanner key; otherwise the dedicated live token.
        let tmasKey = AppSettings.visionOneAPIKey.isEmpty ? AppSettings.v1ApiKey : AppSettings.visionOneAPIKey
        if !tmasKey.isEmpty {
            env["TMAS_API_KEY"] = tmasKey
            env["VISION_ONE_API_KEY"] = tmasKey
        }
        // Hybrid mock/live selector every lab.sh reads. Live-capable labs act on it;
        // the rest ignore it. The region + the live token are provided so a live lab
        // has what it needs; if no key is set a lab falls back to mock on its own.
        env["TREND_LAB_MODE"] = AppSettings.labMode
        env["V1_REGION"] = AppSettings.v1Region
        // The token live REST labs authenticate with (dedicated token → scanner → guard).
        let liveKey = AppSettings.liveAPIKey
        if !liveKey.isEmpty { env["V1_API_KEY"] = liveKey }
        // Code & Container Security's own key for its tmas scan (its dedicated slot).
        let ccsKey = AppSettings.codeContainerKey
        if !ccsKey.isEmpty { env["CCS_API_KEY"] = ccsKey }
        // AI Guard proxy (tmguard) — its own Vision One key + published policy id.
        let guardKey = AppSettings.aiGuardKey
        if !guardKey.isEmpty { env["TMGUARD_API_KEY"] = guardKey }
        if let policy = AppSettings.aiGuardPolicyId { env["TMGUARD_POLICY_ID"] = policy }
        return env
    }

    /// Write `TMAS_API_KEY` to ~/.tmas/.env. Returns nil on success, else an error string.
    static func writeTMASKey(_ key: String) -> String? {
        let tmasDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".tmas")
        let envFile = tmasDir.appending(path: ".env")
        do {
            try FileManager.default.createDirectory(at: tmasDir, withIntermediateDirectories: true)
            try "TMAS_API_KEY=\(key)\n".write(to: envFile, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Write the Authorization header to a 0600 curl config file and return its path, so the
    /// API key is passed via `curl -K <file>` — never in argv or the on-screen console.
    static func writeAuthConfig(_ key: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".trend-lab/.v1auth")
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "header = \"Authorization: Bearer \(key)\"\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return path.path
        } catch {
            return nil
        }
    }

}

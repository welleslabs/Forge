import Foundation

// MARK: - DemoRunning
//
// The surface DemoRunner exposes to the UI, factored into a protocol so a lightweight
// mock can drive SwiftUI previews and unit tests without spawning real processes.
//
// Note: SwiftUI's `@EnvironmentObject` / `@ObservedObject` require a concrete
// ObservableObject, so the views still hold a concrete `DemoRunner`. The protocol
// documents the contract and lets tests/previews substitute a conforming stub via a
// generic or by constructing one directly.
@MainActor
protocol DemoRunning: ObservableObject {
    // Console
    var console: ConsoleStore { get }
    var lines: [ConsoleLine] { get }
    var lineRevision: Int { get }
    var consoleBlocks: [ConsoleBlock] { get }

    // Run state
    var isRunning: Bool { get }
    var isInteractive: Bool { get }
    var isRunningAll: Bool { get }
    var isRunningAttacks: Bool { get }
    var currentLabel: String? { get }
    var alert: AlertInfo? { get set }

    // Lab / environment state
    var labReady: Bool { get }
    var modelRunning: Bool { get }
    var wizardEndpoint: String? { get }
    var adminReady: Bool { get }
    var adminPriming: Bool { get }
    var terminalLaunch: TerminalLaunch? { get }

    // Admin access
    func setupAdminAccess()
    func revokeAdminAccess()

    // Environment lifecycle
    func runEnvironmentSetup(_ components: [EnvironmentComponent], selectedProducts: [DemoProject], basePath: String)
    func runEnvironmentTeardown(_ components: [EnvironmentComponent], basePath: String, full: Bool)
    func startModelMonitor()
    func refreshWizardEndpoint()

    // Attacks
    func runGuardAttack(category: String, prompt: String)
    func runAllGuardAttacks(_ attacks: [GuardAttack])
    func runAttack(_ attack: GuardAttack)

    // Execution / console control
    func execute(_ phase: DemoPhase, basePath: String, ngrokToken: String, visionOneAPIKey: String)
    func stop()
    func clear()
    func closeTerminal()
    func terminalDidExit(code: Int32?)
    func openDocument(relativePath: String, basePath: String)
}

// DemoRunner already implements every requirement above.
extension DemoRunner: DemoRunning {}

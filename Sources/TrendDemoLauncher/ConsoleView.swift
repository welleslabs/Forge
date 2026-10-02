import SwiftUI
import AppKit

struct ConsoleView: View {
    @ObservedObject var runner: DemoRunner
    // Observe the console store directly so streamed lines invalidate ONLY this view —
    // not every view that observes `runner` (which caused an app-wide re-render per line).
    @ObservedObject var console: ConsoleStore
    @Binding var height: CGFloat
    let fullHeight: CGFloat   // detail-pane height; presets are fractions of this
    var onFit: (() -> Void)? = nil   // snap the console back to the auto-fitted height

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Theme.textSec)

                Text("Console")
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.textSec)

                Circle()
                    .fill(runner.isRunning ? Color.green : Color.gray.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .animation(.easeInOut(duration: 0.3), value: runner.isRunning)

                if let label = runner.currentLabel {
                    Text(label)
                        .scaledFont(12, weight: .medium, design: .monospaced)
                        .foregroundStyle(Theme.textSec)
                }

                if runner.terminalLaunch != nil {
                    Text("Interactive")
                        .scaledFont(10.5, weight: .medium)
                        .foregroundStyle(Theme.textSec)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                }

                Spacer()

                // Console height presets — tall = half the window, each step halves again.
                HStack(spacing: 2) {
                    if let onFit {
                        Button { onFit() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .scaledFont(12, weight: .semibold)
                        }
                        .buttonStyle(ConsoleBarButtonStyle(tint: .white.opacity(0.7)))
                        .help("Fit to the page — snap the console back to the auto-size that fills the space below the instructions")
                    }
                    consoleSizeButton("rectangle.compress.vertical", fullHeight * 0.125, "Short console")
                    consoleSizeButton("rectangle",                   fullHeight * 0.25,  "Medium console")
                    consoleSizeButton("rectangle.expand.vertical",   fullHeight * 0.5,   "Tall console (half the window)")
                }
                .padding(.trailing, 4)

                if runner.terminalLaunch != nil {
                    // Embedded terminal: Stop while live, Close once exited.
                    if runner.isRunning {
                        Button { runner.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .scaledFont(11, weight: .medium)
                        }
                        .buttonStyle(ConsoleBarButtonStyle(tint: .red))
                    } else {
                        Button { runner.closeTerminal() } label: {
                            Label("Close", systemImage: "xmark")
                                .scaledFont(11, weight: .medium)
                        }
                        .buttonStyle(ConsoleBarButtonStyle(tint: .white.opacity(0.7)))
                    }
                } else {
                    // Stop button (line-console processes)
                    if runner.isRunning {
                        Button {
                            runner.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .scaledFont(11, weight: .medium)
                        }
                        .buttonStyle(ConsoleBarButtonStyle(tint: .red))
                    }

                    // Copy button
                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .scaledFont(11, weight: .medium)
                    }
                    .buttonStyle(ConsoleBarButtonStyle(tint: .white.opacity(0.7)))
                    .disabled(console.lines.isEmpty)

                    // Clear button
                    Button {
                        runner.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .scaledFont(11, weight: .medium)
                    }
                    .buttonStyle(ConsoleBarButtonStyle(tint: .white.opacity(0.7)))
                    .disabled(console.lines.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)

            Divider()
                .overlay(Theme.stroke)

            if let launch = runner.terminalLaunch {
                // Real terminal emulator for the interactive scan wizard.
                TerminalSessionView(
                    launch: launch,
                    onExit: { code in runner.terminalDidExit(code: code) },
                    registerTerminator: { term in runner.terminateTerminal = term }
                )
                .id(launch.id)
                .padding(6)
            } else {
                // Output
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if console.lines.isEmpty {
                                Text("No output yet. Run a phase or type a prompt below to see results here.")
                                    .scaledFont(12, design: .monospaced)
                                    .foregroundStyle(.white.opacity(0.45))
                                    .padding(12)
                            } else {
                                ForEach(console.consoleBlocks) { block in
                                    if block.header != nil {
                                        groupCard(block)
                                    } else {
                                        looseLine(block.lines[0])
                                    }
                                }
                                // Anchor for auto-scroll
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom")
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: console.lineRevision) { _, _ in scrollToBottom(proxy) }
                    // When a phase/run finishes, make sure the final line is visible even if
                    // the last layout settled a beat after the output stopped streaming.
                    .onChange(of: runner.isRunning) { _, running in
                        if !running { scrollToBottom(proxy) }
                    }
                }

                // Input bar — always visible, terminal-style. Active when running.
                Divider()
                    .background(Color.white.opacity(0.06))
                ConsoleInputBar(runner: runner)
            }
        }
        .background(Color(red: 0.055, green: 0.062, blue: 0.082))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
        // The console is a terminal: keep it dark in both app appearances so the bright
        // stdout/stderr line colors always sit on a dark canvas (and the header text,
        // which uses adaptive Theme colors, resolves to its light-on-dark variant).
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Grouping
    //
    // Console lines are folded into `ConsoleBlock`s by the runner (cached against
    // `lineRevision`); the view just renders the result.

    /// One attack, drawn as a filled, bordered card so the break between attacks is obvious.
    private func groupCard(_ block: ConsoleBlock) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(block.header?.text ?? "")
                .scaledFont(12.5, weight: .bold, design: .monospaced)
                .foregroundStyle(Theme.textPri)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(block.lines) { line in
                Text(line.text)
                    .scaledFont(12, design: .monospaced)
                    .foregroundStyle(lineColor(for: line.type))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .id(block.id)
    }

    private func looseLine(_ line: ConsoleLine) -> some View {
        Text(line.text)
            .scaledFont(12, design: .monospaced)
            .foregroundStyle(lineColor(for: line.type))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 1)
            .id(line.id)
    }

    // MARK: - Helpers

    /// Scroll the output to the very last line. Deferred to the next runloop tick so the
    /// just-appended rows are laid out first — otherwise a fast burst (e.g. a full
    /// teardown) scrolls against stale layout and stops short of the completion line.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func lineColor(for type: LineType) -> Color {
        switch type {
        case .stdout:  return Color(red: 0.88, green: 0.93, blue: 0.88)  // Light green-white
        case .stderr:  return Color(red: 1.0, green: 0.4, blue: 0.4)     // Red
        case .stdin:   return Color(red: 0.6, green: 0.8, blue: 1.0)     // Light blue (user input echo)
        case .system:  return Color(red: 0.5, green: 0.7, blue: 1.0)     // Blue
        case .success: return Color(red: 0.3, green: 0.9, blue: 0.5)     // Green
        case .warning: return Color(red: 1.0, green: 0.75, blue: 0.2)    // Yellow
        case .groupHeader: return Theme.textPri                          // (styled in consoleRow)
        }
    }

    private func copyToClipboard() {
        let text = console.lines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Height presets

    @ViewBuilder
    private func consoleSizeButton(_ icon: String, _ target: CGFloat, _ help: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { height = target }
        } label: {
            Image(systemName: icon).scaledFont(12, weight: .semibold)
        }
        .buttonStyle(ConsoleBarButtonStyle(tint: isActiveHeight(target) ? .white : .white.opacity(0.45)))
        .help(help)
    }

    private func isActiveHeight(_ target: CGFloat) -> Bool {
        abs(height - target) < 2
    }
}

// MARK: - Console Bar Button Style

struct ConsoleBarButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Color.white.opacity(0.1) : Color.clear)
            )
    }
}

// MARK: - Console Input Bar

/// The prompt box at the bottom of the console — type any prompt and send it through
/// AI Guard (the result appears as a "Custom" card in the output above).
private struct ConsoleInputBar: View {
    @ObservedObject var runner: DemoRunner
    @State private var inputText = ""

    private var trimmed: String { inputText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty && !runner.isRunning && !runner.isRunningAttacks && runner.modelRunning }

    private func send() {
        guard canSend else { return }
        runner.runGuardAttack(category: "Custom", prompt: trimmed)
        inputText = ""
    }

    var body: some View {
        HStack(spacing: 8) {
            NativePlainTextField(placeholder: "Type a prompt to send to the model, then press Return…",
                                 text: $inputText, onSubmit: send)
                .frame(height: 24)

            Button { send() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").scaledFont(9, weight: .bold)
                    Text("Run").scaledFont(12, weight: .semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(canSend ? Theme.accent : Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
    }
}


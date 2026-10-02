import SwiftUI
import AppKit

/// The app's one filled button (accent, or the muted caution red for destructive
/// actions) plus a quiet bordered variant for secondary actions. Rounded-rect, flat.
struct PhaseActionButtonStyle: ButtonStyle {
    var primary: Bool = true
    var disabled: Bool = false
    var destructive: Bool = false

    private var fill: Color { destructive ? LabStatus.red : Theme.accent }

    func makeBody(configuration: Configuration) -> some View {
        let base = configuration.label
            .scaledFont(12.5, weight: .medium)
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)

        return Group {
            if primary {
                base
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
            } else {
                base
                    .foregroundStyle(destructive ? LabStatus.red : Theme.textPri)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.tint(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.strokeHi, lineWidth: 1))
            }
        }
        .opacity(disabled ? 0.4 : (configuration.isPressed ? 0.85 : 1))
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Copy Button

/// A small copy-to-clipboard button that confirms the click by flashing a green
/// checkmark and the word "Copied" for a moment.
struct CopyButton: View {
    // A provider so expensive strings (e.g. a JSON-serialized curl command) are built only
    // when the user taps Copy — not eagerly on every render of the row that hosts them.
    private let provide: () -> String
    let help: String
    @State private var copied = false

    init(text: String, help: String = "Copy") { self.provide = { text }; self.help = help }
    init(help: String = "Copy", provider: @escaping () -> String) { self.provide = provider; self.help = help }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(provide(), forType: .string)
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .scaledFont(11, weight: .medium)
                if copied {
                    Text("Copied")
                        .scaledFont(11, weight: .medium)
                }
            }
        }
        .buttonStyle(ConsoleBarButtonStyle(tint: copied ? LabStatus.green : Theme.textSec))
        .help(help)
    }
}

// MARK: - Empty / Coming Soon

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            BrandMark(kind: .forge, size: 56)
            VStack(spacing: 5) {
                Text("No Product Selected")
                    .scaledFont(16, weight: .semibold)
                    .foregroundStyle(Theme.textSec)
                Text("Choose a product from the sidebar to get started.")
                    .scaledFont(13)
                    .foregroundStyle(Theme.textTer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Console Drag Handle

struct ConsoleDragHandle: View {
    @Binding var height: CGFloat
    let minH: CGFloat
    let maxH: CGFloat
    var onManualResize: (() -> Void)? = nil
    @State private var isDragging = false
    @State private var dragStart: CGFloat = 0

    var body: some View {
        ZStack {
            Color.clear.frame(height: 18)
            Rectangle()
                .fill(isDragging ? Theme.strokeHi : Theme.stroke)
                .frame(height: 1)
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    Circle()
                        .fill(Theme.textTer.opacity(isDragging ? 0.9 : 0.4))
                        .frame(width: 2.5, height: 2.5)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 18)
        .contentShape(Rectangle())   // make the entire strip the drag target, not just the dots/line
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .highPriorityGesture(
            // Measure in GLOBAL space: the handle moves as the console grows, so a local
            // translation would re-reference the moved view every frame and oscillate.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { val in
                    if !isDragging {
                        isDragging = true
                        dragStart = height
                        onManualResize?()
                    }
                    height = max(minH, min(max(minH, maxH), dragStart - val.translation.height))
                }
                .onEnded { _ in isDragging = false }
        )
    }
}


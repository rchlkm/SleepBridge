import SwiftUI

/// A scrollable, monospace-optional text block with a built-in Copy button.
/// Used for any pipeline/log output shown to the user — Diagnostics' per-stage
/// results and the main screen's recent-run log — so copy behavior stays
/// consistent instead of being reimplemented (and drifting) per screen.
struct CopyableOutputView: View {
  let text: String
  var monospace: Bool = false
  var maxHeight: CGFloat = 150

  @State private var didCopy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Spacer()
        Button {
          UIPasteboard.general.string = text
          didCopy = true
          Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
          }
        } label: {
          Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .disabled(text.isEmpty)
        .animation(.default, value: didCopy)
      }

      ScrollView {
        Text(text)
          .font(monospace ? .system(.caption, design: .monospaced) : .caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .frame(maxHeight: maxHeight)
    }
  }
}

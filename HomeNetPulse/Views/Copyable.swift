import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// One entry in a card's "Copy" context menu.
struct CopyItem: Identifiable {
    var id: String { label }
    var label: String
    var value: String?
}

extension View {
    /// Selectable text plus a right-click / long-press "Copy" menu.
    @ViewBuilder
    func copyable(_ value: String?, label: String? = nil) -> some View {
        if let value, !value.isEmpty, value != "—" {
            self
                .textSelection(.enabled)
                .contextMenu {
                    Button { Clipboard.copy(value) } label: {
                        Label(label.map { "Copy \($0)" } ?? "Copy", systemImage: "doc.on.doc")
                    }
                }
        } else {
            self
        }
    }

    /// Card-level "Copy" menu with several values plus a "Copy All" summary.
    func copyMenu(title: String, items: [CopyItem]) -> some View {
        let present = items.compactMap { item in item.value.flatMap { $0.isEmpty || $0 == "—" ? nil : (item.label, $0) } }
        return contextMenu {
            ForEach(present, id: \.0) { label, value in
                Button { Clipboard.copy(value) } label: { Label("Copy \(label)", systemImage: "doc.on.doc") }
            }
            if present.count > 1 {
                Divider()
                Button {
                    Clipboard.copy(([title] + present.map { "\($0.0): \($0.1)" }).joined(separator: "\n"))
                } label: { Label("Copy All", systemImage: "doc.on.clipboard") }
            }
        }
    }
}

extension View {
    /// Makes a card open on tap while still allowing long-press / right-click context menus
    /// (a Button wrapper swallows the long-press on iOS).
    func tappableCard(_ action: @escaping () -> Void) -> some View {
        self
            .onTapGesture(perform: action)
            // Keep the card's own buttons (Ping, Reboot, Details…) individually accessible.
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Show Details", action)
    }
}

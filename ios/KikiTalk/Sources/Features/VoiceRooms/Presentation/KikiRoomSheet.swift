import SwiftUI

private struct KikiRoomSheetModifier: ViewModifier {
    @State private var selection: PresentationDetent = .medium

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            configured(content).presentationSizing(.form)
        } else {
            configured(content)
        }
    }

    private func configured(_ content: Content) -> some View {
        content
            .presentationDetents([.medium, .large], selection: $selection)
            .presentationDragIndicator(.visible)
            .presentationBackground(KikiPalette.background)
            .presentationCompactAdaptation(.sheet)
            .tint(KikiPalette.purple)
            .onAppear { selection = .medium }
    }
}

extension View {
    func kikiRoomSheet() -> some View {
        modifier(KikiRoomSheetModifier())
    }
}

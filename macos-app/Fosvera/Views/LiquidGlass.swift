import SwiftUI

extension View {
    /// Applies Liquid Glass (macOS 26+) clipped to `shape`, falling back to a
    /// translucent material on earlier systems so the app still builds and runs.
    @ViewBuilder
    func liquidGlass(_ shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

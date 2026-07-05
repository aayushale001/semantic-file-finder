import SwiftUI

/// The app's primary control: a prominent, Liquid Glass search field with an
/// inline scope menu. Sits front-and-center rather than tucked in the toolbar.
struct SearchBar: View {
    @Binding var query: String
    @Binding var scope: SearchScope
    var isSearching: Bool
    var onSubmit: () -> Void
    var onClear: (() -> Void)? = nil

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(focused ? .primary : .secondary)

            TextField("Search your files by meaning…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit(onSubmit)

            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }

            Divider().frame(height: 22)

            Menu {
                Picker("Search in", selection: $scope) {
                    ForEach(SearchScope.allCases) { scope in
                        Label(scope.label, systemImage: scope.systemImage).tag(scope)
                    }
                }
            } label: {
                Label(scope.label, systemImage: scope.systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Limit search to a kind of file")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .liquidGlass(Capsule(), interactive: true)
        .frame(maxWidth: 620)
        .onAppear { focused = true }
    }
}

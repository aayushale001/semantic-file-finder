import SwiftUI

/// Gemini API key setup — shown automatically on first run (no key configured)
/// and from the toolbar's Settings item. "Save & Test" stores the key in the
/// macOS Keychain, restarts the helper so it picks the key up, and validates it
/// with a lightweight metadata call.
struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    @State private var verified = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.blue.gradient, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemini API Key")
                        .font(.title3.weight(.semibold))
                    Text("Your own Gemini key powers indexing and search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Fosvera talks directly to Google's Gemini using a key that belongs to you, so usage counts against your own Google project quota/billing and your files are shared with no one but Google. Google offers a Gemini API free tier for getting started.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                Label("Get a key in Google AI Studio", systemImage: "arrow.up.forward.app")
            }
            .font(.callout)

            HStack(spacing: 8) {
                SecureField("Paste your API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveAndTest() }
                Button(action: saveAndTest) {
                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 74)
                    } else {
                        Text("Save & Test")
                            .frame(width: 74)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isChecking || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Group {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if let warningMessage {
                    Label(warningMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if verified {
                    Label("Key verified and saved to your Keychain.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else if usingDevKey {
                    Label("Currently using a developer environment key. Save a key here to store it in Keychain and use normal app behavior.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 12) {
                if viewModel.hasStoredAPIKey {
                    Button("Remove Key", role: .destructive) {
                        Task {
                            await viewModel.removeAPIKey()
                            verified = false
                            errorMessage = nil
                            warningMessage = nil
                        }
                    }
                    .disabled(isChecking)
                }
                Spacer()
                Text("Stored in the macOS Keychain")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button(verified ? "Done" : "Close") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    /// True when a key works but none is in the Keychain, which can only happen
    /// when the developer explicitly launches with `SFF_ALLOW_APP_ENV_API_KEY=1`.
    private var usingDevKey: Bool {
        viewModel.modelInfo?.hasApiKey == true && !viewModel.hasStoredAPIKey
    }

    private func saveAndTest() {
        guard !isChecking else { return }
        errorMessage = nil
        warningMessage = nil
        verified = false
        isChecking = true
        Task {
            let result = await viewModel.saveAPIKey(apiKey)
            isChecking = false
            switch result {
            case .verified:
                verified = true
                apiKey = ""
            case .savedButUnverified(let warning):
                warningMessage = warning
                apiKey = ""
            case .failed(let failure):
                errorMessage = failure
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: AppViewModel())
}

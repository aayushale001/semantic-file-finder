import AppKit

/// Presents the native "choose a folder" panel and returns the chosen path.
///
/// The folder-picking *action* now lives in the toolbar, so this is a small
/// free function rather than a view.
@MainActor
func chooseFolderPath() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose a folder to index"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path
}

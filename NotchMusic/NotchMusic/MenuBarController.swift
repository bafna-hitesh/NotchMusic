import AppKit
import Combine
import ServiceManagement

final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    let loginItemTitle = "Open at Login"

    @MainActor func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "music.note",
                accessibilityDescription: "NotchMusic"
            )
            button.image?.isTemplate = true
        }
        statusItem = item
        rebuildMenu()

        // Update menu when track info or lyrics toggle changes
        let spotify = SpotifyController.shared
        spotify.$trackName
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        spotify.$artistName
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        LyricsController.shared.$isEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    // MARK: - Menu

    @MainActor private func rebuildMenu() {
        let menu = NSMenu()

        // Track info title
        let infoItem = NSMenuItem()
        let track = SpotifyController.shared.trackName
        let artist = SpotifyController.shared.artistName
        if track.isEmpty {
            infoItem.attributedTitle = disabledTitle("Not Playing")
        } else {
            infoItem.attributedTitle = disabledTitle("\(track)\n\(artist)")
        }
        menu.addItem(infoItem)
        menu.addItem(.separator())

        // Show Lyrics toggle
        let lyricsItem = NSMenuItem(
            title: "Show Lyrics",
            action: #selector(toggleShowLyrics),
            keyEquivalent: ""
        )
        lyricsItem.target = self
        lyricsItem.state = LyricsController.shared.isEnabled ? .on : .off
        menu.addItem(lyricsItem)

        // Open at Login toggle
        let loginItem = NSMenuItem(
            title: loginItemTitle,
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit NotchMusic",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func disabledTitle(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph,
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Actions

    @MainActor @objc private func toggleShowLyrics() {
        LyricsController.shared.isEnabled.toggle()
        rebuildMenu()
    }

    @MainActor @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("[MenuBar] login item toggle failed: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

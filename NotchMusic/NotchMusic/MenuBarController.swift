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
        let mediaController = MediaController.shared
        mediaController.$trackName
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        mediaController.$artistName
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        LyricsController.shared.$isEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        LyricsController.shared.$fontSize
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        LyricsController.shared.$lyricsColor
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
        let track = MediaController.shared.trackName
        let artist = MediaController.shared.artistName
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

        // Lyrics Settings submenu (only when lyrics enabled)
        if LyricsController.shared.isEnabled {
            let lyricsSettingsItem = NSMenuItem(title: "Lyrics Settings", action: nil, keyEquivalent: "")
            let lyricsSettingsSubmenu = NSMenu()

            let fontSizeItem = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")
            let fontSizeSubmenu = NSMenu()
            for size in LyricsFontSize.allCases {
                let item = NSMenuItem(title: size.displayName, action: #selector(setFontSize(_:)), keyEquivalent: "")
                item.target = self
                item.state = LyricsController.shared.fontSize == size ? .on : .off
                fontSizeSubmenu.addItem(item)
            }
            fontSizeItem.submenu = fontSizeSubmenu
            lyricsSettingsSubmenu.addItem(fontSizeItem)

            let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            let colorSubmenu = NSMenu()
            for color in LyricsColorOption.allCases {
                let item = NSMenuItem(title: color.displayName, action: #selector(setLyricsColor(_:)), keyEquivalent: "")
                item.target = self
                item.state = LyricsController.shared.lyricsColor == color ? .on : .off
                colorSubmenu.addItem(item)
            }
            colorItem.submenu = colorSubmenu
            lyricsSettingsSubmenu.addItem(colorItem)

            lyricsSettingsItem.submenu = lyricsSettingsSubmenu
            menu.addItem(lyricsSettingsItem)
        }

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

    @MainActor @objc private func setFontSize(_ sender: NSMenuItem) {
        guard let size = LyricsFontSize.allCases.first(where: { $0.displayName == sender.title }) else { return }
        LyricsController.shared.fontSize = size
    }

    @MainActor @objc private func setLyricsColor(_ sender: NSMenuItem) {
        guard let color = LyricsColorOption.allCases.first(where: { $0.displayName == sender.title }) else { return }
        LyricsController.shared.lyricsColor = color
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

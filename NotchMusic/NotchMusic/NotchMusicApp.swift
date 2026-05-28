import SwiftUI
import AppKit
import Combine

@main
struct NotchMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchWindow: NotchWindow?
    private var globalEventMonitor: Any?
    private var displayChangeObserver: Any?
    private var playbackObserver: Any?
    private var mediaStateObserver: Any?
    private var authResetObserver: Any?
    private var authAttempted = false
    private var cancellables = Set<AnyCancellable>()
    private var quitKeyMonitor: Any?

    private var targetScreen: NSScreen? {
        let builtIn = NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(screenNumber.uint32Value) != 0
        }
        return builtIn ?? NSScreen.main ?? NSScreen.screens.first
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarController.shared.setup()
        setupNotchWindow()
        setupDisplayChangeObserver()
        setupPlaybackObserver()
        setupMediaStateObserver()

        // Toggle mouse passthrough: collapsed = transparent, expanded = interactive
        NotchStateController.shared.$isExpanded
            .sink { [weak self] isExpanded in
                self?.notchWindow?.ignoresMouseEvents = !isExpanded
            }
            .store(in: &cancellables)

        quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }

        notchWindow?.orderFrontRegardless()
        setupGlobalEventMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupMonitors()
        if let monitor = quitKeyMonitor { NSEvent.removeMonitor(monitor) }
        notchWindow?.orderOut(nil)
        notchWindow = nil
    }

    private func cleanupMonitors() {
        removeGlobalEventMonitor()
        if let observer = displayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            displayChangeObserver = nil
        }
        if let observer = playbackObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackObserver = nil
        }
        if let observer = mediaStateObserver {
            NotificationCenter.default.removeObserver(observer)
            mediaStateObserver = nil
        }
        if let observer = authResetObserver {
            NotificationCenter.default.removeObserver(observer)
            authResetObserver = nil
        }
    }

    private func removeGlobalEventMonitor() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }

    private func setupPlaybackObserver() {
        playbackObserver = NotificationCenter.default.addObserver(
            forName: .mediaPlaybackStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let window = self.notchWindow else { return }

            if !window.isVisible {
                window.orderFrontRegardless()
            }
            NotchStateController.shared.expand()

            let spotifyRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
            if !self.authAttempted, spotifyRunning {
                self.authAttempted = true
                let auth = SpotifyAuthController.shared
                print("[App] playback started — isConfigured=\(auth.isConfigured), isAuthenticated=\(auth.isAuthenticated)")
                if auth.isConfigured, !auth.isAuthenticated {
                    print("[App] triggering authenticate()")
                    auth.authenticate()
                }
            }
        }

        authResetObserver = NotificationCenter.default.addObserver(
            forName: .spotifyAuthDidReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.authAttempted = false
        }
    }

    private func setupMediaStateObserver() {
        mediaStateObserver = NotificationCenter.default.addObserver(
            forName: .mediaPlaybackStopped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NotchStateController.shared.collapse()
        }
    }

    private func setupGlobalEventMonitor() {
        guard globalEventMonitor == nil else { return }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let window = self.notchWindow else { return }

            let location = NSEvent.mouseLocation
            let windowFrame = window.frame

            if windowFrame.contains(location) {
                let isExpanded = NotchStateController.shared.isExpanded
                let notchWidth = isExpanded ? NotchConstants.expandedWidth : NotchConstants.collapsedWidth
                let showLyrics = UserDefaults.standard.bool(forKey: "showLyrics")
                let collapsedH = showLyrics
                    ? NotchConstants.collapsedHeightWithLyrics : NotchConstants.collapsedHeight
                let notchHeight = isExpanded ? NotchConstants.expandedHeight : collapsedH

                let notchX = windowFrame.midX - (notchWidth / 2)
                let notchY = windowFrame.maxY - notchHeight
                let notchRect = NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)

                if notchRect.contains(location) {
                    NotchStateController.shared.toggle()
                }
            } else if NotchStateController.shared.isExpanded {
                NotchStateController.shared.collapse()
            }
        }
    }
    
    private func setupDisplayChangeObserver() {
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.repositionWindow()
        }
    }
    
    private func repositionWindow() {
        guard let window = notchWindow, let screen = targetScreen else { return }
        let maxY = screen.frame.maxY
        let x = screen.frame.midX - (NotchConstants.windowWidth / 2)
        window.setFrameTopLeftPoint(NSPoint(x: x, y: maxY))
    }
    
    private func setupNotchWindow() {
        guard let screen = targetScreen else { return }
        
        let maxY = screen.frame.maxY
        let x = screen.frame.midX - (NotchConstants.windowWidth / 2)

        let frame = NSRect(
            x: x,
            y: maxY - NotchConstants.windowHeight,
            width: NotchConstants.windowWidth,
            height: NotchConstants.windowHeight
        )

        notchWindow = NotchWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let hostingView = PassThroughHostingView(rootView: NotchContentView())
        hostingView.frame = NSRect(x: 0, y: 0, width: NotchConstants.windowWidth, height: NotchConstants.windowHeight)

        notchWindow?.contentView = hostingView
        notchWindow?.setFrameTopLeftPoint(NSPoint(x: x, y: maxY))
    }
}

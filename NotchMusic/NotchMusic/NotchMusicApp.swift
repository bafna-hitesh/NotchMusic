import SwiftUI
import AppKit

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
    private var spotifyRunningObserver: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupNotchWindow()
        setupGlobalEventMonitor()
        setupDisplayChangeObserver()
        setupPlaybackObserver()
        setupSpotifyRunningObserver()
        
        // Initially hide if Spotify is not running
        let isSpotifyRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
        if !isSpotifyRunning {
            notchWindow?.orderOut(nil)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanupMonitors()
        notchWindow?.orderOut(nil)
        notchWindow = nil
    }
    
    private func cleanupMonitors() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let observer = displayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            displayChangeObserver = nil
        }
        if let observer = playbackObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackObserver = nil
        }
        if let observer = spotifyRunningObserver {
            NotificationCenter.default.removeObserver(observer)
            spotifyRunningObserver = nil
        }
    }
    
    private func setupPlaybackObserver() {
        playbackObserver = NotificationCenter.default.addObserver(
            forName: .spotifyPlaybackStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let window = self.notchWindow else { return }
            
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            NotchStateController.shared.expand()
        }
    }
    
    private func setupSpotifyRunningObserver() {
        spotifyRunningObserver = NotificationCenter.default.addObserver(
            forName: .spotifyRunningStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let window = self.notchWindow else { return }
            
            let isRunning = notification.userInfo?["isRunning"] as? Bool ?? false
            
            if isRunning {
                window.orderFrontRegardless()
            } else {
                NotchStateController.shared.collapse()
                window.orderOut(nil)
            }
        }
    }
    
    private func setupGlobalEventMonitor() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let window = self.notchWindow else { return }
            
            let location = NSEvent.mouseLocation
            let windowFrame = window.frame
            
            if windowFrame.contains(location) {
                let isExpanded = NotchStateController.shared.isExpanded
                let notchWidth = isExpanded ? NotchConstants.expandedWidth : NotchConstants.collapsedWidth
                let notchHeight = isExpanded ? NotchConstants.expandedHeight : NotchConstants.collapsedHeight
                
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
        guard let window = notchWindow, let screen = NSScreen.main else { return }
        
        let screenFrame = screen.frame
        let x = screenFrame.midX - (NotchConstants.windowWidth / 2)
        window.setFrameTopLeftPoint(NSPoint(x: x, y: screenFrame.maxY))
    }
    
    private func setupNotchWindow() {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.frame
        let x = screenFrame.midX - (NotchConstants.windowWidth / 2)
        
        let frame = NSRect(
            x: x,
            y: screenFrame.maxY - NotchConstants.windowHeight,
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
        notchWindow?.setFrameTopLeftPoint(NSPoint(x: x, y: screenFrame.maxY))
        notchWindow?.orderFrontRegardless()
    }
}

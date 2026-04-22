import SwiftUI
import AppKit
import ServiceManagement

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
    private var statusItem: NSStatusItem?
    private var globalEventMonitor: Any?
    private var displayChangeObserver: Any?
    private var playbackObserver: Any?
    private var launchAtLoginItem: NSMenuItem?
    
    private let windowWidth: CGFloat = 400
    private let windowHeight: CGFloat = 170
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBarIcon()
        setupNotchWindow()
        setupGlobalEventMonitor()
        setupDisplayChangeObserver()
        setupPlaybackObserver()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanupMonitors()
        notchWindow?.orderOut(nil)
        notchWindow = nil
        statusItem = nil
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
    
    private func setupGlobalEventMonitor() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let window = self.notchWindow else { return }
            
            let location = NSEvent.mouseLocation
            let windowFrame = window.frame
            
            if windowFrame.contains(location) {
                let isExpanded = NotchStateController.shared.isExpanded
                let notchWidth: CGFloat = isExpanded ? 400 : 340
                let notchHeight: CGFloat = isExpanded ? 160 : 38
                
                let notchX = windowFrame.midX - (notchWidth / 2)
                let notchY = windowFrame.maxY - notchHeight
                let notchRect = NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
                
                if notchRect.contains(location) {
                    NotchStateController.shared.toggle()
                }
            } else {
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
        let x = screenFrame.midX - (windowWidth / 2)
        window.setFrameTopLeftPoint(NSPoint(x: x, y: screenFrame.maxY))
    }
    
    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NotchMusic")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show/Hide", action: #selector(toggleNotch), keyEquivalent: "n"))
        menu.addItem(NSMenuItem.separator())
        
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem?.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLoginItem!)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchMusic", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    private var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
    
    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    launchAtLoginItem?.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    launchAtLoginItem?.state = .on
                }
            } catch {
                print("Failed to toggle launch at login: \(error)")
            }
        }
    }
    
    private func setupNotchWindow() {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.frame
        let x = screenFrame.midX - (windowWidth / 2)
        
        let frame = NSRect(x: x, y: screenFrame.maxY - windowHeight, width: windowWidth, height: windowHeight)
        
        notchWindow = NotchWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        let hostingView = PassThroughHostingView(rootView: NotchContentView())
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        
        notchWindow?.contentView = hostingView
        notchWindow?.setFrameTopLeftPoint(NSPoint(x: x, y: screenFrame.maxY))
        notchWindow?.orderFrontRegardless()
    }
    
    @objc private func toggleNotch() {
        guard let window = notchWindow else { return }
        
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

import AppKit
import SwiftUI

// Shared constants to avoid magic number duplication
enum NotchConstants {
    static let windowWidth: CGFloat = 400
    static let windowHeight: CGFloat = 170
    static let collapsedWidth: CGFloat = 340
    static let collapsedHeight: CGFloat = 38
    static let expandedWidth: CGFloat = 400
    static let expandedHeight: CGFloat = 160
}

class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let isExpanded = NotchStateController.shared.isExpanded
        
        let width = isExpanded ? NotchConstants.expandedWidth : NotchConstants.collapsedWidth
        let height = isExpanded ? NotchConstants.expandedHeight : NotchConstants.collapsedHeight
        
        let hitRect = NSRect(
            x: (NotchConstants.windowWidth - width) / 2,
            y: NotchConstants.windowHeight - height,
            width: width,
            height: height
        )
        
        if hitRect.contains(point) {
            return super.hitTest(point)
        }
        
        return nil
    }
}

final class NotchWindow: NSWindow {
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var lastMouseUpdateTime: TimeInterval = 0
    private let mouseUpdateThrottleInterval: TimeInterval = 1.0 / 30.0 // Max 30 updates per second
    
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        animationBehavior = .none
        
        setupMouseTracking()
    }
    
    private func setupMouseTracking() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] event in
            self?.throttledUpdateIgnoresMouseEvents()
            return event
        }
        
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.throttledUpdateIgnoresMouseEvents()
        }
    }
    
    private func throttledUpdateIgnoresMouseEvents() {
        let now = CACurrentMediaTime()
        guard now - lastMouseUpdateTime >= mouseUpdateThrottleInterval else { return }
        lastMouseUpdateTime = now
        
        let mouseLocation = NSEvent.mouseLocation
        let isInNotch = isPointInNotchArea(mouseLocation)
        
        if ignoresMouseEvents == isInNotch {
            ignoresMouseEvents = !isInNotch
        }
    }
    
    private func isPointInNotchArea(_ screenPoint: NSPoint) -> Bool {
        let isExpanded = NotchStateController.shared.isExpanded
        
        let notchWidth = isExpanded ? NotchConstants.expandedWidth : NotchConstants.collapsedWidth
        let notchHeight = isExpanded ? NotchConstants.expandedHeight : NotchConstants.collapsedHeight
        
        let windowFrame = frame
        let notchX = windowFrame.midX - (notchWidth / 2)
        let notchY = windowFrame.maxY - notchHeight
        
        let notchRect = NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
        
        return notchRect.contains(screenPoint)
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    
    deinit {
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

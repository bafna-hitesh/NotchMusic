import AppKit
import SwiftUI

class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let isExpanded = NotchStateController.shared.isExpanded
        
        let width: CGFloat = isExpanded ? 400 : 340
        let height: CGFloat = isExpanded ? 160 : 38
        
        let windowWidth: CGFloat = 400
        let windowHeight: CGFloat = 170
        
        let hitRect = NSRect(
            x: (windowWidth - width) / 2,
            y: windowHeight - height,
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
    private var mouseMonitor: Any?
    
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
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.updateIgnoresMouseEvents()
            return event
        }
        
        // Also add global monitor to track mouse when outside the app
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateIgnoresMouseEvents()
        }
    }
    
    private func updateIgnoresMouseEvents() {
        let mouseLocation = NSEvent.mouseLocation
        let isInNotch = isPointInNotchArea(mouseLocation)
        ignoresMouseEvents = !isInNotch
    }
    
    private func isPointInNotchArea(_ screenPoint: NSPoint) -> Bool {
        let isExpanded = NotchStateController.shared.isExpanded
        
        let notchWidth: CGFloat = isExpanded ? 400 : 340
        let notchHeight: CGFloat = isExpanded ? 160 : 38
        
        // Calculate notch rect in screen coordinates
        let windowFrame = frame
        let notchX = windowFrame.midX - (notchWidth / 2)
        let notchY = windowFrame.maxY - notchHeight
        
        let notchRect = NSRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
        
        return notchRect.contains(screenPoint)
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    
    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

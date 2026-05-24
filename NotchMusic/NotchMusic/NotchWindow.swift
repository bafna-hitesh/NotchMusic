import AppKit
import SwiftUI

// Shared constants to avoid magic number duplication
enum NotchConstants {
    static let windowWidth: CGFloat = 390
    static let windowHeight: CGFloat = 170
    static let collapsedWidth: CGFloat = 310
    static let collapsedHeight: CGFloat = 58
    static let expandedWidth: CGFloat = 375
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
    private var trackingArea: NSTrackingArea?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    func installTrackingArea(in view: NSView) {
        trackingArea = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        ignoresMouseEvents = false
    }

    override func mouseExited(with event: NSEvent) {
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

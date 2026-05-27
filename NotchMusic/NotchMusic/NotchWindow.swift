import AppKit
import SwiftUI

// Shared constants to avoid magic number duplication
enum NotchConstants {
    static let windowWidth: CGFloat = 390
    static let windowHeight: CGFloat = 205
    static let collapsedWidth: CGFloat = 310
    static let collapsedHeight: CGFloat = 40
    static let collapsedHeightWithLyrics: CGFloat = 58
    static let expandedWidth: CGFloat = 375
    static let expandedHeight: CGFloat = 195
}

class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let isExpanded = NotchStateController.shared.isExpanded
        
        let width = isExpanded ? NotchConstants.expandedWidth : NotchConstants.collapsedWidth
        let showLyrics = UserDefaults.standard.bool(forKey: "showLyrics")
        let collapsedH = showLyrics
            ? NotchConstants.collapsedHeightWithLyrics : NotchConstants.collapsedHeight
        let height = isExpanded ? NotchConstants.expandedHeight : collapsedH
        
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

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

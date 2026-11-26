import Cocoa
import SwiftUI

final class HUDPanel: NSPanel {
    private let rootContainer: NSView
    private let effectView: NSVisualEffectView
    private var hostingView: NSHostingView<AnyView>?
    private var currentRadius: CGFloat = 14

    private var isPotentialDrag = false
    private var didDrag = false
    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero

    var onDragStateChanged: ((Bool) -> Void)?
    var constrainOrigin: ((NSPoint, NSSize) -> NSPoint)?

    init<Content: View>(rootView: Content, cornerRadius: CGFloat = 14) {
        self.currentRadius = cornerRadius
        self.rootContainer = NSView(frame: NSRect(x: 0, y: 0, width: 272, height: 320))
        self.effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 272, height: 320))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 272, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false

        rootContainer.wantsLayer = true
        rootContainer.layer?.backgroundColor = NSColor.clear.cgColor

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.maskImage = Self.makeRoundedMaskImage(radius: cornerRadius)
        effectView.translatesAutoresizingMaskIntoConstraints = false

        rootContainer.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
        ])

        let hosting = NSHostingView(rootView: AnyView(rootView))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effectView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        self.hostingView = hosting
        self.contentView = rootContainer
        invalidateShadow()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isPotentialDrag = true
            didDrag = false
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = frame.origin
            super.sendEvent(event)

        case .leftMouseDragged:
            guard isPotentialDrag else {
                super.sendEvent(event)
                return
            }
            let currentMouse = NSEvent.mouseLocation
            let dx = currentMouse.x - dragStartMouse.x
            let dy = currentMouse.y - dragStartMouse.y
            if !didDrag {
                if hypot(dx, dy) < 3.0 {
                    super.sendEvent(event)
                    return
                }
                didDrag = true
                onDragStateChanged?(true)
            }
            let candidate = NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)
            let clamped = constrainOrigin?(candidate, frame.size) ?? candidate
            setFrameOrigin(clamped)

        case .leftMouseUp:
            if didDrag {
                isPotentialDrag = false
                didDrag = false
                onDragStateChanged?(false)
                return
            }
            isPotentialDrag = false
            didDrag = false
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    func setCornerRadius(_ radius: CGFloat) {
        guard abs(currentRadius - radius) > 0.1 else { return }
        currentRadius = radius
        effectView.layer?.cornerRadius = radius
        effectView.maskImage = Self.makeRoundedMaskImage(radius: radius)
        invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            self?.invalidateShadow()
        }
    }

    func updateSize(width: CGFloat, height: CGFloat, clamp: ((NSPoint, NSSize) -> NSPoint)? = nil) {
        let clampedHeight = max(32, min(680, ceil(height)))
        let targetSize = NSSize(width: width, height: clampedHeight)
        if abs(frame.size.width - targetSize.width) < 0.5 &&
            abs(frame.size.height - targetSize.height) < 0.5 {
            return
        }
        // Keep top-right corner anchored when expanding/collapsing
        var newOrigin = NSPoint(
            x: frame.maxX - targetSize.width,
            y: frame.maxY - targetSize.height
        )
        if let clamp {
            newOrigin = clamp(newOrigin, targetSize)
        }
        setFrame(NSRect(origin: newOrigin, size: targetSize), display: true, animate: false)
        invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            self?.invalidateShadow()
        }
    }

    private static func makeRoundedMaskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 2
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

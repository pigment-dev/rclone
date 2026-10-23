import AppKit
import Observation
import RCloneKit

/// Draws the menu bar mark as a template NSImage:
/// two chasing arrows forming a ring; at rest the left stroke extends down into a lowercase "r".
/// While syncing: the arrows rotate (≤4 fps) and a thin progress ring circles the mark.
enum MenuIconRenderer {
    static let side: CGFloat = 18

    static func image(state: MenuIconState, rotation: CGFloat, text: String?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.map { ($0 as NSString).size(withAttributes: attrs) } ?? .zero
        let width = side + (text == nil ? 0 : 4 + ceil(textSize.width))
        let image = NSImage(size: NSSize(width: width, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawMark(ctx, state: state, rotation: rotation)
            if let text {
                (text as NSString).draw(at: NSPoint(x: side + 4, y: (side - textSize.height) / 2 + 0.5), withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawMark(_ ctx: CGContext, state: MenuIconState, rotation: CGFloat) {
        let c = CGPoint(x: side / 2, y: side / 2)
        let syncing = state.running
        let dim: CGFloat = state.offline ? 0.35 : (state.paused ? 0.55 : 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if syncing {
            // Progress ring: faint track + solid arc from 12 o'clock, clockwise.
            let r: CGFloat = 8.1
            ctx.setLineWidth(1.3)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.strokePath()
            let fraction = CGFloat(min(1, max(0, (state.percent ?? 0) / 100)))
            if fraction > 0 {
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - fraction * 2 * .pi, clockwise: true)
                ctx.strokePath()
            }
        }

        let ringR: CGFloat = syncing ? 4.6 : 5.6
        let lw: CGFloat = syncing ? 1.6 : 1.85
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setLineWidth(lw)

        ctx.saveGState()
        // Draw opaque into a layer, then apply the dim once (overlaps don't darken).
        ctx.setAlpha(dim)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if syncing {
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: -rotation)
            ctx.translateBy(x: -c.x, y: -c.y)
            // Two symmetric chasing arrows moving clockwise.
            arrow(ctx, c: c, r: ringR, from: 165, to: 25, lw: lw)
            arrow(ctx, c: c, r: ringR, from: 345, to: 205, lw: lw)
        } else {
            // "r": stem on the left rising into the upper arc, plus the lower chasing arrow.
            let stemX = c.x - ringR
            ctx.move(to: CGPoint(x: stemX, y: 1.6))
            ctx.addLine(to: CGPoint(x: stemX, y: c.y))
            ctx.addArc(center: c, radius: ringR, startAngle: .pi, endAngle: rad(28), clockwise: true)
            ctx.strokePath()
            head(ctx, c: c, r: ringR, at: 28, clockwise: true, lw: lw)
            arrow(ctx, c: c, r: ringR, from: 335, to: 232, lw: lw)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        if state.paused { badge(ctx) { pauseGlyph(ctx) } }
        else if state.attention { badge(ctx) { dot(ctx) } }
    }

    private static func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }

    /// Arc from `from`° to `to`° (math angles), clockwise, with an arrow head at `to`.
    private static func arrow(_ ctx: CGContext, c: CGPoint, r: CGFloat, from: CGFloat, to: CGFloat, lw: CGFloat) {
        ctx.addArc(center: c, radius: r, startAngle: rad(from), endAngle: rad(to), clockwise: true)
        ctx.strokePath()
        head(ctx, c: c, r: r, at: to, clockwise: true, lw: lw)
    }

    private static func head(_ ctx: CGContext, c: CGPoint, r: CGFloat, at deg: CGFloat, clockwise: Bool, lw: CGFloat) {
        let a = rad(deg)
        let tip = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        // Tangent direction of travel (clockwise = decreasing angle).
        let t = CGVector(dx: sin(a), dy: -cos(a))
        let n = CGVector(dx: cos(a), dy: sin(a))
        let len: CGFloat = 2.9, wid: CGFloat = 2.3
        let point = CGPoint(x: tip.x + t.dx * 1.2, y: tip.y + t.dy * 1.2)
        let base = CGPoint(x: tip.x - t.dx * (len - 1.2), y: tip.y - t.dy * (len - 1.2))
        ctx.move(to: point)
        ctx.addLine(to: CGPoint(x: base.x + n.dx * wid, y: base.y + n.dy * wid))
        ctx.addLine(to: CGPoint(x: base.x - n.dx * wid, y: base.y - n.dy * wid))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Clears a halo at the top-trailing corner then draws the badge content.
    private static func badge(_ ctx: CGContext, _ draw: () -> Void) {
        let center = CGPoint(x: side - 3.6, y: side - 3.6)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: center.x - 4.4, y: center.y - 4.4, width: 8.8, height: 8.8))
        ctx.restoreGState()
        draw()
    }

    private static func dot(_ ctx: CGContext) {
        let center = CGPoint(x: side - 3.6, y: side - 3.6)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
    }

    private static func pauseGlyph(_ ctx: CGContext) {
        let center = CGPoint(x: side - 3.6, y: side - 3.6)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: center.x - 2.6, y: center.y - 3, width: 1.9, height: 6))
        ctx.fill(CGRect(x: center.x + 0.7, y: center.y - 3, width: 1.9, height: 6))
    }
}

/// Owns the current menu bar image. Redraws only when the visible state changes, at most 4 fps,
/// and runs its animation timer only while something is syncing.
@MainActor
@Observable
final class MenuIconController {
    private(set) var image: NSImage
    private(set) var accessibilityLabel = "PigmentDev rClone"

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private var last: MenuIconState?
    @ObservationIgnored private var lastText: String?
    @ObservationIgnored private var lastDraw = Date.distantPast
    @ObservationIgnored private var rotation: CGFloat = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingRedraw = false

    static let frameInterval: TimeInterval = 0.25

    init(model: AppModel, prefs: Prefs) {
        self.model = model
        self.prefs = prefs
        image = MenuIconRenderer.image(state: MenuIconState(), rotation: 0, text: nil)
        track()
    }

    private func track() {
        withObservationTracking {
            _ = model.menuIconState
            _ = prefs.menuBarText
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.stateChanged()
                self?.track()
            }
        }
        stateChanged()
    }

    private func stateChanged() {
        let state = model.menuIconState.quantised
        let text = state.text(prefs.menuBarText)
        if state.running { startAnimating() } else { stopAnimating() }
        guard state != last || text != lastText else { return }
        last = state
        lastText = text
        scheduleRedraw()
    }

    private func scheduleRedraw() {
        let since = Date().timeIntervalSince(lastDraw)
        if since >= Self.frameInterval { redraw(); return }
        guard !pendingRedraw else { return }
        pendingRedraw = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.frameInterval - since)) { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingRedraw = false
                self?.redraw()
            }
        }
    }

    private func redraw() {
        let state = last ?? MenuIconState()
        image = MenuIconRenderer.image(state: state, rotation: rotation, text: lastText)
        accessibilityLabel = state.accessibilityLabel
        lastDraw = Date()
    }

    private func startAnimating() {
        guard timer == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let t = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rotation = (self.rotation + .pi / 6).truncatingRemainder(dividingBy: .pi) // symmetric: loop every 180°
                self.redraw()
            }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopAnimating() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        rotation = 0
        scheduleRedraw()
    }
}

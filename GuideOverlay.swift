import SwiftUI

/// Shows the scan route as arrows on a 3D oval half-shell around the face.
/// The shell covers the front and both sides (ear to ear), not the back of the head.
/// Visible before Start. ContentView hides it when scanning starts.
struct GuideOverlay: View {

    // theta = left/right angle. 0 = straight at the face.
    //         +90 = ear on the right of the screen, -90 = ear on the left.
    // phi   = up/down angle. 0 = eye level. Negative = toward the chin.
    //         Positive = toward the forehead.
    // To flip left and right, change the sign of every theta value.
    private static let corners: [(theta: Double, phi: Double)] = [
        (0, 0),        // start: front, middle
        (90, 0),       // sweep to the right ear
        (-90, 0),      // across to the left ear
        (0, 0),        // back to the middle
        (8, -35),      // down to the chin
        (90, -35),     // right
        (-90, -35),    // left
        (-8, -35),     // back to the middle
        (-8, 35),      // up to the forehead
        (90, 35),      // right
        (-90, 35)      // left: end
    ]

    // Oval shape of the shell: width, height, depth.
    private static let radii = (x: 1.0, y: 1.25, z: 0.9)
    // View tilt in radians (camera looks slightly down at the head).
    private static let tilt = 22.0 * Double.pi / 180
    private static let stepsPerLeg = 24

    private let loopSeconds: Double = 16

    private struct Route {
        var points: [CGPoint] = []
        var legs: [(start: Int, end: Int)] = []
        var cumulative: [CGFloat] = [0]
        var total: CGFloat { cumulative.last ?? 0 }
    }

    private let route = GuideOverlay.makeRoute()

    var body: some View {
        ZStack {
            TimelineView(.animation) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let phase = seconds.truncatingRemainder(dividingBy: loopSeconds) / loopSeconds
                Canvas { context, size in
                    render(context: context, size: size, phase: phase)
                }
            }

            VStack(spacing: 6) {
                Text("Move the phone along the path")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                Text("Press Start when you are ready. This guide then hides.")
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                Spacer()
            }
            .padding(.top, 60)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 3D to 2D

    /// Point on the oval shell, projected to the screen.
    /// Result is in unit coordinates: x from -1 to 1, y positive = down.
    private static func project(theta: Double, phi: Double) -> CGPoint {
        let t = theta * Double.pi / 180
        let p = phi * Double.pi / 180
        let x = radii.x * cos(p) * sin(t)
        let y = radii.y * sin(p)
        let z = radii.z * cos(p) * cos(t)
        let screenY = -(y * cos(tilt)) + z * sin(tilt)
        return CGPoint(x: x, y: screenY)
    }

    private static func makeRoute() -> Route {
        var r = Route()
        for i in 0..<(corners.count - 1) {
            let a = corners[i]
            let b = corners[i + 1]
            let startIndex = (i == 0) ? 0 : r.points.count - 1
            for s in 0...stepsPerLeg {
                if i > 0 && s == 0 { continue }
                let f = Double(s) / Double(stepsPerLeg)
                r.points.append(project(theta: a.theta + (b.theta - a.theta) * f,
                                        phi: a.phi + (b.phi - a.phi) * f))
            }
            r.legs.append((start: startIndex, end: r.points.count - 1))
        }
        var sum: CGFloat = 0
        for i in 1..<r.points.count {
            sum += hypot(r.points[i].x - r.points[i - 1].x,
                         r.points[i].y - r.points[i - 1].y)
            r.cumulative.append(sum)
        }
        return r
    }

    // MARK: - Drawing

    private func render(context: GraphicsContext, size: CGSize, phase: Double) {
        let cx = size.width / 2
        let cy = size.height * 0.36
        let hw = size.width * 0.38
        let hh = size.height * 0.20

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: cx + p.x * hw, y: cy + p.y * hh)
        }

        // Faint wireframe of the oval shell
        let faint = GraphicsContext.Shading.color(.white.opacity(0.28))
        for theta in stride(from: -90.0, through: 90.0, by: 30.0) {
            var line = Path()
            var first = true
            for phi in stride(from: -65.0, through: 65.0, by: 5.0) {
                let p = map(GuideOverlay.project(theta: theta, phi: phi))
                if first { line.move(to: p); first = false } else { line.addLine(to: p) }
            }
            context.stroke(line, with: faint, lineWidth: 1)
        }
        for phi in [-60.0, -35.0, 0.0, 35.0, 60.0] {
            var line = Path()
            var first = true
            for theta in stride(from: -90.0, through: 90.0, by: 5.0) {
                let p = map(GuideOverlay.project(theta: theta, phi: phi))
                if first { line.move(to: p); first = false } else { line.addLine(to: p) }
            }
            context.stroke(line, with: faint, lineWidth: 1)
        }

        // Route
        var routePath = Path()
        routePath.move(to: map(route.points[0]))
        for p in route.points.dropFirst() {
            routePath.addLine(to: map(p))
        }
        context.stroke(routePath,
                       with: .color(.yellow.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

        // Arrow head in the middle of each leg
        for leg in route.legs {
            let mid = (leg.start + leg.end) / 2
            let before = map(route.points[mid - 1])
            let after = map(route.points[mid + 1])
            drawArrow(context,
                      at: map(route.points[mid]),
                      angle: atan2(after.y - before.y, after.x - before.x))
        }

        // Start (green) and end (red)
        drawMarker(context, at: map(route.points[0]), color: .green, label: "Start")
        drawMarker(context, at: map(route.points[route.points.count - 1]), color: .red, label: "End")

        // Moving dot
        let dot = map(position(at: phase))
        let r: CGFloat = 10
        let dotRect = CGRect(x: dot.x - r, y: dot.y - r, width: 2 * r, height: 2 * r)
        context.fill(Path(ellipseIn: dotRect), with: .color(.white))
        context.stroke(Path(ellipseIn: dotRect), with: .color(.yellow), lineWidth: 3)
    }

    private func drawArrow(_ context: GraphicsContext, at p: CGPoint, angle: CGFloat) {
        let s: CGFloat = 12
        var tri = Path()
        tri.move(to: CGPoint(x: s, y: 0))
        tri.addLine(to: CGPoint(x: -s * 0.7, y: s * 0.6))
        tri.addLine(to: CGPoint(x: -s * 0.7, y: -s * 0.6))
        tri.closeSubpath()
        let transform = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: angle)
        context.fill(tri.applying(transform), with: .color(.yellow))
    }

    private func drawMarker(_ context: GraphicsContext, at p: CGPoint, color: Color, label: String) {
        let r: CGFloat = 7
        context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(color))
        context.draw(Text(label).font(.caption.bold()).foregroundColor(.white),
                     at: CGPoint(x: p.x, y: p.y - 18))
    }

    /// Point on the route for phase 0...1 (unit coordinates).
    private func position(at phase: Double) -> CGPoint {
        let pts = route.points
        let cum = route.cumulative
        let d = CGFloat(phase) * route.total
        for i in 1..<cum.count {
            if d <= cum[i] {
                let seg = cum[i] - cum[i - 1]
                let f = seg == 0 ? 0 : (d - cum[i - 1]) / seg
                let a = pts[i - 1]
                let b = pts[i]
                return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            }
        }
        return pts[pts.count - 1]
    }
}

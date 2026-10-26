import AppKit

/// Pure geometry checks: no window enumeration, desktop input, permissions,
/// screenshots, or application launch is involved.
@main
struct WindowInteractionTests {
    static func main() {
        typealias Geometry = WindowInteractionGeometry
        typealias Span = WindowInteractionGeometry.Span
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }
        let display = CGRect(x: 0, y: 30, width: 1440, height: 840)
        let left = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let upper = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        check(Geometry.appKitRect(fromQuartz: CGRect(x: 100, y: 100, width: 500, height: 300), primaryTop: 900) == CGRect(x: 100, y: 500, width: 500, height: 300), "primary display converts top-left to bottom-left")
        check(Geometry.appKitRect(fromQuartz: CGRect(x: -1600, y: 700, width: 400, height: 400), primaryTop: 900) == CGRect(x: -1600, y: -200, width: 400, height: 400), "negative x and below-primary offsets")
        check(Geometry.appKitRect(fromQuartz: CGRect(x: 100, y: -800, width: 600, height: 300), primaryTop: 900) == CGRect(x: 100, y: 1400, width: 600, height: 300), "display above primary uses negative Quartz y")
        check(Geometry.appKitRect(fromQuartz: CGRect(x: 1500, y: 50, width: 600, height: 300), primaryTop: 1080).minY == 730, "primary height is explicit and does not follow focused display")
        check(Geometry.floorScreen(for: CGPoint(x: -1000, y: 300), screens: [display, left]) == left, "left display floor selection")
        check(Geometry.floorScreen(for: CGPoint(x: 500, y: 1500), screens: [display, upper]) == upper, "upper display floor selection")
        check(Geometry.floorScreen(for: CGPoint(x: 500, y: -200), screens: [display]) == display, "off-screen position returns nearest screen")
        check(Geometry.floorScreen(for: .zero, screens: []) == nil, "no displays yields no floor")
        let feet = CGPoint(x: 208, y: 82)
        let floor = Geometry.floorOrigin(for: CGPoint(x: 800, y: 500), screens: [display], bodyWidth: 100, anchor: feet)!
        check(floor.y + feet.y == display.minY, "visible sprite feet touch Dock-safe floor")
        check(floor.y < 0, "transparent panel may extend below display")
        let edgeFloor = Geometry.floorOrigin(for: CGPoint(x: 1430, y: 200), screens: [display], bodyWidth: 100, anchor: feet)!
        check(edgeFloor.x + feet.x == display.maxX - 50, "clamp uses visible body width, not panel width")
        let ledge = CGRect(x: 200, y: 200, width: 600, height: 300)
        func spans(_ occluders: [CGRect] = [], window: CGRect = ledge) -> [Span] {
            Geometry.usableTopSpans(window: window, screen: display, occluders: occluders, bodyWidth: 100, headClearance: 150)
        }
        check(spans() == [Span(lower: 256, upper: 744)], "visible edge has body-size padding")
        check(spans([CGRect(x: 150, y: 490, width: 700, height: 200)]).isEmpty, "fully occluded edge rejected")
        let partial = spans([CGRect(x: 400, y: 490, width: 200, height: 200)])
        check(partial == [Span(lower: 256, upper: 341), Span(lower: 659, upper: 744)], "partial occlusion splits safe contact spans")
        check(spans([CGRect(x: 400, y: 250, width: 200, height: 100)]) == spans(), "window below the ledge does not occlude its top")
        check(spans(window: CGRect(x: 200, y: 600, width: 600, height: 200)).isEmpty, "insufficient headroom rejects top")
        check(spans(window: CGRect(x: 200, y: -100, width: 600, height: 100)).isEmpty, "off-screen top rejected")
        check(spans(window: CGRect(x: 200, y: 200, width: 100, height: 100)).isEmpty, "tiny utility windows rejected")
        let seat = CGPoint(x: 148, y: 138)
        let original = Geometry.followedOrigin(window: ledge, fraction: 0.5, spans: spans(), anchor: seat)!
        let movedWindow = ledge.offsetBy(dx: 80, dy: -60)
        let moved = Geometry.followedOrigin(window: movedWindow, fraction: 0.5, spans: spans(window: movedWindow), anchor: seat)!
        check(moved == CGPoint(x: original.x + 80, y: original.y - 60), "perch follows window movement")
        let resizedWindow = CGRect(x: 200, y: 150, width: 800, height: 400)
        let resized = Geometry.followedOrigin(window: resizedWindow, fraction: 0.5, spans: spans(window: resizedWindow), anchor: seat)!
        check(resized.x + seat.x == resizedWindow.midX && resized.y + seat.y == resizedWindow.maxY, "resize preserves fractional seat contact")
        let largerSeat = CGPoint(x: 170, y: 160)
        let rescaledPet = Geometry.followedOrigin(window: ledge, fraction: 0.5, spans: spans(), anchor: largerSeat)!
        check(rescaledPet.x + largerSeat.x == original.x + seat.x && rescaledPet.y + largerSeat.y == original.y + seat.y, "changing pet size preserves world seat contact")
        check(Geometry.followedOrigin(window: nil, fraction: 0.5, spans: [], anchor: seat) == nil, "missing or off-Space target detaches")
        check(Geometry.followedOrigin(window: ledge, fraction: 0.5, spans: [], anchor: seat) == nil, "newly occluded target detaches")
        let fallback = Geometry.floorOrigin(for: CGPoint(x: original.x + seat.x, y: ledge.maxY), screens: [display], bodyWidth: 100, anchor: feet)!
        check(fallback.y + feet.y == display.minY, "lost-window fallback stands on visible floor")
        print("Passed \(count) window-interaction geometry checks.")
    }
}

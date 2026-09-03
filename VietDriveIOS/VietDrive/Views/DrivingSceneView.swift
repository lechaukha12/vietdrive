import SwiftUI

/// Symbolic ribbon approved in the mockups: data controls events, never the road silhouette.
struct DrivingSceneSurface: View {
    let scene: DrivingScene
    let speed: Int
    let isAnimating: Bool
    let hasNearbyAlert: Bool
    var image: (String) -> Image = { Image($0) }
    var supplementalEvents: [DrivingSceneEvent] = []
    var reservedSignRects: [CGRect] = []
    @State private var motion = DrivingSceneMotion()
    @State private var frameClock = DrivingSceneFrameClock()

    var body: some View {
        TimelineView(.animation(minimumInterval: ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 30 : 1.0 / 60,
                                paused: !isAnimating)) { timeline in
            let distance = motion.value(at: timeline.date)
            let advance = frameClock.advance(speed: speed, running: isAnimating, at: timeline.date)
            let events = DrivingRibbon.visibleEvents(scene.events + supplementalEvents).map { event in
                var visual = event
                // Current bridge/tunnel stays anchored until the data says we have left it.
                if event.distanceMeters > 1 { visual.distanceMeters = max(0, event.distanceMeters - advance) }
                return visual
            }
            Canvas { context, size in
                DrivingRibbonDrawing.draw(in: &context, size: size, events: events, travel: distance)
                for actor in DrivingTrafficActor.placements(scene: scene, distance: distance, crowded: hasNearbyAlert,
                                                            events: events)
                    .sorted(by: { $0.point.z > $1.point.z }) {
                    let frame = actor.frame(in: size)
                    let point = CGPoint(x: frame.midX, y: frame.maxY)
                    let scale = DrivingRibbon.depth(actor.point.z)
                    let width = frame.width
                    let stride = actor.pedestrian && isAnimating ? sin(distance * 1.8 + Double(actor.id)) * scale : 0
                    var layer = context
                    layer.opacity = actor.opacity
                    layer.fill(Path(ellipseIn: CGRect(x: point.x - width * 0.26, y: point.y - 2,
                                                     width: width * 0.52, height: width * 0.08)),
                               with: .color(DriveTheme.ink.opacity(0.08)))
                    layer.draw(image(actor.asset), in: frame.offsetBy(dx: 0, dy: stride))
                }
                DrivingRibbonDrawing.annotations(in: &context, size: size, events: events, excluding: reservedSignRects)
            }
        }
        .onAppear { motion.update(speed: speed, running: isAnimating); frameClock.receive() }
        .onChange(of: speed) { _, _ in motion.update(speed: speed, running: isAnimating) }
        .onChange(of: isAnimating) { _, _ in motion.update(speed: speed, running: isAnimating); frameClock.receive() }
        .onChange(of: scene.sampleKey) { _, _ in frameClock.receive() }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .black, location: 0.22),
                                     .init(color: .black, location: 0.94),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DrivingTrafficActor {
    /// Exactly two equal-width lanes: same-direction traffic on the right, decorative oncoming on the left.
    enum Lane: Double {
        case leftWalkway = -1.34, leftShoulder = -0.82, leftVehicle = -0.5
        case rightVehicle = 0.5, rightShoulder = 0.82, rightWalkway = 1.34
    }
    let id: Int
    /// Illustrative metres on the straight ribbon, not real road or vehicle coordinates.
    let lane: Lane
    let distanceMeters: Double
    var point: DrivingScenePoint { .init(x: lane.rawValue * 4, z: distanceMeters) }
    let asset: String
    let motorbike: Bool
    let opacity: Double
    var pedestrian = false

    func frame(in size: CGSize) -> CGRect {
        let depth = DrivingRibbon.depth(distanceMeters)
        let center = DrivingRibbon.point(distance: distanceMeters, side: lane.rawValue, size: size)
        let halfRoadWidth = DrivingRibbon.point(distance: distanceMeters, side: 1, size: size).x - size.width / 2
        // Enforce the whole sprite's bounds, not just its centre, on its assigned side.
        let offset = abs(center.x - size.width / 2)
        let width = min(size.height * 0.26,
                        size.width * (pedestrian ? 0.13 : motorbike ? 0.17 : 0.18)) * depth
        let edgeSlope = size.width * 0.365 / (size.height * 0.92)
        let safeWidth = pedestrian ? min(width, max(0, offset - halfRoadWidth) * 2)
            : max(0, min(width, (offset - 2) * 2, (halfRoadWidth - offset - 2) / (0.5 + edgeSlope)))
        return CGRect(x: center.x - safeWidth / 2, y: center.y - safeWidth,
                      width: safeWidth, height: safeWidth)
    }

    static func placements(scene: DrivingScene, distance: Double, crowded: Bool,
                           events: [DrivingSceneEvent]? = nil) -> [Self] {
        guard distance.isFinite else { return [] }
        let bikes = scene.isLocated && !scene.primaryHighway.hasPrefix("motorway")
        var specs: [(Int, String, Bool, Bool, Lane, Double, Double)] = []
        // Two rows instead of four: half the vehicle seeds, with the same fixed-side lanes.
        for index in 0..<2 {
            let offset = Double(index) * 230
            specs.append((index * 4, index.isMultiple(of: 2) ? "DrivingSedanRear" : "DrivingSUVRear",
                          false, false, .rightVehicle, 185 + offset, 0.10))
            if bikes {
                specs.append((index * 4 + 1, "DrivingMotorbikeRear", true, false, .rightShoulder, 230 + offset, -0.20))
            }
            // Explicitly decorative: never switches to rear-facing cars when map metadata changes.
            specs.append((index * 4 + 2, "DrivingSUVFront", false, false, .leftVehicle, 90 + offset, -1.25))
            if bikes { specs.append((index * 4 + 3, "DrivingMotorbikeFront", true, false, .leftShoulder, 155 + offset, -1.1)) }
        }
        if crowded { specs = Array(specs.prefix(3)) }
        if scene.allowsPedestrians {
            for index in 0..<6 {
                let left = index.isMultiple(of: 2)
                specs.append((100 + index, left ? "DrivingPedestrianFront" : "DrivingPedestrianRear", false, true,
                              left ? .leftWalkway : .rightWalkway, 45 + Double(index) * 73, -0.95))
            }
        }
        var result: [Self] = []
        for (id, asset, bike, pedestrian, lane, start, rate) in specs {
            // Same-direction sprites remain ahead of Mazda instead of looping through the user's car.
            let minimum = lane.rawValue > 0 && !pedestrian ? 180.0 : 25.0
            let span = 525 - minimum
            let raw = start - minimum + distance * rate
            let meters = minimum + ((raw.truncatingRemainder(dividingBy: span) + span).truncatingRemainder(dividingBy: span))
            guard !(events ?? scene.events).contains(where: {
                ($0.cutsRoad || $0.kind == .toll || $0.kind == .tunnel) && abs($0.distanceMeters - meters) < 25
            }),
                  !result.contains(where: { $0.lane == lane && abs($0.distanceMeters - meters) < 18 }) else { continue }
            let opacity = min(0.68, (meters - 25) / 32, (540 - meters) / 460)
            result.append(.init(id: id, lane: lane, distanceMeters: meters, asset: asset,
                                motorbike: bike, opacity: max(0, opacity), pedestrian: pedestrian))
        }
        return result
    }
}

/// A bounded handful of paths each frame. No road mesh, map polygons or parallel-road layers.
private enum DrivingRibbonDrawing {
    static func draw(in context: inout GraphicsContext, size: CGSize,
                     events: [DrivingSceneEvent], travel: Double) {
        let junctions = events.filter(\.cutsRoad)
        var floor = Path()
        floor.addLines([DrivingRibbon.point(depth: 0, side: -1, size: size),
                        DrivingRibbon.point(depth: 0, side: 1, size: size),
                        DrivingRibbon.point(depth: 1.08, side: 1, size: size),
                        DrivingRibbon.point(depth: 1.08, side: -1, size: size)])
        floor.closeSubpath()
        context.fill(floor, with: .color(.white.opacity(0.055)))
        for side in [-1.0, 1.0] {
            let gaps = junctions.filter { side < 0 ? $0.left : $0.right }
                .sorted { $0.distanceMeters > $1.distanceMeters }
            var edge = Path()
            edge.move(to: DrivingRibbon.point(depth: 0, side: side, size: size))
            for event in gaps {
                let far = DrivingRibbon.point(distance: event.distanceMeters + 12, side: side, size: size)
                let near = DrivingRibbon.point(distance: max(0, event.distanceMeters - 12), side: side, size: size)
                let radius = min(10, max(3, (near.y - far.y) * 0.45))
                let outside = side < 0 ? -20.0 : size.width + 20
                edge.addLine(to: CGPoint(x: far.x, y: far.y - radius))
                edge.addQuadCurve(to: CGPoint(x: far.x + side * radius, y: far.y),
                                  control: CGPoint(x: far.x, y: far.y))
                edge.addLine(to: CGPoint(x: outside, y: far.y))
                edge.move(to: CGPoint(x: outside, y: near.y))
                edge.addLine(to: CGPoint(x: near.x + side * radius, y: near.y))
                edge.addQuadCurve(to: CGPoint(x: near.x, y: near.y + radius),
                                  control: CGPoint(x: near.x, y: near.y))
            }
            edge.addLine(to: DrivingRibbon.point(depth: 1.08, side: side, size: size))
            glow(edge, in: &context, width: 1.7, opacity: 0.86)
        }
        var dashes = Path()
        for index in 0..<30 {
            let meters = Double(index) * 27 - travel.truncatingRemainder(dividingBy: 27)
            guard meters > 2, !junctions.contains(where: { abs($0.distanceMeters - meters) < 16 }) else { continue }
            dashes.move(to: DrivingRibbon.point(distance: meters, side: 0, size: size))
            dashes.addLine(to: DrivingRibbon.point(distance: meters + 8, side: 0, size: size))
        }
        context.stroke(dashes, with: .color(.white.opacity(0.50)),
                       style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
    }

    /// Structure outlines and labels remain legible above decorative traffic sprites.
    static func annotations(in context: inout GraphicsContext, size: CGSize, events: [DrivingSceneEvent],
                            excluding signRects: [CGRect]) {
        var occupied = signRects
        for event in events.reversed() {
            if event.kind == .bridge { bridge(event, in: &context, size: size) }
            if event.kind == .toll || event.kind == .tunnel { gate(event, in: &context, size: size) }
            let ground = DrivingRibbon.point(distance: event.distanceMeters, side: 0, size: size)
            let text = event.distanceMeters <= 1 ? event.title : "\(event.title) · \(Int(event.distanceMeters.rounded())) m"
            let y = max(20, ground.y - (event.kind == .toll || event.kind == .tunnel
                                       ? gateHeight(event, size: size) + 31 : 18))
            // Traffic signs stay on the right; landmark captions avoid their occupied rectangles.
            let label = context.resolve(Text(text).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DriveTheme.skyDeep))
            let width = label.measure(in: size).width
            guard let caption = DrivingRibbon.captionFrame(preferredY: y, width: width + 16,
                                                            size: size, excluding: occupied) else { continue }
            occupied.append(caption)
            context.fill(Path(roundedRect: caption, cornerRadius: 10), with: .color(.white.opacity(0.48)))
            context.draw(label, at: CGPoint(x: caption.midX, y: caption.midY), anchor: .center)
        }
    }

    private static func gateHeight(_ event: DrivingSceneEvent, size: CGSize) -> Double {
        min(size.height * 0.26, size.width * 0.36 * DrivingRibbon.depth(event.distanceMeters))
    }

    private static func glow(_ path: Path, in context: inout GraphicsContext,
                             width: Double, opacity: Double = 0.8) {
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 3))
            glow.stroke(path, with: .color(.white.opacity(opacity * 0.4)),
                        style: StrokeStyle(lineWidth: width + 2, lineCap: .round, lineJoin: .round))
        }
        context.stroke(path, with: .color(.white.opacity(opacity)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private static func bridge(_ event: DrivingSceneEvent, in context: inout GraphicsContext, size: CGSize) {
        var rails = Path()
        let length = max(60, min(200, event.lengthMeters))
        for side in [-1.0, 1.0] {
            let a = DrivingRibbon.point(distance: event.distanceMeters, side: side * 1.04, size: size)
            let b = DrivingRibbon.point(distance: event.distanceMeters + length, side: side * 1.04, size: size)
            let height = 12 * DrivingRibbon.depth(event.distanceMeters)
            rails.move(to: CGPoint(x: a.x, y: a.y - height))
            rails.addLine(to: CGPoint(x: b.x, y: b.y - height * 0.5))
            for index in 0...5 {
                let meters = event.distanceMeters + length * Double(index) / 5
                let p = DrivingRibbon.point(distance: meters, side: side * 1.04, size: size)
                rails.move(to: p)
                rails.addLine(to: CGPoint(x: p.x, y: p.y - 12 * DrivingRibbon.depth(meters)))
            }
        }
        glow(rails, in: &context, width: 1.2, opacity: 0.70)
    }

    private static func gate(_ event: DrivingSceneEvent, in context: inout GraphicsContext, size: CGSize) {
        let left = DrivingRibbon.point(distance: event.distanceMeters, side: -1.02, size: size)
        let right = DrivingRibbon.point(distance: event.distanceMeters, side: 1.02, size: size)
        let height = gateHeight(event, size: size)
        var outline = Path()
        outline.move(to: left)
        outline.addLine(to: CGPoint(x: left.x, y: left.y - height))
        if event.kind == .tunnel {
            outline.addQuadCurve(to: CGPoint(x: right.x, y: right.y - height),
                                 control: CGPoint(x: size.width / 2, y: left.y - height * 1.5))
        } else {
            outline.addLine(to: CGPoint(x: right.x, y: right.y - height))
            let header = CGRect(x: left.x - 4, y: left.y - height - 12, width: right.x - left.x + 8, height: 17)
            outline.addRoundedRect(in: header, cornerSize: .init(width: 2, height: 2))
            for fraction in [0.22, 0.5, 0.78] {
                let rect = CGRect(x: left.x + (right.x - left.x) * fraction - 4, y: header.midY - 2,
                                  width: 8, height: 4)
                outline.addRoundedRect(in: rect, cornerSize: .init(width: 1, height: 1))
            }
        }
        outline.move(to: CGPoint(x: right.x, y: right.y - height))
        outline.addLine(to: right)
        glow(outline, in: &context, width: 1.4, opacity: 0.78)
    }
}

struct DrivingVehicleSprite: View {
    let speed: Int
    let curve: Double
    let isAnimating: Bool
    var image: (String) -> Image = { Image($0) }
    @State private var previousSpeed = 0
    @State private var braking = false

    private var pose: Int { curve < -7 ? -1 : curve > 7 ? 1 : 0 }
    private var asset: String { pose < 0 ? "DrivingMazdaLeft" : pose > 0 ? "DrivingMazdaRight" : "DrivingMazdaRearV2" }
    private var plate: CGPoint { pose < 0 ? .init(x: 0.64, y: 0.50) : pose > 0 ? .init(x: 0.37, y: 0.50) : .init(x: 0.50, y: 0.523) }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { timeline in
                let bounce = isAnimating ? sin(timeline.date.timeIntervalSinceReferenceDate * 9) * 0.65 : 0
                ZStack {
                    Ellipse().fill(DriveTheme.ink.opacity(0.16)).blur(radius: 4)
                        .frame(width: geometry.size.width * 0.78, height: geometry.size.height * 0.10)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.89)
                    image(asset).resizable().scaledToFit()
                    VStack(spacing: 0) {
                        Text("86A"); Text("26427")
                    }
                    .font(.system(size: max(4, geometry.size.width * 0.04), weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.black)
                    .position(x: geometry.size.width * plate.x, y: geometry.size.height * plate.y)
                    if braking && pose == 0 {
                        Capsule().fill(.red.opacity(0.7)).blur(radius: 1)
                            .frame(width: geometry.size.width * 0.18, height: 2)
                            .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.17)
                    }
                }
                .offset(y: bounce)
            }
        }
        .task(id: speed) {
            braking = previousSpeed - speed >= 4
            previousSpeed = speed
            guard braking else { return }
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { braking = false }
        }
        .accessibilityLabel("Mazda CX-5 trắng, biển số 86A 26427")
    }
}

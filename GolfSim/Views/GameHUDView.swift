import SwiftUI
import SceneKit

// MARK: - SceneKit bridge

struct SceneContainer: UIViewRepresentable {
    let manager: SceneManager

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = manager.scene
        v.pointOfView = manager.cameraNode
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 60
        v.rendersContinuously = true
        v.isPlaying = true
        v.allowsCameraControl = false
        v.autoenablesDefaultLighting = false
        v.backgroundColor = .black
        manager.start()
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene !== manager.scene { uiView.scene = manager.scene }
        uiView.pointOfView = manager.cameraNode
    }
}

// MARK: - Game container

struct GameView: View {
    @StateObject private var session: GameSession
    @Environment(\.dismiss) private var dismiss

    init(launch: GameLaunch, persistence: PersistenceManager, ble: BluetoothServerManager, motion: MotionManager) {
        _session = StateObject(wrappedValue: GameSession(launch: launch, persistence: persistence, ble: ble, motion: motion))
    }

    var body: some View {
        ZStack {
            if let scene = session.scene {
                SceneContainer(manager: scene).ignoresSafeArea()
            } else {
                RemoteBackdrop(session: session).ignoresSafeArea()
            }
            GameHUDView(session: session, onExit: {
                session.teardown()
                dismiss()
            })
        }
        .statusBarHidden(true)
        .onAppear { session.start() }
        .onDisappear { session.teardown() }
    }
}

private struct RemoteBackdrop: View {
    @ObservedObject var session: GameSession
    @ObservedObject private var ble: BluetoothServerManager

    init(session: GameSession) {
        self.session = session
        self.ble = session.ble
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.10, blue: 0.2), .black], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 54)).foregroundColor(ble.subscriberCount > 0 ? .green : .blue)
                Text("Remote Controller").font(.title.bold()).foregroundColor(.white)
                Text(ble.stateDescription).foregroundColor(.white.opacity(0.7))
                Text("Rendering is off to save battery and heat.\nSwing the phone - only the final impact packet is sent.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 40)
                if !ble.lastPayloadHex.isEmpty {
                    Text("Last packet (\(ble.packetsSent) sent)")
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                    Text(ble.lastPayloadHex).font(.system(size: 11, design: .monospaced)).foregroundColor(.green)
                        .padding(.horizontal, 20).multilineTextAlignment(.center)
                }
            }
        }
    }
}

// MARK: - HUD

struct GameHUDView: View {
    @ObservedObject var session: GameSession
    let onExit: () -> Void
    @State private var confirmExit = false

    private var hole: Hole { session.hole }
    private var metric: Bool { session.settings.useMetricUnits }

    private func dist(_ yards: Double) -> String {
        metric ? "\(Int((yards * 0.9144).rounded())) m" : "\(Int(yards.rounded())) yd"
    }

    var body: some View {
        VStack(spacing: 8) {
            topBar
            HStack(alignment: .top) {
                VStack(spacing: 8) {
                    MiniMapView(session: session).frame(width: 96, height: 150)
                    WindCompass(speedMPH: session.windMPH, relativeDegrees: session.windRelativeDegrees, metric: metric)
                }
                Spacer()
                if session.mode == .standalone { cameraButtons }
            }
            .padding(.horizontal, 12)
            Spacer()
            if let banner = session.banner {
                Text(banner).font(.title2.bold()).foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale)
            }
            if session.shotState == .holeComplete {
                Button { session.nextHole() } label: {
                    Label("Next Hole", systemImage: "flag.checkered").font(.headline)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .background(Color(red: 0.2, green: 0.75, blue: 0.4), in: Capsule()).foregroundColor(.black)
                }
            }
            if session.shotState == .roundComplete { roundSummary }
            bottomPanel
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.25), value: session.banner)
        .confirmationDialog("Leave this round?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Leave round", role: .destructive, action: onExit)
        } message: { Text("Completed holes are already saved.") }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { session.shotState == .roundComplete ? onExit() : (confirmExit = true) } label: {
                Image(systemName: "xmark").font(.headline).foregroundColor(.white)
                    .padding(10).background(.ultraThinMaterial, in: Circle())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Hole \(hole.number) / 18").font(.headline).foregroundColor(.white)
                Text("Par \(hole.par) · \(hole.yardage) yd · \(session.course.name)")
                    .font(.caption2).foregroundColor(.white.opacity(0.75))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Stroke \(session.strokes)").font(.headline).foregroundColor(.white)
                Text("Round \(ScoreName.toParString(session.totalToPar))")
                    .font(.caption2).foregroundColor(.white.opacity(0.75))
            }
            Menu {
                ForEach(PlayMode.allCases) { m in
                    Button { session.setMode(m) } label: { Label(m.title, systemImage: m.symbol) }
                }
            } label: {
                Image(systemName: session.mode.symbol).font(.headline).foregroundColor(.white)
                    .padding(10).background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 8)
    }

    private var cameraButtons: some View {
        VStack(spacing: 8) {
            hudButton("binoculars.fill") {
                session.overviewActive ? session.cancelOverview() : session.playOverview()
            }
            hudButton("arrow.left") { session.aimOffset = max(-30, session.aimOffset - 2) }
            hudButton("arrow.right") { session.aimOffset = min(30, session.aimOffset + 2) }
            hudButton("scope") { session.aimOffset = 0; session.motion.calibrate() }
        }
    }

    private func hudButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.headline).foregroundColor(.white)
                .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                metricTile("To pin", dist(session.distanceToPin))
                metricTile("Lie", session.lie.displayName)
                metricTile("Elev", String(format: "%+.0f yd", session.elevationToPin))
                metricTile("Club spd", session.lastMetrics.map { "\(Int($0.clubheadSpeedMPH)) mph" } ?? "—")
                metricTile("Ball spd", session.lastMetrics.map { "\(Int($0.ballSpeedMPH)) mph" } ?? "—")
            }
            HStack(spacing: 8) {
                metricTile("Launch", session.lastMetrics.map { String(format: "%.1f°", $0.launchAngleDeg) } ?? "—")
                metricTile("Dir", session.lastMetrics.map { String(format: "%+.1f°", $0.azimuthDeg) } ?? "—")
                metricTile("Peak g", session.lastMetrics.map { String(format: "%.1f", $0.peakAccelerationG) } ?? "—")
                metricTile("Carry", session.lastMetrics?.carryYards.map { dist($0) } ?? "—")
                metricTile("Total", session.lastMetrics?.totalYards.map { dist($0) } ?? "—")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Club.all) { c in
                        Button { session.club = c } label: {
                            VStack(spacing: 0) {
                                Text(c.shortName).font(.headline)
                                Text(c.isPutter ? "putt" : "\(Int(c.typicalCarryYards))").font(.caption2)
                            }
                            .frame(width: 52, height: 46)
                            .background(session.club == c ? Color(red: 0.2, green: 0.75, blue: 0.4) : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .foregroundColor(session.club == c ? .black : .white)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.yellow, lineWidth: session.recommendedClub == c && session.club != c ? 1.5 : 0))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.50percent").foregroundColor(.white.opacity(0.7))
                Slider(value: $session.simPower, in: 0.1...1.0).tint(.green)
                Button { session.simulateSwing() } label: {
                    Text("Swing").font(.headline).padding(.horizontal, 20).padding(.vertical, 10)
                        .background(session.shotState == .ready || session.mode == .remote ? Color.white : Color.gray,
                                    in: Capsule()).foregroundColor(.black)
                }
                .disabled(session.shotState != .ready && session.mode == .standalone)
            }
            Text(session.motion.sensorAvailable
                 ? "Swing your phone to hit - or use the test swing"
                 : "No motion sensor - use the test swing")
                .font(.caption2).foregroundColor(.white.opacity(0.5))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 8)
    }

    private func metricTile(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(.white)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(title).font(.system(size: 9)).foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private var roundSummary: some View {
        VStack(spacing: 6) {
            Text("Round complete").font(.title3.bold()).foregroundColor(.white)
            if let r = session.finishedRound {
                Text("\(r.totalStrokes) strokes (\(ScoreName.toParString(r.toPar)))  ·  Front \(r.front9)  Back \(r.back9)")
                    .foregroundColor(.white.opacity(0.85))
            }
            Button("Back to menu", action: onExit)
                .padding(.horizontal, 24).padding(.vertical, 10)
                .background(Color(red: 0.2, green: 0.75, blue: 0.4), in: Capsule()).foregroundColor(.black)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Mini map

struct MiniMapView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        Canvas { ctx, size in
            let L = session.layout
            let b = L.bounds(margin: 30)
            let scale = min(size.width / CGFloat(b.width), size.height / CGFloat(b.height))
            let ox = (size.width - CGFloat(b.width) * scale) / 2
            let oy = (size.height - CGFloat(b.height) * scale) / 2
            func P(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(x: ox + CGFloat(p.x - b.minX) * scale, y: oy + CGFloat(p.y - b.minZ) * scale)
            }
            let style = session.course.style
            var path = Path()
            path.move(to: P(L.tee)); path.addLine(to: P(L.bend)); path.addLine(to: P(L.green))
            ctx.stroke(path, with: .color(style.fairway.color),
                       style: StrokeStyle(lineWidth: CGFloat(L.fairwayHalf * 2) * scale, lineCap: .round, lineJoin: .round))
            for ph in L.placed {
                let color: Color
                switch ph.hazard.kind {
                case .water, .creek: color = .blue
                case .bunker, .potBunker, .wasteBunker: color = style.sand.color
                default: continue
                }
                let c = P(ph.center)
                let r = CGFloat(max(ph.a, ph.b)) * scale
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.7, width: r * 2, height: r * 1.4)), with: .color(color.opacity(0.9)))
            }
            let g = P(L.green)
            let gr = CGFloat(L.greenRadius) * scale
            ctx.fill(Path(ellipseIn: CGRect(x: g.x - gr, y: g.y - gr, width: gr * 2, height: gr * 2)), with: .color(style.green.scaled(1.2).color))
            let pin = P(L.pin)
            ctx.fill(Path(ellipseIn: CGRect(x: pin.x - 2, y: pin.y - 2, width: 4, height: 4)), with: .color(.red))
            let ball = P(session.ballPoint)
            ctx.fill(Path(ellipseIn: CGRect(x: ball.x - 3.5, y: ball.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Wind compass

struct WindCompass: View {
    let speedMPH: Double
    let relativeDegrees: Double
    let metric: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().stroke(Color.white.opacity(0.3), lineWidth: 1)
                Image(systemName: "arrow.up")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.cyan)
                    .rotationEffect(.degrees(relativeDegrees))
                Text("↑").font(.system(size: 8)).foregroundColor(.white.opacity(0.4)).offset(y: -26)
            }
            .frame(width: 58, height: 58)
            Text(metric ? "\(Int(speedMPH * 1.609)) km/h" : "\(Int(speedMPH)) mph")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
        }
    }
}

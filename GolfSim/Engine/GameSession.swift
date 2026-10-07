import Foundation
import SwiftUI
import simd

enum ShotState { case ready, inFlight, holeComplete, roundComplete }

/// Big on-screen moment after a hole (birdie burst, pick-up, etc).
struct Celebration: Identifiable, Equatable {
    enum Kind { case ace, great, par, bogey, pickup }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
}

struct GameLaunch: Identifiable {
    let id = UUID()
    let course: Course
    let mode: PlayMode
    let weather: WeatherCondition
}

/// Owns one round of golf: hole progression, strokes, scoring, mode switching and the glue between
/// motion -> (scene | BLE) -> persistence.
final class GameSession: ObservableObject {

    let course: Course
    let persistence: PersistenceManager
    let ble: BluetoothServerManager
    let motion: MotionManager

    @Published private(set) var scene: SceneManager?
    @Published var mode: PlayMode
    @Published private(set) var holeIndex = 0
    @Published private(set) var strokes = 0
    @Published private(set) var scores: [HoleScore] = []
    @Published private(set) var shotState: ShotState = .ready
    @Published private(set) var distanceToPin: Double = 0
    @Published private(set) var elevationToPin: Double = 0
    @Published private(set) var lie: TerrainType = .tee
    @Published private(set) var lastMetrics: SwingMetrics?
    @Published private(set) var banner: String?
    @Published private(set) var windMPH: Double = 0
    @Published private(set) var windRelativeDegrees: Double = 0
    @Published private(set) var ballPoint: SIMD2<Double> = SIMD2<Double>(0, 0)
    @Published private(set) var layout: HoleLayout
    @Published private(set) var finishedRound: RoundRecord?
    @Published var overviewActive = false
    @Published private(set) var celebration: Celebration?
    @Published var simPower = 0.85

    @Published var club: Club = .driver {
        didSet {
            motion.club = club
            motion.putterMode = club.isPutter
            scene?.putting = club.isPutter
        }
    }
    @Published var aimOffset = 0.0 {
        didSet { scene?.aimOffsetDegrees = aimOffset; refreshWind() }
    }
    @Published var weather: WeatherCondition {
        didSet { scene?.setWeather(weather); refreshWind() }
    }

    private var swingsOnHole = 0
    private var puttsOnHole = 0
    private var driveOnHole = 0.0
    private var pendingSwingID: UUID?
    private var generation = 0

    /// Putting assist (auto-aim, force only). Toggle lives in Settings.
    private var assistEnabled: Bool {
        UserDefaults.standard.object(forKey: "golfsim.puttAssist") as? Bool ?? true
    }

    /// While lining up a putt on the green: the club speed that would just reach the cup.
    var puttHint: (mph: Double, power: Double)? {
        guard mode == .standalone, club.isPutter, lie == .green, assistEnabled, shotState == .ready else { return nil }
        let d = max(0.3, distanceToPin * HoleLayout.yd)
        let v = (0.8 * 0.8 + 2 * 0.055 * weather.rollMultiplier * 9.81 * d).squareRoot()
        let raw = (v / 0.44704) / Club.putter.smash
        return (raw, max(0.05, min(1, (raw - 6) / 70)))
    }

    var hole: Hole { course.holes[holeIndex] }
    var settings: AppSettings { persistence.settings }
    var maxStrokes: Int { hole.par + 5 }

    init(launch: GameLaunch, persistence: PersistenceManager, ble: BluetoothServerManager, motion: MotionManager) {
        self.course = launch.course
        self.persistence = persistence
        self.ble = ble
        self.motion = motion
        self.mode = launch.mode
        self.weather = launch.weather
        self.layout = HoleLayout(course: launch.course, hole: launch.course.holes[0])
        motion.onImpact = { [weak self] m in self?.handleSwing(m) }
        motion.onPracticeSwing = { [weak self] _ in self?.handlePractice() }
        motion.leverArm = persistence.settings.leverArm
    }

    // MARK: Lifecycle

    func start() {
        motion.start()
        if mode == .standalone {
            makeScene()
        } else {
            ble.start()
        }
        loadHole(0, ballAt: nil)
        if mode == .standalone { playOverview() }
    }

    func teardown() {
        generation += 1
        motion.onImpact = nil
        motion.onPracticeSwing = nil
        motion.stop()
        ble.stop()
        scene?.stop()
        scene = nil
    }

    private func makeScene() {
        let s = SceneManager(course: course, weather: weather)
        s.audio.enabled = settings.soundEnabled
        s.puttAssist = assistEnabled
        s.onShotFinished = { [weak self] r in self?.handleResult(r) }
        s.onOverviewFinished = { [weak self] in self?.overviewActive = false }
        s.start()
        scene = s
    }

    func setMode(_ new: PlayMode) {
        guard new != mode else { return }
        mode = new
        if new == .remote {
            let ball = scene?.ballPosition2D
            if let ball { ballPoint = ball }
            scene?.stop()
            scene = nil
            ble.start()
        } else {
            ble.stop()
            makeScene()
            scene?.loadHole(hole, ballAt: ballPoint)
            scene?.putting = club.isPutter
            refreshHUD()
        }
    }

    // MARK: Holes

    private func loadHole(_ index: Int, ballAt: SIMD2<Double>?) {
        holeIndex = index
        strokes = 0
        swingsOnHole = 0
        puttsOnHole = 0
        driveOnHole = 0
        banner = nil
        celebration = nil
        shotState = .ready
        aimOffset = 0
        layout = HoleLayout(course: course, hole: course.holes[index])
        ballPoint = ballAt ?? SIMD2<Double>(0, 0)
        scene?.loadHole(course.holes[index], ballAt: ballAt)
        refreshHUD()
        club = recommendedClub
    }

    func nextHole() {
        guard shotState == .holeComplete, holeIndex < 17 else { return }
        loadHole(holeIndex + 1, ballAt: nil)
        playOverview()
    }

    func playOverview() {
        guard let scene, shotState == .ready else { return }
        overviewActive = true
        scene.playFlyover()
    }

    func cancelOverview() {
        overviewActive = false
        scene?.setCameraState(.address, snap: false)
    }

    private func refreshHUD() {
        if let scene {
            distanceToPin = scene.distanceToPinYards
            elevationToPin = scene.elevationToPinYards
            lie = scene.ballTerrain
            ballPoint = scene.ballPosition2D
        } else {
            distanceToPin = simd_length(layout.pin - ballPoint) / HoleLayout.yd
        }
        refreshWind()
    }

    private func refreshWind() {
        guard let scene else { windMPH = 0; return }
        windMPH = scene.windSpeedMPH
        var rel = scene.windToHeadingDegrees - scene.aimHeadingDegrees
        while rel > 180 { rel -= 360 }
        while rel < -180 { rel += 360 }
        windRelativeDegrees = rel
    }

    var recommendedClub: Club {
        if lie == .green { return .putter }
        if lie == .bunker { return .sandWedge }
        if shotState == .ready && strokes == 0 && hole.par >= 4 { return .driver }
        let d = distanceToPin
        if d < 25 && lie != .rough { return distanceToPin < 12 ? .putter : .sandWedge }
        let candidates = Club.all.filter { !$0.isPutter }
        return candidates.last(where: { $0.typicalCarryYards >= d }) ?? .driver
    }

    // MARK: Swings

    private func handlePractice() {
        Haptics.impact(enabled: settings.hapticsEnabled, strong: false)
        scene?.audio.play(.swish, volume: 0.8)
    }

    func simulateSwing() {
        motion.simulateSwing(power: simPower)
    }

    private func handleSwing(_ raw: SwingMetrics) {
        var swing = raw
        swing.courseID = course.id
        lastMetrics = swing
        Haptics.impact(enabled: settings.hapticsEnabled)

        if mode == .remote {
            ble.sendImpact(swing)
            persistence.logSwing(swing)
            return
        }
        guard let scene, shotState == .ready, !overviewActive else { return }
        strokes += 1
        swingsOnHole += 1
        if club.isPutter { puttsOnHole += 1 }
        shotState = .inFlight
        pendingSwingID = swing.id
        persistence.logSwing(swing)
        scene.puttAssist = assistEnabled
        scene.launch(swing, club: club)
        aimOffset = 0
    }

    private func handleResult(_ r: ShotResult) {
        if let id = pendingSwingID {
            persistence.updateSwing(id: id, carryYards: r.carryYards, totalYards: r.totalYards)
            if lastMetrics?.id == id {
                lastMetrics?.carryYards = r.carryYards
                lastMetrics?.totalYards = r.totalYards
            }
        }
        let isTee = swingsOnHole == 1 && !club.isPutter && hole.par > 3
        if !club.isPutter {
            persistence.registerShot(courseID: course.id, carryYards: r.carryYards,
                                     totalYards: r.totalYards, isTeeShot: isTee)
        }
        if isTee { driveOnHole = r.totalYards }

        let gen = generation
        if r.holed {
            finishHole(strokes: strokes)
            return
        }
        if let penalty = r.penalty {
            strokes += 1
            banner = "\(penalty)  +1 stroke"
            Haptics.warning(enabled: settings.hapticsEnabled)
        }
        if strokes >= maxStrokes {
            scene?.pickUpBall()
            finishHole(strokes: maxStrokes, pickedUp: true)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.generation == gen, let scene = self.scene else { return }
            if r.penalty != nil { scene.dropAtLastLie() } else { scene.prepareNextShot() }
            self.shotState = .ready
            self.refreshHUD()
            self.club = self.recommendedClub
            self.banner = nil
        }
    }

    private func finishHole(strokes finalStrokes: Int, pickedUp: Bool = false) {
        strokes = finalStrokes
        let score = HoleScore(holeNumber: hole.number, par: hole.par, strokes: finalStrokes,
                              putts: puttsOnHole, longestDrive: driveOnHole)
        scores.removeAll { $0.holeNumber == score.holeNumber }
        scores.append(score)
        persistence.recordHole(course: course, score: score)

        let diff = finalStrokes - hole.par
        let name = pickedUp ? "Pick up" : ScoreName.name(strokes: finalStrokes, par: hole.par)
        banner = pickedUp ? "Max strokes reached (+5)" : nil
        let kind: Celebration.Kind
        if pickedUp { kind = .pickup }
        else if finalStrokes == 1 { kind = .ace }
        else if diff <= -1 { kind = .great }
        else if diff == 0 { kind = .par }
        else { kind = .bogey }
        showCelebration(Celebration(kind: kind, title: name,
                                    subtitle: pickedUp ? "Maximum of +5 per hole - ball picked up"
                                                       : "\(finalStrokes) strokes · \(ScoreName.toParString(diff))"))
        if pickedUp {
            Haptics.warning(enabled: settings.hapticsEnabled)
        } else {
            Haptics.success(enabled: settings.hapticsEnabled)
        }

        if holeIndex == 17 {
            finishedRound = persistence.finishRound(course: course)
            shotState = .roundComplete
            scene?.audio.play(.fanfare, delay: 1.2)
        } else {
            shotState = .holeComplete
        }
    }

    private func showCelebration(_ c: Celebration) {
        celebration = c
        let id = c.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            if self?.celebration?.id == id { self?.celebration = nil }
        }
    }

    var totalToPar: Int {
        scores.reduce(0) { $0 + $1.toPar }
    }
}

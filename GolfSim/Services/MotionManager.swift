import Foundation
import CoreMotion

/// Wraps CMMotionManager at 100 Hz, detects a swing, and computes every metric locally.
///
/// V2 swing model:
///  - Direction comes from how far the phone's horizontal heading has turned between address and impact
///    (measured from the full rotation matrix, so it does not depend on how you hold the phone).
///  - Swing plane flatness = how much of the downswing rotation happens around the vertical axis.
///    Flat sweeping swings (driver) launch lower with less spin; steep / upright swings launch higher.
///  - Swing arc = total rotation during the downswing. A small low arc is a chip, a medium one a pitch.
final class MotionManager: ObservableObject {

    static let sampleRateHz = 100.0
    /// Downswing rotation (radians) below which a swing counts as a chip / pitch. Tune to taste.
    static let chipArc = 0.9
    static let pitchArc = 1.8

    @Published private(set) var liveAcceleration: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var sensorAvailable = true
    @Published private(set) var lastMetrics: SwingMetrics?

    var club: Club = .driver
    var putterMode = false
    var leverArm: Double = 1.8

    var onImpact: ((SwingMetrics) -> Void)?
    var onPracticeSwing: ((Double) -> Void)?

    private let manager = CMMotionManager()
    private enum Phase { case idle, swinging, cooldown }
    private var phase: Phase = .idle

    private static let identity = CMRotationMatrix(m11: 1, m12: 0, m13: 0, m21: 0, m22: 1, m23: 0, m31: 0, m32: 0, m33: 1)
    private var refMatrix = MotionManager.identity
    private var peakMatrix = MotionManager.identity
    private var lastT = 0.0
    private var startTime = 0.0
    private var peakAcc = 0.0
    private var peakRot = 0.0
    private var peakTime = 0.0
    private var arc = 0.0
    private var sumRot = 0.0
    private var sumAlong = 0.0
    private var cooldownUntil = 0.0
    private var lastPublish = 0.0

    private var startThreshold: Double { putterMode ? 0.35 : 1.0 }
    var impactThreshold: Double { putterMode ? 0.6 : 2.5 }
    private var practiceThreshold: Double { putterMode ? 0.4 : 1.3 }

    // MARK: Lifecycle

    func start() {
        guard manager.isDeviceMotionAvailable else {
            sensorAvailable = false
            return
        }
        guard !manager.isDeviceMotionActive else { return }
        sensorAvailable = true
        phase = .idle
        lastT = 0
        manager.deviceMotionUpdateInterval = 1.0 / Self.sampleRateHz
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            self.process(motion)
        }
        isRunning = true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
        phase = .idle
    }

    func calibrate() { phase = .idle }

    // MARK: Processing

    private func process(_ motion: CMDeviceMotion) {
        let t = motion.timestamp
        let dt = lastT == 0 ? 0.01 : min(0.05, t - lastT)
        lastT = t

        let a = motion.userAcceleration
        let acc = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let r = motion.rotationRate
        let rot = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        let g = motion.gravity
        let gl = max(0.5, (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
        let along = (r.x * g.x + r.y * g.y + r.z * g.z) / gl   // rad/s around the vertical axis

        if t - lastPublish > 0.05 {
            lastPublish = t
            liveAcceleration = acc
        }

        switch phase {
        case .idle:
            refMatrix = motion.attitude.rotationMatrix
            if acc > startThreshold {
                phase = .swinging
                startTime = t
                peakAcc = acc
                peakRot = rot
                peakTime = t
                arc = rot * dt
                sumRot = rot * dt
                sumAlong = along * dt
                peakMatrix = motion.attitude.rotationMatrix
            }

        case .swinging:
            arc += rot * dt
            sumRot += rot * dt
            sumAlong += along * dt
            if acc > peakAcc {
                peakAcc = acc
                peakTime = t
                peakMatrix = motion.attitude.rotationMatrix
            }
            peakRot = max(peakRot, rot)

            let fallen = acc < 0.4 * peakAcc && (t - startTime) > 0.08
            if (t - peakTime) > 0.12 || fallen {
                finishSwing()
                phase = .cooldown
                cooldownUntil = t + 1.0
            }

        case .cooldown:
            if t > cooldownUntil { phase = .idle }
        }
    }

    private func finishSwing() {
        if peakAcc >= impactThreshold {
            let headingRad = Self.headingChange(from: refMatrix, to: peakMatrix)
            let azimuth = max(-25, min(25, -headingRad * 180 / .pi * 0.6))
            let flat = min(1, abs(sumAlong) / max(sumRot, 0.01))
            let metrics = Self.computeMetrics(peakAcceleration: peakAcc, peakAngularVelocity: peakRot,
                                              azimuthDeg: azimuth, flatness: flat, arc: arc,
                                              club: club, leverArm: leverArm)
            lastMetrics = metrics
            onImpact?(metrics)
        } else if peakAcc >= practiceThreshold {
            onPracticeSwing?(peakAcc)
        }
    }

    /// Counter-clockwise (seen from above) heading change of the phone between two attitudes, radians.
    /// Uses every device axis that is reasonably horizontal at both moments, weighted by how horizontal it is.
    static func headingChange(from a: CMRotationMatrix, to b: CMRotationMatrix) -> Double {
        let ra = [(a.m11, a.m12), (a.m21, a.m22), (a.m31, a.m32)]
        let rb = [(b.m11, b.m12), (b.m21, b.m22), (b.m31, b.m32)]
        var sx = 0.0, sy = 0.0
        for i in 0..<3 {
            let (ax, ay) = ra[i]
            let (bx, by) = rb[i]
            let w = (ax * ax + ay * ay).squareRoot() * (bx * bx + by * by).squareRoot()
            if w < 0.05 { continue }
            let ang = atan2(ax * by - ay * bx, ax * bx + ay * by)
            sx += w * cos(ang)
            sy += w * sin(ang)
        }
        return atan2(sy, sx)
    }

    // MARK: Metric maths (shared with simulated swings)

    static func computeMetrics(peakAcceleration: Double, peakAngularVelocity: Double,
                               azimuthDeg: Double, flatness: Double, arc: Double,
                               club: Club, leverArm: Double) -> SwingMetrics {
        let rawMPH = min(140, max(5, peakAngularVelocity * leverArm * 2.23694))
        let ballMPH = rawMPH * club.speedFactor * club.smash

        var launch = club.launchAngle
        var spin = club.spinRPM
        if !club.isPutter {
            // Flat sweeping swing -> lower launch, less spin. Upright swing -> higher launch, more spin.
            var trim = (0.5 - flatness) * 8
            spin *= 1 + (0.5 - flatness) * 0.4
            // Short, low arcs are chips / pitches: pop the ball up and add spin.
            if arc < chipArc {
                trim += 8
                spin *= 1.25
            } else if arc < pitchArc {
                trim += 3
                spin *= 1.1
            }
            launch = max(3, min(55, club.launchAngle + max(-6, min(14, trim))))
        }

        return SwingMetrics(courseID: nil,
                            clubID: club.id,
                            clubheadSpeedMPH: rawMPH,
                            ballSpeedMPH: ballMPH,
                            peakAccelerationG: peakAcceleration,
                            peakAngularVelocity: peakAngularVelocity,
                            launchAngleDeg: launch,
                            azimuthDeg: max(-25, min(25, azimuthDeg)),
                            spinRPM: spin,
                            planeFlatness: flatness,
                            arcRadians: arc)
    }

    /// Fires a synthetic swing (simulator / no sensor). `power` is 0...1.
    func simulateSwing(power: Double, azimuthDeg: Double = 0) {
        let p = max(0.05, min(1.0, power))
        let rawTarget = club.isPutter ? (6 + 70 * p) : (50 + 60 * p)
        let rot = rawTarget / (leverArm * 2.23694)
        let wedge = club.id >= Club.pitchingWedge.id && !club.isPutter
        let arc: Double = (wedge && p < 0.45) ? 0.6 : (wedge && p < 0.7 ? 1.4 : 3.0)
        let flat = club.id <= Club.wood3.id ? 0.7 : 0.4
        let metrics = Self.computeMetrics(peakAcceleration: 3 + 5 * p, peakAngularVelocity: rot,
                                          azimuthDeg: azimuthDeg, flatness: flat, arc: arc,
                                          club: club, leverArm: leverArm)
        lastMetrics = metrics
        onImpact?(metrics)
    }
}

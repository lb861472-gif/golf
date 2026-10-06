import Foundation
import CoreMotion

/// Wraps CMMotionManager at 100 Hz, detects a swing, and computes every metric locally
/// (peak acceleration, angular velocity, clubhead speed, ball speed, launch vector).
final class MotionManager: ObservableObject {

    static let sampleRateHz = 100.0

    @Published private(set) var liveAcceleration: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var sensorAvailable = true
    @Published private(set) var lastMetrics: SwingMetrics?

    /// Club used to turn raw swing speed into ball speed / launch.
    var club: Club = .driver
    /// Lower thresholds so gentle putting strokes register.
    var putterMode = false
    /// Effective lever arm in metres (swing calibration).
    var leverArm: Double = 1.8

    var onImpact: ((SwingMetrics) -> Void)?
    var onPracticeSwing: ((Double) -> Void)?

    private let manager = CMMotionManager()
    private enum Phase { case idle, swinging, cooldown }
    private var phase: Phase = .idle
    private var reference: CMAttitude?

    private var startTime = 0.0
    private var peakAcc = 0.0
    private var peakRot = 0.0
    private var peakTime = 0.0
    private var yawAtPeak = 0.0
    private var pitchAtPeak = 0.0
    private var cooldownUntil = 0.0
    private var lastPublish = 0.0

    private var startThreshold: Double { putterMode ? 0.35 : 1.0 }
    /// Peak acceleration (g) that counts as ball impact.
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

    /// Re-capture the address attitude.
    func calibrate() {
        reference = nil
        phase = .idle
    }

    // MARK: Processing

    private func process(_ motion: CMDeviceMotion) {
        let t = motion.timestamp
        let a = motion.userAcceleration
        let acc = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let r = motion.rotationRate
        let rot = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()

        if t - lastPublish > 0.05 {
            lastPublish = t
            liveAcceleration = acc
        }

        switch phase {
        case .idle:
            reference = motion.attitude.copy() as? CMAttitude
            if acc > startThreshold {
                phase = .swinging
                startTime = t
                peakAcc = acc
                peakRot = rot
                peakTime = t
                captureAttitude(motion)
            }

        case .swinging:
            if acc > peakAcc {
                peakAcc = acc
                peakTime = t
                captureAttitude(motion)
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

    private func captureAttitude(_ motion: CMDeviceMotion) {
        guard let ref = reference, let rel = motion.attitude.copy() as? CMAttitude else {
            yawAtPeak = 0
            pitchAtPeak = 0
            return
        }
        rel.multiply(byInverseOf: ref)
        yawAtPeak = rel.yaw * 180 / .pi
        pitchAtPeak = rel.pitch * 180 / .pi
    }

    private func finishSwing() {
        if peakAcc >= impactThreshold {
            let metrics = Self.computeMetrics(peakAcceleration: peakAcc, peakAngularVelocity: peakRot,
                                              yawDeg: yawAtPeak, pitchDeg: pitchAtPeak,
                                              club: club, leverArm: leverArm)
            lastMetrics = metrics
            onImpact?(metrics)
        } else if peakAcc >= practiceThreshold {
            onPracticeSwing?(peakAcc)
        }
    }

    // MARK: Metric maths (shared with simulated swings)

    static func computeMetrics(peakAcceleration: Double, peakAngularVelocity: Double,
                               yawDeg: Double, pitchDeg: Double,
                               club: Club, leverArm: Double) -> SwingMetrics {
        let rawMPH = min(140, max(5, peakAngularVelocity * leverArm * 2.23694))
        let ballMPH = rawMPH * club.speedFactor * club.smash
        let trim = club.isPutter ? 0 : max(-6, min(6, pitchDeg * 0.25))
        let azimuth = max(-25, min(25, yawDeg))
        return SwingMetrics(courseID: nil,
                            clubID: club.id,
                            clubheadSpeedMPH: rawMPH,
                            ballSpeedMPH: ballMPH,
                            peakAccelerationG: peakAcceleration,
                            peakAngularVelocity: peakAngularVelocity,
                            launchAngleDeg: club.launchAngle + trim,
                            azimuthDeg: azimuth,
                            spinRPM: club.spinRPM)
    }

    /// Fires a synthetic swing (simulator / no sensor). `power` is 0...1.
    func simulateSwing(power: Double, azimuthDeg: Double = 0) {
        let p = max(0.05, min(1.0, power))
        let rawTarget = club.isPutter ? (6 + 40 * p) : (50 + 60 * p)   // mph
        let rot = rawTarget / (leverArm * 2.23694)
        let metrics = Self.computeMetrics(peakAcceleration: 3 + 5 * p, peakAngularVelocity: rot,
                                          yawDeg: azimuthDeg, pitchDeg: 0,
                                          club: club, leverArm: leverArm)
        lastMetrics = metrics
        onImpact?(metrics)
    }
}

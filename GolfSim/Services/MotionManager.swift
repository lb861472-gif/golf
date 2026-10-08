import Foundation
import CoreMotion
import simd

/// Wraps CMMotionManager at 100 Hz, detects a swing, and computes every metric locally.
///
/// Swing detection (V3) tells the BACKSWING from the DOWNSWING:
///  - While you take the phone back, its rotation direction and acceleration direction are remembered.
///  - A real swing only starts when the phone then moves the OPPOSITE way (the forward swing).
///    Moving back the same way you took it back is ignored, so bringing the phone back never swings.
///  - The address position is locked in while the phone is still, so direction is measured from where
///    you set up, not from the top of the backswing.
///
/// Other metrics (unchanged from V2):
///  - Direction = heading change of the phone between address and impact.
///  - Swing plane flatness = share of the downswing rotation around the vertical axis.
///  - Swing arc = total rotation during the downswing (small = chip / pitch).
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
    private var addressMatrix = MotionManager.identity
    private var hasAddress = false
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

    // Backswing memory (device frame)
    private var backRot = SIMD3<Double>(0, 0, 0)      // net rotation (rad) while taking the phone back
    private var backAcc = SIMD3<Double>(0, 0, 0)      // net acceleration impulse (g*s) while taking it back
    private var lastBackTime = 0.0
    private var stillTime = 0.0
    private var frozenBackUnit = SIMD3<Double>(0, 0, 0)   // backswing direction frozen when a swing starts
    private var hasFrozenBack = false
    private var netRot = SIMD3<Double>(0, 0, 0)
    private var misalignTime = 0.0

    private var startThreshold: Double { putterMode ? 0.35 : 1.0 }
    var impactThreshold: Double { putterMode ? 0.6 : 2.5 }
    private var practiceThreshold: Double { putterMode ? 0.4 : 1.3 }
    /// Minimum peak rotation speed (rad/s) for a swing to count as a real stroke.
    private var minRotation: Double { putterMode ? 0.8 : 4.0 }

    // MARK: Lifecycle

    func start() {
        guard manager.isDeviceMotionAvailable else {
            sensorAvailable = false
            return
        }
        guard !manager.isDeviceMotionActive else { return }
        sensorAvailable = true
        resetBackswing()
        hasAddress = false
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

    func calibrate() {
        resetBackswing()
        hasAddress = false
        phase = .idle
    }

    private func resetBackswing() {
        backRot = .zero
        backAcc = .zero
        stillTime = 0
        misalignTime = 0
        hasFrozenBack = false
    }

    // MARK: Processing

    private func process(_ motion: CMDeviceMotion) {
        let t = motion.timestamp
        let dt = lastT == 0 ? 0.01 : min(0.05, t - lastT)
        lastT = t

        let a = motion.userAcceleration
        let av = SIMD3<Double>(a.x, a.y, a.z)
        let acc = simd_length(av)
        let r = motion.rotationRate
        let rv = SIMD3<Double>(r.x, r.y, r.z)
        let rot = simd_length(rv)
        let g = motion.gravity
        let gl = max(0.5, (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
        let along = (r.x * g.x + r.y * g.y + r.z * g.z) / gl   // rad/s around the vertical axis

        if t - lastPublish > 0.05 {
            lastPublish = t
            liveAcceleration = acc
        }

        if !hasAddress {
            addressMatrix = motion.attitude.rotationMatrix
            hasAddress = true
        }

        switch phase {
        case .idle:
            // Lock in the address position whenever the phone is still and no backswing is in progress.
            if rot < 0.6 && acc < 0.15 { stillTime += dt } else { stillTime = 0 }
            if stillTime > 0.25 && simd_length(backRot) < 0.25 {
                addressMatrix = motion.attitude.rotationMatrix
            }
            // Forget an old backswing after a long pause.
            if t - lastBackTime > 2.5 {
                backRot = .zero
                backAcc = .zero
            }

            let backLen = simd_length(backRot)
            let rotUnit = rot > 0.01 ? rv / rot : SIMD3<Double>(0, 0, 0)

            if acc > startThreshold {
                var forward = true
                if backLen > 0.35 {
                    // Rotating the opposite way to the backswing = the forward swing.
                    forward = simd_dot(rotUnit, backRot / backLen) < -0.15
                } else if simd_length(backAcc) > 0.12 && acc > 0 {
                    forward = simd_dot(av / acc, backAcc / simd_length(backAcc)) < 0.2
                }

                if forward {
                    phase = .swinging
                    startTime = t
                    peakAcc = acc
                    peakRot = rot
                    peakTime = t
                    arc = rot * dt
                    sumRot = rot * dt
                    sumAlong = along * dt
                    netRot = rv * dt
                    misalignTime = 0
                    hasFrozenBack = backLen > 0.35
                    frozenBackUnit = hasFrozenBack ? backRot / backLen : .zero
                    peakMatrix = motion.attitude.rotationMatrix
                    break
                }
            }

            // Anything else that moves the phone is treated as part of the backswing.
            if rot > 1.0 || acc > 0.15 {
                backRot += rv * dt
                backAcc += av * dt
                lastBackTime = t
                let len = simd_length(backRot)
                if len > 6 { backRot *= 6 / len }
            }

        case .swinging:
            arc += rot * dt
            sumRot += rot * dt
            sumAlong += along * dt
            netRot += rv * dt
            if acc > peakAcc {
                peakAcc = acc
                peakTime = t
                peakMatrix = motion.attitude.rotationMatrix
            }
            peakRot = max(peakRot, rot)

            // Still turning the SAME way as the backswing? Then this was just the phone coming back - abort.
            if hasFrozenBack && rot > 2.0 {
                if simd_dot(rv / rot, frozenBackUnit) > 0.3 { misalignTime += dt } else { misalignTime = 0 }
                if misalignTime > 0.08 {
                    backRot += netRot
                    backAcc = .zero
                    lastBackTime = t
                    phase = .idle
                    break
                }
            }

            let fallen = acc < 0.4 * peakAcc && (t - startTime) > 0.08
            if (t - peakTime) > 0.12 || fallen {
                finishSwing()
                phase = .cooldown
                cooldownUntil = t + 1.0
            }

        case .cooldown:
            if t > cooldownUntil {
                phase = .idle
                resetBackswing()
                hasAddress = false
            }
        }
    }

    private func finishSwing() {
        // The net rotation of a real forward swing points against the backswing.
        var directionOK = true
        if hasFrozenBack { directionOK = simd_dot(netRot, frozenBackUnit) < 0 }

        if directionOK && peakAcc >= impactThreshold && peakRot >= minRotation {
            let headingRad = Self.headingChange(from: addressMatrix, to: peakMatrix)
            let azimuth = max(-25, min(25, -headingRad * 180 / .pi * 0.6))
            let flat = min(1, abs(sumAlong) / max(sumRot, 0.01))
            let metrics = Self.computeMetrics(peakAcceleration: peakAcc, peakAngularVelocity: peakRot,
                                              azimuthDeg: azimuth, flatness: flat, arc: arc,
                                              club: club, leverArm: leverArm)
            lastMetrics = metrics
            onImpact?(metrics)
        } else if directionOK && peakAcc >= practiceThreshold {
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

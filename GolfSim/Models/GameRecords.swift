import Foundation

// MARK: - Play mode

enum PlayMode: String, Codable, CaseIterable, Identifiable {
    case standalone, remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standalone: return "Standalone"
        case .remote: return "Remote Controller"
        }
    }

    var symbol: String {
        switch self {
        case .standalone: return "iphone.gen3"
        case .remote: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Clubs

struct Club: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let shortName: String
    let loft: Double
    /// Base launch angle in degrees.
    let launchAngle: Double
    let spinRPM: Double
    /// Scales the measured swing speed down for shorter clubs.
    let speedFactor: Double
    /// Ball speed / clubhead speed.
    let smash: Double
    let typicalCarryYards: Double

    var isPutter: Bool { id == 7 }

    static let driver = Club(id: 0, name: "Driver", shortName: "DR", loft: 10.5, launchAngle: 12, spinRPM: 2600,
                             speedFactor: 1.0, smash: 1.48, typicalCarryYards: 240)
    static let wood3 = Club(id: 1, name: "3 Wood", shortName: "3W", loft: 15, launchAngle: 13, spinRPM: 3600,
                            speedFactor: 0.93, smash: 1.42, typicalCarryYards: 225)
    static let iron5 = Club(id: 2, name: "5 Iron", shortName: "5i", loft: 27, launchAngle: 15, spinRPM: 5200,
                            speedFactor: 0.86, smash: 1.34, typicalCarryYards: 190)
    static let iron7 = Club(id: 3, name: "7 Iron", shortName: "7i", loft: 34, launchAngle: 17, spinRPM: 6500,
                            speedFactor: 0.80, smash: 1.25, typicalCarryYards: 160)
    static let iron9 = Club(id: 4, name: "9 Iron", shortName: "9i", loft: 42, launchAngle: 21, spinRPM: 8000,
                            speedFactor: 0.74, smash: 1.19, typicalCarryYards: 135)
    static let pitchingWedge = Club(id: 5, name: "Pitching Wedge", shortName: "PW", loft: 46, launchAngle: 25,
                                    spinRPM: 9000, speedFactor: 0.70, smash: 1.143, typicalCarryYards: 115)
    static let sandWedge = Club(id: 6, name: "Sand Wedge", shortName: "SW", loft: 56, launchAngle: 30,
                                spinRPM: 9800, speedFactor: 0.64, smash: 1.06, typicalCarryYards: 90)
    static let putter = Club(id: 7, name: "Putter", shortName: "PT", loft: 3, launchAngle: 0, spinRPM: 0,
                             speedFactor: 1.0, smash: 0.157, typicalCarryYards: 0)

    static let all: [Club] = [driver, wood3, iron5, iron7, iron9, pitchingWedge, sandWedge, putter]

    static func byID(_ id: Int) -> Club { all.first { $0.id == id } ?? .driver }
}

// MARK: - Swing metrics (edge-computed on device)

struct SwingMetrics: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var courseID: String?
    var clubID: Int
    var clubheadSpeedMPH: Double
    var ballSpeedMPH: Double
    var peakAccelerationG: Double
    var peakAngularVelocity: Double
    var launchAngleDeg: Double
    var azimuthDeg: Double
    var spinRPM: Double
    var carryYards: Double?
    var totalYards: Double?
    /// 0 = upright swing plane, 1 = perfectly flat swing plane (nil for old saved swings).
    var planeFlatness: Double?
    /// Total rotation (radians) during the downswing - small for chips, large for full swings.
    var arcRadians: Double?

    var club: Club { Club.byID(clubID) }

    /// "Chip", "Pitch" or "Full", plus the swing plane when it is clearly flat or steep.
    var shotType: String {
        if club.isPutter { return "Putt" }
        guard let arc = arcRadians else { return "Full" }
        let base = arc < MotionManager.chipArc ? "Chip" : (arc < MotionManager.pitchArc ? "Pitch" : "Full")
        let pf = planeFlatness ?? 0.5
        if pf > 0.65 { return base + " · Flat" }
        if pf < 0.35 { return base + " · Steep" }
        return base
    }
}

// MARK: - Scorecards

struct HoleScore: Codable, Identifiable, Hashable {
    var holeNumber: Int
    var par: Int
    var strokes: Int
    var putts: Int
    /// Total yards of the tee shot (0 on par 3s / putt-only holes).
    var longestDrive: Double

    var id: Int { holeNumber }
    var toPar: Int { strokes - par }
}

struct RoundRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var courseID: String
    var courseName: String
    var date = Date()
    var holes: [HoleScore] = []
    var completed = false

    var totalStrokes: Int { holes.reduce(0) { $0 + $1.strokes } }
    var totalPar: Int { holes.reduce(0) { $0 + $1.par } }
    var toPar: Int { totalStrokes - totalPar }
    var front9: Int { holes.filter { $0.holeNumber <= 9 }.reduce(0) { $0 + $1.strokes } }
    var back9: Int { holes.filter { $0.holeNumber > 9 }.reduce(0) { $0 + $1.strokes } }
    var front9Par: Int { holes.filter { $0.holeNumber <= 9 }.reduce(0) { $0 + $1.par } }
    var back9Par: Int { holes.filter { $0.holeNumber > 9 }.reduce(0) { $0 + $1.par } }
    var longestDrive: Double { holes.map(\.longestDrive).max() ?? 0 }
    var totalPutts: Int { holes.reduce(0) { $0 + $1.putts } }
}

struct CourseBests: Codable, Hashable {
    var lowestScore: Int?
    var lowestToPar: Int?
    var longestDrive: Double = 0
    var bestCarry: Double = 0
    var roundsPlayed: Int = 0
    var totalStrokes: Int = 0
    /// Best strokes per hole (index 0 == hole 1). 0 means "not played".
    var bestHoleStrokes: [Int] = Array(repeating: 0, count: 18)

    var averageScore: Double? {
        roundsPlayed > 0 ? Double(totalStrokes) / Double(roundsPlayed) : nil
    }
}

// MARK: - Settings

struct AppSettings: Codable, Hashable {
    var defaultMode: PlayMode = .standalone
    var hapticsEnabled = true
    var soundEnabled = true
    var useMetricUnits = false
    /// Effective lever arm (metres) used to turn angular velocity into clubhead speed.
    var leverArm: Double = 1.8
    var lastCourseID: String?
}

// MARK: - Helpers

enum ScoreName {
    static func name(strokes: Int, par: Int) -> String {
        if strokes == 1 { return "Hole in One!" }
        switch strokes - par {
        case ...(-3): return "Albatross"
        case -2: return "Eagle"
        case -1: return "Birdie"
        case 0: return "Par"
        case 1: return "Bogey"
        case 2: return "Double Bogey"
        case 3: return "Triple Bogey"
        default: return "+\(strokes - par)"
        }
    }

    static func toParString(_ v: Int) -> String {
        v == 0 ? "E" : (v > 0 ? "+\(v)" : "\(v)")
    }
}

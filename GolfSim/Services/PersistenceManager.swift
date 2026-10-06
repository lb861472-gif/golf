import Foundation

/// Saves rounds, 18-hole scorecards, course bests and swing records to disk (JSON) and
/// settings to UserDefaults. Everything is saved automatically on hole / round completion.
final class PersistenceManager: ObservableObject {

    private struct Store: Codable {
        var rounds: [RoundRecord] = []
        var bests: [String: CourseBests] = [:]
        var swings: [SwingMetrics] = []
        var inProgress: RoundRecord?
    }

    @Published private(set) var rounds: [RoundRecord] = []
    @Published private(set) var bests: [String: CourseBests] = [:]
    @Published private(set) var swings: [SwingMetrics] = []
    @Published private(set) var inProgress: RoundRecord?

    @Published var settings: AppSettings {
        didSet { saveSettings() }
    }

    private static let settingsKey = "golfsim.settings.v1"
    private let ioQueue = DispatchQueue(label: "golfsim.persistence", qos: .utility)
    private let fileURL: URL
    private let maxSwings = 600

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        fileURL = base.appendingPathComponent("golfsim-store.json")

        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }

        if let data = try? Data(contentsOf: fileURL),
           let store = try? JSONDecoder().decode(Store.self, from: data) {
            rounds = store.rounds
            bests = store.bests
            swings = store.swings
            inProgress = store.inProgress
        }
    }

    // MARK: Queries

    func bests(for courseID: String) -> CourseBests { bests[courseID] ?? CourseBests() }

    func rounds(for courseID: String) -> [RoundRecord] {
        rounds.filter { $0.courseID == courseID }.sorted { $0.date > $1.date }
    }

    var totalRounds: Int { rounds.count }

    var bestRoundToPar: (round: RoundRecord, toPar: Int)? {
        rounds.min { $0.toPar < $1.toPar }.map { ($0, $0.toPar) }
    }

    var overallLongestDrive: Double { bests.values.map(\.longestDrive).max() ?? 0 }
    var overallBestCarry: Double { bests.values.map(\.bestCarry).max() ?? 0 }

    func averageClubheadSpeed(courseID: String?) -> Double {
        let list = swings.filter { s in
            guard s.club.isPutter == false else { return false }
            if let courseID { return s.courseID == courseID }
            return true
        }
        guard !list.isEmpty else { return 0 }
        return list.reduce(0) { $0 + $1.clubheadSpeedMPH } / Double(list.count)
    }

    func swings(for courseID: String) -> [SwingMetrics] {
        swings.filter { $0.courseID == courseID }
    }

    // MARK: Mutations

    func logSwing(_ metrics: SwingMetrics) {
        swings.append(metrics)
        if swings.count > maxSwings { swings.removeFirst(swings.count - maxSwings) }
        saveStore()
    }

    func updateSwing(id: UUID, carryYards: Double, totalYards: Double) {
        guard let idx = swings.lastIndex(where: { $0.id == id }) else { return }
        swings[idx].carryYards = carryYards
        swings[idx].totalYards = totalYards
        saveStore()
    }

    /// Updates personal records after every shot.
    func registerShot(courseID: String, carryYards: Double, totalYards: Double, isTeeShot: Bool) {
        var b = bests(for: courseID)
        b.bestCarry = max(b.bestCarry, carryYards)
        if isTeeShot { b.longestDrive = max(b.longestDrive, totalYards) }
        bests[courseID] = b
        saveStore()
    }

    /// Called as soon as a hole is completed so the 18-hole scorecard is always persisted.
    func recordHole(course: Course, score: HoleScore) {
        if inProgress == nil || inProgress?.courseID != course.id || inProgress?.completed == true {
            inProgress = RoundRecord(courseID: course.id, courseName: course.name)
        }
        inProgress?.holes.removeAll { $0.holeNumber == score.holeNumber }
        inProgress?.holes.append(score)
        inProgress?.holes.sort { $0.holeNumber < $1.holeNumber }

        var b = bests(for: course.id)
        let idx = score.holeNumber - 1
        if idx >= 0 && idx < b.bestHoleStrokes.count {
            let current = b.bestHoleStrokes[idx]
            if current == 0 || score.strokes < current { b.bestHoleStrokes[idx] = score.strokes }
        }
        bests[course.id] = b
        settings.lastCourseID = course.id
        saveStore()
    }

    /// Finalises the in-progress round and updates course records.
    @discardableResult
    func finishRound(course: Course) -> RoundRecord? {
        guard var round = inProgress, round.courseID == course.id else { return nil }
        round.completed = true
        round.date = Date()
        rounds.append(round)

        var b = bests(for: course.id)
        b.roundsPlayed += 1
        b.totalStrokes += round.totalStrokes
        if round.holes.count == 18 {
            if b.lowestScore == nil || round.totalStrokes < (b.lowestScore ?? Int.max) {
                b.lowestScore = round.totalStrokes
                b.lowestToPar = round.toPar
            }
        }
        b.longestDrive = max(b.longestDrive, round.longestDrive)
        bests[course.id] = b
        inProgress = nil
        saveStore()
        return round
    }

    func abandonRound() {
        inProgress = nil
        saveStore()
    }

    func resetAll() {
        rounds = []
        bests = [:]
        swings = []
        inProgress = nil
        saveStore()
    }

    // MARK: Disk

    private func saveStore() {
        let store = Store(rounds: rounds, bests: bests, swings: swings, inProgress: inProgress)
        let url = fileURL
        ioQueue.async {
            if let data = try? JSONEncoder().encode(store) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }
}

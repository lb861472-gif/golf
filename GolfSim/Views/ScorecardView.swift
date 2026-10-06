import SwiftUI
import Charts

struct ScorecardView: View {
    @EnvironmentObject var persistence: PersistenceManager
    @State private var courseID: String = Course.all[0].id
    @State private var selectedRoundID: UUID?

    private var course: Course { Course.byID(courseID) ?? Course.all[0] }
    private var rounds: [RoundRecord] { persistence.rounds(for: courseID) }
    private var bests: CourseBests { persistence.bests(for: courseID) }
    private var selectedRound: RoundRecord? {
        rounds.first { $0.id == selectedRoundID } ?? rounds.first
    }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.07, blue: 0.09).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Course", selection: $courseID) {
                        ForEach(Course.all) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)

                    statsGrid
                    if rounds.count > 1 { trendChart }
                    if let round = selectedRound {
                        roundBreakdown(round)
                        scoreGrid(round)
                    } else {
                        Text("No completed rounds on \(course.name) yet.")
                            .foregroundColor(.white.opacity(0.6)).padding(.top, 30)
                    }
                    if rounds.count > 1 { history }
                    bestHoles
                }
                .padding(16)
            }
        }
        .navigationTitle("Personal Records")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: courseID) { _ in selectedRoundID = nil }
    }

    // MARK: Pieces

    private var statsGrid: some View {
        let avgSpeed = persistence.averageClubheadSpeed(courseID: courseID)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            tile("Best Round", bests.lowestScore.map { "\($0)" } ?? "—")
            tile("To Par", bests.lowestToPar.map { ScoreName.toParString($0) } ?? "—")
            tile("Rounds", "\(bests.roundsPlayed)")
            tile("Avg Score", bests.averageScore.map { String(format: "%.1f", $0) } ?? "—")
            tile("Longest Drive", bests.longestDrive > 0 ? "\(Int(bests.longestDrive)) yd" : "—")
            tile("Best Carry", bests.bestCarry > 0 ? "\(Int(bests.bestCarry)) yd" : "—")
            tile("Avg Club Speed", avgSpeed > 0 ? "\(Int(avgSpeed)) mph" : "—")
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).foregroundColor(.white).minimumScaleFactor(0.6).lineLimit(1)
            Text(title).font(.caption2).foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var trendChart: some View {
        let data = Array(rounds.reversed().enumerated())
        return VStack(alignment: .leading) {
            Text("Score trend").font(.subheadline.bold()).foregroundColor(.white)
            Chart {
                ForEach(data, id: \.element.id) { idx, r in
                    LineMark(x: .value("Round", idx + 1), y: .value("Score", r.totalStrokes))
                        .foregroundStyle(Color.green)
                    PointMark(x: .value("Round", idx + 1), y: .value("Score", r.totalStrokes))
                        .foregroundStyle(Color.green)
                }
            }
            .frame(height: 140)
            .chartYScale(domain: .automatic(includesZero: false))
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func roundBreakdown(_ r: RoundRecord) -> some View {
        HStack(spacing: 10) {
            tile("Front 9", "\(r.front9)  (\(ScoreName.toParString(r.front9 - r.front9Par)))")
            tile("Back 9", "\(r.back9)  (\(ScoreName.toParString(r.back9 - r.back9Par)))")
            tile("Total", "\(r.totalStrokes)  (\(ScoreName.toParString(r.toPar)))")
        }
    }

    private func scoreGrid(_ r: RoundRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hole-by-hole · \(r.date.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline.bold()).foregroundColor(.white)
            nineRow(r, range: 1...9)
            nineRow(r, range: 10...18)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func nineRow(_ r: RoundRecord, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(Array(range), id: \.self) { n in cell("\(n)", .white.opacity(0.5), bold: true) }
            }
            HStack(spacing: 0) {
                ForEach(Array(range), id: \.self) { n in
                    cell("\(course.holes[n - 1].par)", .white.opacity(0.5))
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(range), id: \.self) { n in
                    if let h = r.holes.first(where: { $0.holeNumber == n }) {
                        cell("\(h.strokes)", color(for: h.toPar), bold: true)
                    } else {
                        cell("·", .white.opacity(0.3))
                    }
                }
            }
        }
    }

    private func cell(_ text: String, _ color: Color, bold: Bool = false) -> some View {
        Text(text).font(.system(size: 13, weight: bold ? .bold : .regular, design: .monospaced))
            .foregroundColor(color).frame(maxWidth: .infinity)
    }

    private func color(for toPar: Int) -> Color {
        switch toPar {
        case ...(-2): return .yellow
        case -1: return .green
        case 0: return .white
        case 1: return .orange
        default: return .red
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Round history").font(.subheadline.bold()).foregroundColor(.white)
            ForEach(rounds.prefix(12)) { r in
                Button { selectedRoundID = r.id } label: {
                    HStack {
                        Text(r.date.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Text("\(r.totalStrokes)  \(ScoreName.toParString(r.toPar))").bold()
                    }
                    .font(.footnote)
                    .foregroundColor(r.id == selectedRound?.id ? .green : .white)
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var bestHoles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Best score per hole").font(.subheadline.bold()).foregroundColor(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 9), spacing: 6) {
                ForEach(0..<18, id: \.self) { i in
                    let v = bests.bestHoleStrokes[i]
                    VStack(spacing: 2) {
                        Text("\(i + 1)").font(.system(size: 9)).foregroundColor(.white.opacity(0.5))
                        Text(v == 0 ? "·" : "\(v)").font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(v == 0 ? .white.opacity(0.3) : color(for: v - course.holes[i].par))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

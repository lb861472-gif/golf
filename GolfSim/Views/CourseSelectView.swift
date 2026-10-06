import SwiftUI

struct CourseSelectView: View {
    @EnvironmentObject var persistence: PersistenceManager
    let onPlay: (GameLaunch) -> Void

    @State private var weatherByCourse: [String: WeatherCondition] = [:]
    @State private var mode: PlayMode = .standalone

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.07, blue: 0.09).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Picker("Mode", selection: $mode) {
                        ForEach(PlayMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(Course.all) { course in
                        CourseCard(course: course,
                                   bests: persistence.bests(for: course.id),
                                   weather: Binding(get: { weatherByCourse[course.id] ?? course.defaultWeather },
                                                    set: { weatherByCourse[course.id] = $0 }),
                                   onPlay: {
                            onPlay(GameLaunch(course: course, mode: mode,
                                              weather: weatherByCourse[course.id] ?? course.defaultWeather))
                        })
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Courses")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { mode = persistence.settings.defaultMode }
    }
}

private struct CourseCard: View {
    let course: Course
    let bests: CourseBests
    @Binding var weather: WeatherCondition
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [course.style.skyTop.color, course.style.skyHorizon.color,
                                        course.style.fairway.color, course.style.rough.color],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name).font(.title2.bold()).foregroundColor(.white)
                    Text(course.subtitle).font(.subheadline).foregroundColor(.white.opacity(0.85))
                }
                .padding(14)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text(course.blurb).font(.footnote).foregroundColor(.white.opacity(0.75))

            HStack(spacing: 8) {
                chip("Par \(course.par)")
                chip("\(course.totalYardage) yd")
                chip("Wind \(Int(course.baseWindMPH)) mph")
            }
            HStack(spacing: 4) {
                Text("Hazards").font(.caption).foregroundColor(.white.opacity(0.6))
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: Double(i) < course.hazardRating.rounded() ? "flame.fill" : "flame")
                        .font(.caption).foregroundColor(.orange)
                }
                Spacer()
                ForEach(course.tags, id: \.self) { chip($0, dim: true) }
            }

            CourseMapView(course: course)
                .frame(height: 150)

            // Weather controls
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WeatherCondition.allCases) { w in
                        Button { weather = w } label: {
                            Label(w.displayName, systemImage: w.symbol)
                                .font(.caption.bold())
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(weather == w ? Color(red: 0.2, green: 0.75, blue: 0.4) : Color.white.opacity(0.1),
                                            in: Capsule())
                                .foregroundColor(weather == w ? .black : .white)
                        }
                    }
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Best: \(bests.lowestScore.map { "\($0)" } ?? "—")   Rounds: \(bests.roundsPlayed)")
                    Text("Longest drive: \(bests.longestDrive > 0 ? "\(Int(bests.longestDrive)) yd" : "—")")
                }
                .font(.caption).foregroundColor(.white.opacity(0.7))
                Spacer()
                Button(action: onPlay) {
                    Text("Play").font(.headline).padding(.horizontal, 26).padding(.vertical, 10)
                        .background(Color(red: 0.2, green: 0.75, blue: 0.4), in: Capsule())
                        .foregroundColor(.black)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
    }

    private func chip(_ text: String, dim: Bool = false) -> some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(dim ? 0.06 : 0.14), in: Capsule())
            .foregroundColor(.white.opacity(dim ? 0.6 : 0.95))
    }
}

/// 18-hole map: every hole drawn as a tiny tee -> green line.
struct CourseMapView: View {
    let course: Course

    var body: some View {
        Canvas { ctx, size in
            let cols = 9, rows = 2
            let cw = size.width / CGFloat(cols)
            let ch = size.height / CGFloat(rows)
            for (i, hole) in course.holes.enumerated() {
                let col = i % cols, row = i / cols
                let ox = CGFloat(col) * cw, oy = CGFloat(row) * ch
                let tee = CGPoint(x: ox + cw / 2, y: oy + ch - 14)
                let len = ch - 28
                let bendY = tee.y - len * 0.58
                let bend = CGPoint(x: tee.x, y: bendY)
                let theta = hole.dogleg * 0.5
                let l1 = len * 0.42
                let green = CGPoint(x: bend.x + CGFloat(sin(theta)) * l1, y: bend.y - CGFloat(cos(theta)) * l1)

                var path = Path()
                path.move(to: tee); path.addLine(to: bend); path.addLine(to: green)
                ctx.stroke(path, with: .color(course.style.fairway.color), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: green.x - 5, y: green.y - 5, width: 10, height: 10)),
                         with: .color(course.style.green.scaled(1.25).color))
                for hz in hole.hazards where hz.kind == .water || hz.kind == .creek {
                    let t = CGFloat(hz.along / Double(hole.yardage))
                    let px = tee.x + (green.x - tee.x) * t + CGFloat(hz.lateral) * 0.25
                    let py = tee.y + (green.y - tee.y) * t
                    ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: py - 3, width: 8, height: 6)), with: .color(.blue.opacity(0.8)))
                }
                let label = Text("\(hole.number)").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.8))
                ctx.draw(label, at: CGPoint(x: tee.x, y: tee.y + 8))
            }
        }
        .background(course.style.rough.scaled(0.55).color, in: RoundedRectangle(cornerRadius: 12))
    }
}

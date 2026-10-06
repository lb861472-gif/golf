import SwiftUI

struct MainMenuView: View {
    @EnvironmentObject var persistence: PersistenceManager
    @EnvironmentObject var ble: BluetoothServerManager
    @EnvironmentObject var motion: MotionManager

    @State private var launch: GameLaunch?
    @State private var showSettings = false
    @State private var quickMode: PlayMode = .standalone

    private var quickCourse: Course {
        if let id = persistence.settings.lastCourseID, let c = Course.byID(id) { return c }
        return Course.pebbleGreens
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.04, green: 0.16, blue: 0.12), Color(red: 0.02, green: 0.05, blue: 0.08)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        header
                        quickPlayCard
                        recordSummary
                        navigationButtons
                        coursePreviews
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
        }
        .fullScreenCover(item: $launch) { l in
            GameView(launch: l, persistence: persistence, ble: ble, motion: motion)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(persistence)
        }
        .onAppear { quickMode = persistence.settings.defaultMode }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("GOLF SIM")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.6, green: 0.95, blue: 0.7)],
                                                    startPoint: .leading, endPoint: .trailing))
                Text("5 courses · 90 holes")
                    .font(.subheadline).foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2).foregroundColor(.white)
                    .padding(12).background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var quickPlayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quick Play", systemImage: "bolt.fill")
                .font(.headline).foregroundColor(.white)
            Text("\(quickCourse.name) · \(quickCourse.subtitle)")
                .font(.subheadline).foregroundColor(.white.opacity(0.7))
            Picker("Mode", selection: $quickMode) {
                ForEach(PlayMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Button {
                launch = GameLaunch(course: quickCourse, mode: quickMode, weather: quickCourse.defaultWeather)
            } label: {
                Text("Play 18 Holes")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color(red: 0.2, green: 0.75, blue: 0.4), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundColor(.black)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var recordSummary: some View {
        HStack(spacing: 12) {
            statTile("Rounds", "\(persistence.totalRounds)", "flag.fill")
            statTile("Best", persistence.bestRoundToPar.map { ScoreName.toParString($0.toPar) } ?? "—", "trophy.fill")
            statTile("Longest", persistence.overallLongestDrive > 0 ? "\(Int(persistence.overallLongestDrive)) yd" : "—", "arrow.up.right")
        }
    }

    private func statTile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(Color(red: 0.6, green: 0.95, blue: 0.7))
            Text(value).font(.title3.bold()).foregroundColor(.white)
            Text(title).font(.caption).foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var navigationButtons: some View {
        VStack(spacing: 12) {
            NavigationLink {
                CourseSelectView(onPlay: { launch = $0 })
            } label: { menuRow("Course Select", "map.fill", "Choose a course, weather and mode") }
            NavigationLink {
                ScorecardView()
            } label: { menuRow("Personal Records", "list.number", "Scorecards, bests and swing stats") }
            Button { showSettings = true } label: { menuRow("Settings", "slider.horizontal.3", "Haptics, sound, units, calibration") }
        }
    }

    private func menuRow(_ title: String, _ icon: String, _ sub: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 36)
                .foregroundColor(Color(red: 0.6, green: 0.95, blue: 0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundColor(.white)
                Text(sub).font(.caption).foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.4))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var coursePreviews: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Courses").font(.headline).foregroundColor(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Course.all) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            Spacer()
                            Text(c.name).font(.subheadline.bold()).foregroundColor(.white)
                            Text("Par \(c.par)").font(.caption).foregroundColor(.white.opacity(0.8))
                        }
                        .padding(12)
                        .frame(width: 150, height: 100, alignment: .leading)
                        .background(LinearGradient(colors: [c.style.skyTop.color, c.style.skyHorizon.color, c.style.fairway.color],
                                                   startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var persistence: PersistenceManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gameplay") {
                    Picker("Default mode", selection: $persistence.settings.defaultMode) {
                        ForEach(PlayMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Haptics", isOn: $persistence.settings.hapticsEnabled)
                    Toggle("Sound", isOn: $persistence.settings.soundEnabled)
                    Toggle("Metric units", isOn: $persistence.settings.useMetricUnits)
                }
                Section("Swing calibration") {
                    VStack(alignment: .leading) {
                        Text("Swing power scale: \(persistence.settings.leverArm, specifier: "%.1f")")
                        Slider(value: $persistence.settings.leverArm, in: 1.0...3.0, step: 0.1)
                        Text("Raise this if your swings feel too short, lower it if too long.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Section("Data") {
                    Button("Reset all records", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete all rounds, bests and swing history?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { persistence.resetAll() }
            }
        }
    }
}

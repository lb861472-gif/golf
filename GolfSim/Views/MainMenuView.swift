import SwiftUI

// MARK: - Home screen

struct MainMenuView: View {
    @EnvironmentObject var persistence: PersistenceManager
    @EnvironmentObject var ble: BluetoothServerManager
    @EnvironmentObject var motion: MotionManager

    @AppStorage("golfsim.musicEnabled") private var musicOn = true

    @State private var index = 0
    @State private var weatherOverride: WeatherCondition?
    @State private var mode: PlayMode = .standalone
    @State private var launch: GameLaunch?
    @State private var showSettings = false
    @State private var didSetup = false

    private var course: Course { Course.all[index] }
    private var weather: WeatherCondition { weatherOverride ?? course.defaultWeather }
    private var bests: CourseBests { persistence.bests(for: course.id) }
    private let accent = Color(red: 0.36, green: 0.86, blue: 0.52)

    var body: some View {
        NavigationStack {
            ZStack {
                background
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header
                        carousel
                        pageDots
                        courseInfo
                        weatherRow
                        modeRow
                        playButton
                        bottomBar
                        footer
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
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
        .onAppear {
            if !didSetup {
                didSetup = true
                if let id = persistence.settings.lastCourseID, let i = Course.all.firstIndex(where: { $0.id == id }) { index = i }
                mode = persistence.settings.defaultMode
            }
            applyMusic()
        }
        .onChange(of: index) { _ in
            weatherOverride = nil
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .onChange(of: musicOn) { _ in applyMusic() }
        .onChange(of: launch?.id) { _ in applyMusic() }
        .onChange(of: persistence.settings.soundEnabled) { _ in applyMusic() }
    }

    private func applyMusic() {
        if musicOn && persistence.settings.soundEnabled && launch == nil {
            MenuMusic.shared.play()
        } else {
            MenuMusic.shared.stop()
        }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            Color.black
            CoursePreviewArt(course: course)
                .id(course.id)
                .scaleEffect(1.35)
                .blur(radius: 30)
                .saturation(1.25)
                .transition(.opacity)
            LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.62), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: index)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 32, height: 32)
                    .background(accent, in: Circle())
                Text("Golf Sim")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
            }
            Spacer()
            glassButton(musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill") { musicOn.toggle() }
            glassButton("gearshape.fill") { showSettings = true }
        }
        .padding(.top, 8)
    }

    private func glassButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Carousel

    private var carousel: some View {
        TabView(selection: $index) {
            ForEach(0..<Course.all.count, id: \.self) { i in
                HeroCard(course: Course.all[i], animated: i == index)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 14)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 340)
        .padding(.horizontal, -4)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<Course.all.count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.3))
                    .frame(width: i == index ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
        .padding(.top, -8)
    }

    // MARK: Info

    private var courseInfo: some View {
        HStack(spacing: 0) {
            infoBlock("PAR", "\(course.par)")
            divider
            infoBlock("YARDS", "\(course.totalYardage)")
            divider
            VStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Double(i) < course.hazardRating.rounded() ? .orange : .white.opacity(0.18))
                    }
                }
                .frame(height: 24)
                Text("HAZARDS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundColor(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            divider
            infoBlock("BEST", bests.lowestScore.map { "\($0)" } ?? "—")
        }
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 30)
    }

    private func infoBlock(_ title: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(.white).frame(height: 24)
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Controls

    private var weatherRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WeatherCondition.allCases) { w in
                    Button {
                        weatherOverride = w
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Label(w.displayName, systemImage: w.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(weather == w ? Color.white : Color.white.opacity(0.12), in: Capsule())
                            .foregroundColor(weather == w ? .black : .white)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var modeRow: some View {
        HStack(spacing: 0) {
            ForEach(PlayMode.allCases) { m in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { mode = m } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m.symbol)
                        Text(m.title)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(mode == m ? Color.white.opacity(0.95) : Color.clear, in: Capsule())
                    .foregroundColor(mode == m ? .black : .white.opacity(0.85))
                }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var playButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            launch = GameLaunch(course: course, mode: mode, weather: weather)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                Text("Play 18 Holes")
            }
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(accent, in: Capsule())
            .shadow(color: accent.opacity(0.45), radius: 16, y: 6)
        }
        .buttonStyle(PressableStyle())
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            NavigationLink {
                ScorecardView()
            } label: { barItem("list.number", "Records") }
            NavigationLink {
                CourseSelectView(onPlay: { launch = $0 })
            } label: { barItem("map.fill", "All Courses") }
            Button { showSettings = true } label: { barItem("slider.horizontal.3", "Settings") }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func barItem(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        Text(persistence.totalRounds == 0
             ? "Swing your phone to play, or use the on-screen test swing."
             : "\(persistence.totalRounds) rounds played · Longest drive \(Int(persistence.overallLongestDrive)) yd")
            .font(.footnote)
            .foregroundColor(.white.opacity(0.5))
            .multilineTextAlignment(.center)
    }
}

// MARK: - Hero card

struct HeroCard: View {
    let course: Course
    let animated: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoursePreviewArt(course: course, animated: animated)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
            VStack(alignment: .leading, spacing: 7) {
                Text(course.subtitle.uppercased())
                    .font(.system(size: 12, weight: .bold)).tracking(1.6)
                    .foregroundColor(.white.opacity(0.85))
                Text(course.name)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.7).lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(course.tags, id: \.self) { t in
                        Text(t).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var persistence: PersistenceManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("golfsim.musicEnabled") private var musicOn = true
    @AppStorage("golfsim.puttAssist") private var puttAssist = true
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gameplay") {
                    Picker("Default mode", selection: $persistence.settings.defaultMode) {
                        ForEach(PlayMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Haptics", isOn: $persistence.settings.hapticsEnabled)
                    Toggle("Metric units", isOn: $persistence.settings.useMetricUnits)
                    Toggle("Putting assist (auto-aim, force only)", isOn: $puttAssist)
                }
                Section("Audio") {
                    Toggle("Sound effects", isOn: $persistence.settings.soundEnabled)
                    Toggle("Menu music", isOn: $musicOn)
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

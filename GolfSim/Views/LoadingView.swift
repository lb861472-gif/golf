import SwiftUI

/// Shown while a round loads: logo, course name, progress bar and the studio credit.
struct SwingitLoadingView: View {
    let course: Course
    @State private var progress: CGFloat = 0
    @State private var appeared = false
    @State private var tipIndex = Int.random(in: 0..<4)

    private let tips = [
        "Take the phone back slowly, then swing through - the takeaway is ignored.",
        "A flat swing flies lower. A steep, short swing pops the ball up for chips.",
        "On the green, the line is automatic. Just match the force.",
        "Tap the binoculars to fly over the hole before you tee off."
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.16, blue: 0.09), Color(red: 0.01, green: 0.06, blue: 0.04)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(red: 0.2, green: 0.55, blue: 0.3).opacity(0.35), .clear],
                           center: .center, startRadius: 10, endRadius: 360)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                Image("SwingitLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .scaleEffect(appeared ? 1 : 0.8)
                    .opacity(appeared ? 1 : 0)

                Text("Loading \(course.name)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.top, 30)
                Text(course.subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.86, blue: 0.52), Color(red: 0.7, green: 1, blue: 0.75)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * progress))
                    }
                }
                .frame(width: 220, height: 6)
                .padding(.top, 26)

                Text(tips[tipIndex])
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.top, 22)

                Spacer()

                VStack(spacing: 4) {
                    Text("A SWINGIT LABS PRODUCTION")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2.4)
                        .foregroundColor(.white.opacity(0.75))
                    Text("© Swingit Labs")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.bottom, 34)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) { appeared = true }
            withAnimation(.easeInOut(duration: 2.6)) { progress = 1 }
        }
    }
}

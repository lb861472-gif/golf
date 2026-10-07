import SwiftUI

/// Hand-built illustration of each course, drawn with SwiftUI Canvas (no image assets).
/// Used for the home-screen carousel, the course list and the blurred background.
struct CoursePreviewArt: View {
    let course: Course
    var animated = false

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                Canvas { ctx, size in
                    CourseArtPainter(course: course).paint(&ctx, size: size, time: tl.date.timeIntervalSinceReferenceDate)
                }
            }
        } else {
            Canvas { ctx, size in
                CourseArtPainter(course: course).paint(&ctx, size: size, time: 0)
            }
        }
    }
}

private struct ArtFrame {
    let w: CGFloat
    let h: CGFloat
    let hy: CGFloat     // horizon
    let top: CGFloat    // where the ground starts

    func cx(_ t: Double) -> CGFloat { w * CGFloat(0.5 + 0.09 * sin(t * 2.4 + 0.8) * (1 - t * 0.4)) }
    func hw(_ t: Double) -> CGFloat { w * CGFloat(0.03 + 0.43 * pow(t, 1.3)) }
    func y(_ t: Double) -> CGFloat { top + (h - top) * CGFloat(t) }
}

private struct CourseArtPainter {
    let course: Course
    private var st: CourseStyle { course.style }

    private func col(_ c: RGB, _ a: Double = 1) -> Color { Color(red: c.r, green: c.g, blue: c.b, opacity: a) }

    func paint(_ ctx: inout GraphicsContext, size: CGSize, time: Double) {
        let w = size.width, h = size.height
        let hy = h * 0.56
        let top = course.theme == .coastal ? hy + h * 0.09 : hy
        let f = ArtFrame(w: w, h: h, hy: hy, top: top)
        let seed = UInt64(course.id.utf8.reduce(7) { ($0 &* 31 &+ Int($1)) & 0xffffff })
        var rng = SeededRNG(seed: seed)

        drawSky(&ctx, f)
        drawSun(&ctx, f)
        drawClouds(&ctx, f, time: time, rng: &rng)

        switch course.theme {
        case .coastal: drawOcean(&ctx, f)
        case .forest: drawPineLayers(&ctx, f, rng: &rng)
        case .desert: drawMesas(&ctx, f, rng: &rng)
        case .alpine: drawPeaks(&ctx, f, rng: &rng)
        case .links: drawHills(&ctx, f, rng: &rng)
        }

        // Ground
        let ground = Path(CGRect(x: 0, y: top, width: w, height: h - top))
        ctx.fill(ground, with: .linearGradient(Gradient(colors: [col(st.rough, 1), col(st.rough.scaled(0.6), 1)]),
                                                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: h)))

        switch course.theme {
        case .coastal: drawCliff(&ctx, f)
        case .alpine: drawLake(&ctx, f)
        case .links: drawWall(&ctx, f)
        default: break
        }

        drawFairway(&ctx, f)
        drawGreen(&ctx, f, time: time)
        drawBunkers(&ctx, f)

        switch course.theme {
        case .forest: drawForegroundPines(&ctx, f)
        case .desert: drawCacti(&ctx, f)
        case .alpine: drawForegroundPines(&ctx, f)
        case .coastal: drawGulls(&ctx, f, time: time)
        case .links: break
        }
        drawTufts(&ctx, f, rng: &rng)

        // Vignette
        ctx.fill(Path(CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45)),
                 with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.35)]),
                                       startPoint: CGPoint(x: 0, y: h * 0.55), endPoint: CGPoint(x: 0, y: h)))
    }

    // MARK: Sky

    private func drawSky(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: f.w, height: f.hy + 2)),
                 with: .linearGradient(Gradient(colors: [col(st.skyTop), col(st.skyHorizon)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: f.hy)))
    }

    private func drawSun(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        let sx = f.w * CGFloat(0.2 + 0.6 * (st.sunAzimuth / 360))
        let sy = f.hy - CGFloat(st.sunElevation / 90) * f.hy * 0.82 - 6
        let overcast = course.theme == .forest || course.theme == .links
        let glowR = f.w * (overcast ? 0.25 : 0.4)
        ctx.fill(Path(ellipseIn: CGRect(x: sx - glowR, y: sy - glowR, width: glowR * 2, height: glowR * 2)),
                 with: .radialGradient(Gradient(colors: [col(st.sunColor, overcast ? 0.25 : 0.7), col(st.sunColor, 0)]),
                                       center: CGPoint(x: sx, y: sy), startRadius: 0, endRadius: glowR))
        if !overcast {
            let r = f.w * 0.045
            ctx.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)), with: .color(col(st.sunColor)))
        }
    }

    private func drawClouds(_ ctx: inout GraphicsContext, _ f: ArtFrame, time: Double, rng: inout SeededRNG) {
        let heavy = course.theme == .links || course.theme == .forest
        let n = heavy ? 7 : 4
        for i in 0..<n {
            let base = CGFloat.random(in: 0...1, using: &rng)
            let y = f.hy * CGFloat.random(in: 0.12...0.55, using: &rng)
            let s = f.w * CGFloat.random(in: 0.12...0.26, using: &rng)
            let speed = 6.0 + Double(i) * 1.5
            var x = (base * (f.w + 240) + CGFloat(time * speed)).truncatingRemainder(dividingBy: f.w + 240) - 120
            if x < -120 { x += f.w + 240 }
            let alpha = heavy ? 0.42 : 0.5
            let tint: Color = heavy ? Color(white: 0.85, opacity: alpha) : Color(white: 1, opacity: alpha)
            for k in 0..<3 {
                let ox = CGFloat(k - 1) * s * 0.45
                let oy = CGFloat(k % 2) * -s * 0.07
                ctx.fill(Path(ellipseIn: CGRect(x: x + ox - s * 0.5, y: y + oy - s * 0.16, width: s, height: s * 0.32)), with: .color(tint))
            }
        }
    }

    // MARK: Theme backdrops

    private func drawOcean(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        let y0 = f.hy - 3
        let y1 = f.top + 4
        ctx.fill(Path(CGRect(x: 0, y: y0, width: f.w, height: y1 - y0)),
                 with: .linearGradient(Gradient(colors: [col(st.water.mixed(with: st.skyHorizon, 0.35)), col(st.water.scaled(0.8))]),
                                       startPoint: CGPoint(x: 0, y: y0), endPoint: CGPoint(x: 0, y: y1)))
        // Sun glitter
        let sx = f.w * CGFloat(0.2 + 0.6 * (st.sunAzimuth / 360))
        for k in 0..<7 {
            let yy = y0 + CGFloat(k) * (y1 - y0) / 7 + 2
            let ww = f.w * (0.03 + 0.018 * CGFloat(k))
            ctx.fill(Path(roundedRect: CGRect(x: sx - ww / 2, y: yy, width: ww, height: 1.6), cornerRadius: 1),
                     with: .color(.white.opacity(0.65 - Double(k) * 0.06)))
        }
    }

    private func drawCliff(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: f.top + 2))
        p.addLine(to: CGPoint(x: f.w * 0.22, y: f.top + f.h * 0.03))
        p.addLine(to: CGPoint(x: f.w * 0.33, y: f.top + f.h * 0.16))
        p.addLine(to: CGPoint(x: f.w * 0.20, y: f.top + f.h * 0.34))
        p.addLine(to: CGPoint(x: 0, y: f.top + f.h * 0.42))
        p.closeSubpath()
        ctx.fill(p, with: .linearGradient(Gradient(colors: [Color(red: 0.62, green: 0.52, blue: 0.40), Color(red: 0.34, green: 0.28, blue: 0.22)]),
                                          startPoint: CGPoint(x: 0, y: f.top), endPoint: CGPoint(x: f.w * 0.3, y: f.top + f.h * 0.4)))
        var water = Path()
        water.move(to: CGPoint(x: 0, y: f.top + f.h * 0.15))
        water.addLine(to: CGPoint(x: f.w * 0.17, y: f.top + f.h * 0.2))
        water.addLine(to: CGPoint(x: 0, y: f.top + f.h * 0.42))
        water.closeSubpath()
        ctx.fill(water, with: .color(col(st.water, 0.9)))
    }

    private func drawGulls(_ ctx: inout GraphicsContext, _ f: ArtFrame, time: Double) {
        for i in 0..<3 {
            let x = f.w * (0.62 + CGFloat(i) * 0.1) + CGFloat(sin(time * 0.6 + Double(i))) * 6
            let y = f.hy * (0.38 + CGFloat(i) * 0.09)
            var p = Path()
            p.move(to: CGPoint(x: x - 8, y: y))
            p.addQuadCurve(to: CGPoint(x: x, y: y + 2), control: CGPoint(x: x - 4, y: y - 5))
            p.addQuadCurve(to: CGPoint(x: x + 8, y: y), control: CGPoint(x: x + 4, y: y - 5))
            ctx.stroke(p, with: .color(.white.opacity(0.9)), lineWidth: 1.4)
        }
    }

    private func pine(_ ctx: inout GraphicsContext, x: CGFloat, base: CGFloat, height: CGFloat, color: Color) {
        var p = Path()
        let tw = height * 0.46
        for i in 0..<4 {
            let t = CGFloat(i) / 4
            let ty = base - height + height * 0.88 * t
            let by = ty + height * 0.36
            let half = tw * (0.4 + 0.6 * t) / 2
            p.move(to: CGPoint(x: x, y: ty))
            p.addLine(to: CGPoint(x: x + half, y: by))
            p.addLine(to: CGPoint(x: x - half, y: by))
            p.closeSubpath()
        }
        p.addRect(CGRect(x: x - height * 0.025, y: base - height * 0.1, width: height * 0.05, height: height * 0.1))
        ctx.fill(p, with: .color(color))
    }

    private func drawPineLayers(_ ctx: inout GraphicsContext, _ f: ArtFrame, rng: inout SeededRNG) {
        let layers: [(CGFloat, Int, CGFloat, Double)] = [(0.0, 18, 0.20, 0.30), (0.03, 14, 0.27, 0.5), (0.07, 10, 0.34, 0.72)]
        for (offset, count, hFrac, depth) in layers {
            let c = st.fairway.mixed(with: st.skyHorizon, 1 - depth).scaled(0.55 + 0.25 * depth)
            for i in 0..<count {
                let x = (CGFloat(i) + CGFloat.random(in: 0...0.8, using: &rng)) * f.w / CGFloat(count)
                pine(&ctx, x: x, base: f.hy + f.h * offset + 6, height: f.h * hFrac * CGFloat.random(in: 0.7...1.1, using: &rng), color: col(c))
            }
            ctx.fill(Path(CGRect(x: 0, y: f.hy - f.h * 0.02 + f.h * offset, width: f.w, height: f.h * 0.09)),
                     with: .linearGradient(Gradient(colors: [.clear, col(st.skyHorizon, 0.38), .clear]),
                                           startPoint: CGPoint(x: 0, y: f.hy - f.h * 0.02 + f.h * offset),
                                           endPoint: CGPoint(x: 0, y: f.hy + f.h * 0.07 + f.h * offset)))
        }
    }

    private func drawForegroundPines(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        let dark = st.fairway.scaled(0.28)
        pine(&ctx, x: f.w * 0.07, base: f.h * 0.98, height: f.h * 0.72, color: col(dark))
        pine(&ctx, x: f.w * 0.20, base: f.h * 0.86, height: f.h * 0.44, color: col(dark.scaled(1.15)))
        pine(&ctx, x: f.w * 0.94, base: f.h * 1.0, height: f.h * 0.78, color: col(dark))
        pine(&ctx, x: f.w * 0.82, base: f.h * 0.84, height: f.h * 0.38, color: col(dark.scaled(1.15)))
    }

    private func drawMesas(_ ctx: inout GraphicsContext, _ f: ArtFrame, rng: inout SeededRNG) {
        let rust = RGB(0.62, 0.30, 0.18)
        for layer in 0..<3 {
            let depth = Double(layer) / 2          // 0 far ... 1 near
            let c = rust.mixed(with: st.skyHorizon, 0.65 - 0.55 * depth).scaled(0.8 + 0.2 * depth)
            let n = 4 + layer
            for i in 0..<n {
                let cxm = (CGFloat(i) + CGFloat.random(in: 0.1...0.9, using: &rng)) * f.w / CGFloat(n)
                let ww = f.w * CGFloat.random(in: 0.18...0.34, using: &rng)
                let hh = f.h * CGFloat(0.13 + 0.06 * depth) * CGFloat.random(in: 0.7...1.2, using: &rng)
                let base = f.hy + 6
                var p = Path()
                p.move(to: CGPoint(x: cxm - ww / 2, y: base))
                p.addLine(to: CGPoint(x: cxm - ww * 0.42, y: base - hh * 0.55))
                p.addLine(to: CGPoint(x: cxm - ww * 0.34, y: base - hh * 0.58))
                p.addLine(to: CGPoint(x: cxm - ww * 0.30, y: base - hh))
                p.addLine(to: CGPoint(x: cxm + ww * 0.30, y: base - hh))
                p.addLine(to: CGPoint(x: cxm + ww * 0.36, y: base - hh * 0.55))
                p.addLine(to: CGPoint(x: cxm + ww / 2, y: base))
                p.closeSubpath()
                ctx.fill(p, with: .linearGradient(Gradient(colors: [col(c.scaled(1.15)), col(c.scaled(0.8))]),
                                                  startPoint: CGPoint(x: 0, y: base - hh), endPoint: CGPoint(x: 0, y: base)))
            }
        }
    }

    private func drawCacti(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        let c = Color(red: 0.07, green: 0.10, blue: 0.07)
        func saguaro(_ x: CGFloat, _ base: CGFloat, _ hgt: CGFloat) {
            let tw = hgt * 0.1
            var p = Path()
            p.addRoundedRect(in: CGRect(x: x - tw / 2, y: base - hgt, width: tw, height: hgt), cornerSize: CGSize(width: tw / 2, height: tw / 2))
            p.addRoundedRect(in: CGRect(x: x - tw * 2.1, y: base - hgt * 0.62, width: tw * 0.8, height: hgt * 0.3), cornerSize: CGSize(width: tw * 0.4, height: tw * 0.4))
            p.addRect(CGRect(x: x - tw * 2.1, y: base - hgt * 0.38, width: tw * 2, height: tw * 0.7))
            p.addRoundedRect(in: CGRect(x: x + tw * 1.3, y: base - hgt * 0.78, width: tw * 0.8, height: hgt * 0.34), cornerSize: CGSize(width: tw * 0.4, height: tw * 0.4))
            p.addRect(CGRect(x: x, y: base - hgt * 0.48, width: tw * 1.7, height: tw * 0.7))
            ctx.fill(p, with: .color(c))
        }
        saguaro(f.w * 0.10, f.h * 1.0, f.h * 0.62)
        saguaro(f.w * 0.90, f.h * 0.96, f.h * 0.46)
        saguaro(f.w * 0.78, f.h * 0.78, f.h * 0.2)
    }

    private func drawPeaks(_ ctx: inout GraphicsContext, _ f: ArtFrame, rng: inout SeededRNG) {
        for layer in 0..<2 {
            let depth = Double(layer)
            let n = 7
            var pts: [CGPoint] = [CGPoint(x: -10, y: f.hy + 6)]
            var apexes: [CGPoint] = []
            for i in 0...n {
                let x = CGFloat(i) / CGFloat(n) * (f.w + 20) - 10
                let peak = CGFloat.random(in: 0.2...0.46, using: &rng) * (layer == 0 ? 1.0 : 0.6)
                let apex = CGPoint(x: x, y: f.hy - f.h * peak)
                apexes.append(apex)
                pts.append(apex)
                if i < n { pts.append(CGPoint(x: x + (f.w / CGFloat(n)) * 0.5, y: f.hy - f.h * CGFloat.random(in: 0.06...0.14, using: &rng))) }
            }
            pts.append(CGPoint(x: f.w + 10, y: f.hy + 6))
            var p = Path()
            p.addLines(pts)
            p.closeSubpath()
            let rock = RGB(0.45, 0.48, 0.55).mixed(with: st.skyHorizon, layer == 0 ? 0.55 : 0.15)
            ctx.fill(p, with: .linearGradient(Gradient(colors: [col(rock.scaled(1.15)), col(rock.scaled(0.75))]),
                                              startPoint: CGPoint(x: 0, y: f.hy - f.h * 0.4), endPoint: CGPoint(x: 0, y: f.hy)))
            // Snow caps
            for a in apexes where a.y < f.hy - f.h * 0.14 {
                let drop = (f.hy - a.y) * 0.34
                var cap = Path()
                cap.move(to: a)
                cap.addLine(to: CGPoint(x: a.x + drop * 0.55, y: a.y + drop))
                cap.addLine(to: CGPoint(x: a.x + drop * 0.2, y: a.y + drop * 0.78))
                cap.addLine(to: CGPoint(x: a.x - drop * 0.1, y: a.y + drop * 1.05))
                cap.addLine(to: CGPoint(x: a.x - drop * 0.35, y: a.y + drop * 0.8))
                cap.addLine(to: CGPoint(x: a.x - drop * 0.6, y: a.y + drop))
                cap.closeSubpath()
                ctx.fill(cap, with: .color(.white.opacity(layer == 0 ? 0.85 : 0.97)))
            }
            _ = depth
        }
    }

    private func drawLake(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        let r = CGRect(x: f.w * 0.62, y: f.top + f.h * 0.07, width: f.w * 0.34, height: f.h * 0.09)
        ctx.fill(Path(ellipseIn: r), with: .linearGradient(Gradient(colors: [col(st.water.mixed(with: st.skyHorizon, 0.4)), col(st.water.scaled(0.8))]),
                                                           startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
        ctx.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.25)), lineWidth: 1)
    }

    private func drawHills(_ ctx: inout GraphicsContext, _ f: ArtFrame, rng: inout SeededRNG) {
        let colors: [RGB] = [st.skyHorizon.mixed(with: st.accent, 0.3), st.accent.mixed(with: st.rough, 0.35), st.rough.mixed(with: st.accent, 0.2).scaled(0.85)]
        for layer in 0..<3 {
            let amp = f.h * (0.07 - 0.015 * CGFloat(layer))
            let base = f.hy + f.h * CGFloat(layer) * 0.04
            let phase = Double.random(in: 0...6, using: &rng)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: f.h))
            var x: CGFloat = 0
            while x <= f.w + 6 {
                let y = base - amp * CGFloat(0.55 + 0.45 * sin(Double(x) / Double(f.w) * 7 + phase + Double(layer) * 1.7))
                p.addLine(to: CGPoint(x: x, y: y))
                x += 6
            }
            p.addLine(to: CGPoint(x: f.w, y: f.h))
            p.closeSubpath()
            ctx.fill(p, with: .color(col(colors[layer])))
        }
    }

    private func drawWall(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        for i in 0..<16 {
            let t = CGFloat(i) / 16
            let x = f.w * (0.02 + 0.34 * t)
            let y = f.top + f.h * (0.30 - 0.22 * t)
            let s = f.w * (0.05 - 0.03 * t)
            let rect = CGRect(x: x, y: y - s * 0.7, width: s, height: s * 0.7)
            ctx.fill(Path(roundedRect: rect, cornerRadius: s * 0.12), with: .color(Color(white: 0.5 - 0.1 * Double(t), opacity: 1)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: s * 0.12), with: .color(.black.opacity(0.25)), lineWidth: 0.8)
        }
    }

    // MARK: Fairway, green, bunkers

    private func drawFairway(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        let stripes = 14
        for i in 0..<stripes {
            let t0 = pow(Double(i) / Double(stripes), 1.7)
            let t1 = pow(Double(i + 1) / Double(stripes), 1.7)
            var p = Path()
            p.move(to: CGPoint(x: f.cx(t0) - f.hw(t0), y: f.y(t0)))
            p.addLine(to: CGPoint(x: f.cx(t0) + f.hw(t0), y: f.y(t0)))
            p.addLine(to: CGPoint(x: f.cx(t1) + f.hw(t1), y: f.y(t1)))
            p.addLine(to: CGPoint(x: f.cx(t1) - f.hw(t1), y: f.y(t1)))
            p.closeSubpath()
            let c = i % 2 == 0 ? st.fairway : st.fairwayAlt
            ctx.fill(p, with: .color(col(c)))
        }
    }

    private func drawGreen(_ ctx: inout GraphicsContext, _ f: ArtFrame, time: Double) {
        let gx = f.cx(0), gy = f.y(0) + f.h * 0.012
        let gw = f.w * 0.15, gh = f.w * 0.04
        let rect = CGRect(x: gx - gw / 2, y: gy - gh / 2, width: gw, height: gh)
        ctx.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -1.5)), with: .color(col(st.fairwayAlt.scaled(1.1))))
        ctx.fill(Path(ellipseIn: rect), with: .color(col(st.green.scaled(1.12))))
        let topY = gy - f.h * 0.14
        var stick = Path()
        stick.move(to: CGPoint(x: gx + gw * 0.1, y: gy))
        stick.addLine(to: CGPoint(x: gx + gw * 0.1, y: topY))
        ctx.stroke(stick, with: .color(.white), lineWidth: 1.4)
        let flutter = CGFloat(sin(time * 3.2)) * 2.2
        var flag = Path()
        flag.move(to: CGPoint(x: gx + gw * 0.1, y: topY))
        flag.addQuadCurve(to: CGPoint(x: gx + gw * 0.1 + f.w * 0.05, y: topY + f.h * 0.022),
                          control: CGPoint(x: gx + gw * 0.1 + f.w * 0.03, y: topY + flutter))
        flag.addLine(to: CGPoint(x: gx + gw * 0.1, y: topY + f.h * 0.045))
        flag.closeSubpath()
        ctx.fill(flag, with: .color(Color(red: 0.92, green: 0.15, blue: 0.15)))
    }

    private func drawBunkers(_ ctx: inout GraphicsContext, _ f: ArtFrame) {
        let spots: [(Double, CGFloat)] = [(0.10, -1.15), (0.14, 1.2), (0.34, 1.12), (0.58, -1.1)]
        for (t, side) in spots {
            let x = f.cx(t) + side * f.hw(t)
            let y = f.y(t) + f.h * 0.01
            let ww = f.w * CGFloat(0.04 + 0.2 * t)
            let hh = ww * 0.32
            let r = CGRect(x: x - ww / 2, y: y - hh / 2, width: ww, height: hh)
            let sand = course.theme == .links ? st.sand.scaled(0.92) : st.sand
            ctx.fill(Path(ellipseIn: r.insetBy(dx: -1.5, dy: -1)), with: .color(col(sand.scaled(0.72))))
            ctx.fill(Path(ellipseIn: r), with: .color(col(sand)))
        }
    }

    private func drawTufts(_ ctx: inout GraphicsContext, _ f: ArtFrame, rng: inout SeededRNG) {
        for _ in 0..<70 {
            let side: CGFloat = Bool.random(using: &rng) ? 1 : -1
            let t = pow(Double.random(in: 0.25...1, using: &rng), 1.2)
            let x = f.cx(t) + side * (f.hw(t) + CGFloat.random(in: 0...f.w * 0.3, using: &rng))
            let y = f.y(t)
            let hh = f.h * CGFloat(0.012 + 0.04 * t)
            var p = Path()
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + CGFloat.random(in: -hh...hh, using: &rng) * 0.4, y: y - hh))
            let c = Bool.random(using: &rng) ? st.rough.scaled(1.4) : st.accent.scaled(0.9)
            ctx.stroke(p, with: .color(col(c, 0.85)), lineWidth: max(0.8, hh * 0.12))
        }
    }
}

import UIKit
import CoreGraphics
import simd

/// Every texture in the game is generated here at runtime - no asset catalog required.
enum ProceduralTextures {

    // MARK: - Pixel helpers

    private static func image(width: Int, height: Int, pixels: [UInt8]) -> UIImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else {
            return UIImage()
        }
        return UIImage(cgImage: cg)
    }

    private static func hash2(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        var n = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ seed &* 2147483647)
        n = (n ^ (n >> 13)) &* 1274126177
        n = n ^ (n >> 16)
        return Double(n) / Double(UInt32.max)
    }

    /// Value noise that tiles every `period` lattice cells.
    private static func tileNoise(_ x: Double, _ y: Double, period: Int, seed: Int) -> Double {
        let fx = floor(x), fy = floor(y)
        let xi = Int(fx), yi = Int(fy)
        let xf = x - fx, yf = y - fy
        func h(_ a: Int, _ b: Int) -> Double {
            hash2(((a % period) + period) % period, ((b % period) + period) % period, seed)
        }
        let u = xf * xf * (3 - 2 * xf)
        let v = yf * yf * (3 - 2 * yf)
        let a = h(xi, yi), b = h(xi + 1, yi), c = h(xi, yi + 1), d = h(xi + 1, yi + 1)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    private static func normalMap(size: Int, strength: Double, height: (Int, Int) -> Double) -> UIImage {
        var hmap = [Double](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size { hmap[y * size + x] = height(x, y) } }
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let xl = hmap[y * size + (x + size - 1) % size]
                let xr = hmap[y * size + (x + 1) % size]
                let yu = hmap[((y + size - 1) % size) * size + x]
                let yd = hmap[((y + 1) % size) * size + x]
                var n = SIMD3<Double>((xl - xr) * strength, (yu - yd) * strength, 1)
                n = simd_normalize(n)
                let i = (y * size + x) * 4
                px[i] = UInt8(max(0, min(255, (n.x * 0.5 + 0.5) * 255)))
                px[i + 1] = UInt8(max(0, min(255, (n.y * 0.5 + 0.5) * 255)))
                px[i + 2] = UInt8(max(0, min(255, (n.z * 0.5 + 0.5) * 255)))
                px[i + 3] = 255
            }
        }
        return image(width: size, height: size, pixels: px)
    }

    // MARK: - Tiling normal maps

    /// Fine grass / ground detail, tileable.
    static let detailNormalMap: UIImage = {
        let size = 256
        return normalMap(size: size, strength: 3.2) { x, y in
            var sum = 0.0
            var amp = 0.5
            var freq = 8
            for o in 0..<4 {
                let fx = Double(x) / Double(size) * Double(freq)
                let fy = Double(y) / Double(size) * Double(freq)
                sum += tileNoise(fx, fy, period: freq, seed: 11 + o) * amp
                amp *= 0.5
                freq *= 2
            }
            return sum
        }
    }()

    /// Gritty sand variant.
    static let sandNormalMap: UIImage = {
        let size = 256
        return normalMap(size: size, strength: 5.0) { x, y in
            tileNoise(Double(x) / 4.0, Double(y) / 4.0, period: 64, seed: 71) * 0.6 +
            tileNoise(Double(x) / 16.0, Double(y) / 16.0, period: 16, seed: 72) * 0.4
        }
    }()

    /// Water ripples: a sum of integer-wavelength sines so it tiles perfectly.
    static let waterNormalMap: UIImage = {
        let size = 256
        let waves: [(kx: Double, ky: Double, amp: Double, ph: Double)] = [
            (3, 1, 0.6, 0.3), (-2, 4, 0.5, 1.7), (5, -3, 0.35, 2.9), (7, 6, 0.2, 4.1), (-9, 2, 0.15, 5.3)
        ]
        return normalMap(size: size, strength: 2.2) { x, y in
            let u = Double(x) / Double(size)
            let v = Double(y) / Double(size)
            var h = 0.0
            for w in waves { h += sin(2 * .pi * (w.kx * u + w.ky * v) + w.ph) * w.amp * 0.08 }
            return h
        }
    }()

    /// Golf-ball dimples (hex-ish staggered grid).
    static let ballNormalMap: UIImage = {
        let size = 256
        let cols = 14.0
        let cell = Double(size) / cols
        let radius = cell * 0.42
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let row = Int(floor(Double(y) / cell))
                let offset = row % 2 == 0 ? 0.0 : cell / 2
                let gx = (Double(x) + offset).truncatingRemainder(dividingBy: cell) - cell / 2
                let gy = (Double(y)).truncatingRemainder(dividingBy: cell) - cell / 2
                let d = (gx * gx + gy * gy).squareRoot()
                var n = SIMD3<Double>(0, 0, 1)
                if d < radius {
                    let k = d / radius
                    n = simd_normalize(SIMD3<Double>(-gx / radius * 0.9 * k, -gy / radius * 0.9 * k, 0.55))
                }
                let i = (y * size + x) * 4
                px[i] = UInt8((n.x * 0.5 + 0.5) * 255)
                px[i + 1] = UInt8((n.y * 0.5 + 0.5) * 255)
                px[i + 2] = UInt8((n.z * 0.5 + 0.5) * 255)
                px[i + 3] = 255
            }
        }
        return image(width: size, height: size, pixels: px)
    }()

    // MARK: - Particles / sprites

    static let softParticle: UIImage = radial(size: 64, inner: UIColor(white: 1, alpha: 1), outer: UIColor(white: 1, alpha: 0))

    static let streak: UIImage = {
        let size = CGSize(width: 8, height: 64)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let colors = [UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0.9).cgColor,
                          UIColor(white: 1, alpha: 0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }()

    static func radial(size: Int, inner: UIColor, outer: UIColor) -> UIImage {
        let s = CGSize(width: size, height: size)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: s, format: fmt).image { ctx in
            let colors = [inner.cgColor, outer.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let c = CGPoint(x: s.width / 2, y: s.height / 2)
                ctx.cgContext.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                                 endRadius: s.width / 2, options: [])
            }
        }
    }

    /// Alpha falloff used by ponds so the edges look shallow and the middle deep.
    static let pondAlpha: UIImage = radial(size: 128, inner: UIColor(white: 1, alpha: 0.96),
                                           outer: UIColor(white: 1, alpha: 0.55))

    // MARK: - Sky

    static func sky(top: RGB, horizon: RGB, ground: RGB, cloudiness: Double, seed: UInt64) -> UIImage {
        let size = CGSize(width: 1024, height: 512)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            let mid = top.mixed(with: horizon, 0.6)
            let colors = [top.uiColor.cgColor, mid.uiColor.cgColor, horizon.uiColor.cgColor,
                          horizon.uiColor.cgColor, ground.uiColor.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                  locations: [0, 0.35, 0.5, 0.56, 1]) {
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Soft clouds
            var rng = SeededRNG(seed: seed)
            let count = Int(70 * cloudiness)
            for _ in 0..<count {
                let x = CGFloat.random(in: 0...size.width, using: &rng)
                let y = CGFloat.random(in: 40...230, using: &rng)
                let w = CGFloat.random(in: 80...260, using: &rng)
                let h = w * CGFloat.random(in: 0.12...0.25, using: &rng)
                let alpha = CGFloat.random(in: 0.05...0.16, using: &rng) * CGFloat(0.6 + cloudiness)
                for dx in [-size.width, 0, size.width] {
                    let rect = CGRect(x: x + dx - w / 2, y: y - h / 2, width: w, height: h)
                    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: [UIColor(white: 1, alpha: alpha).cgColor,
                                                   UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                                          locations: [0, 1]) {
                        c.saveGState()
                        c.translateBy(x: rect.midX, y: rect.midY)
                        c.scaleBy(x: w / 2, y: h / 2)
                        c.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
                        c.restoreGState()
                    }
                }
            }
        }
    }

    static func sunGlow(color: RGB) -> UIImage {
        radial(size: 256, inner: color.uiColor(alpha: 1.0), outer: color.uiColor(alpha: 0.0))
    }

    // MARK: - Hole map (top-down ground texture)

    static func holeMap(layout: HoleLayout, style: CourseStyle, bounds: HoleBounds, size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        var rng = SeededRNG(seed: UInt64(layout.hole.number) &* 7919 &+ 17)

        return renderer.image { ctx in
            let c = ctx.cgContext
            let sx = size.width / CGFloat(bounds.width)
            let sz = size.height / CGFloat(bounds.height)
            func P(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(x: CGFloat(p.x - bounds.minX) * sx, y: CGFloat(p.y - bounds.minZ) * sz)
            }
            func poly(_ pts: [CGPoint]) {
                guard let first = pts.first else { return }
                c.beginPath()
                c.move(to: first)
                for p in pts.dropFirst() { c.addLine(to: p) }
                c.closePath()
            }

            // 1. Rough base + speckle
            c.setFillColor(style.rough.uiColor.cgColor)
            c.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<70_000 {
                let x = CGFloat.random(in: 0...size.width, using: &rng)
                let y = CGFloat.random(in: 0...size.height, using: &rng)
                let v = Double.random(in: 0.78...1.18, using: &rng)
                let accent = Double.random(in: 0...1, using: &rng) < 0.12
                let col = accent ? style.accent : style.rough.scaled(v)
                c.setFillColor(col.uiColor(alpha: accent ? 0.5 : 0.7).cgColor)
                let w = CGFloat.random(in: 1...3, using: &rng)
                c.fill(CGRect(x: x, y: y, width: w, height: w * 1.6))
            }

            // Corridor helpers
            let total = layout.totalLength
            let phase = Double(layout.hole.number) * 1.3
            func halfWidth(_ base: Double, _ s: Double) -> Double {
                base * (1 + 0.10 * sin(s * 0.045 + phase) + 0.05 * sin(s * 0.13 + phase * 2))
            }
            var samples: [Double] = []
            var s = -6.0
            while s < total + 8 { samples.append(s); s += 4 }
            samples.append(total + 8)

            // 2. First cut of rough
            let cutLeft = samples.map { P(layout.world(s: $0, l: -halfWidth(layout.fairwayHalf + 4.5, $0))) }
            let cutRight = samples.map { P(layout.world(s: $0, l: halfWidth(layout.fairwayHalf + 4.5, $0))) }
            poly(cutLeft + cutRight.reversed())
            c.setFillColor(style.rough.mixed(with: style.fairway, 0.45).uiColor.cgColor)
            c.fillPath()

            // 3. Fairway with mown stripes
            for i in 0..<(samples.count - 1) {
                let s0 = samples[i], s1 = samples[i + 1]
                let a = P(layout.world(s: s0, l: -halfWidth(layout.fairwayHalf, s0)))
                let b = P(layout.world(s: s1, l: -halfWidth(layout.fairwayHalf, s1)))
                let d = P(layout.world(s: s0, l: halfWidth(layout.fairwayHalf, s0)))
                let e = P(layout.world(s: s1, l: halfWidth(layout.fairwayHalf, s1)))
                let col = (i / 2) % 2 == 0 ? style.fairway : style.fairwayAlt
                c.setFillColor(col.uiColor.cgColor)
                c.setStrokeColor(col.uiColor.cgColor)
                c.setLineWidth(1)
                poly([a, b, e, d])
                c.drawPath(using: .fillStroke)
            }

            // 4. Tee box
            let teeC = P(layout.tee)
            let teeRect = CGRect(x: teeC.x - 5 * sx, y: teeC.y - 7 * sz, width: 10 * sx, height: 14 * sz)
            c.setFillColor(style.fairwayAlt.scaled(1.08).uiColor.cgColor)
            c.fill(teeRect)

            // 5. Hazards
            for ph in layout.placed {
                let kind = ph.hazard.kind
                switch kind {
                case .trees, .stoneWall, .rocks, .boulder, .cliff: continue
                default: break
                }
                var ring: [CGPoint] = []
                for k in 0..<56 {
                    let t = Double(k) / 56 * 2 * .pi
                    let wob = 1 + 0.10 * sin(t * 5 + ph.s0) + 0.05 * sin(t * 3 + ph.l0)
                    ring.append(P(layout.world(s: ph.s0 + ph.a * cos(t) * wob, l: ph.l0 + ph.b * sin(t) * wob)))
                }
                switch kind {
                case .water, .creek:
                    poly(ring)
                    c.setFillColor(style.water.scaled(0.8).uiColor.cgColor)
                    c.setStrokeColor(style.rough.scaled(0.7).uiColor.cgColor)
                    c.setLineWidth(3)
                    c.drawPath(using: .fillStroke)
                default:
                    let sandCol = kind == .wasteBunker ? style.sand.mixed(with: style.rough, 0.25) : style.sand
                    poly(ring)
                    c.setFillColor(sandCol.uiColor.cgColor)
                    c.setStrokeColor((kind == .potBunker ? style.fairway.scaled(0.45) : style.sand.scaled(0.78)).uiColor.cgColor)
                    c.setLineWidth(kind == .potBunker ? 5 : 3)
                    c.drawPath(using: .fillStroke)
                    // sand grain
                    c.saveGState()
                    poly(ring)
                    c.clip()
                    let bb = c.boundingBoxOfClipPath
                    for _ in 0..<Int(max(80, bb.width * bb.height / 40)) {
                        let x = CGFloat.random(in: bb.minX...bb.maxX, using: &rng)
                        let y = CGFloat.random(in: bb.minY...bb.maxY, using: &rng)
                        c.setFillColor(sandCol.scaled(Double.random(in: 0.82...1.05, using: &rng)).uiColor(alpha: 0.8).cgColor)
                        c.fill(CGRect(x: x, y: y, width: 1.6, height: 1.6))
                    }
                    c.restoreGState()
                }
            }

            // 6. Green: collar, putting surface with mow rings
            let gC = P(layout.green)
            let rpx = CGFloat(layout.greenRadius) * sx
            let rpz = CGFloat(layout.greenRadius) * sz
            func ellipse(_ scale: CGFloat) -> CGRect {
                CGRect(x: gC.x - rpx * scale, y: gC.y - rpz * scale, width: rpx * 2 * scale, height: rpz * 2 * scale)
            }
            c.setFillColor(style.fairwayAlt.scaled(1.1).uiColor.cgColor)
            c.fillEllipse(in: ellipse(1.0 + 3.0 / CGFloat(layout.greenRadius)))
            c.setFillColor(style.green.uiColor.cgColor)
            c.fillEllipse(in: ellipse(1.0))
            for k in 1...6 {
                let sc = CGFloat(k) / 6
                c.setStrokeColor(UIColor(white: k % 2 == 0 ? 1 : 0, alpha: 0.05).cgColor)
                c.setLineWidth(max(2, rpx * 0.08))
                c.strokeEllipse(in: ellipse(sc))
            }
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [style.green.scaled(1.18).uiColor(alpha: 0.55).cgColor,
                                           style.green.uiColor(alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                c.saveGState()
                c.translateBy(x: gC.x, y: gC.y)
                c.scaleBy(x: rpx, y: rpz)
                c.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
                c.restoreGState()
            }
        }
    }
}

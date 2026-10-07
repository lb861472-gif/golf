import Foundation
import simd

@inline(__always)
func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

struct PathProjection {
    var s: Double      // metres along the centre-line (negative behind the tee)
    var l: Double      // metres right (+) / left (-) of the centre-line
    var dist: Double   // distance to the centre-line
}

struct PlacedHazard {
    let hazard: Hazard
    let s0: Double
    let l0: Double
    let a: Double      // semi-axis along the hole (m)
    let b: Double      // semi-axis across the hole (m)
    let center: SIMD2<Double>

    var depth: Double {
        switch hazard.kind {
        case .water: return 1.3
        case .creek: return 0.9
        case .bunker: return 0.55
        case .potBunker: return 1.5
        case .wasteBunker: return 0.45
        default: return 0
        }
    }
}

struct HoleBounds {
    var minX: Double
    var maxX: Double
    var minZ: Double
    var maxZ: Double
    var width: Double { maxX - minX }
    var height: Double { maxZ - minZ }
}

/// Pure-maths description of one hole. World axes: tee at the origin, play direction -Z,
/// +X to the right, +Y up, 1 unit == 1 metre. The 2D vectors store (x, z) in (x, y).
struct HoleLayout {
    static let yd = 0.9144

    let course: Course
    let hole: Hole
    let tee = SIMD2<Double>(0, 0)
    let dir0 = SIMD2<Double>(0, -1)
    let dir1: SIMD2<Double>
    let bend: SIMD2<Double>
    let green: SIMD2<Double>
    let pin: SIMD2<Double>
    let seg0Len: Double
    let seg1Len: Double
    let totalLength: Double
    let fairwayHalf: Double
    let greenRadius: Double
    let cliffDistance: Double
    let oceanSide: Double
    let seed: Double
    /// Sea level for coastal holes - always safely below the tee, fairway and green.
    let seaY: Double
    private(set) var placed: [PlacedHazard] = []

    init(course: Course, hole: Hole) {
        self.course = course
        self.hole = hole
        let y = Self.yd
        let total = Double(hole.yardage) * y
        let l0 = total * 0.58
        let l1 = total - l0
        let theta = hole.dogleg * 0.5
        let d1 = SIMD2<Double>(sin(theta), -cos(theta))
        let b = SIMD2<Double>(0, -1) * l0
        let g = b + d1 * l1

        totalLength = total
        seg0Len = l0
        seg1Len = l1
        dir1 = d1
        bend = b
        green = g
        pin = g + SIMD2<Double>(hole.pinOffsetX, hole.pinOffsetZ) * y
        fairwayHalf = hole.fairwayWidth * y / 2
        greenRadius = hole.greenRadius * y
        cliffDistance = hole.fairwayWidth * y / 2 + 20
        oceanSide = Double(hole.oceanSide)
        seed = Double(hole.number) * 3.7 + Double(course.id.count) * 1.3
        seaY = min(0, hole.elevationChange * y) - 3.5 - course.theme.undulation * 1.3

        placed = hole.hazards.map { hz in
            let s0 = hz.along * y
            let lat = hz.lateral * y
            return PlacedHazard(hazard: hz, s0: s0, l0: lat,
                                a: max(0.5, hz.halfLength * y), b: max(0.4, hz.halfWidth * y),
                                center: self.world(s: s0, l: lat))
        }
    }

    // MARK: Path maths

    @inline(__always)
    private func rightOf(_ d: SIMD2<Double>) -> SIMD2<Double> { SIMD2<Double>(-d.y, d.x) }

    func world(s: Double, l: Double) -> SIMD2<Double> {
        if s <= seg0Len {
            return tee + dir0 * s + rightOf(dir0) * l
        }
        return bend + dir1 * (s - seg0Len) + rightOf(dir1) * l
    }

    func direction(atS s: Double) -> SIMD2<Double> { s <= seg0Len ? dir0 : dir1 }

    private func closest(_ p: SIMD2<Double>, origin: SIMD2<Double>, dir: SIMD2<Double>,
                         length: Double, base: Double, extendBack: Bool) -> PathProjection {
        let rel = p - origin
        var t = simd_dot(rel, dir)
        t = min(length, t)
        if !extendBack { t = max(0, t) }
        let cp = origin + dir * t
        let diff = p - cp
        return PathProjection(s: base + t, l: simd_dot(diff, rightOf(dir)), dist: simd_length(diff))
    }

    func project(_ p: SIMD2<Double>) -> PathProjection {
        let a = closest(p, origin: tee, dir: dir0, length: seg0Len, base: 0, extendBack: true)
        let b = closest(p, origin: bend, dir: dir1, length: seg1Len, base: seg0Len, extendBack: false)
        return a.dist <= b.dist ? a : b
    }

    func bounds(margin: Double) -> HoleBounds {
        let xs = [tee.x, bend.x, green.x]
        let zs = [tee.y, bend.y, green.y]
        let side = fairwayHalf + margin
        return HoleBounds(minX: (xs.min() ?? 0) - side, maxX: (xs.max() ?? 0) + side,
                          minZ: (zs.min() ?? 0) - margin, maxZ: (zs.max() ?? 0) + margin)
    }

    /// Natural (flat) ground level at a hazard's centre-line position.
    func baseHeight(atS s: Double) -> Double {
        hole.elevationChange * Self.yd * max(0, min(1, s / totalLength))
    }

    /// Height of the water surface for a pond / creek.
    func waterLevel(_ ph: PlacedHazard) -> Double {
        baseHeight(atS: ph.s0) - 0.35 * ph.depth
    }

    // MARK: Terrain classification

    func hazardU(_ ph: PlacedHazard, s: Double, l: Double) -> Double {
        let ds = (s - ph.s0) / ph.a
        let dl = (l - ph.l0) / ph.b
        return ds * ds + dl * dl
    }

    func terrain(at p: SIMD2<Double>) -> TerrainType {
        let dg = simd_length(p - green)
        if dg <= greenRadius { return .green }
        let pr = project(p)

        for ph in placed {
            switch ph.hazard.kind {
            case .cliff, .trees, .stoneWall, .rocks, .boulder:
                continue
            default:
                break
            }
            if hazardU(ph, s: pr.s, l: pr.l) <= 1 {
                switch ph.hazard.kind {
                case .water, .creek: return .water
                case .wasteBunker: return .waste
                default: return .bunker
                }
            }
        }

        if oceanSide != 0 && pr.l * oceanSide > cliffDistance + 10 { return .water }
        if simd_length(p - tee) < 4.5 { return .tee }
        if dg <= greenRadius + 3 { return .fairway }
        if abs(pr.l) <= fairwayHalf && pr.s >= -4 { return .fairway }
        if course.theme == .links && abs(pr.l) > fairwayHalf + 5 { return .fescue }
        return .rough
    }

    // MARK: Height field

    private func hash(_ x: Double, _ y: Double) -> Double {
        let h = sin(x * 127.1 + y * 311.7 + seed * 17.3) * 43758.5453
        return h - floor(h)
    }

    private func valueNoise(_ x: Double, _ y: Double) -> Double {
        let xi = floor(x), yi = floor(y)
        let xf = x - xi, yf = y - yi
        let u = xf * xf * (3 - 2 * xf)
        let v = yf * yf * (3 - 2 * yf)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        let top = a + (b - a) * u
        let bottom = c + (d - c) * u
        return top + (bottom - top) * v
    }

    /// Roughly in [-1, 1]
    private func fbm(_ x: Double, _ y: Double) -> Double {
        var amp = 0.5, f = 1.0, sum = 0.0
        for _ in 0..<3 {
            sum += (valueNoise(x * f, y * f) - 0.5) * 2 * amp
            f *= 2.1
            amp *= 0.5
        }
        return sum * 1.6
    }

    func height(at p: SIMD2<Double>) -> Double {
        let pr = project(p)
        return height(at: p, projection: pr)
    }

    func height(at p: SIMD2<Double>, projection pr: PathProjection) -> Double {
        let sc = max(0, min(1, pr.s / totalLength))
        var h = hole.elevationChange * Self.yd * sc
        let undul = course.theme.undulation
        let n = fbm(p.x * 0.035, p.y * 0.035)
        let outside = smoothstep(fairwayHalf, fairwayHalf + 30, abs(pr.l))
        h += n * undul * (0.35 + 0.65 * outside)

        // Green: flatten the noise, add the slope / tiers
        let rel = p - green
        let dg = simd_length(rel)
        if dg < greenRadius * 1.7 {
            let w = 1 - smoothstep(greenRadius * 0.95, greenRadius * 1.7, dg)
            h -= n * undul * 0.35 * w
            h += (hole.greenSlopeX * rel.x + hole.greenSlopeZ * rel.y) * w
            let tier = (course.theme == .alpine || course.theme == .links) ? 0.35 : 0.12
            h += sin(rel.x * 0.35 + seed) * cos(rel.y * 0.3 + seed * 0.5) * tier * w
        }

        // Hazard depressions
        for ph in placed {
            let depth = ph.depth
            if depth == 0 { continue }
            let u = hazardU(ph, s: pr.s, l: pr.l)
            if ph.hazard.kind == .water || ph.hazard.kind == .creek {
                // Flat banks, a bowl whose rim is exactly the water line (u == 1), blended into the terrain.
                if u < 2.6 {
                    let base = baseHeight(atS: ph.s0)
                    let wl = base - 0.35 * depth
                    let bed: Double
                    if u < 1 {
                        bed = wl - 0.65 * depth * (1 - smoothstep(0.2, 1.0, u))
                    } else {
                        bed = wl + 0.35 * depth * smoothstep(1.0, 1.4, u)
                    }
                    let w = 1 - smoothstep(1.4, 2.6, u)
                    h = h * (1 - w) + bed * w
                }
            } else if u < 1.8 {
                h -= depth * (1 - smoothstep(0.55, 1.8, u))
            }
        }

        // Coastal cliff drop towards the sea
        if oceanSide != 0 {
            let over = pr.l * oceanSide - cliffDistance
            if over > 0 {
                let k = smoothstep(0, 14, over)
                h = h + (seaY - 3 - h) * k
            }
        }
        return h
    }

    func gradient(at p: SIMD2<Double>, eps: Double = 0.6) -> SIMD2<Double> {
        let hx1 = height(at: SIMD2<Double>(p.x + eps, p.y))
        let hx0 = height(at: SIMD2<Double>(p.x - eps, p.y))
        let hz1 = height(at: SIMD2<Double>(p.x, p.y + eps))
        let hz0 = height(at: SIMD2<Double>(p.x, p.y - eps))
        return SIMD2<Double>((hx1 - hx0) / (2 * eps), (hz1 - hz0) / (2 * eps))
    }

    func normal(at p: SIMD2<Double>) -> SIMD3<Double> {
        let g = gradient(at: p)
        return simd_normalize(SIMD3<Double>(-g.x, 1, -g.y))
    }

    /// Y rotation (radians) that aligns a node's local -Z with the given 2D direction.
    static func yaw(for dir: SIMD2<Double>) -> Double { atan2(-dir.x, -dir.y) }

    func inBounds(_ p: SIMD2<Double>) -> Bool {
        let b = bounds(margin: 120)
        return p.x > b.minX && p.x < b.maxX && p.y > b.minZ && p.y < b.maxZ
    }
}

import Foundation
import SwiftUI
import UIKit

// MARK: - Colour helper (Codable, usable from SwiftUI / UIKit / SceneKit)

struct RGB: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    var color: Color { Color(red: r, green: g, blue: b) }
    var uiColor: UIColor { UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }

    func uiColor(alpha: Double) -> UIColor {
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(alpha))
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    func scaled(_ k: Double) -> RGB {
        RGB(min(1, max(0, r * k)), min(1, max(0, g * k)), min(1, max(0, b * k)))
    }
}

// MARK: - Deterministic RNG so every launch builds the same 90 holes

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Enumerations

enum CourseTheme: String, Codable, CaseIterable, Hashable {
    case coastal, forest, desert, alpine, links

    /// Amplitude (metres) of the rolling noise used by the terrain generator.
    var undulation: Double {
        switch self {
        case .coastal: return 1.1
        case .forest: return 1.8
        case .desert: return 1.5
        case .alpine: return 3.2
        case .links: return 2.4
        }
    }
}

enum TerrainType: String, Codable, CaseIterable, Hashable {
    case tee, fairway, rough, fescue, green, bunker, waste, water

    var displayName: String {
        switch self {
        case .tee: return "Tee Box"
        case .fairway: return "Fairway"
        case .rough: return "Rough"
        case .fescue: return "Deep Fescue"
        case .green: return "Green"
        case .bunker: return "Bunker"
        case .waste: return "Waste Area"
        case .water: return "Water"
        }
    }

    /// Rolling resistance coefficient (multiplied by g to get deceleration).
    var rollingResistance: Double {
        switch self {
        case .tee: return 0.14
        case .fairway: return 0.13
        case .rough: return 0.40
        case .fescue: return 0.55
        case .green: return 0.055
        case .bunker: return 1.2
        case .waste: return 0.8
        case .water: return 5.0
        }
    }

    /// Fraction of vertical speed kept on a bounce.
    var restitution: Double {
        switch self {
        case .tee: return 0.38
        case .fairway: return 0.42
        case .rough: return 0.18
        case .fescue: return 0.12
        case .green: return 0.32
        case .bunker: return 0.02
        case .waste: return 0.08
        case .water: return 0.0
        }
    }

    /// Fraction of horizontal speed kept on a bounce.
    var tangentialRetention: Double {
        switch self {
        case .tee: return 0.70
        case .fairway: return 0.72
        case .rough: return 0.45
        case .fescue: return 0.35
        case .green: return 0.62
        case .bunker: return 0.05
        case .waste: return 0.20
        case .water: return 0.0
        }
    }
}

enum WeatherCondition: String, Codable, CaseIterable, Identifiable, Hashable {
    case clear, overcast, windy, rain, fog

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .overcast: return "Overcast"
        case .windy: return "Windy"
        case .rain: return "Rain"
        case .fog: return "Fog"
        }
    }

    var symbol: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .overcast: return "cloud.fill"
        case .windy: return "wind"
        case .rain: return "cloud.rain.fill"
        case .fog: return "cloud.fog.fill"
        }
    }

    var windMultiplier: Double {
        switch self {
        case .clear: return 1.0
        case .overcast: return 1.0
        case .windy: return 1.9
        case .rain: return 1.2
        case .fog: return 0.5
        }
    }

    /// Damp turf rolls less.
    var rollMultiplier: Double {
        switch self {
        case .clear: return 1.0
        case .overcast: return 1.0
        case .windy: return 1.0
        case .rain: return 1.25
        case .fog: return 1.1
        }
    }

    var lightMultiplier: Double {
        switch self {
        case .clear: return 1.0
        case .overcast: return 0.65
        case .windy: return 0.9
        case .rain: return 0.5
        case .fog: return 0.55
        }
    }

    var fogMultiplier: Double {
        switch self {
        case .clear: return 1.0
        case .overcast: return 0.8
        case .windy: return 1.0
        case .rain: return 0.55
        case .fog: return 0.22
        }
    }

    /// 0 = untouched sky colours, 1 = fully grey.
    var skyGray: Double {
        switch self {
        case .clear: return 0.0
        case .overcast: return 0.55
        case .windy: return 0.15
        case .rain: return 0.75
        case .fog: return 0.8
        }
    }
}

enum HazardKind: String, Codable, CaseIterable, Hashable {
    case water, creek, bunker, potBunker, wasteBunker, trees, rocks, boulder, cliff, stoneWall

    var displayName: String {
        switch self {
        case .water: return "Water"
        case .creek: return "Creek"
        case .bunker: return "Bunker"
        case .potBunker: return "Pot Bunker"
        case .wasteBunker: return "Waste Bunker"
        case .trees: return "Trees"
        case .rocks: return "Rock Outcrop"
        case .boulder: return "Boulder"
        case .cliff: return "Cliff"
        case .stoneWall: return "Stone Wall"
        }
    }

    var severity: Double {
        switch self {
        case .water: return 1.4
        case .creek: return 0.9
        case .bunker: return 0.4
        case .potBunker: return 0.7
        case .wasteBunker: return 0.35
        case .trees: return 0.5
        case .rocks: return 0.6
        case .boulder: return 0.5
        case .cliff: return 1.2
        case .stoneWall: return 0.6
        }
    }
}

// MARK: - Hazard / Hole

struct Hazard: Codable, Hashable, Identifiable {
    var kind: HazardKind
    /// Yards from the tee measured along the hole centre-line.
    var along: Double
    /// Yards left (negative) / right (positive) of the centre-line.
    var lateral: Double
    /// Semi-axis along the hole direction, yards.
    var halfLength: Double
    /// Semi-axis across the hole direction, yards.
    var halfWidth: Double

    var id: String { "\(kind.rawValue)-\(Int(along))-\(Int(lateral))" }
}

struct Hole: Codable, Hashable, Identifiable {
    var id: Int { number }
    let number: Int
    let name: String
    let par: Int
    let yardage: Int
    /// -1 (sharp left) ... +1 (sharp right). 0 = straight.
    let dogleg: Double
    /// Net elevation change tee -> green, yards (+ is uphill).
    let elevationChange: Double
    let fairwayWidth: Double
    let greenRadius: Double
    let greenSlopeX: Double
    let greenSlopeZ: Double
    let pinOffsetX: Double
    let pinOffsetZ: Double
    /// -1 ocean on the left, +1 ocean on the right, 0 none.
    let oceanSide: Int
    let hazards: [Hazard]

    var hazardLoad: Double { hazards.reduce(0) { $0 + $1.kind.severity } }
}

struct CourseStyle: Hashable {
    var skyTop: RGB
    var skyHorizon: RGB
    var fogColor: RGB
    var fogStart: Double
    var fogEnd: Double
    var sunElevation: Double      // degrees above horizon
    var sunAzimuth: Double        // degrees clockwise from north (-Z)
    var sunColor: RGB
    var sunIntensity: Double      // 1.0 == 1000 lumens
    var ambientIntensity: Double
    var fairway: RGB
    var fairwayAlt: RGB
    var rough: RGB
    var accent: RGB               // heather / wildflower speckle in the rough
    var sand: RGB
    var water: RGB
    var green: RGB
}

// MARK: - Course

struct Course: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let theme: CourseTheme
    let blurb: String
    let tags: [String]
    let baseWindMPH: Double
    let defaultWeather: WeatherCondition
    let style: CourseStyle
    let holes: [Hole]

    var par: Int { holes.reduce(0) { $0 + $1.par } }
    var totalYardage: Int { holes.reduce(0) { $0 + $1.yardage } }
    var frontPar: Int { holes.prefix(9).reduce(0) { $0 + $1.par } }
    var backPar: Int { holes.suffix(9).reduce(0) { $0 + $1.par } }

    /// 1...5 rating based on hazard severity across all 18 holes.
    var hazardRating: Double {
        let load = holes.reduce(0.0) { $0 + $1.hazardLoad } / 18.0
        return min(5, max(1, load / 1.6))
    }

    static func == (lhs: Course, rhs: Course) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func byID(_ id: String) -> Course? { all.first { $0.id == id } }
}

// MARK: - Factory

extension Course {

    static let all: [Course] = [pebbleGreens, oceanPines, desertLinks, alpineCrest, standrewsBay]

    // Par 72
    static let pebbleGreens = Course(
        id: "pebble-greens",
        name: "Pebble Greens",
        subtitle: "Coastal Links",
        theme: .coastal,
        blurb: "Crisp coastal sunlight, white sand and cliffside drops with doglegs over ocean inlets.",
        tags: ["Ocean mist", "Cliffs", "Sea breeze"],
        baseWindMPH: 9,
        defaultWeather: .clear,
        style: CourseStyle(
            skyTop: RGB(0.18, 0.44, 0.86), skyHorizon: RGB(0.74, 0.87, 0.97),
            fogColor: RGB(0.74, 0.87, 0.97), fogStart: 380, fogEnd: 1100,
            sunElevation: 52, sunAzimuth: 140, sunColor: RGB(1.0, 0.97, 0.90),
            sunIntensity: 1.5, ambientIntensity: 0.45,
            fairway: RGB(0.30, 0.62, 0.22), fairwayAlt: RGB(0.37, 0.69, 0.27),
            rough: RGB(0.22, 0.46, 0.16), accent: RGB(0.85, 0.80, 0.45),
            sand: RGB(0.96, 0.94, 0.84), water: RGB(0.04, 0.30, 0.52),
            green: RGB(0.20, 0.66, 0.30)),
        holes: buildHoles(theme: .coastal,
                          pars: [4, 5, 3, 4, 4, 3, 5, 4, 4,  4, 3, 5, 4, 4, 3, 4, 5, 4],
                          seed: 1101))

    // Par 72
    static let oceanPines = Course(
        id: "ocean-pines",
        name: "Ocean Pines",
        subtitle: "Pacific Northwest Forest",
        theme: .forest,
        blurb: "Moody overcast forest, dense pines, creeks across the fairways and fog between the trees.",
        tags: ["Fog banks", "Wet turf", "Swaying pines"],
        baseWindMPH: 4,
        defaultWeather: .overcast,
        style: CourseStyle(
            skyTop: RGB(0.42, 0.49, 0.55), skyHorizon: RGB(0.70, 0.74, 0.76),
            fogColor: RGB(0.62, 0.68, 0.68), fogStart: 60, fogEnd: 420,
            sunElevation: 35, sunAzimuth: 200, sunColor: RGB(0.88, 0.92, 0.95),
            sunIntensity: 0.9, ambientIntensity: 0.65,
            fairway: RGB(0.13, 0.35, 0.14), fairwayAlt: RGB(0.17, 0.41, 0.17),
            rough: RGB(0.26, 0.27, 0.13), accent: RGB(0.35, 0.22, 0.12),
            sand: RGB(0.78, 0.72, 0.58), water: RGB(0.07, 0.20, 0.22),
            green: RGB(0.14, 0.45, 0.20)),
        holes: buildHoles(theme: .forest,
                          pars: [4, 4, 3, 5, 4, 4, 3, 4, 5,  5, 4, 3, 4, 4, 5, 3, 4, 4],
                          seed: 2202))

    // Par 71
    static let desertLinks = Course(
        id: "desert-links",
        name: "Desert Links",
        subtitle: "Canyon Sunset",
        theme: .desert,
        blurb: "Golden-hour light, red rock canyon walls, sprawling waste bunkers and long shadows.",
        tags: ["Heat shimmer", "Dust", "Long shadows"],
        baseWindMPH: 6,
        defaultWeather: .clear,
        style: CourseStyle(
            skyTop: RGB(0.22, 0.18, 0.46), skyHorizon: RGB(1.0, 0.62, 0.32),
            fogColor: RGB(0.95, 0.64, 0.42), fogStart: 300, fogEnd: 1000,
            sunElevation: 9, sunAzimuth: 250, sunColor: RGB(1.0, 0.62, 0.30),
            sunIntensity: 1.6, ambientIntensity: 0.35,
            fairway: RGB(0.50, 0.60, 0.25), fairwayAlt: RGB(0.57, 0.66, 0.30),
            rough: RGB(0.76, 0.64, 0.40), accent: RGB(0.62, 0.40, 0.22),
            sand: RGB(0.93, 0.78, 0.45), water: RGB(0.10, 0.35, 0.40),
            green: RGB(0.30, 0.66, 0.30)),
        holes: buildHoles(theme: .desert,
                          pars: [4, 3, 5, 4, 4, 3, 4, 5, 4,  4, 5, 3, 4, 4, 3, 4, 4, 4],
                          seed: 3303))

    // Par 72
    static let alpineCrest = Course(
        id: "alpine-crest",
        name: "Alpine Crest",
        subtitle: "Mountain Peaks",
        theme: .alpine,
        blurb: "High-altitude sun, snow-capped peaks, boulders and crisp lakes with severe elevation change.",
        tags: ["Swirling mist", "Big elevation", "Tiered greens"],
        baseWindMPH: 8,
        defaultWeather: .clear,
        style: CourseStyle(
            skyTop: RGB(0.10, 0.36, 0.80), skyHorizon: RGB(0.76, 0.89, 1.0),
            fogColor: RGB(0.80, 0.90, 1.0), fogStart: 280, fogEnd: 1300,
            sunElevation: 58, sunAzimuth: 120, sunColor: RGB(1.0, 0.98, 0.94),
            sunIntensity: 1.6, ambientIntensity: 0.5,
            fairway: RGB(0.24, 0.55, 0.25), fairwayAlt: RGB(0.30, 0.61, 0.30),
            rough: RGB(0.30, 0.42, 0.22), accent: RGB(0.70, 0.60, 0.80),
            sand: RGB(0.86, 0.85, 0.80), water: RGB(0.05, 0.35, 0.56),
            green: RGB(0.22, 0.62, 0.32)),
        holes: buildHoles(theme: .alpine,
                          pars: [4, 3, 4, 5, 4, 3, 5, 4, 4,  5, 4, 3, 4, 4, 3, 5, 4, 4],
                          seed: 4404))

    // Par 73
    static let standrewsBay = Course(
        id: "st-andrews-bay",
        name: "St. Andrews Bay",
        subtitle: "Scottish Highlands",
        theme: .links,
        blurb: "Rolling heather hills, deep pot bunkers, golden fescue, stone walls and heavy wind.",
        tags: ["Heavy wind", "Damp turf", "Pot bunkers"],
        baseWindMPH: 15,
        defaultWeather: .overcast,
        style: CourseStyle(
            skyTop: RGB(0.52, 0.55, 0.60), skyHorizon: RGB(0.76, 0.78, 0.80),
            fogColor: RGB(0.72, 0.74, 0.76), fogStart: 90, fogEnd: 520,
            sunElevation: 25, sunAzimuth: 300, sunColor: RGB(0.92, 0.92, 0.90),
            sunIntensity: 0.85, ambientIntensity: 0.6,
            fairway: RGB(0.40, 0.55, 0.25), fairwayAlt: RGB(0.45, 0.60, 0.30),
            rough: RGB(0.62, 0.52, 0.30), accent: RGB(0.47, 0.28, 0.48),
            sand: RGB(0.80, 0.74, 0.60), water: RGB(0.12, 0.24, 0.30),
            green: RGB(0.30, 0.58, 0.28)),
        holes: buildHoles(theme: .links,
                          pars: [4, 4, 5, 4, 3, 4, 4, 3, 5,  5, 4, 3, 4, 5, 4, 3, 4, 5],
                          seed: 5505))
}

// MARK: - Hole generators

extension Course {

    private static func holeNames(for theme: CourseTheme) -> ([String], [String]) {
        switch theme {
        case .coastal:
            return (["Gull", "Tide", "Kelp", "Breaker", "Cove", "Sandpiper"],
                    ["Point", "Run", "Drop", "Bend", "Reach", "Inlet"])
        case .forest:
            return (["Cedar", "Fern", "Hemlock", "Mossy", "Creekside", "Spruce"],
                    ["Hollow", "Passage", "Glen", "Ridge", "Crossing", "Clearing"])
        case .desert:
            return (["Mesa", "Cactus", "Sundown", "Red Rock", "Mirage", "Coyote"],
                    ["Wash", "Canyon", "Flats", "Arroyo", "Butte", "Trail"])
        case .alpine:
            return (["Summit", "Glacier", "Edelweiss", "Crag", "Timberline", "Aspen"],
                    ["Pass", "Descent", "Switchback", "Tarn", "Saddle", "Ledge"])
        case .links:
            return (["Heather", "Fescue", "Auld", "Gorse", "Thistle", "Burn"],
                    ["Dyke", "Ridge", "Hollow", "Road", "Knoll", "Furrow"])
        }
    }

    static func buildHoles(theme: CourseTheme, pars: [Int], seed: UInt64) -> [Hole] {
        var rng = SeededRNG(seed: seed)
        var holes: [Hole] = []
        let (adjectives, nouns) = holeNames(for: theme)

        for (index, par) in pars.enumerated() {
            let number = index + 1

            func r(_ lo: Double, _ hi: Double) -> Double {
                Double.random(in: lo...hi, using: &rng)
            }

            // Yardage
            var yardage: Double
            switch par {
            case 3: yardage = r(140, 225)
            case 4: yardage = r(345, 465)
            default: yardage = r(505, 590)
            }
            if theme == .alpine { yardage *= 0.96 }
            if theme == .desert { yardage *= 1.03 }

            // Dogleg
            let side: Double = r(0, 1) < 0.5 ? -1 : 1
            var dogleg = 0.0
            if par > 3 {
                dogleg = r(0, 1) < 0.55 ? side * r(0.25, 0.75) : side * r(0, 0.15)
                if theme == .forest { dogleg *= 0.75 }
            }

            // Elevation
            var elevation: Double
            switch theme {
            case .coastal: elevation = side * r(0, 6)
            case .forest: elevation = side * r(0, 8)
            case .desert: elevation = side * r(0, 10)
            case .alpine: elevation = (r(0, 1) < 0.5 ? -1.0 : 1.0) * r(12, 38)
            case .links: elevation = side * r(0, 5)
            }

            // Fairway width
            var fairway: Double
            switch theme {
            case .coastal: fairway = r(34, 42)
            case .forest: fairway = r(26, 32)
            case .desert: fairway = r(44, 56)
            case .alpine: fairway = r(30, 38)
            case .links: fairway = r(36, 46)
            }
            if par == 3 { fairway *= 0.8 }

            // Green
            var greenRadius = par == 3 ? r(10.5, 14) : r(12, 17)
            if theme == .links { greenRadius *= 1.3 }

            let slopeMag: Double
            switch theme {
            case .coastal, .forest: slopeMag = 0.05
            case .desert: slopeMag = 0.06
            case .alpine: slopeMag = 0.10
            case .links: slopeMag = 0.11
            }

            let pinX = r(-0.45, 0.45) * greenRadius
            let pinZ = r(-0.45, 0.45) * greenRadius

            // Ocean side for the coastal course (4 inland holes for variety)
            var ocean = 0
            if theme == .coastal && index % 5 != 4 {
                ocean = index % 2 == 0 ? -1 : 1
            }

            let hazards = makeHazards(theme: theme, par: par, yardage: yardage, fairway: fairway,
                                      greenRadius: greenRadius, oceanSide: ocean, rng: &rng)

            let name = "\(adjectives[index % adjectives.count]) \(nouns[(index * 2 + 1) % nouns.count])"

            holes.append(Hole(
                number: number,
                name: name,
                par: par,
                yardage: Int(yardage.rounded()),
                dogleg: dogleg,
                elevationChange: elevation,
                fairwayWidth: fairway,
                greenRadius: greenRadius,
                greenSlopeX: r(-1, 1) * slopeMag,
                greenSlopeZ: r(-1, 1) * slopeMag,
                pinOffsetX: pinX,
                pinOffsetZ: pinZ,
                oceanSide: ocean,
                hazards: hazards))
        }
        return holes
    }

    private static func makeHazards(theme: CourseTheme, par: Int, yardage: Double, fairway: Double,
                                    greenRadius: Double, oceanSide: Int, rng: inout SeededRNG) -> [Hazard] {
        var out: [Hazard] = []

        func r(_ lo: Double, _ hi: Double) -> Double {
            Double.random(in: lo...hi, using: &rng)
        }

        let pot = theme == .links
        let bunkerKind: HazardKind = pot ? .potBunker : .bunker
        let fwHalf = fairway / 2

        // Greenside bunkers
        let nGreen = Int(r(2, 3.99))
        let startSide: Double = r(0, 1) < 0.5 ? -1 : 1
        for i in 0..<nGreen {
            let side = i % 2 == 0 ? startSide : -startSide
            out.append(Hazard(kind: bunkerKind,
                              along: yardage - r(-3, 9),
                              lateral: side * (greenRadius + r(1.5, 5)),
                              halfLength: pot ? r(2.5, 3.8) : r(3.5, 6),
                              halfWidth: pot ? r(2.5, 3.5) : r(3, 5)))
        }

        // Fairway bunkers
        if par >= 4 {
            let nFair = r(0, 1) < 0.6 ? 2 : 1
            for i in 0..<nFair {
                let side: Double = i == 0 ? (r(0, 1) < 0.5 ? -1 : 1) : (r(0, 1) < 0.5 ? -1 : 1)
                let kind: HazardKind = theme == .desert ? .wasteBunker : bunkerKind
                out.append(Hazard(kind: kind,
                                  along: yardage * r(0.55, 0.78),
                                  lateral: side * (fwHalf + r(-1, 5)),
                                  halfLength: pot ? r(3, 4.5) : r(6, 10),
                                  halfWidth: pot ? r(2.5, 3.5) : r(3, 5)))
            }
        }

        // Theme specific hazards
        switch theme {
        case .coastal:
            if oceanSide != 0 {
                out.append(Hazard(kind: .cliff, along: yardage * 0.5,
                                  lateral: Double(oceanSide) * (fwHalf + 22),
                                  halfLength: yardage * 0.5, halfWidth: 3))
            }
            if r(0, 1) < 0.55 {
                let side: Double = oceanSide != 0 ? Double(oceanSide) * -1 : (r(0, 1) < 0.5 ? -1 : 1)
                out.append(Hazard(kind: .water, along: yardage * r(0.45, 0.8),
                                  lateral: side * (fwHalf + r(10, 16)),
                                  halfLength: r(18, 26), halfWidth: r(10, 14)))
            }
        case .forest:
            if r(0, 1) < 0.45 {
                out.append(Hazard(kind: .creek, along: yardage * r(0.4, 0.72), lateral: 0,
                                  halfLength: r(2.2, 3.2), halfWidth: fwHalf + 14))
            }
            for _ in 0..<2 {
                let side: Double = r(0, 1) < 0.5 ? -1 : 1
                out.append(Hazard(kind: .trees, along: yardage * r(0.2, 0.7),
                                  lateral: side * (fwHalf + 4),
                                  halfLength: 18, halfWidth: 5))
            }
        case .desert:
            if r(0, 1) < 0.7 {
                let side: Double = r(0, 1) < 0.5 ? -1 : 1
                out.append(Hazard(kind: .rocks, along: yardage * r(0.3, 0.8),
                                  lateral: side * (fwHalf + r(6, 16)),
                                  halfLength: 6, halfWidth: 5))
            }
            let side: Double = r(0, 1) < 0.5 ? -1 : 1
            out.append(Hazard(kind: .wasteBunker, along: yardage * r(0.35, 0.7),
                              lateral: side * (fwHalf + r(-2, 6)),
                              halfLength: 20, halfWidth: 8))
        case .alpine:
            if r(0, 1) < 0.4 {
                let side: Double = r(0, 1) < 0.5 ? -1 : 1
                out.append(Hazard(kind: .water, along: yardage * r(0.4, 0.8),
                                  lateral: side * (fwHalf + r(8, 14)),
                                  halfLength: 20, halfWidth: 12))
            }
            let nBoulders = Int(r(1, 2.99))
            for _ in 0..<nBoulders {
                let side: Double = r(0, 1) < 0.5 ? -1 : 1
                out.append(Hazard(kind: .boulder, along: yardage * r(0.25, 0.85),
                                  lateral: side * (fwHalf + r(3, 8)),
                                  halfLength: 2.5, halfWidth: 2.5))
            }
        case .links:
            if r(0, 1) < 0.4 {
                let side: Double = r(0, 1) < 0.5 ? -1 : 1
                out.append(Hazard(kind: .stoneWall, along: yardage * r(0.2, 0.75),
                                  lateral: side * (fwHalf + r(10, 18)),
                                  halfLength: 16, halfWidth: 0.7))
            }
            let nPots = Int(r(1, 2.99))
            for _ in 0..<nPots {
                let side: Double = r(0, 1) < 0.5 ? -1 : 1
                out.append(Hazard(kind: .potBunker, along: yardage * r(0.35, 0.7),
                                  lateral: side * (fwHalf - r(0, 6)),
                                  halfLength: r(2.5, 3.5), halfWidth: r(2.5, 3.5)))
            }
        }
        return out
    }
}

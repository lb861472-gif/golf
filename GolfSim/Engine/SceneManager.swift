import SceneKit
import UIKit
import simd
import QuartzCore

enum CameraState { case address, flight, overview, celebrate }
enum BallPhase { case rest, flight, rolling, holed }

struct ShotResult {
    var carryYards: Double
    var totalYards: Double
    var landingTerrain: TerrainType
    var finalTerrain: TerrainType
    var holed: Bool
    var penalty: String?
    var distanceToPinYards: Double
    var finalPosition: SIMD2<Double>
}

/// Something the ball can bounce off (tree, rock, wall).
private struct Collider {
    var x: Double
    var z: Double
    var baseY: Double
    var top: Double
    var radius: Double
    var tree: Bool
    var k: Double

    /// Trees are a thin trunk with a cone of branches above it, so the ball clips the branches realistically.
    func radius(atY y: Double) -> Double {
        if !tree { return radius }
        let hn = (y - baseY) / k
        if hn < 0 || hn > 9.2 { return 0 }
        if hn < 1.8 { return 0.34 * k }
        let f = max(0, 1 - (hn - 1.8) / 7.4)
        return max(0.25 * k, 2.6 * k * pow(f, 0.9))
    }
}

private final class DisplayLinkProxy {
    weak var target: SceneManager?
    init(_ t: SceneManager) { target = t }
    @objc func tick(_ link: CADisplayLink) { target?.tick(link) }
}

// MARK: - Noise helpers for the distant landscape

private func hash2d(_ x: Double, _ y: Double, _ s: Double) -> Double {
    let h = sin(x * 127.1 + y * 311.7 + s * 17.3) * 43758.5453
    return h - floor(h)
}

private func vnoise(_ x: Double, _ y: Double, _ s: Double) -> Double {
    let xi = floor(x), yi = floor(y)
    let xf = x - xi, yf = y - yi
    let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
    let a = hash2d(xi, yi, s), b = hash2d(xi + 1, yi, s), c = hash2d(xi, yi + 1, s), d = hash2d(xi + 1, yi + 1, s)
    let top = a + (b - a) * u
    let bottom = c + (d - c) * u
    return top + (bottom - top) * v
}

private func fbm2(_ x: Double, _ y: Double, _ s: Double, _ octaves: Int) -> Double {
    var sum = 0.0, amp = 0.5, f = 1.0, norm = 0.0
    for _ in 0..<octaves {
        sum += vnoise(x * f, y * f, s) * amp
        norm += amp
        f *= 2.03
        amp *= 0.5
    }
    return sum / norm
}

private func ridged2(_ x: Double, _ y: Double, _ s: Double, _ octaves: Int) -> Double {
    var sum = 0.0, amp = 0.5, f = 1.0, w = 1.0, norm = 0.0
    for _ in 0..<octaves {
        var n = 1 - abs(2 * vnoise(x * f, y * f, s) - 1)
        n *= n
        sum += n * amp * w
        norm += amp
        w = min(1, n * 2)
        f *= 2.05
        amp *= 0.5
    }
    return min(1, max(0, sum / norm * 1.15))
}

// MARK: - Mesh builder (many small blades in a single draw call)

private struct MeshBuilder {
    var v: [SCNVector3] = []
    var n: [SCNVector3] = []
    var uv: [CGPoint] = []
    var idx: [UInt32] = []

    mutating func blade(base: SIMD3<Float>, dirX: Float, dirZ: Float, width: Float, height: Float, lean: Float, u: CGFloat) {
        let px = -dirZ * width / 2, pz = dirX * width / 2
        let i = UInt32(v.count)
        v.append(SCNVector3(base.x - px, base.y, base.z - pz))
        v.append(SCNVector3(base.x + px, base.y, base.z + pz))
        v.append(SCNVector3(base.x + dirX * lean, base.y + height, base.z + dirZ * lean))
        for _ in 0..<3 { n.append(SCNVector3(0, 1, 0)) }
        uv.append(CGPoint(x: u, y: 0))
        uv.append(CGPoint(x: u, y: 0))
        uv.append(CGPoint(x: u, y: 1))
        idx.append(contentsOf: [i, i + 1, i + 2])
    }

    func geometry() -> SCNGeometry? {
        guard !v.isEmpty else { return nil }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: v),
                                     SCNGeometrySource(normals: n),
                                     SCNGeometrySource(textureCoordinates: uv)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }
}

/// Procedural SceneKit golf engine: terrain mesh, PBR materials, animated water, mountains, ground cover,
/// particles, multi-state camera, ball flight / roll physics with tree bounces and audio triggers.
final class SceneManager: NSObject {

    /// Flip to true if the ground texture appears mirrored front-to-back on device.
    static let flipTextureV = false
    static let ballVisualRadius: Float = 0.055

    let scene = SCNScene()
    let cameraNode = SCNNode()
    let audio = GameAudio()

    var onShotFinished: ((ShotResult) -> Void)?
    var onOverviewFinished: (() -> Void)?

    private(set) var course: Course
    private(set) var layout: HoleLayout!
    private(set) var weather: WeatherCondition
    private(set) var phase: BallPhase = .rest
    private(set) var cameraState: CameraState = .address
    private(set) var windSpeedMPH = 0.0
    private(set) var windToHeadingDegrees = 0.0
    private(set) var aimHeadingDegrees = 0.0
    var putting = false {
        didSet { if phase == .rest { refreshAim() } }
    }
    /// Putting assist: on the green the putt is auto-aimed at the cup and can never roll off the green.
    var puttAssist = true
    var aimOffsetDegrees = 0.0 {
        didSet { if phase == .rest { refreshAim() } }
    }

    // Nodes
    private let worldNode = SCNNode()
    private let ballNode = SCNNode()
    private let lookTarget = SCNNode()
    private let followNode = SCNNode()
    private let sunNode = SCNNode()
    private let ambientNode = SCNNode()
    private let sunGlowNode = SCNNode()
    private let trailNode = SCNNode()
    private var flagPivot: SCNNode?
    private var sunDirection = SIMD3<Float>(0, 1, 0)
    private var glowDistance: Float = 300

    // Materials
    private var pondMaterial = SCNMaterial()
    private var oceanMaterial = SCNMaterial()

    // Ball state
    private var pos = SIMD3<Double>(0, 0, 0)
    private var vel = SIMD3<Double>(0, 0, 0)
    private var shotOrigin = SIMD3<Double>(0, 0, 0)
    private var firstLanding: SIMD3<Double>?
    private var landingTerrain: TerrainType = .fairway
    private var spinRPM = 0.0
    private var sideSpinRPM = 0.0
    private var flightTime = 0.0
    private var rollTime = 0.0
    private var windVector = SIMD3<Double>(0, 0, 0)
    private var assistedPutt = false
    private var ballOnGreen = false
    private var arrowNodes: [SCNNode] = []
    private var lastCollisionSound = 0.0
    private var lastLie = SIMD3<Double>(0, 0, 0)
    private var colliders: [Collider] = []
    private var farY = -3.0

    // Camera state
    private var aimDir = SIMD3<Double>(0, 0, -1)
    private var chaseDir = SIMD3<Double>(0, 0, -1)
    private var camPos = SIMD3<Double>(0, 3, 6)
    private var lookPos = SIMD3<Double>(0, 0, -30)
    private var overviewT = 0.0
    private var celebrateT = 0.0
    private let overviewDuration = 9.0
    private var snapCamera = true

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var startTimestamp: CFTimeInterval = 0

    // MARK: - Init

    init(course: Course, weather: WeatherCondition) {
        self.course = course
        self.weather = weather
        super.init()
        buildStaticScene()
    }

    deinit { link?.invalidate() }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
        startTimestamp = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
        audio.stopAll()
    }

    // MARK: - Static scene

    private func buildStaticScene() {
        let cam = SCNCamera()
        cam.fieldOfView = 62
        cam.zNear = 0.25
        cam.zFar = 6000
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)

        let constraint = SCNLookAtConstraint(target: lookTarget)
        constraint.isGimbalLockEnabled = true
        cameraNode.constraints = [constraint]
        scene.rootNode.addChildNode(lookTarget)

        let sun = SCNLight()
        sun.type = .directional
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowSampleCount = 8
        sun.shadowRadius = 3
        sun.shadowMode = .deferred
        sun.automaticallyAdjustsShadowProjection = true
        sun.maximumShadowDistance = 160
        sun.shadowCascadeCount = 3
        sun.shadowCascadeSplittingFactor = 0.2
        sunNode.light = sun
        scene.rootNode.addChildNode(sunNode)

        let amb = SCNLight()
        amb.type = .ambient
        ambientNode.light = amb
        scene.rootNode.addChildNode(ambientNode)

        scene.rootNode.addChildNode(worldNode)
        scene.rootNode.addChildNode(followNode)

        buildBall()
        scene.rootNode.addChildNode(ballNode)

        let glow = SCNPlane(width: 1, height: 1)
        let gm = SCNMaterial()
        gm.lightingModel = .constant
        gm.diffuse.contents = ProceduralTextures.sunGlow(color: RGB(1, 0.9, 0.7))
        gm.blendMode = .add
        gm.writesToDepthBuffer = false
        gm.isDoubleSided = true
        glow.materials = [gm]
        sunGlowNode.geometry = glow
        sunGlowNode.constraints = [SCNBillboardConstraint()]
        sunGlowNode.castsShadow = false
        scene.rootNode.addChildNode(sunGlowNode)

        pondMaterial = makeWaterMaterial(ocean: false)
        oceanMaterial = makeWaterMaterial(ocean: true)
        buildArrows()
    }

    // MARK: - Putting guide arrows

    private func buildArrows() {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0.38))
        path.addLine(to: CGPoint(x: 0.4, y: -0.04))
        path.addLine(to: CGPoint(x: 0.4, y: -0.26))
        path.addLine(to: CGPoint(x: 0, y: 0.1))
        path.addLine(to: CGPoint(x: -0.4, y: -0.26))
        path.addLine(to: CGPoint(x: -0.4, y: -0.04))
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0.004)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(red: 1, green: 0.93, blue: 0.45, alpha: 1)
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        shape.materials = [m]
        for _ in 0..<8 {
            let holder = SCNNode()
            let flat = SCNNode(geometry: shape)
            flat.eulerAngles.x = -.pi / 2
            flat.scale = SCNVector3(0.5, 0.5, 0.5)
            flat.castsShadow = false
            flat.renderingOrder = 200
            holder.addChildNode(flat)
            holder.isHidden = true
            scene.rootNode.addChildNode(holder)
            arrowNodes.append(holder)
        }
    }

    /// Chevrons flowing from the ball towards the cup while you line up a putt on the green.
    private func updateArrows(now: Double) {
        guard layout != nil else { return }
        let show = puttAssist && putting && ballOnGreen && phase == .rest && cameraState == .address
        let dist = simd_length(layout.pin - ballPosition2D)
        if !show || dist < 0.9 {
            for n in arrowNodes where !n.isHidden { n.isHidden = true }
            return
        }
        let count = min(arrowNodes.count, max(2, Int(dist / 0.9)))
        let dir = (layout.pin - ballPosition2D) / dist
        let yaw = Float(HoleLayout.yaw(for: dir))
        for (i, node) in arrowNodes.enumerated() {
            if i >= count { node.isHidden = true; continue }
            let t = (now * 0.55 + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            let p = ballPosition2D + dir * (0.35 + t * (dist - 0.55))
            node.isHidden = false
            node.eulerAngles.y = yaw
            node.simdPosition = SIMD3<Float>(Float(p.x), Float(layout.height(at: p)) + 0.035, Float(p.y))
            node.opacity = CGFloat(sin(t * .pi))
        }
    }

    private func refreshBallOnGreen() {
        ballOnGreen = layout != nil && layout.terrain(at: ballPosition2D) == .green
    }

    private func buildBall() {
        let sphere = SCNSphere(radius: CGFloat(Self.ballVisualRadius))
        sphere.segmentCount = 48
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.97, alpha: 1)
        m.roughness.contents = 0.22
        m.metalness.contents = 0.0
        m.normal.contents = ProceduralTextures.ballNormalMap
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = 1.2
        sphere.materials = [m]
        ballNode.geometry = sphere
        ballNode.castsShadow = true

        let ps = SCNParticleSystem()
        ps.particleImage = ProceduralTextures.softParticle
        ps.birthRate = 0
        ps.particleLifeSpan = 0.7
        ps.particleSize = 0.05
        ps.particleColor = UIColor(white: 1, alpha: 0.6)
        ps.blendMode = .additive
        ps.isLocal = false
        ps.emitterShape = nil
        trailNode.addParticleSystem(ps)
        ballNode.addChildNode(trailNode)
    }

    private func setTrail(_ on: Bool) {
        trailNode.particleSystems?.first?.birthRate = on ? 90 : 0
    }

    // MARK: - Water

    private static let waterGeometryShader = """
    #pragma arguments
    float uTime;
    float uAmp;
    float uFreq;
    #pragma body
    float3 p = _geometry.position.xyz;
    float w = sin(p.x * uFreq + uTime * 1.1) * 0.6 + sin(p.z * uFreq * 1.3 - uTime * 1.4) * 0.4 + sin((p.x + p.z) * uFreq * 0.7 + uTime * 0.7) * 0.5;
    _geometry.position.y += w * uAmp;
    """

    private static let waterSurfaceShader = """
    #pragma arguments
    float uTime;
    float uRipple;
    float3 uDeep;
    float3 uShallow;
    float3 uSky;
    #pragma body
    float2 p = _surface.diffuseTexcoord * 6.0;
    float t = uTime;
    float2 g = float2(cos(p.x * 1.3 + t * 0.9 + p.y * 0.7), cos(p.y * 1.1 - t * 0.8 + p.x * 0.5));
    g += 0.6 * float2(cos(p.x * 2.7 - t * 1.4 + p.y * 1.9), cos(p.y * 2.3 + t * 1.2 - p.x * 1.7));
    g += 0.35 * float2(cos(p.x * 5.1 + t * 2.1), cos(p.y * 4.7 - t * 1.9));
    float3 n = normalize(_surface.normal + float3(g.x, g.y, 0.0) * uRipple);
    _surface.normal = n;
    float3 v = normalize(_surface.view);
    float fres = pow(1.0 - saturate(dot(v, n)), 3.5);
    float3 col = mix(uDeep, uShallow, saturate(0.45 + 0.2 * g.x));
    col = mix(col, uSky, saturate(fres * 0.9));
    float glint = pow(saturate(0.5 * g.x + 0.5 * g.y + 0.25), 10.0);
    _surface.diffuse = float4(col, 1.0);
    _surface.emission = float4(uSky * fres * 0.3 + float3(glint * 0.35), 1.0);
    _surface.roughness = 0.05;
    _surface.metalness = 0.0;
    """

    private func makeWaterMaterial(ocean: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = ProceduralTextures.whiteDot
        m.roughness.contents = 0.05
        m.metalness.contents = 0.0
        m.normal.contents = ProceduralTextures.waterNormalMap
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = 0.8
        m.isDoubleSided = true
        m.transparency = ocean ? 0.96 : 0.8
        m.shaderModifiers = [.geometry: Self.waterGeometryShader, .surface: Self.waterSurfaceShader]
        m.setValue(NSNumber(value: Float(0)), forKey: "uTime")
        m.setValue(NSNumber(value: Float(ocean ? 0.9 : 0.03)), forKey: "uAmp")
        m.setValue(NSNumber(value: Float(ocean ? 0.03 : 0.9)), forKey: "uFreq")
        m.setValue(NSNumber(value: Float(ocean ? 0.22 : 0.16)), forKey: "uRipple")
        applyWaterColors(to: m)
        return m
    }

    private func applyWaterColors(to m: SCNMaterial) {
        let st = course.style
        let deep = st.water.scaled(0.65)
        let shallow = st.water.mixed(with: RGB(0.6, 0.9, 0.9), 0.3)
        let sky = st.skyHorizon.mixed(with: RGB(0.62, 0.64, 0.66), weather.skyGray)
        m.setValue(NSValue(scnVector3: SCNVector3(Float(deep.r), Float(deep.g), Float(deep.b))), forKey: "uDeep")
        m.setValue(NSValue(scnVector3: SCNVector3(Float(shallow.r), Float(shallow.g), Float(shallow.b))), forKey: "uShallow")
        m.setValue(NSValue(scnVector3: SCNVector3(Float(sky.r), Float(sky.g), Float(sky.b))), forKey: "uSky")
    }

    /// Flat elliptical pond mesh built in real metres so the wave shader works in world scale.
    private func makePondGeometry(a: Double, b: Double) -> SCNGeometry {
        let rings = 7, segs = 64
        var verts = [SCNVector3(0, 0, 0)]
        var uvs = [CGPoint(x: 0, y: 0)]
        for ring in 1...rings {
            let r = Double(ring) / Double(rings)
            for s in 0..<segs {
                let ang = Double(s) / Double(segs) * 2 * .pi
                let x = b * r * cos(ang), z = a * r * sin(ang)
                verts.append(SCNVector3(Float(x), 0, Float(z)))
                uvs.append(CGPoint(x: x / 6, y: z / 6))
            }
        }
        let normals = [SCNVector3](repeating: SCNVector3(0, 1, 0), count: verts.count)
        var idx = [UInt32]()
        for s in 0..<segs {
            let s1 = (s + 1) % segs
            idx.append(contentsOf: [0, UInt32(1 + s1), UInt32(1 + s)])
        }
        for ring in 1..<rings {
            for s in 0..<segs {
                let s1 = (s + 1) % segs
                let A = UInt32(1 + (ring - 1) * segs + s), B = UInt32(1 + (ring - 1) * segs + s1)
                let C = UInt32(1 + ring * segs + s), D = UInt32(1 + ring * segs + s1)
                idx.append(contentsOf: [A, B, C, B, D, C])
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: uvs)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    private func makeGridGeometry(size: Double, cells: Int) -> SCNGeometry {
        var verts = [SCNVector3](), uvs = [CGPoint]()
        let step = size / Double(cells)
        for iz in 0...cells {
            for ix in 0...cells {
                let x = -size / 2 + Double(ix) * step, z = -size / 2 + Double(iz) * step
                verts.append(SCNVector3(Float(x), 0, Float(z)))
                uvs.append(CGPoint(x: x / 6, y: z / 6))
            }
        }
        let normals = [SCNVector3](repeating: SCNVector3(0, 1, 0), count: verts.count)
        var idx = [UInt32]()
        let w = cells + 1
        for iz in 0..<cells {
            for ix in 0..<cells {
                let i00 = UInt32(iz * w + ix), i10 = i00 + 1, i01 = UInt32((iz + 1) * w + ix), i11 = i01 + 1
                idx.append(contentsOf: [i00, i01, i10, i10, i01, i11])
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: uvs)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    private func pbr(_ c: RGB, roughness: Double = 0.9, metalness: Double = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c.uiColor
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }

    private func detailed(_ c: RGB, roughness: Double = 0.95, tiles: Float = 3, intensity: CGFloat = 1.0) -> SCNMaterial {
        let m = pbr(c, roughness: roughness)
        m.normal.contents = ProceduralTextures.detailNormalMap
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = intensity
        m.normal.contentsTransform = SCNMatrix4MakeScale(tiles, tiles, 1)
        return m
    }

    // MARK: - Hole loading

    func setWeather(_ w: WeatherCondition) {
        weather = w
        guard layout != nil else { return }
        configureWind()
        applyStyle()
        configureParticles()
        refreshAim()
    }

    func loadHole(_ hole: Hole, ballAt: SIMD2<Double>? = nil) {
        phase = .rest
        setTrail(false)
        worldNode.childNodes.forEach { $0.removeFromParentNode() }
        colliders.removeAll()
        layout = HoleLayout(course: course, hole: hole)
        configureWind()
        buildTerrain()
        buildBackdrop()
        buildHazardVisuals()
        buildFlag()
        buildDecor()
        buildGroundCover()
        buildScatter()
        applyStyle()
        configureParticles()
        placeBall(at: ballAt ?? SIMD2<Double>(0, 0))
        aimOffsetDegrees = 0
        overviewT = 0
        celebrateT = 0
        setCameraState(.address, snap: true)
        audio.startWind(volume: Float(min(0.5, 0.08 + windSpeedMPH / 45)))
    }

    private func stableSeed() -> UInt64 {
        let base = course.id.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return base &+ UInt64(layout.hole.number) &* 7919
    }

    // MARK: - Wind

    private func configureWind() {
        var rng = SeededRNG(seed: stableSeed() &+ 99)
        let speed = course.baseWindMPH * weather.windMultiplier * Double.random(in: 0.6...1.3, using: &rng)
        let heading = Double.random(in: 0...360, using: &rng)
        windSpeedMPH = speed
        windToHeadingDegrees = heading
        let ms = speed * 0.44704
        let r = heading * .pi / 180
        windVector = SIMD3<Double>(sin(r) * ms, 0, -cos(r) * ms)
    }

    // MARK: - Style: sky, light, fog

    private func applyStyle() {
        let st = course.style
        let gray = weather.skyGray
        let g = RGB(0.62, 0.64, 0.66)
        let top = st.skyTop.mixed(with: g, gray)
        let hor = st.skyHorizon.mixed(with: g, gray)
        let fog = st.fogColor.mixed(with: g, gray)

        let sky = ProceduralTextures.sky(top: top, horizon: hor, ground: hor.scaled(0.78),
                                         cloudiness: 0.25 + gray, seed: stableSeed())
        scene.background.contents = sky
        scene.lightingEnvironment.contents = sky
        scene.lightingEnvironment.intensity = CGFloat(0.9 * (0.5 + 0.5 * weather.lightMultiplier))

        scene.fogColor = fog.uiColor
        scene.fogStartDistance = CGFloat(max(70, st.fogStart * weather.fogMultiplier))
        scene.fogEndDistance = CGFloat(max(300, st.fogEnd * weather.fogMultiplier))
        scene.fogDensityExponent = 1.4

        sunNode.light?.color = st.sunColor.mixed(with: RGB(1, 1, 1), gray * 0.7).uiColor
        sunNode.light?.intensity = CGFloat(1000 * st.sunIntensity * weather.lightMultiplier)
        sunNode.light?.shadowColor = UIColor(white: 0, alpha: CGFloat(0.6 * (1 - gray * 0.5)))
        ambientNode.light?.color = UIColor(white: 1, alpha: 1)
        ambientNode.light?.intensity = CGFloat(1000 * st.ambientIntensity * (0.8 + 0.4 * gray))

        let el = st.sunElevation * .pi / 180
        let az = st.sunAzimuth * .pi / 180
        let dir = SIMD3<Float>(Float(sin(az) * cos(el)), Float(sin(el)), Float(-cos(az) * cos(el)))
        sunDirection = dir
        sunNode.simdPosition = dir * 100
        sunNode.simdLook(at: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        let showGlow = (course.theme == .coastal || course.theme == .desert || course.theme == .alpine) && gray < 0.4
        sunGlowNode.isHidden = !showGlow
        glowDistance = Float(max(80, scene.fogStartDistance * 0.92))
        sunGlowNode.simdScale = SIMD3<Float>(repeating: glowDistance * 0.35)
        sunGlowNode.opacity = CGFloat(1 - gray)

        applyWaterColors(to: pondMaterial)
        applyWaterColors(to: oceanMaterial)
    }

    // MARK: - Terrain

    private func buildTerrain() {
        let L = layout!
        let b = L.bounds(margin: 120)
        let cell = 2.5
        let nx = Int(ceil(b.width / cell)) + 1
        let nz = Int(ceil(b.height / cell)) + 1

        // Pass 1: raw heights (also tells us how low the whole hole goes)
        var raw = [Double](repeating: 0, count: nx * nz)
        var minRaw = Double.greatestFiniteMagnitude
        for iz in 0..<nz {
            for ix in 0..<nx {
                let x = b.minX + Double(ix) * cell
                let z = b.minZ + Double(iz) * cell
                let h = L.height(at: SIMD2<Double>(x, z))
                raw[iz * nx + ix] = h
                if L.oceanSide == 0 || h > L.seaY { minRaw = min(minRaw, h) }
            }
        }
        farY = course.theme == .coastal ? L.seaY : (minRaw - 2.0)
        let edgeTarget = farY - 1.0

        var heights = [Float](repeating: 0, count: nx * nz)
        for iz in 0..<nz {
            for ix in 0..<nx {
                let x = b.minX + Double(ix) * cell
                let z = b.minZ + Double(iz) * cell
                let edge = min(min(x - b.minX, b.maxX - x), min(z - b.minZ, b.maxZ - z))
                let k = smoothstep(0, 45, edge)
                heights[iz * nx + ix] = Float(edgeTarget + (raw[iz * nx + ix] - edgeTarget) * k)
            }
        }

        var verts = [SCNVector3](); verts.reserveCapacity(nx * nz)
        var normals = [SCNVector3](); normals.reserveCapacity(nx * nz)
        var uvs = [CGPoint](); uvs.reserveCapacity(nx * nz)
        var tangents = [Float](); tangents.reserveCapacity(nx * nz * 4)
        let c = Float(cell)

        for iz in 0..<nz {
            for ix in 0..<nx {
                let h = heights[iz * nx + ix]
                let x = Float(b.minX) + Float(ix) * c
                let z = Float(b.minZ) + Float(iz) * c
                verts.append(SCNVector3(x, h, z))
                let hl = heights[iz * nx + max(0, ix - 1)]
                let hr = heights[iz * nx + min(nx - 1, ix + 1)]
                let hu = heights[max(0, iz - 1) * nx + ix]
                let hd = heights[min(nz - 1, iz + 1) * nx + ix]
                let n = simd_normalize(SIMD3<Float>((hl - hr) / (2 * c), 1, (hu - hd) / (2 * c)))
                normals.append(SCNVector3(n.x, n.y, n.z))
                var t = SIMD3<Float>(1, 0, 0)
                t = simd_normalize(t - n * simd_dot(n, t))
                tangents.append(contentsOf: [t.x, t.y, t.z, -1])
                let u = CGFloat(ix) / CGFloat(nx - 1)
                var v = CGFloat(iz) / CGFloat(nz - 1)
                if Self.flipTextureV { v = 1 - v }
                uvs.append(CGPoint(x: u, y: v))
            }
        }

        var indices = [UInt32](); indices.reserveCapacity((nx - 1) * (nz - 1) * 6)
        for iz in 0..<(nz - 1) {
            for ix in 0..<(nx - 1) {
                let i00 = UInt32(iz * nx + ix)
                let i10 = i00 + 1
                let i01 = UInt32((iz + 1) * nx + ix)
                let i11 = i01 + 1
                indices.append(contentsOf: [i00, i01, i10, i10, i01, i11])
            }
        }

        let tanData = tangents.withUnsafeBufferPointer { Data(buffer: $0) }
        let tanSource = SCNGeometrySource(data: tanData, semantic: .tangent, vectorCount: nx * nz,
                                          usesFloatComponents: true, componentsPerVector: 4,
                                          bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                          dataStride: 4 * MemoryLayout<Float>.size)
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts),
                                        SCNGeometrySource(normals: normals),
                                        SCNGeometrySource(textureCoordinates: uvs),
                                        tanSource],
                              elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])

        let mapSize = CGSize(width: 1024, height: CGFloat(min(2560, max(1024, Int(1024 * b.height / b.width)))))
        let map = ProceduralTextures.holeMap(layout: L, style: course.style, bounds: b, size: mapSize)

        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = map
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 8
        let wet = weather == .rain || course.theme == .forest
        m.roughness.contents = wet ? 0.6 : 0.93
        m.metalness.contents = 0.0
        m.normal.contents = ProceduralTextures.detailNormalMap
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = 1.0
        m.normal.contentsTransform = SCNMatrix4MakeScale(Float(b.width / 4), Float(b.height / 4), 1)
        geo.materials = [m]

        let node = SCNNode(geometry: geo)
        node.name = "terrain"
        node.castsShadow = false
        worldNode.addChildNode(node)
    }

    // MARK: - Distant landscape (mountains, mesas, hills, ocean)

    private func buildBackdrop() {
        let L = layout!
        let theme = course.theme
        let center = L.green * 0.5
        let size = 3600.0
        let cells = 150
        let step = size / Double(cells)
        let baseY = theme == .coastal ? L.seaY - 1.0 : farY - 0.5
        let seed = Double(abs(course.id.hashValueStable % 97)) + 1

        let hMax: Double
        switch theme {
        case .alpine: hMax = 620
        case .desert: hMax = 190
        case .forest: hMax = 150
        case .coastal: hMax = 90
        case .links: hMax = 85
        }

        var hs = [Double](repeating: 0, count: (cells + 1) * (cells + 1))
        for iz in 0...cells {
            for ix in 0...cells {
                let x = center.x - size / 2 + Double(ix) * step
                let z = center.y - size / 2 + Double(iz) * step
                let d = L.project(SIMD2<Double>(x, z)).dist
                var H = 0.0
                var mask = 0.0
                switch theme {
                case .alpine:
                    mask = smoothstep(380, 950, d)
                    H = 620 * pow(ridged2(x / 700, z / 700, seed, 6), 1.25)
                case .desert:
                    mask = smoothstep(260, 700, d)
                    let m = ridged2(x / 520, z / 520, seed, 4) * 5
                    let level = floor(m) + smoothstep(0.35, 0.65, m - floor(m))
                    H = 190 * min(1, level / 5)
                case .forest:
                    mask = smoothstep(260, 650, d)
                    H = 150 * fbm2(x / 380, z / 380, seed, 4)
                case .coastal:
                    mask = smoothstep(700, 1400, d)
                    H = 90 * pow(ridged2(x / 600, z / 600, seed, 3), 1.4)
                case .links:
                    mask = smoothstep(300, 750, d)
                    H = 85 * fbm2(x / 300, z / 300, seed, 4)
                }
                hs[iz * (cells + 1) + ix] = baseY + H * mask
            }
        }

        let ramp: [(Double, RGB)]
        switch theme {
        case .alpine:
            ramp = [(0, RGB(0.10, 0.24, 0.11)), (0.12, RGB(0.18, 0.33, 0.14)), (0.28, RGB(0.36, 0.33, 0.30)),
                    (0.5, RGB(0.50, 0.50, 0.53)), (0.66, RGB(0.90, 0.92, 0.97)), (1, RGB(1, 1, 1))]
        case .desert:
            ramp = [(0, RGB(0.78, 0.58, 0.36)), (0.4, RGB(0.64, 0.32, 0.19)), (0.75, RGB(0.52, 0.23, 0.15)), (1, RGB(0.72, 0.42, 0.26))]
        case .forest:
            ramp = [(0, RGB(0.06, 0.16, 0.09)), (0.5, RGB(0.10, 0.24, 0.12)), (1, RGB(0.18, 0.32, 0.17))]
        case .coastal:
            ramp = [(0, RGB(0.30, 0.45, 0.28)), (0.5, RGB(0.42, 0.50, 0.32)), (1, RGB(0.55, 0.55, 0.52))]
        case .links:
            ramp = [(0, RGB(0.38, 0.38, 0.24)), (0.5, RGB(0.46, 0.30, 0.46)), (1, RGB(0.52, 0.47, 0.34))]
        }

        var verts = [SCNVector3](), normals = [SCNVector3](), uvs = [CGPoint]()
        verts.reserveCapacity(hs.count); normals.reserveCapacity(hs.count); uvs.reserveCapacity(hs.count)
        let w = cells + 1
        let cf = Float(step)
        for iz in 0...cells {
            for ix in 0...cells {
                let h = hs[iz * w + ix]
                let x = center.x - size / 2 + Double(ix) * step
                let z = center.y - size / 2 + Double(iz) * step
                verts.append(SCNVector3(Float(x), Float(h), Float(z)))
                let hl = Float(hs[iz * w + max(0, ix - 1)]), hr = Float(hs[iz * w + min(cells, ix + 1)])
                let hu = Float(hs[max(0, iz - 1) * w + ix]), hd = Float(hs[min(cells, iz + 1) * w + ix])
                let n = simd_normalize(SIMD3<Float>((hl - hr) / (2 * cf), 1, (hu - hd) / (2 * cf)))
                normals.append(SCNVector3(n.x, n.y, n.z))
                var u = (h - baseY) / hMax
                if theme == .alpine { u -= Double(1 - n.y) * 0.9 }
                u += (hash2d(x * 0.05, z * 0.05, seed) - 0.5) * 0.06
                uvs.append(CGPoint(x: CGFloat(max(0, min(1, u))), y: 0.5))
            }
        }
        var idx = [UInt32]()
        for iz in 0..<cells {
            for ix in 0..<cells {
                let i00 = UInt32(iz * w + ix), i10 = i00 + 1, i01 = UInt32((iz + 1) * w + ix), i11 = i01 + 1
                idx.append(contentsOf: [i00, i01, i10, i10, i01, i11])
            }
        }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals),
                                        SCNGeometrySource(textureCoordinates: uvs)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = ProceduralTextures.elevationRamp(ramp)
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.roughness.contents = 1.0
        m.metalness.contents = 0.0
        geo.materials = [m]
        let node = SCNNode(geometry: geo)
        node.castsShadow = false
        node.name = "backdrop"
        worldNode.addChildNode(node)

        if theme == .coastal {
            let ocean = SCNNode(geometry: makeGridGeometry(size: size, cells: 60))
            ocean.geometry?.materials = [oceanMaterial]
            ocean.simdPosition = SIMD3<Float>(Float(center.x), Float(L.seaY), Float(center.y))
            ocean.castsShadow = false
            worldNode.addChildNode(ocean)
        }
    }

    // MARK: - Hazards and decor

    private func buildHazardVisuals() {
        let L = layout!
        for ph in L.placed {
            switch ph.hazard.kind {
            case .water, .creek:
                let node = SCNNode(geometry: makePondGeometry(a: ph.a, b: ph.b))
                node.geometry?.materials = [pondMaterial]
                node.simdPosition = SIMD3<Float>(Float(ph.center.x), Float(L.waterLevel(ph)), Float(ph.center.y))
                node.eulerAngles.y = Float(HoleLayout.yaw(for: L.direction(atS: ph.s0)))
                node.castsShadow = false
                worldNode.addChildNode(node)
            case .rocks:
                addRockCluster(at: ph.center, count: 4, spread: ph.a, scale: 1.6)
            case .boulder:
                addRockCluster(at: ph.center, count: 1, spread: 0.1, scale: 2.2)
            case .stoneWall:
                addWall(ph)
            default:
                break
            }
        }

        let cup = SCNCylinder(radius: 0.054, height: 0.012)
        cup.materials = [pbr(RGB(0.02, 0.02, 0.02), roughness: 1)]
        let cupNode = SCNNode(geometry: cup)
        cupNode.simdPosition = SIMD3<Float>(Float(L.pin.x), Float(L.height(at: L.pin)) + 0.004, Float(L.pin.y))
        worldNode.addChildNode(cupNode)

        for side in [-1.0, 1.0] {
            let s = SCNSphere(radius: 0.18)
            s.materials = [pbr(side < 0 ? RGB(0.95, 0.95, 0.95) : RGB(0.15, 0.35, 0.9), roughness: 0.5)]
            let n = SCNNode(geometry: s)
            let p = SIMD2<Double>(side * 3.5, 4)
            n.simdPosition = SIMD3<Float>(Float(p.x), Float(L.height(at: p)) + 0.18, Float(p.y))
            worldNode.addChildNode(n)
        }
    }

    private func rockColor() -> RGB {
        switch course.theme {
        case .desert: return RGB(0.62, 0.30, 0.18)
        case .alpine: return RGB(0.50, 0.50, 0.52)
        default: return RGB(0.45, 0.45, 0.44)
        }
    }

    private func rockMaterial() -> SCNMaterial {
        let mat = pbr(rockColor(), roughness: 1)
        mat.normal.contents = ProceduralTextures.sandNormalMap
        mat.normal.wrapS = .repeat
        mat.normal.wrapT = .repeat
        mat.normal.intensity = 1.4
        return mat
    }

    private func addRockCluster(at c: SIMD2<Double>, count: Int, spread: Double, scale: Double) {
        var rng = SeededRNG(seed: stableSeed() &+ UInt64(abs(c.x * 10 + c.y)))
        let mat = rockMaterial()
        for _ in 0..<count {
            let ox = Double.random(in: -spread...spread, using: &rng) * 0.6
            let oz = Double.random(in: -spread...spread, using: &rng) * 0.6
            let p = SIMD2<Double>(c.x + ox, c.y + oz)
            let k = Double.random(in: 0.7...1.3, using: &rng) * scale
            let sph = SCNSphere(radius: 1)
            sph.segmentCount = 16
            sph.materials = [mat]
            let n = SCNNode(geometry: sph)
            let y = layout.height(at: p)
            n.simdPosition = SIMD3<Float>(Float(p.x), Float(y + k * 0.35), Float(p.y))
            n.scale = SCNVector3(Float(k * 1.1), Float(k * 0.8), Float(k))
            n.eulerAngles.y = Float.random(in: 0...6.28, using: &rng)
            worldNode.addChildNode(n)
            colliders.append(Collider(x: p.x, z: p.y, baseY: y, top: y + k * 1.2, radius: k * 1.0, tree: false, k: k))
        }
    }

    private func addWall(_ ph: PlacedHazard) {
        let mat = rockMaterial()
        mat.diffuse.contents = RGB(0.52, 0.51, 0.48).uiColor
        let yaw = Float(HoleLayout.yaw(for: layout.direction(atS: ph.s0)))
        var rng = SeededRNG(seed: stableSeed() &+ 5)
        var s = -ph.a
        while s < ph.a {
            let p = layout.world(s: ph.s0 + s, l: ph.l0)
            let h = Double.random(in: 1.0...1.3, using: &rng)
            let box = SCNBox(width: 0.7, height: CGFloat(h), length: 2.1, chamferRadius: 0.08)
            box.materials = [mat]
            let n = SCNNode(geometry: box)
            let y = layout.height(at: p)
            n.simdPosition = SIMD3<Float>(Float(p.x), Float(y + h / 2), Float(p.y))
            n.eulerAngles.y = yaw
            worldNode.addChildNode(n)
            colliders.append(Collider(x: p.x, z: p.y, baseY: y, top: y + h, radius: 1.1, tree: false, k: 1))
            s += 2.0
        }
    }

    private func buildFlag() {
        let L = layout!
        let base = SIMD3<Float>(Float(L.pin.x), Float(L.height(at: L.pin)), Float(L.pin.y))
        let stick = SCNCylinder(radius: 0.012, height: 2.4)
        stick.materials = [pbr(RGB(0.95, 0.95, 0.95), roughness: 0.4)]
        let sn = SCNNode(geometry: stick)
        sn.simdPosition = base + SIMD3<Float>(0, 1.2, 0)
        worldNode.addChildNode(sn)

        let pivot = SCNNode()
        pivot.simdPosition = base + SIMD3<Float>(0, 2.1, 0)
        let plane = SCNPlane(width: 0.9, height: 0.55)
        let fm = pbr(RGB(0.9, 0.1, 0.1), roughness: 0.8)
        fm.isDoubleSided = true
        plane.materials = [fm]
        let fn = SCNNode(geometry: plane)
        fn.position = SCNVector3(0.45, 0, 0)
        pivot.addChildNode(fn)
        worldNode.addChildNode(pivot)
        flagPivot = pivot
    }

    private func buildDecor() {
        switch course.theme {
        case .forest: buildTrees(spruce: false, density: 1.0)
        case .alpine: buildTrees(spruce: true, density: 0.6)
        case .desert: buildCacti()
        case .links, .coastal: break
        }
    }

    // MARK: Trees

    private func makePineProto(variant: Int, spruce: Bool) -> SCNNode {
        let root = SCNNode()
        let trunk = SCNCylinder(radius: 0.3, height: 2.6)
        trunk.radialSegmentCount = 8
        trunk.materials = [detailed(RGB(0.26, 0.17, 0.10), roughness: 1, tiles: 2)]
        let tn = SCNNode(geometry: trunk)
        tn.position = SCNVector3(0, 1.3, 0)
        root.addChildNode(tn)

        let palette: [RGB]
        if spruce {
            palette = [RGB(0.08, 0.24, 0.17), RGB(0.10, 0.28, 0.20), RGB(0.07, 0.21, 0.15)]
        } else {
            palette = [RGB(0.07, 0.27, 0.11), RGB(0.11, 0.31, 0.12), RGB(0.09, 0.24, 0.13)]
        }
        let base = palette[variant % palette.count]
        let tiers = 5
        for i in 0..<tiers {
            let t = Double(i) / Double(tiers - 1)
            let radius = (2.8 - 1.9 * t) * (variant == 1 ? 1.12 : 1.0)
            let height = 2.5 - 0.5 * t
            let y = 1.9 + Double(i) * 1.55
            let cone = SCNCone(topRadius: 0.04, bottomRadius: CGFloat(radius), height: CGFloat(height))
            cone.radialSegmentCount = 18
            cone.materials = [detailed(base.scaled(0.8 + 0.5 * t), roughness: 0.95, tiles: 3, intensity: 1.2)]
            let n = SCNNode(geometry: cone)
            n.position = SCNVector3(0, Float(y), 0)
            n.eulerAngles.y = Float(i) * 0.6
            root.addChildNode(n)
        }
        return root.flattenedClone()
    }

    private func buildTrees(spruce: Bool, density: Double) {
        guard density > 0, let L = layout else { return }
        let protos = (0..<3).map { makePineProto(variant: $0, spruce: spruce) }
        var rng = SeededRNG(seed: stableSeed() &+ 31)
        let container = SCNNode()
        var s = -14.0
        while s < L.totalLength + 40 {
            for side in [-1.0, 1.0] {
                for row in 0..<3 {
                    let p0 = [0.85, 0.5, 0.35][row] * density
                    if Double.random(in: 0...1, using: &rng) > p0 { continue }
                    let off = L.fairwayHalf + (row == 0 ? Double.random(in: 5...12, using: &rng)
                                               : row == 1 ? Double.random(in: 14...34, using: &rng)
                                               : Double.random(in: 36...70, using: &rng))
                    let w = L.world(s: s + Double.random(in: -3...3, using: &rng), l: side * off)
                    if L.project(w).dist < L.fairwayHalf + 3 { continue }
                    let terr = L.terrain(at: w)
                    if terr == .water || terr == .green { continue }
                    let y = L.height(at: w)
                    let k = Double.random(in: 0.8...1.5, using: &rng)
                    let sy = spruce ? 1.25 : 1.0
                    let sxz = spruce ? 0.8 : 1.0
                    let t = protos[Int.random(in: 0..<3, using: &rng)].clone()
                    t.simdPosition = SIMD3<Float>(Float(w.x), Float(y), Float(w.y))
                    t.scale = SCNVector3(Float(k * sxz), Float(k * sy), Float(k * sxz))
                    t.eulerAngles.y = Float.random(in: 0...6.28, using: &rng)
                    let amp = CGFloat(Double.random(in: 0.015...0.04, using: &rng))
                    let dur = Double.random(in: 1.6...3.2, using: &rng)
                    let a = SCNAction.rotateBy(x: amp, y: 0, z: amp * 0.6, duration: dur)
                    a.timingMode = .easeInEaseOut
                    t.runAction(.repeatForever(.sequence([a, a.reversed()])))
                    container.addChildNode(t)
                    colliders.append(Collider(x: w.x, z: w.y, baseY: y, top: y + 9.2 * k * sy,
                                              radius: 0.34 * k, tree: true, k: k * sy))
                }
            }
            s += 8
        }
        worldNode.addChildNode(container)
    }

    private func buildCacti() {
        let L = layout!
        var rng = SeededRNG(seed: stableSeed() &+ 77)
        let mat = detailed(RGB(0.22, 0.40, 0.20), roughness: 0.9, tiles: 2)
        let root = SCNNode()
        let body = SCNCapsule(capRadius: 0.3, height: 3.4); body.materials = [mat]
        let bn = SCNNode(geometry: body); bn.position = SCNVector3(0, 1.7, 0); root.addChildNode(bn)
        for side in [-1.0, 1.0] {
            let arm = SCNCapsule(capRadius: 0.18, height: 1.6); arm.materials = [mat]
            let an = SCNNode(geometry: arm)
            an.position = SCNVector3(Float(side * 0.65), 2.3, 0)
            root.addChildNode(an)
        }
        let proto = root.flattenedClone()
        for _ in 0..<110 {
            let s = Double.random(in: -10...(L.totalLength + 30), using: &rng)
            let side: Double = Bool.random(using: &rng) ? 1 : -1
            let w = L.world(s: s, l: side * (L.fairwayHalf + Double.random(in: 8...70, using: &rng)))
            if L.terrain(at: w) != .rough { continue }
            let t = proto.clone()
            let k = Float.random(in: 0.7...1.5, using: &rng)
            let y = L.height(at: w)
            t.simdPosition = SIMD3<Float>(Float(w.x), Float(y), Float(w.y))
            t.scale = SCNVector3(k, k, k)
            t.eulerAngles.y = Float.random(in: 0...6.28, using: &rng)
            worldNode.addChildNode(t)
            colliders.append(Collider(x: w.x, z: w.y, baseY: y, top: y + 3.4 * Double(k), radius: 0.4 * Double(k), tree: false, k: Double(k)))
        }
    }

    // MARK: Ground cover (the detail outside the fairway)

    private func buildGroundCover() {
        let L = layout!
        let st = course.style
        var rng = SeededRNG(seed: stableSeed() &+ 555)
        var grass = MeshBuilder()
        var flowers = MeshBuilder()

        let hRange: (Double, Double)
        switch course.theme {
        case .coastal: hRange = (0.28, 0.55)
        case .forest: hRange = (0.25, 0.5)
        case .desert: hRange = (0.2, 0.45)
        case .alpine: hRange = (0.3, 0.6)
        case .links: hRange = (0.45, 0.85)
        }

        var attempts = 0
        var placedTufts = 0
        let target = 15000
        while placedTufts < target && attempts < target * 4 {
            attempts += 1
            let s = Double.random(in: -10...(L.totalLength + 20), using: &rng)
            let side: Double = Bool.random(using: &rng) ? 1 : -1
            let l = side * (L.fairwayHalf + 0.6 + pow(Double.random(in: 0...1, using: &rng), 1.7) * 70)
            let p = L.world(s: s, l: l)
            let terr = L.terrain(at: p)
            if terr != .rough && terr != .fescue { continue }
            let y = Float(L.height(at: p))
            var h = Double.random(in: hRange.0...hRange.1, using: &rng)
            if terr == .fescue { h *= 1.5 }
            let u = CGFloat.random(in: 0...1, using: &rng)
            let blades = 4
            for _ in 0..<blades {
                let ang = Float.random(in: 0...(2 * .pi), using: &rng)
                let dx = cos(ang), dz = sin(ang)
                let ox = Float.random(in: -0.1...0.1, using: &rng), oz = Float.random(in: -0.1...0.1, using: &rng)
                grass.blade(base: SIMD3<Float>(Float(p.x) + ox, y, Float(p.y) + oz), dirX: dx, dirZ: dz,
                            width: Float.random(in: 0.05...0.09, using: &rng),
                            height: Float(h * Double.random(in: 0.7...1.15, using: &rng)),
                            lean: Float(h * Double.random(in: 0.1...0.35, using: &rng)), u: u)
            }
            if Double.random(in: 0...1, using: &rng) < 0.12 {
                for _ in 0..<3 {
                    let ang = Float.random(in: 0...(2 * .pi), using: &rng)
                    flowers.blade(base: SIMD3<Float>(Float(p.x) + Float.random(in: -0.2...0.2, using: &rng), y,
                                                     Float(p.y) + Float.random(in: -0.2...0.2, using: &rng)),
                                  dirX: cos(ang), dirZ: sin(ang), width: 0.1,
                                  height: Float(Double.random(in: 0.22...0.42, using: &rng)),
                                  lean: 0.05, u: CGFloat.random(in: 0.6...1, using: &rng))
                }
            }
            placedTufts += 1
        }

        let container = SCNNode()
        if let g = grass.geometry() {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = ProceduralTextures.grassRamp(base: st.rough.scaled(0.95),
                                                              variation: st.rough.mixed(with: st.accent, 0.45).scaled(1.1),
                                                              tipBoost: 1.35)
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .clamp
            m.roughness.contents = 0.95
            m.metalness.contents = 0.0
            m.isDoubleSided = true
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.castsShadow = false
            container.addChildNode(n)
        }
        if let f = flowers.geometry() {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = ProceduralTextures.grassRamp(base: st.rough.scaled(0.8), variation: st.accent.scaled(1.35), tipBoost: 1.25)
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .clamp
            m.roughness.contents = 0.9
            m.isDoubleSided = true
            f.materials = [m]
            let n = SCNNode(geometry: f)
            n.castsShadow = false
            container.addChildNode(n)
        }
        worldNode.addChildNode(container)
    }

    /// Bushes, shrubs and pebbles scattered through the rough.
    private func buildScatter() {
        let L = layout!
        var rng = SeededRNG(seed: stableSeed() &+ 909)
        let st = course.style

        func bushProto(_ color: RGB) -> SCNNode {
            let root = SCNNode()
            let mat = detailed(color, roughness: 0.95, tiles: 2, intensity: 1.3)
            for _ in 0..<5 {
                let sph = SCNSphere(radius: CGFloat.random(in: 0.35...0.7, using: &rng))
                sph.segmentCount = 10
                sph.materials = [mat]
                let n = SCNNode(geometry: sph)
                n.position = SCNVector3(Float.random(in: -0.5...0.5, using: &rng), Float.random(in: 0.25...0.6, using: &rng),
                                        Float.random(in: -0.5...0.5, using: &rng))
                n.scale = SCNVector3(1, 0.75, 1)
                root.addChildNode(n)
            }
            return root.flattenedClone()
        }

        let bushColors: [RGB]
        let bushCount: Int
        switch course.theme {
        case .forest: bushColors = [RGB(0.10, 0.28, 0.12), RGB(0.16, 0.30, 0.10), RGB(0.28, 0.24, 0.10)]; bushCount = 100
        case .coastal: bushColors = [RGB(0.28, 0.45, 0.20), RGB(0.40, 0.50, 0.25)]; bushCount = 40
        case .desert: bushColors = [RGB(0.55, 0.48, 0.28), RGB(0.45, 0.45, 0.22)]; bushCount = 70
        case .alpine: bushColors = [RGB(0.15, 0.30, 0.15), RGB(0.30, 0.38, 0.20)]; bushCount = 50
        case .links: bushColors = [RGB(0.50, 0.42, 0.12), st.accent.scaled(0.8), RGB(0.30, 0.38, 0.14)]; bushCount = 90
        }
        let protos = bushColors.map { bushProto($0) }
        let container = SCNNode()
        var placed = 0, tries = 0
        while placed < bushCount && tries < bushCount * 6 {
            tries += 1
            let s = Double.random(in: -10...(L.totalLength + 20), using: &rng)
            let side: Double = Bool.random(using: &rng) ? 1 : -1
            let l = side * (L.fairwayHalf + 5 + Double.random(in: 0...55, using: &rng))
            let p = L.world(s: s, l: l)
            let t = L.terrain(at: p)
            if t != .rough && t != .fescue { continue }
            if L.project(p).dist < L.fairwayHalf + 3 { continue }
            let node = protos[Int.random(in: 0..<protos.count, using: &rng)].clone()
            let k = Float.random(in: 0.7...1.8, using: &rng)
            node.simdPosition = SIMD3<Float>(Float(p.x), Float(L.height(at: p)), Float(p.y))
            node.scale = SCNVector3(k, k * Float.random(in: 0.8...1.2, using: &rng), k)
            node.eulerAngles.y = Float.random(in: 0...6.28, using: &rng)
            container.addChildNode(node)
            placed += 1
        }

        // Pebbles
        let rockMat = rockMaterial()
        for _ in 0..<70 {
            let s = Double.random(in: -10...(L.totalLength + 20), using: &rng)
            let side: Double = Bool.random(using: &rng) ? 1 : -1
            let p = L.world(s: s, l: side * (L.fairwayHalf + 3 + Double.random(in: 0...50, using: &rng)))
            let t = L.terrain(at: p)
            if t != .rough && t != .fescue { continue }
            let sph = SCNSphere(radius: CGFloat.random(in: 0.12...0.4, using: &rng))
            sph.segmentCount = 8
            sph.materials = [rockMat]
            let n = SCNNode(geometry: sph)
            n.simdPosition = SIMD3<Float>(Float(p.x), Float(L.height(at: p)) + 0.05, Float(p.y))
            n.scale = SCNVector3(1.2, 0.7, 1)
            n.castsShadow = false
            container.addChildNode(n)
        }
        worldNode.addChildNode(container)
    }

    // MARK: - Particles

    private func softSystem(size: CGFloat, rate: CGFloat, life: CGFloat, speed: CGFloat,
                            color: UIColor, box: SCNVector3) -> SCNParticleSystem {
        let ps = SCNParticleSystem()
        ps.particleImage = ProceduralTextures.softParticle
        ps.birthRate = rate
        ps.particleLifeSpan = life
        ps.particleLifeSpanVariation = life * 0.3
        ps.particleVelocity = speed
        ps.particleVelocityVariation = speed
        ps.particleSize = size
        ps.particleSizeVariation = size * 0.5
        ps.particleColor = color
        ps.emitterShape = SCNBox(width: CGFloat(box.x), height: CGFloat(box.y), length: CGFloat(box.z), chamferRadius: 0)
        ps.birthLocation = .volume
        ps.spreadingAngle = 180
        ps.isLocal = false
        ps.warmupDuration = Double(life)
        ps.blendMode = .alpha
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 1.0, 0.0]
        fade.keyTimes = [0.0, 0.35, 1.0]
        ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        return ps
    }

    private func configureParticles() {
        followNode.childNodes.forEach { $0.removeFromParentNode() }
        followNode.removeAllActions()
        let holder = SCNNode()
        followNode.addChildNode(holder)
        let amb = SCNNode()
        amb.position = SCNVector3(0, 4, -25)
        holder.addChildNode(amb)

        let fogF = CGFloat(weather == .fog ? 1.8 : 1.0)
        switch course.theme {
        case .coastal:
            amb.addParticleSystem(softSystem(size: 9, rate: 8 * fogF, life: 12, speed: 1.5,
                                             color: UIColor(white: 1, alpha: 0.18), box: SCNVector3(90, 5, 90)))
        case .forest:
            amb.addParticleSystem(softSystem(size: 28, rate: 5 * fogF, life: 16, speed: 0.8,
                                             color: UIColor(red: 0.8, green: 0.86, blue: 0.84, alpha: 0.12),
                                             box: SCNVector3(90, 6, 90)))
        case .desert:
            amb.addParticleSystem(softSystem(size: 0.14, rate: 120, life: 8, speed: 0.7,
                                             color: UIColor(red: 0.95, green: 0.78, blue: 0.5, alpha: 0.6),
                                             box: SCNVector3(70, 10, 70)))
            let shimmer = softSystem(size: 14, rate: 4, life: 8, speed: 0.4,
                                     color: UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 0.08),
                                     box: SCNVector3(80, 1, 80))
            shimmer.acceleration = SCNVector3(0, 0.35, 0)
            amb.addParticleSystem(shimmer)
        case .alpine:
            amb.addParticleSystem(softSystem(size: 18, rate: 6 * fogF, life: 14, speed: 1.2,
                                             color: UIColor(white: 1, alpha: 0.16), box: SCNVector3(90, 12, 90)))
            holder.runAction(.repeatForever(.rotateBy(x: 0, y: 0.35, z: 0, duration: 20)))
        case .links:
            amb.addParticleSystem(softSystem(size: 22, rate: 6 * fogF, life: 14, speed: 1.4,
                                             color: UIColor(white: 0.95, alpha: 0.13), box: SCNVector3(90, 8, 90)))
        }

        if weather == .rain {
            let rain = SCNParticleSystem()
            rain.particleImage = ProceduralTextures.softParticle
            rain.birthRate = 1600
            rain.particleLifeSpan = 1.1
            rain.particleVelocity = 35
            rain.particleVelocityVariation = 4
            rain.emittingDirection = SCNVector3(0, -1, 0)
            rain.spreadingAngle = 0
            rain.particleSize = 0.04
            rain.stretchFactor = 0.12
            rain.particleColor = UIColor(white: 1, alpha: 0.5)
            rain.emitterShape = SCNBox(width: 60, height: 0.1, length: 60, chamferRadius: 0)
            rain.isLocal = false
            rain.warmupDuration = 1.1
            let rn = SCNNode()
            rn.position = SCNVector3(0, 22, -10)
            rn.addParticleSystem(rain)
            followNode.addChildNode(rn)
        }
    }

    func impactBurst(at p: SIMD3<Double>, terrain: TerrainType, intensity: Double) {
        let ps = SCNParticleSystem()
        ps.particleImage = ProceduralTextures.softParticle
        ps.birthRate = 900
        ps.emissionDuration = 0.06
        ps.loops = false
        ps.particleLifeSpan = 0.9
        ps.particleLifeSpanVariation = 0.4
        ps.particleVelocity = CGFloat(2.5 + 3 * min(1.5, intensity))
        ps.particleVelocityVariation = 2
        ps.emittingDirection = SCNVector3(0, 1, 0)
        ps.spreadingAngle = 55
        ps.particleSize = 0.05
        ps.particleSizeVariation = 0.03
        ps.isAffectedByGravity = true
        let c: UIColor
        switch terrain {
        case .bunker, .waste: c = course.style.sand.uiColor(alpha: 0.9)
        case .water: c = UIColor(white: 1, alpha: 0.8)
        default: c = course.style.fairway.scaled(0.9).uiColor(alpha: 0.9)
        }
        ps.particleColor = c
        ps.particleColorVariation = SCNVector4(0.05, 0.05, 0.05, 0.1)
        let n = SCNNode()
        n.simdPosition = SIMD3<Float>(Float(p.x), Float(p.y) + 0.03, Float(p.z))
        n.addParticleSystem(ps)
        worldNode.addChildNode(n)
        n.runAction(.sequence([.wait(duration: 2.5), .removeFromParentNode()]))
    }

    private func leafBurst(at p: SIMD3<Double>) {
        let ps = SCNParticleSystem()
        ps.particleImage = ProceduralTextures.confettiSquare
        ps.birthRate = 300
        ps.emissionDuration = 0.08
        ps.loops = false
        ps.particleLifeSpan = 1.4
        ps.particleVelocity = 2.2
        ps.particleVelocityVariation = 1.5
        ps.spreadingAngle = 120
        ps.particleSize = 0.07
        ps.isAffectedByGravity = true
        ps.orientationMode = .free
        ps.particleColor = UIColor(red: 0.2, green: 0.45, blue: 0.15, alpha: 1)
        ps.particleColorVariation = SCNVector4(0.1, 0.2, 0.1, 0)
        let n = SCNNode()
        n.simdPosition = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        n.addParticleSystem(ps)
        worldNode.addChildNode(n)
        n.runAction(.sequence([.wait(duration: 2), .removeFromParentNode()]))
    }

    /// Confetti, gold sparkles and an expanding ring around the cup.
    private func celebrationBurst() {
        let L = layout!
        let base = SIMD3<Float>(Float(L.pin.x), Float(L.height(at: L.pin)) + 0.05, Float(L.pin.y))

        let confetti = SCNParticleSystem()
        confetti.particleImage = ProceduralTextures.confettiSquare
        confetti.birthRate = 700
        confetti.emissionDuration = 0.3
        confetti.loops = false
        confetti.particleLifeSpan = 2.4
        confetti.particleLifeSpanVariation = 0.6
        confetti.particleVelocity = 6.5
        confetti.particleVelocityVariation = 2.5
        confetti.emittingDirection = SCNVector3(0, 1, 0)
        confetti.spreadingAngle = 50
        confetti.particleSize = 0.08
        confetti.particleSizeVariation = 0.03
        confetti.isAffectedByGravity = true
        confetti.orientationMode = .free
        confetti.dampingFactor = 0.6
        confetti.particleColor = UIColor(red: 0.95, green: 0.6, blue: 0.5, alpha: 1)
        confetti.particleColorVariation = SCNVector4(1, 1, 1, 0)

        let sparks = SCNParticleSystem()
        sparks.particleImage = ProceduralTextures.softParticle
        sparks.birthRate = 400
        sparks.emissionDuration = 0.25
        sparks.loops = false
        sparks.particleLifeSpan = 1.0
        sparks.particleVelocity = 3
        sparks.particleVelocityVariation = 1.5
        sparks.emittingDirection = SCNVector3(0, 1, 0)
        sparks.spreadingAngle = 80
        sparks.particleSize = 0.12
        sparks.blendMode = .additive
        sparks.particleColor = UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1)

        let n = SCNNode()
        n.simdPosition = base
        n.addParticleSystem(confetti)
        n.addParticleSystem(sparks)
        worldNode.addChildNode(n)
        n.runAction(.sequence([.wait(duration: 4), .removeFromParentNode()]))

        let ring = SCNTorus(ringRadius: 0.15, pipeRadius: 0.018)
        let rm = SCNMaterial()
        rm.lightingModel = .constant
        rm.diffuse.contents = UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 1)
        rm.blendMode = .add
        ring.materials = [rm]
        let rn = SCNNode(geometry: ring)
        rn.simdPosition = base
        rn.castsShadow = false
        worldNode.addChildNode(rn)
        rn.runAction(.sequence([.group([.scale(to: 14, duration: 0.9), .fadeOut(duration: 0.9)]), .removeFromParentNode()]))

        // Flag wiggle
        if let pivot = flagPivot {
            let w = SCNAction.sequence([.rotateBy(x: 0, y: 0.35, z: 0, duration: 0.08), .rotateBy(x: 0, y: -0.7, z: 0, duration: 0.16),
                                        .rotateBy(x: 0, y: 0.35, z: 0, duration: 0.08)])
            pivot.runAction(.repeat(w, count: 4))
        }
    }

    // MARK: - Ball control

    func placeBall(at p: SIMD2<Double>) {
        phase = .rest
        ballNode.removeAllActions()
        ballNode.opacity = 1
        ballNode.scale = SCNVector3(1, 1, 1)
        pos = SIMD3<Double>(p.x, layout.height(at: p), p.y)
        vel = .zero
        lastLie = pos
        syncBallNode()
        refreshBallOnGreen()
        refreshAim()
    }

    func dropAtLastLie() {
        placeBall(at: SIMD2<Double>(lastLie.x, lastLie.z))
        setCameraState(.address, snap: false)
    }

    func prepareNextShot() {
        guard phase == .rest else { return }
        refreshBallOnGreen()
        refreshAim()
        setCameraState(.address, snap: false)
    }

    /// Picks the ball up (max strokes reached).
    func pickUpBall() {
        phase = .holed
        setTrail(false)
        ballNode.runAction(.group([.move(by: SCNVector3(0, 1.4, 0), duration: 0.6), .fadeOut(duration: 0.6)]))
        audio.play(.pickup)
    }

    var ballPosition2D: SIMD2<Double> { SIMD2<Double>(pos.x, pos.z) }
    var ballTerrain: TerrainType { layout.terrain(at: ballPosition2D) }
    var distanceToPinYards: Double { simd_length(layout.pin - ballPosition2D) / HoleLayout.yd }
    var elevationToPinYards: Double { (layout.height(at: layout.pin) - pos.y) / HoleLayout.yd }

    private func syncBallNode() {
        ballNode.simdPosition = SIMD3<Float>(Float(pos.x), Float(pos.y) + Self.ballVisualRadius, Float(pos.z))
    }

    private func refreshAim() {
        guard layout != nil else { return }
        let p = ballPosition2D
        let proj = layout.project(p)
        var target = layout.pin
        if abs(layout.hole.dogleg) > 0.25 && proj.s < layout.seg0Len - 25 { target = layout.bend }
        var d = target - p
        if simd_length(d) < 0.01 { d = layout.dir1 }
        d = simd_normalize(d)
        let base = atan2(d.x, -d.y)
        let assistActive = puttAssist && putting && ballOnGreen
        let heading = base + (assistActive ? 0 : aimOffsetDegrees) * .pi / 180
        aimDir = SIMD3<Double>(sin(heading), 0, -cos(heading))
        aimHeadingDegrees = heading * 180 / .pi
        if phase == .rest { chaseDir = aimDir }
    }

    func launch(_ m: SwingMetrics, club: Club) {
        guard phase == .rest else { return }
        let v = m.ballSpeedMPH * 0.44704
        var headingDeg = aimHeadingDegrees + m.azimuthDeg
        assistedPutt = false
        if club.isPutter && puttAssist && ballOnGreen {
            // Putting assist: the line to the cup is automatic - only the force matters.
            let d = layout.pin - ballPosition2D
            headingDeg = atan2(d.x, -d.y) * 180 / .pi
            assistedPutt = true
        }
        let heading = headingDeg * .pi / 180
        let la = m.launchAngleDeg * .pi / 180
        let horiz = v * cos(la)
        vel = SIMD3<Double>(sin(heading) * horiz, v * sin(la), -cos(heading) * horiz)
        spinRPM = m.spinRPM
        sideSpinRPM = -m.azimuthDeg * 50
        shotOrigin = pos
        lastLie = pos
        flightTime = 0
        rollTime = 0
        firstLanding = nil
        lastCollisionSound = 0
        chaseDir = SIMD3<Double>(sin(heading), 0, -cos(heading))
        if club.isPutter {
            phase = .rolling
            vel.y = 0
            audio.play(.impact, volume: 0.45)
        } else {
            phase = .flight
            pos.y += 0.02
            setTrail(true)
            audio.play(.impact)
            // The gallery reacts to a good strike
            let strength = Float(min(1, max(0.25, v / 60)))
            audio.play(.cheerSmall, volume: 0.3 + 0.5 * strength, delay: 0.45)
        }
        impactBurst(at: pos, terrain: ballTerrain, intensity: v / 60)
        setCameraState(.flight, snap: false)
    }

    // MARK: - Camera

    func setCameraState(_ s: CameraState, snap: Bool) {
        cameraState = s
        snapCamera = snap
        if s == .overview { overviewT = 0 }
        if s == .celebrate { celebrateT = 0 }
    }

    func playFlyover() {
        guard phase == .rest else { return }
        setCameraState(.overview, snap: true)
    }

    /// Slides the camera towards the ball until no tree / rock is in the way.
    private func clearOfObstacles(_ p: inout SIMD3<Double>, towards target: SIMD3<Double>) {
        for _ in 0..<10 {
            var blocked = false
            for c in colliders {
                let dx = p.x - c.x, dz = p.z - c.z
                let r = c.radius(atY: p.y) + 0.9
                if p.y >= c.baseY && p.y <= c.top + 0.5 && dx * dx + dz * dz < r * r { blocked = true; break }
            }
            if !blocked { return }
            var d = target - p
            d.y = 0
            let len = simd_length(d)
            if len < 1.2 { p.y += 1.5; return }
            p += simd_normalize(d) * 1.1
            p.y += 0.25
        }
    }

    private func updateCamera(dt: Double) {
        guard layout != nil else { return }
        var desiredPos = camPos
        var desiredLook = lookPos
        var rate = 3.0
        let ballP = pos + SIMD3<Double>(0, 0.05, 0)

        switch cameraState {
        case .address:
            let back = putting ? 2.6 : 6.0
            let up = putting ? 1.0 : 2.4
            desiredPos = ballP - aimDir * back + SIMD3<Double>(0, up, 0)
            clearOfObstacles(&desiredPos, towards: ballP)
            let ahead = putting ? min(14, max(3, distanceToPinYards * HoleLayout.yd)) : 45
            desiredLook = ballP + aimDir * ahead + SIMD3<Double>(0, putting ? -0.1 : 1.5, 0)
            rate = 2.4
        case .flight:
            let h = SIMD3<Double>(vel.x, 0, vel.z)
            if simd_length(h) > 0.5 {
                let t = simd_normalize(h)
                chaseDir = simd_normalize(chaseDir + (t - chaseDir) * 0.06)
            }
            let back = phase == .flight ? 14.0 : 8.0
            let up = phase == .flight ? 5.5 : 2.8
            desiredPos = ballP - chaseDir * back + SIMD3<Double>(0, up, 0)
            clearOfObstacles(&desiredPos, towards: ballP)
            desiredLook = ballP + vel * 0.12
            rate = 4.0
        case .overview:
            overviewT += 1.0 / 60.0 / overviewDuration
            let t = min(1, overviewT)
            let e = t * t * (3 - 2 * t)
            let total = layout.totalLength
            let s = -20 + (total + 20) * e
            let cp = layout.world(s: s - 45, l: 24 * (1 - e) + 10)
            let ground = layout.height(at: cp)
            desiredPos = SIMD3<Double>(cp.x, ground + 30 - 14 * e, cp.y)
            let lp = layout.world(s: s + 55, l: 0)
            desiredLook = SIMD3<Double>(lp.x, layout.height(at: lp), lp.y)
            rate = 12
            if overviewT >= 1 {
                setCameraState(.address, snap: false)
                onOverviewFinished?()
            }
        case .celebrate:
            celebrateT += dt
            let a = 0.9 + celebrateT * 0.45
            let r = 3.8 - min(1.3, celebrateT * 0.4)
            let pinY = layout.height(at: layout.pin)
            desiredPos = SIMD3<Double>(layout.pin.x + cos(a) * r, pinY + 1.5, layout.pin.y + sin(a) * r)
            desiredLook = SIMD3<Double>(layout.pin.x, pinY + 0.5, layout.pin.y)
            rate = 3
        }

        let gy = layout.height(at: SIMD2<Double>(desiredPos.x, desiredPos.z))
        desiredPos.y = max(desiredPos.y, gy + 1.0)

        if snapCamera {
            camPos = desiredPos
            lookPos = desiredLook
            snapCamera = false
        } else {
            let k = min(1, rate / 60.0)
            camPos += (desiredPos - camPos) * k
            lookPos += (desiredLook - lookPos) * min(1, (rate + 2) / 60.0)
        }
        cameraNode.simdPosition = SIMD3<Float>(camPos)
        lookTarget.simdPosition = SIMD3<Float>(lookPos)
    }

    // MARK: - Frame loop

    fileprivate func tick(_ link: CADisplayLink) {
        guard layout != nil else { return }
        let now = link.timestamp
        if startTimestamp == 0 { startTimestamp = now }
        var dt = lastTimestamp == 0 ? 1.0 / 60 : now - lastTimestamp
        lastTimestamp = now
        dt = min(dt, 1.0 / 20)
        let clock = Float(now - startTimestamp)

        pondMaterial.setValue(NSNumber(value: clock), forKey: "uTime")
        oceanMaterial.setValue(NSNumber(value: clock), forKey: "uTime")

        if phase == .flight || phase == .rolling {
            let n = max(1, Int(ceil(dt / (1.0 / 240))))
            let h = dt / Double(n)
            for _ in 0..<n {
                if phase == .flight { stepFlight(h) } else if phase == .rolling { stepRolling(h) } else { break }
            }
            if phase == .flight || phase == .rolling { syncBallNode() }
            if phase == .flight {
                let right = SIMD3<Float>(Float(-chaseDir.z), 0, Float(chaseDir.x))
                let ang = Float(spinRPM / 60 * 2 * .pi * dt * 0.15)
                ballNode.simdLocalRotate(by: simd_quatf(angle: ang, axis: simd_normalize(right)))
            }
        }
        updateCamera(dt: dt)
        updateArrows(now: now)

        followNode.simdPosition = cameraNode.simdPosition
        sunGlowNode.simdPosition = cameraNode.simdPosition + sunDirection * glowDistance
        if let pivot = flagPivot, phase != .holed {
            let phi = windToHeadingDegrees * .pi / 180
            let flutter = sin(now * 5) * 0.18 * min(1, windSpeedMPH / 10)
            pivot.eulerAngles.y = Float(.pi / 2 - phi + flutter)
        }
    }

    // MARK: - Physics

    /// Bounces the ball off trees / rocks / walls. Returns true if anything was hit.
    @discardableResult
    private func collideWithObstacles() -> Bool {
        var hit = false
        for c in colliders {
            if pos.y < c.baseY - 0.05 || pos.y > c.top { continue }
            let r = c.radius(atY: pos.y) + 0.03
            if r <= 0 { continue }
            let dx = pos.x - c.x, dz = pos.z - c.z
            let d2 = dx * dx + dz * dz
            if d2 >= r * r { continue }
            let d = max(d2.squareRoot(), 1e-4)
            let n = SIMD3<Double>(dx / d, 0, dz / d)
            pos.x = c.x + n.x * r
            pos.z = c.z + n.z * r
            let vn = simd_dot(vel, n)
            if vn < 0 {
                vel -= n * (vn * 1.35)          // reflect with restitution 0.35
                vel *= 0.72
                if vel.y > 0 { vel.y *= 0.8 }
                hit = true
                let speed = abs(vn)
                if speed > 1.5 && flightTime - lastCollisionSound > 0.25 {
                    lastCollisionSound = flightTime
                    audio.play(c.tree ? .treeHit : .thud, volume: Float(min(1, 0.35 + speed / 20)))
                    if c.tree { leafBurst(at: pos) }
                }
            }
        }
        return hit
    }

    /// After the ball stops, make sure it is not sitting inside a trunk / rock.
    private func resolveRestOverlap() {
        for c in colliders {
            let r = c.radius(atY: pos.y + 0.3) + 0.2
            let dx = pos.x - c.x, dz = pos.z - c.z
            let d2 = dx * dx + dz * dz
            if r > 0 && d2 < r * r {
                let d = max(d2.squareRoot(), 1e-4)
                pos.x = c.x + dx / d * r
                pos.z = c.z + dz / d * r
                pos.y = layout.height(at: SIMD2<Double>(pos.x, pos.z))
            }
        }
    }

    private func stepFlight(_ h: Double) {
        let rel = vel - windVector
        let speed = simd_length(rel)
        let k = 0.5 * 1.2 * (Double.pi * 0.02135 * 0.02135) / 0.04593
        let spinNow = spinRPM * exp(-flightTime / 25)
        let w = spinNow * 2 * .pi / 60
        let S = 0.02135 * w / max(speed, 1)
        let cl = min(0.28, 1.4 * S)

        var acc = SIMD3<Double>(0, -9.81, 0)
        acc += rel * (-k * 0.22 * speed)
        if speed > 1 {
            let rh = rel / speed
            var up = SIMD3<Double>(0, 1, 0) - rh * simd_dot(SIMD3<Double>(0, 1, 0), rh)
            let ul = simd_length(up)
            if ul > 1e-6 {
                up /= ul
                acc += up * (k * cl * speed * speed)
            }
            let hh = SIMD3<Double>(rh.x, 0, rh.z)
            let hl = simd_length(hh)
            if hl > 1e-6 && sideSpinRPM != 0 {
                let hn = hh / hl
                let right = SIMD3<Double>(-hn.z, 0, hn.x)
                let sSide = 0.02135 * (sideSpinRPM * 2 * .pi / 60) / max(speed, 1)
                let cs = max(-0.15, min(0.15, 1.2 * sSide))
                acc += right * (k * cs * speed * speed)
            }
        }
        vel += acc * h
        pos += vel * h
        flightTime += h

        collideWithObstacles()

        let p2 = SIMD2<Double>(pos.x, pos.z)
        if !layout.inBounds(p2) || flightTime > 30 || pos.y < -80 {
            finish(holed: false, penalty: "Out of bounds")
            return
        }

        let pr = layout.project(p2)
        let gy = layout.height(at: p2, projection: pr)
        if pos.y <= gy && vel.y <= 0 {
            handleLanding(gy: gy, p2: p2)
        }
    }

    private func handleLanding(gy: Double, p2: SIMD2<Double>) {
        let terr = layout.terrain(at: p2)
        pos.y = gy
        let first = firstLanding == nil
        if first {
            firstLanding = pos
            landingTerrain = terr
        }
        if terr == .water {
            audio.play(.splash)
            impactBurst(at: pos, terrain: .water, intensity: 1.2)
            finish(holed: false, penalty: "Water hazard")
            return
        }
        let n = layout.normal(at: p2)
        let vn = simd_dot(vel, n)
        let impact = -vn
        if vn < 0 {
            let spinNow = spinRPM * exp(-flightTime / 25)
            let retention = terr.tangentialRetention * (1 - min(0.55, spinNow / 18000))
            let vNormal = n * vn
            let vTan = vel - vNormal
            let wetK = weather == .rain ? 0.85 : 1.0
            vel = vTan * retention - vNormal * (terr.restitution * wetK)
            let vol = Float(min(1, 0.3 + impact / 25))
            if terr == .bunker || terr == .waste {
                audio.play(.sand, volume: vol)
            } else if first {
                audio.play(.land, volume: vol)
            } else if impact > 1.5 {
                audio.play(.bounce, volume: vol * 0.8)
            }
            if impact > 2.0 { impactBurst(at: pos, terrain: terr, intensity: impact / 30) }

            let bounceUp = simd_dot(vel, n)
            if bounceUp < 1.0 || terr == .bunker || terr == .waste {
                phase = .rolling
                vel = vel - n * simd_dot(vel, n)
                vel.y = 0
                setTrail(false)
            } else {
                pos.y = gy + 0.01
            }
        }
    }

    private func stepRolling(_ h: Double) {
        rollTime += h
        let p2 = SIMD2<Double>(pos.x, pos.z)
        let terr = layout.terrain(at: p2)
        if terr == .water {
            audio.play(.splash)
            impactBurst(at: pos, terrain: .water, intensity: 0.8)
            finish(holed: false, penalty: "Water hazard")
            return
        }
        if !layout.inBounds(p2) { finish(holed: false, penalty: "Out of bounds"); return }
        let g = 9.81
        let grad = layout.gradient(at: p2)
        var vh = SIMD2<Double>(vel.x, vel.z)
        let ah = assistedPutt ? SIMD2<Double>(0, 0) : grad * (-g)
        let mu = terr.rollingResistance * weather.rollMultiplier
        let decel = mu * g

        let dPin = simd_length(p2 - layout.pin)
        if terr == .green && dPin < 0.09 && simd_length(vh) < 1.7 {
            pos = SIMD3<Double>(layout.pin.x, pos.y, layout.pin.y)
            finish(holed: true, penalty: nil)
            return
        }

        var sp = simd_length(vh)
        if rollTime > 25 || (sp < 0.02 && simd_length(ah) <= decel) {
            vel = .zero
            finish(holed: false, penalty: nil)
            return
        }
        vh += ah * h
        sp = simd_length(vh)
        if sp > 1e-6 {
            let dir = vh / sp
            vh -= dir * decel * h
            if simd_dot(vh, dir) < 0 { vh = .zero }
        }
        vel = SIMD3<Double>(vh.x, 0, vh.y)
        let nx = pos.x + vh.x * h
        let nz = pos.z + vh.y * h
        if assistedPutt && layout.terrain(at: SIMD2<Double>(nx, nz)) != .green {
            // Putting assist: the ball stops at the edge of the green instead of rolling off it.
            vel = .zero
            finish(holed: false, penalty: nil)
            return
        }
        pos.x = nx
        pos.z = nz
        pos.y = layout.height(at: SIMD2<Double>(pos.x, pos.z))
        if collideWithObstacles() {
            pos.y = layout.height(at: SIMD2<Double>(pos.x, pos.z))
        }
    }

    private func finish(holed: Bool, penalty: String?) {
        let wasPutt = phase == .rolling && firstLanding == nil
        setTrail(false)
        if !holed { resolveRestOverlap() }
        assistedPutt = false
        phase = holed ? .holed : .rest
        let landing = firstLanding ?? pos
        let carry = hypot(landing.x - shotOrigin.x, landing.z - shotOrigin.z) / HoleLayout.yd
        let total = hypot(pos.x - shotOrigin.x, pos.z - shotOrigin.z) / HoleLayout.yd
        let p2 = SIMD2<Double>(pos.x, pos.z)
        syncBallNode()

        let finalTerrain = layout.terrain(at: p2)
        refreshBallOnGreen()
        if holed {
            let cupY = Float(layout.height(at: layout.pin)) + 0.02 + Self.ballVisualRadius
            ballNode.removeAllActions()
            let roll = SCNAction.move(to: SCNVector3(Float(layout.pin.x), cupY, Float(layout.pin.y)), duration: 0.12)
            let drop = SCNAction.group([.move(by: SCNVector3(0, -0.22, 0), duration: 0.28),
                                        .scale(to: 0.7, duration: 0.28)])
            drop.timingMode = .easeIn
            ballNode.runAction(.sequence([roll, drop, .fadeOut(duration: 0.12)]))
            celebrationBurst()
            audio.play(.cup)
            audio.play(.sparkle, delay: 0.3)
            audio.play(.cheerBig, delay: 0.4)
            setCameraState(.celebrate, snap: false)
        } else if penalty != nil {
            audio.play(.groan, volume: 0.9, delay: 0.3)
        } else if finalTerrain == .green && !wasPutt {
            audio.play(.applause, volume: 0.55, delay: 0.5)
        }

        let result = ShotResult(carryYards: wasPutt ? total : carry,
                                totalYards: total,
                                landingTerrain: landingTerrain,
                                finalTerrain: finalTerrain,
                                holed: holed,
                                penalty: penalty,
                                distanceToPinYards: simd_length(layout.pin - p2) / HoleLayout.yd,
                                finalPosition: p2)
        onShotFinished?(result)
    }
}

private extension String {
    /// Stable (non-randomised) hash so landscapes are identical on every launch.
    var hashValueStable: Int {
        var h: UInt64 = 1469598103934665603
        for b in utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(truncatingIfNeeded: h & 0x7fffffff)
    }
}

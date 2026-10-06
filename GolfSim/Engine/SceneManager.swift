import SceneKit
import UIKit
import simd
import QuartzCore

enum CameraState { case address, flight, overview }
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

private struct Collider {
    var x: Double
    var z: Double
    var radius: Double
    var top: Double
}

private final class DisplayLinkProxy {
    weak var target: SceneManager?
    init(_ t: SceneManager) { target = t }
    @objc func tick(_ link: CADisplayLink) { target?.tick(link) }
}

/// Procedural SceneKit golf engine: terrain mesh, PBR materials, water, sky, particles,
/// multi-state camera, ball flight / roll physics and audio triggers.
final class SceneManager: NSObject {

    /// Flip to true if the ground texture appears mirrored front-to-back on device.
    static let flipTextureV = false
    static let ballVisualRadius: Float = 0.055
    private static let ballPhysicsRadius = 0.0214

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
    var putting = false
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
    private var windVector = SIMD3<Double>(0, 0, 0)
    private var treeHitPlayed = false
    private var lastLie = SIMD3<Double>(0, 0, 0)
    private var colliders: [Collider] = []

    // Camera state
    private var aimDir = SIMD3<Double>(0, 0, -1)
    private var chaseDir = SIMD3<Double>(0, 0, -1)
    private var camPos = SIMD3<Double>(0, 3, 6)
    private var lookPos = SIMD3<Double>(0, 0, -30)
    private var overviewT = 0.0
    private let overviewDuration = 9.0
    private var snapCamera = true

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

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
        cam.zNear = 0.1
        cam.zFar = 4000
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)

        let constraint = SCNLookAtConstraint(target: lookTarget)
        constraint.isGimbalLockEnabled = true
        cameraNode.constraints = [constraint]
        scene.rootNode.addChildNode(lookTarget)

        // Sun
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

        // Ambient fill
        let amb = SCNLight()
        amb.type = .ambient
        ambientNode.light = amb
        scene.rootNode.addChildNode(ambientNode)

        scene.rootNode.addChildNode(worldNode)
        scene.rootNode.addChildNode(followNode)

        buildBall()
        scene.rootNode.addChildNode(ballNode)

        // Sun glow sprite (kept inside the fog start distance so it stays visible)
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

        pondMaterial = makeWaterMaterial(depthFade: true)
        oceanMaterial = makeWaterMaterial(depthFade: false)

        // Animate the shared water normal maps forever
        let animate = SCNAction.repeatForever(.customAction(duration: 40) { [weak self] _, t in
            guard let self = self else { return }
            let k = Float(t / 40)
            self.pondMaterial.normal.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(3, 3, 1), SCNMatrix4MakeTranslation(k * 4, k * 2.5, 0))
            self.oceanMaterial.normal.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(300, 300, 1), SCNMatrix4MakeTranslation(k * 6, k * 3, 0))
        })
        scene.rootNode.runAction(animate)
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

    private func makeWaterMaterial(depthFade: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = course.style.water.uiColor
        m.roughness.contents = 0.08
        m.metalness.contents = 0.0
        m.normal.contents = ProceduralTextures.waterNormalMap
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = 0.9
        m.isDoubleSided = true
        if depthFade {
            m.transparent.contents = ProceduralTextures.pondAlpha
            m.transparencyMode = .aOne
        } else {
            m.transparency = 0.9
        }
        m.shaderModifiers = [.surface: """
        #pragma body
        float3 V = normalize(_surface.view);
        float3 N = normalize(_surface.normal);
        float f = pow(1.0 - saturate(dot(V, N)), 3.0);
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb * 0.55, float3(0.62, 0.78, 0.90), f);
        """]
        return m
    }

    private func pbr(_ c: RGB, roughness: Double = 0.9, metalness: Double = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c.uiColor
        m.roughness.contents = roughness
        m.metalness.contents = metalness
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
        buildFarGround()
        buildHazardVisuals()
        buildFlag()
        buildDecor()
        applyStyle()
        configureParticles()
        placeBall(at: ballAt ?? SIMD2<Double>(0, 0))
        aimOffsetDegrees = 0
        overviewT = 0
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
        scene.fogStartDistance = CGFloat(st.fogStart * weather.fogMultiplier)
        scene.fogEndDistance = CGFloat(st.fogEnd * weather.fogMultiplier)
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

        // Glow only on bright / clear themes
        let showGlow = (course.theme == .coastal || course.theme == .desert || course.theme == .alpine) && gray < 0.4
        sunGlowNode.isHidden = !showGlow
        glowDistance = Float(max(80, st.fogStart * weather.fogMultiplier * 0.92))
        sunGlowNode.simdScale = SIMD3<Float>(repeating: glowDistance * 0.35)
        sunGlowNode.opacity = CGFloat(1 - gray)

        pondMaterial.diffuse.contents = st.water.uiColor
        oceanMaterial.diffuse.contents = st.water.uiColor
    }

    // MARK: - Terrain

    private func buildTerrain() {
        let L = layout!
        let b = L.bounds(margin: 120)
        let cell = 2.5
        let nx = Int(ceil(b.width / cell)) + 1
        let nz = Int(ceil(b.height / cell)) + 1
        let farY = farGroundY()

        var heights = [Float](repeating: 0, count: nx * nz)
        for iz in 0..<nz {
            for ix in 0..<nx {
                let x = b.minX + Double(ix) * cell
                let z = b.minZ + Double(iz) * cell
                var h = L.height(at: SIMD2<Double>(x, z))
                let edge = min(min(x - b.minX, b.maxX - x), min(z - b.minZ, b.maxZ - z))
                let k = smoothstep(0, 45, edge)
                h = farY + (h - farY) * k
                heights[iz * nx + ix] = Float(h)
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
        m.normal.intensity = 0.7
        m.normal.contentsTransform = SCNMatrix4MakeScale(Float(b.width / 4), Float(b.height / 4), 1)
        geo.materials = [m]

        let node = SCNNode(geometry: geo)
        node.name = "terrain"
        node.castsShadow = false
        worldNode.addChildNode(node)
    }

    private func farGroundY() -> Double {
        if course.theme == .coastal { return HoleLayout.seaLevel }
        let e = layout.hole.elevationChange * HoleLayout.yd
        return min(0, e) - 2.5
    }

    private func buildFarGround() {
        let plane = SCNPlane(width: 8000, height: 8000)
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        let y = Float(farGroundY())
        node.simdPosition = SIMD3<Float>(Float(layout.green.x * 0.5), y, Float(layout.green.y * 0.5))
        if course.theme == .coastal {
            plane.materials = [oceanMaterial]
        } else {
            plane.materials = [pbr(course.style.rough.scaled(0.8), roughness: 1)]
        }
        node.castsShadow = false
        worldNode.addChildNode(node)
    }

    // MARK: - Hazards and decor

    private func buildHazardVisuals() {
        let L = layout!
        let sand = SCNMaterial()
        _ = sand
        for ph in L.placed {
            switch ph.hazard.kind {
            case .water, .creek:
                let cyl = SCNCylinder(radius: 1, height: 0.02)
                cyl.radialSegmentCount = 56
                cyl.materials = [pondMaterial]
                let node = SCNNode(geometry: cyl)
                let h = L.height(at: ph.center) + ph.depth * 0.55
                node.simdPosition = SIMD3<Float>(Float(ph.center.x), Float(h), Float(ph.center.y))
                node.scale = SCNVector3(Float(ph.b), 1, Float(ph.a))
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

        // Cup
        let cup = SCNCylinder(radius: 0.054, height: 0.012)
        cup.materials = [pbr(RGB(0.02, 0.02, 0.02), roughness: 1)]
        let cupNode = SCNNode(geometry: cup)
        cupNode.simdPosition = SIMD3<Float>(Float(L.pin.x), Float(L.height(at: L.pin)) + 0.004, Float(L.pin.y))
        worldNode.addChildNode(cupNode)

        // Tee markers
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

    private func addRockCluster(at c: SIMD2<Double>, count: Int, spread: Double, scale: Double) {
        var rng = SeededRNG(seed: stableSeed() &+ UInt64(abs(c.x * 10 + c.y)))
        let mat = pbr(rockColor(), roughness: 1)
        mat.normal.contents = ProceduralTextures.sandNormalMap
        mat.normal.wrapS = .repeat; mat.normal.wrapT = .repeat
        for _ in 0..<count {
            let ox = Double.random(in: -spread...spread, using: &rng) * 0.6
            let oz = Double.random(in: -spread...spread, using: &rng) * 0.6
            let p = SIMD2<Double>(c.x + ox, c.y + oz)
            let k = Double.random(in: 0.7...1.3, using: &rng) * scale
            let sph = SCNSphere(radius: 1)
            sph.segmentCount = 14
            sph.materials = [mat]
            let n = SCNNode(geometry: sph)
            let y = layout.height(at: p)
            n.simdPosition = SIMD3<Float>(Float(p.x), Float(y + k * 0.35), Float(p.y))
            n.scale = SCNVector3(Float(k * 1.1), Float(k * 0.8), Float(k))
            n.eulerAngles.y = Float.random(in: 0...6.28, using: &rng)
            worldNode.addChildNode(n)
            colliders.append(Collider(x: p.x, z: p.y, radius: k * 1.0, top: y + k * 1.2))
        }
    }

    private func addWall(_ ph: PlacedHazard) {
        let mat = pbr(RGB(0.52, 0.51, 0.48), roughness: 1)
        mat.normal.contents = ProceduralTextures.sandNormalMap
        mat.normal.wrapS = .repeat; mat.normal.wrapT = .repeat
        let dir = layout.direction(atS: ph.s0)
        let yaw = Float(HoleLayout.yaw(for: dir))
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
            colliders.append(Collider(x: p.x, z: p.y, radius: 1.1, top: y + h))
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
        case .alpine: buildTrees(spruce: true, density: 0.55); buildPeaks()
        case .desert: buildCacti(); buildMesas()
        case .links: buildTrees(spruce: false, density: 0.0)
        case .coastal: break
        }
        // Hazard "trees" clusters on non-forest themes are covered by forest density; nothing else.
    }

    private func makePineProto(spruce: Bool) -> SCNNode {
        let root = SCNNode()
        let trunk = SCNCylinder(radius: 0.28, height: 2.4)
        trunk.materials = [pbr(RGB(0.25, 0.16, 0.09), roughness: 1)]
        let tn = SCNNode(geometry: trunk)
        tn.position = SCNVector3(0, 1.2, 0)
        root.addChildNode(tn)
        let leaf = pbr(spruce ? RGB(0.10, 0.28, 0.18) : RGB(0.09, 0.30, 0.12), roughness: 0.95)
        let tiers: [(Double, Double, Double)] = [(2.6, 4.0, 3.6), (2.0, 3.6, 5.6), (1.3, 3.2, 7.4)]
        for (r, h, y) in tiers {
            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(r), height: CGFloat(h))
            cone.materials = [leaf]
            let n = SCNNode(geometry: cone)
            n.position = SCNVector3(0, Float(y), 0)
            root.addChildNode(n)
        }
        return root.flattenedClone()
    }

    private func buildTrees(spruce: Bool, density: Double) {
        guard density > 0, let L = layout else { return }
        let proto = makePineProto(spruce: spruce)
        var rng = SeededRNG(seed: stableSeed() &+ 31)
        let container = SCNNode()
        var s = -14.0
        while s < L.totalLength + 40 {
            for side in [-1.0, 1.0] {
                for row in 0..<2 {
                    let p0 = (row == 0 ? 0.85 : 0.5) * density
                    if Double.random(in: 0...1, using: &rng) > p0 { continue }
                    let off = L.fairwayHalf + (row == 0 ? Double.random(in: 5...12, using: &rng)
                                                        : Double.random(in: 14...34, using: &rng))
                    let w = L.world(s: s + Double.random(in: -3...3, using: &rng), l: side * off)
                    if L.project(w).dist < L.fairwayHalf + 3 { continue }
                    if L.terrain(at: w) == .water || L.terrain(at: w) == .green { continue }
                    let y = L.height(at: w)
                    let k = Double.random(in: 0.8...1.5, using: &rng)
                    let sy = spruce ? 1.25 : 1.0
                    let sxz = spruce ? 0.8 : 1.0
                    let t = proto.clone()
                    t.simdPosition = SIMD3<Float>(Float(w.x), Float(y), Float(w.y))
                    t.scale = SCNVector3(Float(k * sxz), Float(k * sy), Float(k * sxz))
                    t.eulerAngles.y = Float.random(in: 0...6.28, using: &rng)
                    let amp = CGFloat(Double.random(in: 0.015...0.04, using: &rng))
                    let dur = Double.random(in: 1.6...3.2, using: &rng)
                    let a = SCNAction.rotateBy(x: amp, y: 0, z: amp * 0.6, duration: dur)
                    a.timingMode = .easeInEaseOut
                    t.runAction(.repeatForever(.sequence([a, a.reversed()])))
                    container.addChildNode(t)
                    colliders.append(Collider(x: w.x, z: w.y, radius: 0.9 * k, top: y + 9 * k * sy))
                }
            }
            s += 8
        }
        worldNode.addChildNode(container)
    }

    private func buildCacti() {
        let L = layout!
        var rng = SeededRNG(seed: stableSeed() &+ 77)
        let mat = pbr(RGB(0.22, 0.40, 0.20), roughness: 0.9)
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
        for _ in 0..<90 {
            let s = Double.random(in: -10...(L.totalLength + 30), using: &rng)
            let side: Double = Bool.random(using: &rng) ? 1 : -1
            let w = L.world(s: s, l: side * (L.fairwayHalf + Double.random(in: 8...70, using: &rng)))
            if L.terrain(at: w) != .rough { continue }
            let t = proto.clone()
            let k = Float.random(in: 0.7...1.5, using: &rng)
            t.simdPosition = SIMD3<Float>(Float(w.x), Float(L.height(at: w)), Float(w.y))
            t.scale = SCNVector3(k, k, k)
            t.eulerAngles.y = Float.random(in: 0...6.28, using: &rng)
            worldNode.addChildNode(t)
        }
    }

    private func buildMesas() {
        let L = layout!
        var rng = SeededRNG(seed: stableSeed() &+ 123)
        let mat = pbr(RGB(0.60, 0.27, 0.16), roughness: 1)
        mat.normal.contents = ProceduralTextures.sandNormalMap
        mat.normal.wrapS = .repeat; mat.normal.wrapT = .repeat
        var s = -60.0
        while s < L.totalLength + 200 {
            for side in [-1.0, 1.0] {
                let h = Double.random(in: 25...70, using: &rng)
                let w = Double.random(in: 25...55, using: &rng)
                let p = L.world(s: s, l: side * (L.fairwayHalf + Double.random(in: 120...220, using: &rng)))
                let box = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(w * Double.random(in: 0.8...1.6, using: &rng)), chamferRadius: 2)
                let shade = Double.random(in: 0.85...1.15, using: &rng)
                let m = pbr(RGB(0.60, 0.27, 0.16).scaled(shade), roughness: 1)
                m.normal.contents = ProceduralTextures.sandNormalMap
                m.normal.wrapS = .repeat; m.normal.wrapT = .repeat
                box.materials = [m]
                let n = SCNNode(geometry: box)
                n.simdPosition = SIMD3<Float>(Float(p.x), Float(farGroundY() + h / 2 - 4), Float(p.y))
                n.eulerAngles.y = Float.random(in: 0...3.14, using: &rng)
                worldNode.addChildNode(n)
            }
            s += Double.random(in: 40...60, using: &rng)
        }
        _ = mat
    }

    private func buildPeaks() {
        let L = layout!
        var rng = SeededRNG(seed: stableSeed() &+ 321)
        let rock = pbr(RGB(0.42, 0.43, 0.46), roughness: 1)
        let snow = pbr(RGB(0.96, 0.97, 1.0), roughness: 0.7)
        for i in 0..<9 {
            let ang = Double(i) / 9 * 2 * .pi + Double.random(in: -0.2...0.2, using: &rng)
            let dist = Double.random(in: 520...800, using: &rng)
            let c = L.green * 0.5
            let H = Double.random(in: 180...320, using: &rng)
            let R = H * Double.random(in: 0.7...1.0, using: &rng)
            let base = Float(farGroundY() - 20)
            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(R), height: CGFloat(H)); cone.materials = [rock]
            let n = SCNNode(geometry: cone)
            n.simdPosition = SIMD3<Float>(Float(c.x + sin(ang) * dist), base + Float(H / 2), Float(c.y - cos(ang) * dist))
            worldNode.addChildNode(n)
            let h2 = H * 0.4
            let cap = SCNCone(topRadius: 0, bottomRadius: CGFloat(R * 0.4), height: CGFloat(h2)); cap.materials = [snow]
            let cn = SCNNode(geometry: cap)
            cn.simdPosition = SIMD3<Float>(n.simdPosition.x, base + Float(H - h2 / 2), n.simdPosition.z)
            worldNode.addChildNode(cn)
        }
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
                                             color: UIColor(red: 0.8, green: 0.86, blue: 0.84, alpha: 0.14),
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
        refreshAim()
    }

    func dropAtLastLie() {
        placeBall(at: SIMD2<Double>(lastLie.x, lastLie.z))
        setCameraState(.address, snap: false)
    }

    func prepareNextShot() {
        guard phase == .rest else { return }
        refreshAim()
        setCameraState(.address, snap: false)
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
        let heading = base + aimOffsetDegrees * .pi / 180
        aimDir = SIMD3<Double>(sin(heading), 0, -cos(heading))
        aimHeadingDegrees = heading * 180 / .pi
        if phase == .rest { chaseDir = aimDir }
    }

    func launch(_ m: SwingMetrics, club: Club) {
        guard phase == .rest else { return }
        let v = m.ballSpeedMPH * 0.44704
        let heading = (aimHeadingDegrees + m.azimuthDeg) * .pi / 180
        let la = m.launchAngleDeg * .pi / 180
        let horiz = v * cos(la)
        vel = SIMD3<Double>(sin(heading) * horiz, v * sin(la), -cos(heading) * horiz)
        spinRPM = m.spinRPM
        sideSpinRPM = -m.azimuthDeg * 50
        shotOrigin = pos
        lastLie = pos
        flightTime = 0
        firstLanding = nil
        treeHitPlayed = false
        chaseDir = SIMD3<Double>(sin(heading), 0, -cos(heading))
        if club.isPutter {
            phase = .rolling
            vel.y = 0
        } else {
            phase = .flight
            pos.y += 0.02
            setTrail(true)
        }
        audio.play(.impact)
        impactBurst(at: pos, terrain: ballTerrain, intensity: v / 60)
        setCameraState(.flight, snap: false)
    }

    // MARK: - Camera

    func setCameraState(_ s: CameraState, snap: Bool) {
        cameraState = s
        snapCamera = snap
        if s == .overview { overviewT = 0 }
    }

    func playFlyover() {
        guard phase == .rest else { return }
        setCameraState(.overview, snap: true)
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
        var dt = lastTimestamp == 0 ? 1.0 / 60 : now - lastTimestamp
        lastTimestamp = now
        dt = min(dt, 1.0 / 20)

        if phase == .flight || phase == .rolling {
            let n = max(1, Int(ceil(dt / (1.0 / 240))))
            let h = dt / Double(n)
            for _ in 0..<n {
                if phase == .flight { stepFlight(h) } else if phase == .rolling { stepRolling(h) } else { break }
            }
            syncBallNode()
            if phase == .flight {
                let right = SIMD3<Float>(Float(-chaseDir.z), 0, Float(chaseDir.x))
                let ang = Float(spinRPM / 60 * 2 * .pi * dt * 0.15)
                ballNode.simdLocalRotate(by: simd_quatf(angle: ang, axis: simd_normalize(right)))
            }
        }
        updateCamera(dt: dt)

        followNode.simdPosition = cameraNode.simdPosition
        sunGlowNode.simdPosition = cameraNode.simdPosition + sunDirection * glowDistance
        if let pivot = flagPivot {
            let phi = windToHeadingDegrees * .pi / 180
            let flutter = sin(now * 5) * 0.18 * min(1, windSpeedMPH / 10)
            pivot.eulerAngles.y = Float(.pi / 2 - phi + flutter)
        }
    }

    // MARK: - Physics

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

        // Obstacles
        for c in colliders {
            let dx = pos.x - c.x, dz = pos.z - c.z
            if dx * dx + dz * dz < c.radius * c.radius && pos.y < c.top {
                vel.x *= 0.15; vel.z *= 0.15
                vel.y = min(vel.y, 0) * 0.5
                if !treeHitPlayed { treeHitPlayed = true; audio.play(.thud, volume: 0.8) }
            }
        }

        let p2 = SIMD2<Double>(pos.x, pos.z)
        if !layout.inBounds(p2) || flightTime > 30 || pos.y < -60 {
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
        if firstLanding == nil {
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
            if impact > 2.0 {
                impactBurst(at: pos, terrain: terr, intensity: impact / 30)
                audio.play((terr == .bunker || terr == .waste) ? .sand : .thud, volume: Float(min(1, impact / 25)))
            }
            let bounceUp = simd_dot(vel, n)
            if bounceUp < 1.0 || terr == .bunker || terr == .waste {
                phase = .rolling
                vel = vel - n * simd_dot(vel, n)
                vel.y = 0
                setTrail(false)
            } else {
                pos.y = gy + 0.01
                flightTime += 0
            }
        }
    }

    private func stepRolling(_ h: Double) {
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
        let ah = grad * (-g)
        let mu = terr.rollingResistance * weather.rollMultiplier
        let decel = mu * g

        // Cup capture
        let dPin = simd_length(p2 - layout.pin)
        if terr == .green && dPin < 0.09 && simd_length(vh) < 1.7 {
            pos = SIMD3<Double>(layout.pin.x, pos.y, layout.pin.y)
            finish(holed: true, penalty: nil)
            return
        }

        var sp = simd_length(vh)
        if sp < 0.02 && simd_length(ah) <= decel {
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
        pos.x += vh.x * h
        pos.z += vh.y * h
        pos.y = layout.height(at: SIMD2<Double>(pos.x, pos.z))
    }

    private func finish(holed: Bool, penalty: String?) {
        let wasPutt = phase == .rolling && firstLanding == nil
        phase = holed ? .holed : .rest
        setTrail(false)
        let landing = firstLanding ?? pos
        let carry = hypot(landing.x - shotOrigin.x, landing.z - shotOrigin.z) / HoleLayout.yd
        let total = hypot(pos.x - shotOrigin.x, pos.z - shotOrigin.z) / HoleLayout.yd
        let p2 = SIMD2<Double>(pos.x, pos.z)
        if holed {
            audio.play(.cup)
            ballNode.runAction(.group([.move(by: SCNVector3(0, -0.12, 0), duration: 0.25),
                                       .fadeOut(duration: 0.4)]))
        }
        let result = ShotResult(carryYards: wasPutt ? total : carry,
                                totalYards: total,
                                landingTerrain: landingTerrain,
                                finalTerrain: layout.terrain(at: p2),
                                holed: holed,
                                penalty: penalty,
                                distanceToPinYards: simd_length(layout.pin - p2) / HoleLayout.yd,
                                finalPosition: p2)
        syncBallNode()
        onShotFinished?(result)
    }
}

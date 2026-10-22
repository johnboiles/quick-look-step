import SceneKit
import Cocoa
import Quartz


/// A tiny helper that converts a STEP or VRML file into a ready-to-render
/// `SCNScene`, replicating the same camera and lighting configuration we use in
/// the preview extension so thumbnails and previews look identical before any
/// user interaction.
enum SceneBuilder {
    /// Builds a SceneKit scene containing the geometry loaded from the STEP
    /// (`.step`/`.stp`) or VRML 2.0 (`.wrl`) file at `url`.
    /// - Throws: An `NSError` if the STEP file cannot be parsed by the Rust
    ///           backend, or a `VRMLError` for VRML files.
    static func scene(for url: URL) throws -> SCNScene {
        switch url.pathExtension.lowercased() {
        case "step", "stp":
            return try frame(stepNode(for: url))
        case "wrl":
            return try frame(vrmlNode(for: url))
        default:
            throw NSError(
                domain: "SceneBuilder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported file type \"\(url.pathExtension)\""]
            )
        }
    }

    /// Loads a STEP file through foxtrot into a single-geometry node.
    private static func stepNode(for url: URL) throws -> SCNNode {
        // --- Load via FFI and measure duration ---
        var mesh = MeshSlice()
        let start = CFAbsoluteTimeGetCurrent()
        let ok = url.path.withCString { cPath in
            foxtrot_load_step(cPath, &mesh)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        NSLog("foxtrot_load_step(%@) -> %@ in %.2f ms", url.path, ok ? "OK" : "FAIL", elapsedMs)
        guard ok else {
            throw NSError(
                domain: "SceneBuilder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load STEP file"]
            )
        }
        defer { foxtrot_free_mesh(mesh) }

        // Build SceneKit geometry from the raw buffers.
        let vertexCount = Int(mesh.vert_count)
        let indexCount = Int(mesh.tri_count) * 3

        let vertexData = Data(
            bytes: mesh.verts!,
            count: vertexCount * 3 * MemoryLayout<Float>.size
        )
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )

        var sources = [vertexSource]
        if let normals = mesh.normals {
            let normalData = Data(
                bytes: normals,
                count: vertexCount * 3 * MemoryLayout<Float>.size
            )
            sources.append(SCNGeometrySource(
                data: normalData,
                semantic: .normal,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: 3 * MemoryLayout<Float>.size
            ))
        }

        let indexData = Data(
            bytes: mesh.tris!,
            count: indexCount * MemoryLayout<UInt32>.size
        )
        let geometryElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: Int(mesh.tri_count),
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: sources, elements: [geometryElement])
        geometry.firstMaterial = SCNMaterial()
        geometry.firstMaterial?.lightingModel = .blinn
        geometry.firstMaterial?.diffuse.contents = NSColor.white
        geometry.firstMaterial?.isDoubleSided = true

        return SCNNode(geometry: geometry)
    }

    /// Loads a VRML 2.0 file into a node with one child geometry per distinct
    /// material, so component colours show up. Shapes sharing a material are
    /// merged: KiCad boards have tens of thousands of Shapes but only dozens of
    /// materials, and one node per Shape makes rendering several times slower.
    private static func vrmlNode(for url: URL) throws -> SCNNode {
        let start = CFAbsoluteTimeGetCurrent()
        let vrml = try VRMLParser.parse(url: url)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        NSLog("VRMLParser.parse(%@) -> %d parts, %d triangles in %.2f ms",
              url.path, vrml.parts.count, vrml.triangleCount, elapsedMs)

        var order: [VRMLMaterial?] = []
        var partsByMaterial: [VRMLMaterial?: [VRMLPart]] = [:]
        for part in vrml.parts {
            if partsByMaterial[part.material] == nil { order.append(part.material) }
            partsByMaterial[part.material, default: []].append(part)
        }

        let root = SCNNode()
        for key in order {
            let parts = partsByMaterial[key]!
            var positions: [Float] = []
            var normals: [Float] = []
            var indices: [UInt32] = []
            positions.reserveCapacity(parts.reduce(0) { $0 + $1.positions.count })
            normals.reserveCapacity(positions.capacity)
            indices.reserveCapacity(parts.reduce(0) { $0 + $1.indices.count })
            for part in parts {
                let base = UInt32(positions.count / 3)
                positions.append(contentsOf: part.positions)
                normals.append(contentsOf: part.normals)
                indices.append(contentsOf: part.indices.lazy.map { $0 + base })
            }

            let geometry = SCNGeometry(
                sources: [
                    floatSource(positions, semantic: .vertex),
                    floatSource(normals, semantic: .normal),
                ],
                elements: [
                    SCNGeometryElement(
                        data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
                        primitiveType: .triangles,
                        primitiveCount: indices.count / 3,
                        bytesPerIndex: MemoryLayout<UInt32>.size
                    ),
                ]
            )
            geometry.firstMaterial = material(for: key)
            root.addChildNode(SCNNode(geometry: geometry))
        }
        return root
    }

    private static func floatSource(_ values: [Float], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        SCNGeometrySource(
            data: values.withUnsafeBufferPointer { Data(buffer: $0) },
            semantic: semantic,
            vectorCount: values.count / 3,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )
    }

    private static func material(for vrml: VRMLMaterial?) -> SCNMaterial {
        func color(_ c: SIMD3<Float>) -> NSColor {
            NSColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        }
        let material = SCNMaterial()
        material.lightingModel = .blinn
        // KiCad models don't have consistent winding.
        material.isDoubleSided = true
        guard let vrml else {
            material.diffuse.contents = NSColor.white
            return material
        }
        material.diffuse.contents = color(vrml.diffuse)
        material.specular.contents = color(vrml.specular)
        material.emission.contents = color(vrml.emissive)
        // VRML97 maps shininess [0, 1] to a Blinn exponent of shininess × 128.
        material.shininess = CGFloat(max(1, vrml.shininess * 128))
        if vrml.transparency > 0 {
            material.transparency = CGFloat(1 - vrml.transparency)
            material.transparencyMode = .dualLayer
        }
        return material
    }

    /// Centres and scales `node`, then adds the camera and lights shared by
    /// the preview and the thumbnail.
    private static func frame(_ node: SCNNode) throws -> SCNScene {
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)

        // --- Scale & centre geometry ---
        let (minBounds, maxBounds) = node.boundingBox
        let size = SCNVector3(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )

        // Uniformly scale so the largest dimension maps to `targetSize` units.
        let targetSize: CGFloat = 100.0
        let maxExtent = max(size.x, max(size.y, size.z))
        guard maxExtent > 0, maxExtent.isFinite else {
            throw NSError(
                domain: "SceneBuilder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "File contains no geometry with a visible extent"]
            )
        }
        let scaleFactor = targetSize / maxExtent
        let sf = Float(scaleFactor)
        node.scale = SCNVector3(sf, sf, sf)

        // Re-centre so model origin is at (0,0,0)
        let center = SCNVector3(
            (maxBounds.x + minBounds.x) / 2.0,
            (maxBounds.y + minBounds.y) / 2.0,
            (maxBounds.z + minBounds.z) / 2.0
        )
        node.position = SCNVector3(Float(-center.x * scaleFactor),
                                   Float(-center.y * scaleFactor),
                                   Float(-center.z * scaleFactor))

        // --- Camera setup ---
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 45
        cameraNode.camera = camera

        // Place camera so the entire bounding sphere fits inside the view.
        let sx = Float(size.x), sy = Float(size.y), sz = Float(size.z)
        let radius = (sqrt(sx*sx + sy*sy + sz*sz) / 2.0) * sf
        let fovRadians = (Float(camera.fieldOfView) / 2.0) * (.pi / 180.0)
        let distance = radius / tanf(fovRadians)

        // Use a diagonal viewing direction for depth.
        cameraNode.position = SCNVector3(distance, distance, distance)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // --- Lighting ---
        func makeOmni(intensity: CGFloat, position: SCNVector3) -> SCNNode {
            let lightNode = SCNNode()
            lightNode.light = SCNLight()
            lightNode.light?.type = .omni
            lightNode.light?.intensity = intensity
            lightNode.position = position
            return lightNode
        }
        scene.rootNode.addChildNode(makeOmni(intensity: 850, position: cameraNode.position))
        scene.rootNode.addChildNode(makeOmni(intensity: 700, position: SCNVector3(0, 0, -targetSize * 2)))

        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.color = NSColor(white: 1, alpha: 1)
        ambientNode.light?.intensity = 300
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }
} 

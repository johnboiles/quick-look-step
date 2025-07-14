import SceneKit
import Cocoa
import Quartz


/// A tiny helper that converts a STEP file into a ready-to-render `SCNScene`,
/// replicating the same camera and lighting configuration we use in the preview
/// extension so thumbnails and previews look identical before any user
/// interaction.
enum SceneBuilder {
    /// Builds a SceneKit scene containing the geometry loaded from the STEP
    /// file at `url`.
    /// - Throws: An `NSError` if the STEP file cannot be parsed by the Rust
    ///           backend.
    static func scene(for url: URL) throws -> SCNScene {
        // Load mesh data through the Rust FFI.
        var mesh = MeshSlice()
        let ok = url.path.withCString { cPath in
            foxtrot_load_step(cPath, &mesh)
        }
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

        let geometry = SCNGeometry(sources: [vertexSource], elements: [geometryElement])
        geometry.firstMaterial = SCNMaterial()
        geometry.firstMaterial?.lightingModel = .blinn
        geometry.firstMaterial?.diffuse.contents = NSColor.white
        geometry.firstMaterial?.isDoubleSided = true

        // Assemble the scene graph.
        let scene = SCNScene()
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        // --- Normalise size & centre the model ---
        let (minBounds, maxBounds) = node.boundingBox
        let size = SCNVector3(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )
        let maxExtent = max(size.x, max(size.y, size.z))
        let targetSize: Float = 100.0
        let scaleFactor = CGFloat(targetSize) / CGFloat(maxExtent)
        let sf = Float(scaleFactor)
        node.scale = SCNVector3(sf, sf, sf)

        let center = SCNVector3(
            (maxBounds.x + minBounds.x) / 2.0,
            (maxBounds.y + minBounds.y) / 2.0,
            (maxBounds.z + minBounds.z) / 2.0
        )
        node.position = SCNVector3(
            CGFloat(-center.x) * scaleFactor,
            CGFloat(-center.y) * scaleFactor,
            CGFloat(-center.z) * scaleFactor
        )

        // --- Camera setup ---
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 45
        cameraNode.camera = camera

        let cameraDistance = targetSize
        cameraNode.position = SCNVector3(cameraDistance, cameraDistance * 0.5, cameraDistance)
        cameraNode.look(at: SCNVector3(0, 0, 0))
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

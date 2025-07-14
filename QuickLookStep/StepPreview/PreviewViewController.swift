//
//  PreviewViewController.swift
//  StepPreview
//
//  Created by John Boiles on 7/14/25.
//

import Cocoa
import Quartz
import SceneKit

class PreviewViewController: NSViewController, QLPreviewingController {

    @IBOutlet var scnView: SCNView!
    
    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    override func loadView() {
        super.loadView()
        scnView.allowsCameraControl = true
        scnView.backgroundColor = .clear
        scnView.autoenablesDefaultLighting = true
    }

    /*
    func preparePreviewOfSearchableItem(identifier: String, queryString: String?) async throws {
        // Implement this method and set QLSupportsSearchableItems to YES in the Info.plist of the extension if you support CoreSpotlight.

        // Perform any setup necessary in order to prepare the view.
        // Quick Look will display a loading spinner until this returns.
    }
    */

    func preparePreviewOfFile(at url: URL) async throws {
        // Create an empty MeshSlice struct to receive pointers from Rust
        var mesh = MeshSlice()

        let ok = url.path.withCString { cPath in
            foxtrot_load_step(cPath, &mesh)
        }

        guard ok else {
            throw NSError(domain: "STEPPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load STEP file"])
        }

        // At this point, mesh.verts is a pointer to [Float], length = vert_count * 3
        let count = Int(mesh.vert_count)
        print("Loaded \(count) vertices")

        let floatCount = count * 3

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

        // Add geometry to scene
        let scene = SCNScene()
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        // Normalize scale and find center position
        let (min, maxv) = node.boundingBox
        let size = SCNVector3(
            maxv.x - min.x,
            maxv.y - min.y,
            maxv.z - min.z
        )
        let maxExtent = max(size.x, max(size.y, size.z))
        let targetSize: Float = 100.0  // You can tweak this (100 units = ~1 screen unit)
        let scaleFactor = CGFloat(targetSize) / maxExtent
        node.scale = SCNVector3(scaleFactor, scaleFactor, scaleFactor)

        // Center model
        let center = SCNVector3(
            (maxv.x + min.x) / 2,
            (maxv.y + min.y) / 2,
            (maxv.z + min.z) / 2
        )
        node.position = SCNVector3(-center.x * scaleFactor,
                                   -center.y * scaleFactor,
                                   -center.z * scaleFactor)
        
        // Add camera and light
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 45
        cameraNode.camera = camera
        // Position the camera above and to the side to give a more useful default perspective (similar to the built-in STL Quick Look)
        let cameraDistance = targetSize
        cameraNode.position = SCNVector3(cameraDistance, cameraDistance * 0.5, cameraDistance)
        // Make sure the camera is aimed at the center of the scene (origin)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .omni
        lightNode.light?.intensity = 850
        lightNode.position = cameraNode.position
        scene.rootNode.addChildNode(lightNode)

        let lightNode2 = SCNNode()
        lightNode2.light = SCNLight()
        lightNode2.light?.type = .omni
        lightNode2.light?.intensity = 700
        lightNode2.position = SCNVector3(0, 0, -targetSize * 2)
        scene.rootNode.addChildNode(lightNode2)

        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light!.type  = .ambient
        ambientNode.light!.color = NSColor(white: 1, alpha: 1.0) // raise/lower to taste
        ambientNode.light!.intensity = 300
        scene.rootNode.addChildNode(ambientNode)

        scnView.scene = scene

        foxtrot_free_mesh(mesh)
    }

}

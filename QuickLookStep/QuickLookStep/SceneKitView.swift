import SwiftUI
import SceneKit
import Metal

/// A simple SwiftUI wrapper around `SCNView` so we can embed SceneKit or Model I/O
/// content inside a SwiftUI hierarchy.
struct SceneKitView: NSViewRepresentable {
    /// The scene to show.  When this changes, the view updates.
    var scene: SCNScene?

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoresizingMask = [.width, .height]
        scnView.backgroundColor = .clear
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling4X
        scnView.autoenablesDefaultLighting = false // we set lighting in the scene builder
        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.scene = scene
        nsView.pointOfView = scene?.rootNode.childNode(withName: "camera", recursively: true)
    }
} 
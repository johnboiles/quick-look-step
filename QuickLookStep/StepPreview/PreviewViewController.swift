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
        // Use an opaque background color to avoid transparent composite rendering failures on macOS 26+
        scnView.backgroundColor = SceneBuilder.viewportBackgroundColor
        scnView.autoenablesDefaultLighting = false

        addVersionWatermark()
    }

    /*
    func preparePreviewOfSearchableItem(identifier: String, queryString: String?) async throws {
        // Implement this method and set QLSupportsSearchableItems to YES in the Info.plist of the extension if you support CoreSpotlight.

        // Perform any setup necessary in order to prepare the view.
        // Quick Look will display a loading spinner until this returns.
    }
    */

    func preparePreviewOfFile(at url: URL) async throws {
        // Build the scene using our shared helper so that the preview and
        // thumbnail use identical geometry, camera, and lighting.
        let scene = try SceneBuilder.scene(for: url)
        await MainActor.run {
            scnView.scene = scene
            if let camera = scene.rootNode.childNode(withName: "camera", recursively: true) {
                scnView.pointOfView = camera
            }
            scnView.needsDisplay = true
        }
    }

    private func addVersionWatermark() {
        let label = NSTextField(labelWithString: versionString())
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.2)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
    }

    private func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "QuickLookStep.app v\(version) (\(build))"
    }

}

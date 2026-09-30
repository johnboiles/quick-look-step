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
        scnView.backgroundColor = NSColor.systemTeal
        scnView.autoenablesDefaultLighting = true

        addVersionWatermark()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let scene = try SceneBuilder.scene(for: url)
        scnView.scene = scene
        scnView.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = NSColor.systemTeal
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

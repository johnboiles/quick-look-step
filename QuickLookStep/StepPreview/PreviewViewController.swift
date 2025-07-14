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
        // Build the scene using our shared helper so that the preview and
        // thumbnail use identical geometry, camera, and lighting.
        let scene = try SceneBuilder.scene(for: url)
        scnView.scene = scene
    }

}

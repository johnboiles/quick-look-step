//
//  ThumbnailProvider.swift
//  StepThumbnail
//
//  Created by John Boiles on 7/14/25.
//

import QuickLookThumbnailing
import SceneKit
import Cocoa
import Metal

class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // We perform heavy work off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Build the scene using the shared helper.
                let scene = try SceneBuilder.scene(for: request.fileURL)

                // Set up an off-screen SceneKit renderer.
                let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                renderer.scene = scene
                renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)

                let pointSize = request.maximumSize
                let scale = CGFloat(request.scale)
                let pixelSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)

                let t0 = CFAbsoluteTimeGetCurrent()
                let image = renderer.snapshot(atTime: 0, with: pixelSize, antialiasingMode: .multisampling4X)
                let snapshotMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                NSLog("renderer.snapshot finished in %.2f ms", snapshotMs)

                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw NSError(domain: "ThumbnailProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage from snapshot"])
                }

                let reply = QLThumbnailReply(contextSize: pointSize, drawing: { ctx -> Bool in
                    ctx.draw(cgImage, in: CGRect(origin: .zero, size: pixelSize))
                    return true
                })

                handler(reply, nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}

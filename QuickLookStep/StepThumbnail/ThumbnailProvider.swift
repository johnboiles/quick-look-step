//
//  ThumbnailProvider.swift
//  StepThumbnail
//
//  Created by John Boiles on 7/14/25.
//

import QuickLookThumbnailing

class ThumbnailProvider: QLThumbnailProvider {
    
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        
        // There are three ways to provide a thumbnail through a QLThumbnailReply. Only one of them should be used.
        
        // First way: Draw the thumbnail into the current context, set up with UIKit's coordinate system.
        handler(QLThumbnailReply(contextSize: request.maximumSize, currentContextDrawing: { () -> Bool in
            // Draw the thumbnail here.
            
            // Return true if the thumbnail was successfully drawn inside this block.
            return true
        }), nil)
        
        /*
        
        // Second way: Draw the thumbnail into a context passed to your block, set up with Core Graphics's coordinate system.
        handler(QLThumbnailReply(contextSize: request.maximumSize, drawing: { (context) -> Bool in
            // Draw the thumbnail here.
         
            // Return true if the thumbnail was successfully drawn inside this block.
            return true
        }), nil)
         
        // Third way: Set an image file URL.
        handler(QLThumbnailReply(imageFileURL: Bundle.main.url(forResource: "fileThumbnail", withExtension: "jpg")!), nil)
        
        */
        
        // GPT's code
//        // Reuse exactly the same Rust → SceneKit pipeline,
//        // but render off‑screen at request.maximumSize:
//        let reply = QLThumbnailReply(contextSize: request.maximumSize) { ctx in
//            // scene.snapshot() is Metal‑backed and GPU quick.
//            let image = scnView.snapshot()
//            image.draw(in: CGRect(origin: .zero, size: request.maximumSize))
//            return true
//        }
//        handler(reply, nil)
//        return Progress(totalUnitCount: 1)
    }
}

// PersonPhoto — the one photo of the user's own person Suno Try-on dresses.
// The photo never leaves the Mac except as bytes of the multipart body to the
// local sidecar (which forwards it to the hosted gateway for one generation
// and keeps nothing), so it is stored like a preference, not like a document:
// a single JPEG in Application Support, named, owned, and wiped by the app.
//
// Presence of the file IS the feature switch — there is no preference. Saving
// a photo enables Try-on; removing it disables the setup card and the flow's
// photo requirement together.

import AppKit

enum PersonPhoto {
    /// The stored photo, resized so the upload stays small and the generation
    /// prompt sees a sane subject crop. 1024 on the long edge is plenty for a
    /// 1K-sized generation.
    static let fileURL: URL = {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SunoFlow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("person.jpg")
    }()

    /// Whether a person photo is on file — the Try-on switch.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Load the stored photo, if any.
    static func load() -> NSImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }

    /// The stored photo as JPEG bytes ready for the multipart upload, if any.
    static func loadJPEG() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    /// Store a picked image: downscaled to 1024 on the long edge, re-encoded
    /// JPEG 0.85. The file on disk is always upload-ready, so the client reads
    /// it straight off disk.
    static func save(_ image: NSImage) -> Bool {
        // NSBitmapImageRep has no scaling API; the CGImage/CGContext path is
        // the same one ScreenShot.downscale uses.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }

        let maxEdge = 1024
        let longest = max(cg.width, cg.height)
        let scaled: CGImage
        if longest > maxEdge {
            let factor = CGFloat(maxEdge) / CGFloat(longest)
            let newW = Int((CGFloat(cg.width) * factor).rounded())
            let newH = Int((CGFloat(cg.height) * factor).rounded())
            guard let ctx = CGContext(
                data: nil, width: newW, height: newH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
            scaled = ctx.makeImage() ?? cg
        } else {
            scaled = cg
        }

        guard let data = NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Remove the stored photo — Try-on goes back to needing setup.
    static func wipe() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// NSImage → JPEG bytes (AppKit has no `jpegData(quality:)`; that is the
    /// UIKit API). Shared by the show/save paths in AnswerFlow.
    static func jpegData(_ image: NSImage, quality: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
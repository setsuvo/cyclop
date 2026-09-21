import Foundation
import ImageIO

/// Reads image metadata before AppKit is allowed to decode pixels. Encoded
/// byte limits alone do not stop a tiny compression bomb from allocating a
/// very large bitmap.
enum ImagePolicy {
    static func dimensionsAreSafe(width: Int, height: Int, maxPixels: Int) -> Bool {
        width > 0 && height > 0 && maxPixels > 0 && width <= maxPixels / height
    }

    static func accepts(_ data: Data, maxBytes: Int, maxPixels: Int, maxFrames: Int = 100) -> Bool {
        guard !data.isEmpty, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= maxFrames else { return false }

        var remainingPixels = maxPixels
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  dimensionsAreSafe(width: width, height: height, maxPixels: maxPixels) else { return false }
            let pixels = width * height
            guard pixels <= remainingPixels else { return false }
            remainingPixels -= pixels
        }
        return true
    }
}

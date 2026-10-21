import CoreGraphics
import Foundation

/// An overlay cannot acknowledge text hidden behind its video surface.
public enum ReadVisibilityPolicy {
    public static func readable(row: CGRect, viewport: CGRect, occlusions: [CGRect]) -> Bool {
        guard row.maxY > viewport.minY, row.maxY <= viewport.maxY, row.intersects(viewport) else { return false }
        return !occlusions.contains { !$0.isEmpty && $0.intersects(row.intersection(viewport)) }
    }
}

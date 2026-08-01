//
//  FrameOrientation.swift
//  Converting a UIKit image orientation into the one Vision wants.
//
//  Kept here, keyed on the raw value, so it is testable without UIKit — the mapping is a known
//  trap and deserves tests more than it deserves to live next to its caller.
//
//  The two enums disagree on raw values:
//
//      UIImage.Orientation   up=0 down=1 left=2 right=3 upM=4 downM=5 leftM=6 rightM=7
//      CGImagePropertyOr.    up=1 upM=2  down=3 downM=4 leftM=5 right=6 rightM=7 left=8
//
//  `CGImagePropertyOrientation(rawValue: ui.rawValue)` therefore compiles, runs, and is wrong for
//  every value. It shows up as "the barcode just doesn't scan sometimes", which is close to
//  undiagnosable from the outside.
//

#if canImport(CoreGraphics)

import CoreGraphics
import ImageIO

public extension CGImagePropertyOrientation {

    /// Maps a `UIImage.Orientation` raw value. Takes the raw value rather than the type so this
    /// stays testable on platforms without UIKit.
    ///
    /// Unknown values fall back to `.up` rather than trapping — an unexpected orientation should
    /// degrade a single frame, not stop a live camera loop.
    static func fromUIImageOrientation(rawValue: Int) -> CGImagePropertyOrientation {
        switch rawValue {
        case 0: return .up
        case 1: return .down
        case 2: return .left
        case 3: return .right
        case 4: return .upMirrored
        case 5: return .downMirrored
        case 6: return .leftMirrored
        case 7: return .rightMirrored
        default: return .up
        }
    }
}

/// A camera frame together with which way up it actually is.
///
/// The orientation travels WITH the image because separating them is how it gets lost: a frame
/// handed around as a bare `CGImage` silently becomes an upright one.
public struct CapturedFrame: Sendable {
    public let image: CGImage
    public let orientation: CGImagePropertyOrientation

    public init(image: CGImage, orientation: CGImagePropertyOrientation = .up) {
        self.image = image
        self.orientation = orientation
    }
}

#endif

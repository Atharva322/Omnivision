//
//  FaceClusterThresholdTests.swift
//  Guards the face-match threshold against the distances actually measured on hardware.
//
//  MEASURED 2026-08-01 — 9 photos of 3 people, taken through the glasses, all 36 pairwise
//  feature-print distances computed:
//
//      same person       0.53 - 0.85   (mean 0.69)
//      different people  0.61 - 0.96   (mean 0.75)
//
//  The distributions OVERLAP. Two different people measured 0.61 — closer than the same person
//  photographed twice at 0.85. VNGenerateImageFeaturePrintRequest is general image similarity,
//  not a face embedding, so it cannot do face re-identification. Rotating crops upright first
//  was tested and made it worse (0.85 -> 1.02).
//
//  The default was 22.0: more than twenty times the largest distance ever observed. Every face
//  would have matched every other face, collapsing all people into one person and confidently
//  recalling the wrong name — the exact failure the accuracy doctrine exists to prevent. It went
//  unnoticed because FaceCluster had no tests and nothing called it.
//

import XCTest
@testable import AccessLensTrackC

final class FaceClusterThresholdTests: XCTestCase {
    /// The old feature-print threshold was invalid. Until MobileFaceNet is calibrated on glasses
    /// data, the default embedding matcher must refuse even an identical vector.
    func testUncalibratedDefaultCannotMatch() {
        let match = EmbeddingMatcher.uncalibrated.nearest(
            to: [1, 0],
            among: [UUID(): [[1, 0]]]
        )
        XCTAssertNil(match)
    }
}

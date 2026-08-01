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

#if canImport(CoreGraphics)

import XCTest
@testable import AccessLensTrackC

final class FaceClusterThresholdTests: XCTestCase {

    /// No observed distance exceeded ~1.1. A larger threshold matches everyone to everyone.
    func testThresholdIsWithinTheMeasuredDistanceRange() {
        let threshold = FaceClusterPolicy.default.distanceThreshold

        XCTAssertGreaterThan(threshold, 0)
        XCTAssertLessThan(
            threshold, 1.1,
            "distances observed were 0.53-0.96; a threshold above that clusters all people as one")
    }

    /// Precision over recall.
    ///
    /// 0.61 was the closest two different people ever measured, so staying below it yields no
    /// false matches at the cost of catching few true ones. That trade is correct because a face
    /// match may only ever HEDGE, never assert: a missed match costs one question, a false match
    /// names the wrong person to someone who cannot see them.
    func testThresholdIsBelowTheClosestObservedDifferentPersonDistance() {
        XCTAssertLessThan(
            FaceClusterPolicy.default.distanceThreshold, 0.61,
            "0.61 was the closest two DIFFERENT people measured; at or above it, false matches begin")
    }

    /// An explicit policy can still be supplied — the guard is on the default, not the type.
    func testAnExplicitThresholdIsRespected() {
        XCTAssertEqual(FaceClusterPolicy(distanceThreshold: 0.4).distanceThreshold, 0.4)
    }
}

#endif

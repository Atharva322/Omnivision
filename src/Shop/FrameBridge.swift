//
// FrameBridge.swift
// Track B — DAT camera frames to an AsyncStream the shop path can consume.
//
// iOS ONLY.
//
// The SDK delivers frames through a callback publisher and hands back a token that must be held
// for the subscription to stay alive. This wraps that in an AsyncStream so consumers can use
// `for await` and so the token's lifetime is tied to the stream rather than to whatever view
// happened to create it — a dropped token stops frames silently, with no error anywhere.
//

#if os(iOS)

import CoreGraphics
import Foundation
import UIKit
import AccessLensTrackC

enum FrameBridge {

    /// Bridges a DAT video-frame publisher into `AsyncStream<CapturedFrame>`.
    ///
    /// - Parameter listen: the SDK's subscribe call. Injected rather than referenced directly so
    ///   this file does not import MWDATCamera, which keeps it usable with MockDeviceKit and with
    ///   a plain phone-camera source.
    /// - Returns: the stream, plus a cancel closure the caller must call on teardown.
    static func stream(
        listen: @escaping (@escaping (UIImage) -> Void) -> Any
    ) -> (frames: AsyncStream<CapturedFrame>, cancel: () -> Void) {

        var token: Any?
        var continuation: AsyncStream<CapturedFrame>.Continuation!

        // Bounded, dropping oldest. Frames arrive faster than Vision drains them, and an
        // unbounded stream would grow without limit. Dropping is also correct on the merits: a
        // stale frame is worthless because the wearer has already moved the package.
        let stream = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(2)) { c in
            continuation = c
        }

        token = listen { uiImage in
            guard let cgImage = uiImage.cgImage else { return }
            continuation.yield(
                CapturedFrame(
                    image: cgImage,
                    // Carried, never assumed. UIImage.Orientation and CGImagePropertyOrientation
                    // disagree on raw values, so this goes through the tested mapping.
                    orientation: .fromUIImageOrientation(
                        rawValue: uiImage.imageOrientation.rawValue)
                )
            )
        }

        let cancel: () -> Void = {
            continuation.finish()
            token = nil
        }
        return (stream, cancel)
    }
}

#endif

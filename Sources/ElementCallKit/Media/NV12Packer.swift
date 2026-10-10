//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreMedia
import CoreVideo
import Foundation

/// Turns an I420 frame into an NV12 `CMSampleBuffer` for `AVSampleBufferDisplayLayer`; the inverse of
/// `I420Repacker`. Buffers come from a pool keyed on the frame size, and the format description is
/// reused while the size is stable.
@available(iOS 18, *)
final nonisolated class NV12Packer: @unchecked Sendable {
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var formatDescription: CMVideoFormatDescription?
    
    func makeSampleBuffer(from frame: MatrixRTCVideoFrame) -> CMSampleBuffer? {
        guard let pixelBuffer = makePixelBuffer(width: frame.width, height: frame.height) else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let packed = frame.withPlanes { y, u, v -> Bool in
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return false }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            
            for row in 0..<y.height {
                memcpy(yBase + row * yStride, y.pointer + row * y.stride, y.width)
            }
            for row in 0..<u.height {
                let uRow = (u.pointer + row * u.stride).assumingMemoryBound(to: UInt8.self)
                let vRow = (v.pointer + row * v.stride).assumingMemoryBound(to: UInt8.self)
                let uvRow = (uvBase + row * uvStride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<u.width {
                    uvRow[column * 2] = uRow[column]
                    uvRow[column * 2 + 1] = vRow[column]
                }
            }
            return true
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard packed else { return nil }
        
        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            formatDescription = description
        }
        guard let formatDescription else { return nil }
        
        // No timebase: the layer shows each sample as soon as it arrives.
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil,
                                                              imageBuffer: pixelBuffer,
                                                              formatDescription: formatDescription,
                                                              sampleTiming: &timing,
                                                              sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }
        
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
    
    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
            formatDescription = nil
        }
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        return pixelBuffer
    }
}

//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Accelerate
import CoreVideo
import MatrixRtc

/// Turns the NV12 (`420v`/`420f`) buffers iPhone cameras and ReplayKit produce into the tightly
/// packed I420 planes `captureVideo` takes.
///
/// Rows are copied one by one: a plane's stride may exceed its width, and copying `stride × rows`
/// in one go copies padding as picture, which reads as a frame shearing sideways. Chroma is half
/// resolution **rounded up**.
@available(iOS 18, *)
nonisolated enum I420Repacker {
    struct Planes {
        let width: Int
        let height: Int
        let y: Data
        let u: Data
        let v: Data
        
        var chromaWidth: Int {
            (width + 1) / 2
        }
        
        var chromaHeight: Int {
            (height + 1) / 2
        }
    }
    
    /// - Parameter maxLongEdge: downscale so the longer side does not exceed it (screen share).
    static func repack(_ pixelBuffer: CVPixelBuffer, maxLongEdge: Int? = nil) -> Planes? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            MatrixRTCLog.warning("Unsupported pixel format \(format), expected NV12")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        
        var y = Data(count: width * height)
        var u = Data(count: chromaWidth * chromaHeight)
        var v = Data(count: chromaWidth * chromaHeight)
        
        y.withUnsafeMutableBytes { dest in
            let destination = dest.baseAddress!
            for row in 0..<height {
                memcpy(destination + row * width, yBase + row * yStride, width)
            }
        }
        // NV12 interleaves Cb/Cr; I420 wants them as two planes.
        u.withUnsafeMutableBytes { uDest in
            v.withUnsafeMutableBytes { vDest in
                let uPointer = uDest.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let vPointer = vDest.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for row in 0..<chromaHeight {
                    let source = (uvBase + row * uvStride).assumingMemoryBound(to: UInt8.self)
                    let uRow = uPointer + row * chromaWidth
                    let vRow = vPointer + row * chromaWidth
                    for column in 0..<chromaWidth {
                        uRow[column] = source[column * 2]
                        vRow[column] = source[column * 2 + 1]
                    }
                }
            }
        }
        
        let planes = Planes(width: width, height: height, y: y, u: u, v: v)
        if let maxLongEdge, max(width, height) > maxLongEdge {
            return downscale(planes, maxLongEdge: maxLongEdge)
        }
        return planes
    }
    
    private static func downscale(_ planes: Planes, maxLongEdge: Int) -> Planes {
        let scale = Double(maxLongEdge) / Double(max(planes.width, planes.height))
        // Even dimensions keep chroma subsampling exact.
        let width = max(2, Int(Double(planes.width) * scale) & ~1)
        let height = max(2, Int(Double(planes.height) * scale) & ~1)
        return Planes(width: width,
                      height: height,
                      y: scalePlane(planes.y, from: (planes.width, planes.height), to: (width, height)),
                      u: scalePlane(planes.u, from: (planes.chromaWidth, planes.chromaHeight), to: (width / 2, height / 2)),
                      v: scalePlane(planes.v, from: (planes.chromaWidth, planes.chromaHeight), to: (width / 2, height / 2)))
    }
    
    private static func scalePlane(_ plane: Data, from source: (Int, Int), to destination: (Int, Int)) -> Data {
        var output = Data(count: destination.0 * destination.1)
        var input = plane
        input.withUnsafeMutableBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var sourceBuffer = vImage_Buffer(data: inputBytes.baseAddress, height: vImagePixelCount(source.1), width: vImagePixelCount(source.0), rowBytes: source.0)
                var destinationBuffer = vImage_Buffer(data: outputBytes.baseAddress, height: vImagePixelCount(destination.1), width: vImagePixelCount(destination.0), rowBytes: destination.0)
                vImageScale_Planar8(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        return output
    }
}

@available(iOS 18, *)
nonisolated extension I420Repacker.Planes {
    func ffiFrame(rotation: FfiVideoRotation, timestampUs: Int64) -> FfiVideoFrameData {
        FfiVideoFrameData(width: UInt32(width),
                          height: UInt32(height),
                          rotation: rotation,
                          timestampUs: timestampUs,
                          dataY: y,
                          strideY: UInt32(width),
                          dataU: u,
                          strideU: UInt32(chromaWidth),
                          dataV: v,
                          strideV: UInt32(chromaWidth))
    }
}

//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc

@available(iOS 18, *)
public nonisolated enum MatrixRTCVideoRotation: Int, Sendable {
    case deg0 = 0, deg90 = 90, deg180 = 180, deg270 = 270
    
    init(_ rotation: FfiVideoRotation) {
        switch rotation {
        case .deg0: self = .deg0
        case .deg90: self = .deg90
        case .deg180: self = .deg180
        case .deg270: self = .deg270
        }
    }
}

/// A decoded (or locally captured) I420 frame.
///
/// Remote planes are the core's own memory and stay valid exactly as long as this object is alive:
/// ARC is the reference count, so hold the frame while reading and drop it when done. Rotation is
/// *not* applied to the pixels; the renderer turns the picture upright.
@available(iOS 18, *)
public final nonisolated class MatrixRTCVideoFrame: @unchecked Sendable {
    public struct Plane {
        public let pointer: UnsafeRawPointer
        public let stride: Int
        public let width: Int
        public let height: Int
    }
    
    public let width: Int
    public let height: Int
    public let rotation: MatrixRTCVideoRotation
    public let timestampUs: Int64
    /// The self view mirrors the front camera; remote frames never are.
    public let isMirrored: Bool
    
    private enum Storage {
        case remote(VideoFrameRef)
        case local(I420Repacker.Planes)
    }
    
    private let storage: Storage
    
    init(ref: VideoFrameRef) {
        storage = .remote(ref)
        width = Int(ref.width())
        height = Int(ref.height())
        rotation = .init(ref.rotation())
        timestampUs = ref.timestampUs()
        isMirrored = false
    }
    
    init(planes: I420Repacker.Planes, rotation: MatrixRTCVideoRotation, isMirrored: Bool) {
        storage = .local(planes)
        width = planes.width
        height = planes.height
        self.rotation = rotation
        timestampUs = 0
        self.isMirrored = isMirrored
    }
    
    /// Width / height once rotated upright.
    public var uprightAspect: CGFloat {
        let rotated = rotation == .deg90 || rotation == .deg270
        return CGFloat(rotated ? height : width) / CGFloat(max(1, rotated ? width : height))
    }
    
    /// Reads the three planes; the pointers are valid only inside `body`.
    public func withPlanes<T>(_ body: (_ y: Plane, _ u: Plane, _ v: Plane) throws -> T) rethrows -> T {
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        switch storage {
        case .remote(let ref):
            let y = Plane(pointer: UnsafeRawPointer(bitPattern: UInt(ref.planePtr(plane: .y)))!, stride: Int(ref.stride(plane: .y)), width: width, height: height)
            let u = Plane(pointer: UnsafeRawPointer(bitPattern: UInt(ref.planePtr(plane: .u)))!, stride: Int(ref.stride(plane: .u)), width: chromaWidth, height: chromaHeight)
            let v = Plane(pointer: UnsafeRawPointer(bitPattern: UInt(ref.planePtr(plane: .v)))!, stride: Int(ref.stride(plane: .v)), width: chromaWidth, height: chromaHeight)
            return try body(y, u, v)
        case .local(let planes):
            return try planes.y.withUnsafeBytes { yBytes in
                try planes.u.withUnsafeBytes { uBytes in
                    try planes.v.withUnsafeBytes { vBytes in
                        try body(Plane(pointer: yBytes.baseAddress!, stride: width, width: width, height: height),
                                 Plane(pointer: uBytes.baseAddress!, stride: chromaWidth, width: chromaWidth, height: chromaHeight),
                                 Plane(pointer: vBytes.baseAddress!, stride: chromaWidth, width: chromaWidth, height: chromaHeight))
                    }
                }
            }
        }
    }
}

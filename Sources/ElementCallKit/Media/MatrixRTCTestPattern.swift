//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// A generated picture, so a surface can be looked at without a call behind it.
///
/// Shipped in the product rather than the test target, for the same reason the port fakes are: the
/// example harness runs on it. Until this existed, everything the renderer does — fitting against
/// filling, zoom, pan, and the shape of the picture through a resize — could only be seen by joining
/// a real call, which is precisely where looking closely is hardest.
///
/// Colour bars with a heavy border, because the questions it has to answer are geometric: a border
/// that runs off the edges is a crop, a border with black beside it is a letterbox, and a border
/// that changes thickness partway through a move is the picture being stretched rather than redrawn.
/// The bar that sweeps down it says the stream is live rather than a still.
@available(iOS 18, *)
public nonisolated enum MatrixRTCTestPattern {
    /// BT.601 limited range, which is what the renderer's shader decodes.
    private struct Colour {
        let y: UInt8
        let u: UInt8
        let v: UInt8
    }
    
    private static let bars = [
        Colour(y: 235, u: 128, v: 128), // white
        Colour(y: 210, u: 16, v: 146), // yellow
        Colour(y: 170, u: 166, v: 16), // cyan
        Colour(y: 145, u: 54, v: 34), // green
        Colour(y: 106, u: 202, v: 222), // magenta
        Colour(y: 81, u: 90, v: 240), // red
        Colour(y: 41, u: 240, v: 110), // blue
        Colour(y: 16, u: 128, v: 128) // black
    ]
    
    /// Mid grey, which is deliberately not one of the bars. White would merge with the white bar
    /// beside it, leaving no way to tell where the border ends and the picture begins — which is the
    /// one thing this is here to show.
    private static let border = Colour(y: 128, u: 128, v: 128)
    /// The band that sweeps down the picture, inside the border.
    private static let sweep = Colour(y: 235, u: 128, v: 128)
    private static let borderFraction = 0.04
    
    /// One frame. `phase` moves the sweeping bar; pass a rising integer to make it move.
    ///
    /// Built a row at a time from three templates rather than a pixel at a time, because a pixel at
    /// a time is a million bounds-checked writes per frame per tile per tick, which on a phone made
    /// the harness stutter far worse than anything it was built to show. The pattern is columns plus
    /// a border plus one sweeping band, so there are only ever three distinct rows in it.
    public static func frame(width: Int,
                             height: Int,
                             phase: Int = 0,
                             rotation: MatrixRTCVideoRotation = .deg0,
                             isMirrored: Bool = false) -> MatrixRTCVideoFrame {
        let width = max(2, width)
        let height = max(2, height)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        // The bars divide what the border leaves *exactly*, and the remainder goes to the border.
        // Split the other way round, 640 less two 14-pixel borders is 612, which is not a multiple
        // of eight: the bars came out 76 and 77 wide and the picture was a ruler with uneven marks.
        let margin = Int(Double(min(width, height)) * borderFraction)
        let barWidth = max(1, (width - 2 * margin) / bars.count)
        let inset = max(0, (width - barWidth * bars.count) / 2)
        let sweepTop = phase % max(1, height)
        let sweepThickness = max(2, height / 40)
        
        // Three rows: through the bars, all border, and the sweeping band. The bars are divided
        // across what the border leaves, not across the whole width, so that every one of them is
        // the same size. Drawn over the full width instead, the border ate the end bar and hid
        // itself against the white one, and bar width is the measure the picture is read with.
        let inner = barWidth * bars.count
        var barsY = [UInt8](repeating: 0, count: width)
        var barsU = [UInt8](repeating: 0, count: chromaWidth)
        var barsV = [UInt8](repeating: 0, count: chromaWidth)
        var sweepY = [UInt8](repeating: 0, count: width)
        var sweepU = [UInt8](repeating: 0, count: chromaWidth)
        var sweepV = [UInt8](repeating: 0, count: chromaWidth)
        for column in 0..<width {
            let isEdge = column < inset || column >= inset + inner
            let bar = isEdge ? border : bars[min(bars.count - 1, (column - inset) / barWidth)]
            let band = isEdge ? border : sweep
            barsY[column] = bar.y
            sweepY[column] = band.y
            if column % 2 == 0 {
                barsU[column / 2] = bar.u
                barsV[column / 2] = bar.v
                sweepU[column / 2] = band.u
                sweepV[column / 2] = band.v
            }
        }
        let edgeY = [UInt8](repeating: border.y, count: width)
        let edgeU = [UInt8](repeating: border.u, count: chromaWidth)
        let edgeV = [UInt8](repeating: border.v, count: chromaWidth)
        
        // Vertically there is nothing to divide evenly, so the border is simply the margin.
        let verticalInset = min(margin, height / 2)
        var y = Data(capacity: width * height)
        var u = Data(capacity: chromaWidth * chromaHeight)
        var v = Data(capacity: chromaWidth * chromaHeight)
        for row in 0..<height {
            let isEdge = row < verticalInset || row >= height - verticalInset
            let isSweep = row >= sweepTop && row < sweepTop + sweepThickness
            y.append(contentsOf: isEdge ? edgeY : (isSweep ? sweepY : barsY))
            if row % 2 == 0, u.count < chromaWidth * chromaHeight {
                u.append(contentsOf: isEdge ? edgeU : (isSweep ? sweepU : barsU))
                v.append(contentsOf: isEdge ? edgeV : (isSweep ? sweepV : barsV))
            }
        }
        
        return MatrixRTCVideoFrame(planes: I420Repacker.Planes(width: width, height: height, y: y, u: u, v: v),
                                   rotation: rotation,
                                   isMirrored: isMirrored)
    }
}

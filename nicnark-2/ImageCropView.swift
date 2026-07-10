//
//  ImageCropView.swift
//  nicnark-2
//
//  Full-screen square cropper: pan + pinch-zoom an already-picked image inside a fixed square
//  window, then emit the cropped square. Can photos render as circles / rounded squares
//  elsewhere in the app, so a square crop frames them cleanly. Operates entirely on an in-memory
//  UIImage — no photo-library permission needed (selection stays with PhotosPicker/PHPicker).
//

import SwiftUI
import UIKit

struct ImageCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onCrop: (UIImage) -> Void

    // Committed transform (clamped on each gesture end).
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    // Transient gesture deltas.
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            // The square crop window fills the available width (or height, whichever is smaller).
            let side = min(geo.size.width, geo.size.height)
            // baseScale makes the image exactly *fill* the square at scale 1, so the square is
            // always fully covered and every crop is a valid square within the image.
            let base = max(side / image.size.width, side / image.size.height)
            let liveScale = clampedScale(scale * pinch)
            let d = base * liveScale
            let dispW = image.size.width * d
            let dispH = image.size.height * d
            let rawOffset = CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
            let live = clampedOffset(rawOffset, dispW: dispW, dispH: dispH, side: side)

            let magnify = MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    let newScale = clampedScale(scale * value.magnification)
                    scale = newScale
                    let nd = base * newScale
                    offset = clampedOffset(offset,
                                           dispW: image.size.width * nd,
                                           dispH: image.size.height * nd,
                                           side: side)
                }

            let pan = DragGesture()
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let nd = base * scale
                    let moved = CGSize(width: offset.width + value.translation.width,
                                       height: offset.height + value.translation.height)
                    offset = clampedOffset(moved,
                                           dispW: image.size.width * nd,
                                           dispH: image.size.height * nd,
                                           side: side)
                }

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .frame(width: dispW, height: dispH)
                    .offset(live)
                    .frame(width: side, height: side)
                    .clipped()
                    .overlay(
                        Rectangle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1)
                            .frame(width: side, height: side)
                    )
                    .gesture(SimultaneousGesture(magnify, pan))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .top) { topBar(side: side, base: base) }
            .overlay(alignment: .bottom) { hint }
        }
    }

    private func topBar(side: CGFloat, base: CGFloat) -> some View {
        HStack {
            Button("Cancel", action: onCancel)
            Spacer()
            Text("Move and Scale")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Done") { performCrop(side: side, base: base) }
                .fontWeight(.semibold)
        }
        .padding()
        .foregroundStyle(.white)
        .background(.black.opacity(0.45))
    }

    private var hint: some View {
        Text("Pinch to zoom · Drag to reposition")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .padding(.bottom, 24)
    }

    // MARK: - Clamping

    private func clampedScale(_ s: CGFloat) -> CGFloat {
        min(max(s, 1), maxScale)
    }

    private func clampedOffset(_ o: CGSize, dispW: CGFloat, dispH: CGFloat, side: CGFloat) -> CGSize {
        let maxX = max(0, (dispW - side) / 2)
        let maxY = max(0, (dispH - side) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }

    // MARK: - Crop

    /// Maps the square crop window (points) back into image pixels and extracts it. The display
    /// math: a point in the square maps to image points via the total scale `d = base * scale`,
    /// with the image centered then shifted by `offset`.
    private func performCrop(side: CGFloat, base: CGFloat) {
        let d = base * scale
        guard d > 0 else { onCrop(image); return }

        let cropSidePts = side / d
        let cropXPts = image.size.width / 2 - (side / 2 + offset.width) / d
        let cropYPts = image.size.height / 2 - (side / 2 + offset.height) / d

        // Normalize orientation so the CGImage pixel grid matches these point coordinates.
        let normalized = image.normalizedUp()
        guard let cg = normalized.cgImage else { onCrop(image); return }
        let sc = normalized.scale

        var rect = CGRect(x: cropXPts * sc, y: cropYPts * sc,
                          width: cropSidePts * sc, height: cropSidePts * sc).integral

        let maxW = CGFloat(cg.width), maxH = CGFloat(cg.height)
        rect.origin.x = min(max(rect.origin.x, 0), max(0, maxW - 1))
        rect.origin.y = min(max(rect.origin.y, 0), max(0, maxH - 1))
        rect.size.width = min(rect.size.width, maxW - rect.origin.x)
        rect.size.height = min(rect.size.height, maxH - rect.origin.y)

        guard rect.width > 0, rect.height > 0, let cropped = cg.cropping(to: rect) else {
            onCrop(image); return
        }
        onCrop(UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up))
    }
}

private extension UIImage {
    /// Redraws the image with `.up` orientation so its CGImage pixel grid is upright, making
    /// pixel-space crop rectangles straightforward regardless of the source's EXIF orientation.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

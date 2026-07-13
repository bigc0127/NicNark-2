//
//  CanImagePicker.swift
//  nicnark-2
//
//  Reusable control for attaching / cropping / replacing / removing a photo on a can.
//

import SwiftUI
import PhotosUI

struct CanImagePicker: View {
    @Binding var image: UIImage?

    @State private var selection: PhotosPickerItem?
    @State private var cropTarget: CropTarget?

    var body: some View {
        VStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 120)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 30))
                                .foregroundColor(.secondary)
                            Text("No photo yet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
            }

            HStack {
                let hasPhoto = image != nil
                PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                    Label(hasPhoto ? "Replace Photo" : "Choose Photo", systemImage: "photo")
                }

                if let current = image {
                    Spacer()
                    Button {
                        cropTarget = CropTarget(image: current)
                    } label: {
                        Label("Crop", systemImage: "crop")
                    }

                    Spacer()
                    Button(role: .destructive) {
                        image = nil
                        selection = nil
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            .font(.callout)
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            Task {
                let data = try? await newValue.loadTransferable(type: Data.self)
                let downsized: UIImage? = await Task.detached(priority: .userInitiated) {
                    guard let data, let ui = UIImage(data: data) else { return nil }
                    // ≥ store post-crop budget (1000px) with headroom for crop zoom; 1600 was soft.
                    return downscaleUIImage(ui, maxDimension: 3000)
                }.value
                guard let downsized else { return }
                cropTarget = CropTarget(image: downsized)
            }
        }
        .fullScreenCover(item: $cropTarget) { target in
            ImageCropView(
                image: target.image,
                onCancel: { cropTarget = nil },
                onCrop: { cropped in
                    image = cropped
                    cropTarget = nil
                }
            )
        }
    }
}

private struct CropTarget: Identifiable {
    let id = UUID()
    let image: UIImage
}

private nonisolated func downscaleUIImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > maxDimension, longest > 0 else { return image }
    let scale = maxDimension / longest
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: newSize))
    }
}

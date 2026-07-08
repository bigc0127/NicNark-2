//
//  CanImagePicker.swift
//  nicnark-2
//
//  Reusable control for attaching / replacing / removing a photo on a can. It binds an
//  in-memory UIImage; the parent editor persists it via CanImageStore on Save (so a brand-new
//  can — whose UUID doesn't exist until it's created — is handled correctly).
//

import SwiftUI
import PhotosUI

struct CanImagePicker: View {
    /// The currently-chosen image (nil = no photo / removed). Owned by the parent editor.
    @Binding var image: UIImage?

    @State private var selection: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 12) {
            // Preview
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

            // Actions
            HStack {
                PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                    Label(image == nil ? "Choose Photo" : "Replace Photo", systemImage: "photo")
                }

                if image != nil {
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
                // Data is Sendable; the resulting UIImage is only assigned back on the main
                // actor (this view is @MainActor), so nothing non-Sendable crosses a boundary.
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    image = ui
                }
            }
        }
    }
}

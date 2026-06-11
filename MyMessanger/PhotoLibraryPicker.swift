//
//  PhotoLibraryPicker.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 20.03.2026.
//

import SwiftUI
import PhotosUI

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    @Binding var selectedImagesData: [Data]
    @Environment(\.dismiss) private var dismiss
    
    var selectionLimit: Int = 10
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        
        init(_ parent: PhotoLibraryPicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            
            guard !results.isEmpty else { return }
            
            let providers = results.map { $0.itemProvider }
            
            Task.detached(priority: .userInitiated) {
                let loadedData = await withTaskGroup(of: Data?.self, returning: [Data].self) { group in
                    for provider in providers {
                        group.addTask {
                            await Self.loadImageData(from: provider)
                        }
                    }
                    var collected: [Data] = []
                    for await data in group {
                        if let data { collected.append(data) }
                    }
                    return collected
                }
                
                await MainActor.run { [loadedData] in
                    self.parent.selectedImagesData.append(contentsOf: loadedData)
                }
            }
        }
        
        private static func loadImageData(from provider: NSItemProvider) async -> Data? {
            // Prefer loading raw data representation for best quality
            if provider.hasRepresentationConforming(toTypeIdentifier: "public.image") {
                return await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, error in
                        if let data = data {
                            // Передаём оригинальные данные — ImageCompressor обработает
                            // resize и сжатие позже. Двойное пережатие через
                            // UIImage → jpegData убрано (вызывало AlphaPremulLast warning).
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
            return nil
        }
    }
}

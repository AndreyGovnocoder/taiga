//
//  CameraPicker.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 11.03.2026.
//


import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var selectedImagesData: [Data]
    @Environment(\.presentationMode) private var presentationMode
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        
        init(_ parent: CameraPicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            parent.presentationMode.wrappedValue.dismiss()
            
            guard let image = info[.originalImage] as? UIImage else { return }
            
            Task.detached(priority: .userInitiated) {
                // Рисуем через opaque renderer → убираем альфа-канал → нет AlphaPremulLast warning
                let size = image.size
                let format = UIGraphicsImageRendererFormat()
                format.opaque = true
                format.scale = image.scale
                let opaqueImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                if let data = opaqueImage.jpegData(compressionQuality: 0.8) {
                    await MainActor.run {
                        self.parent.selectedImagesData.append(data)
                    }
                }
            }
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}




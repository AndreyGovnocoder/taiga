//
//  AttachmentMenuSheet.swift
//  MyMessanger
//
//  Created by Antigravity AI on 23.03.2026.
//

import SwiftUI

/// Компактный bottom-sheet для выбора типа вложения.
/// Отображается при нажатии на 📎.
struct AttachmentMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let onPhoto: () -> Void
    let onCamera: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            // Кнопки
            HStack(spacing: 24) {
                attachButton(
                    title: "Фото",
                    icon: "photo.on.rectangle.angled",
                    gradient: [Color.blue, Color.cyan]
                ) {
                    dismiss()
                    // Небольшая задержка для dismiss sheet перед показом picker
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onPhoto()
                    }
                }
                
                attachButton(
                    title: "Камера",
                    icon: "camera.fill",
                    gradient: [Color.orange, Color.red]
                ) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onCamera()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            //Spacer()
        }
    }
    
    @ViewBuilder
    private func attachButton(title: String, icon: String, gradient: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

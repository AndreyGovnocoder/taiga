//
//  SelectedPhoto.swift
//  MyMessanger
//
//  Model для выбранного из галереи/камеры фото.
//  Strip preview отображает лёгкий thumbnail, полная Data загружается при отправке.
//

import SwiftUI
import PhotosUI

/// Представляет выбранное пользователем фото с лёгким thumbnail.
/// Полная Data загружается лениво при отправке (для галереи) или хранится сразу (для камеры).
struct SelectedPhoto: Identifiable {
    let id = UUID()
    
    /// Источник: galleryItem для lazy loading полной Data, или rawData для камеры
    let pickerItem: PhotosPickerItem?
    let rawData: Data?  // Для камеры — Data уже готова
    
    /// Thumbnail для strip preview
    var thumbnail: Image?
    
    init(pickerItem: PhotosPickerItem) {
        self.pickerItem = pickerItem
        self.rawData = nil
        self.thumbnail = nil
    }
    
    init(cameraData: Data) {
        self.pickerItem = nil
        self.rawData = cameraData
        if let uiImg = UIImage(data: cameraData) {
            self.thumbnail = Image(uiImage: uiImg)
        }
    }
    
    /// Загрузить полную Data (из галереи — lazy, из камеры — мгновенно)
    func loadFullData() async -> Data? {
        if let rawData { return rawData }
        return try? await pickerItem?.loadTransferable(type: Data.self)
    }
}

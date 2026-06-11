//
//  ChatsSettingsView.swift
//  MyMessanger
//

import SwiftUI

struct ChatsSettingsView: View {
    @State private var showStubAlert = false
    
    var body: some View {
        Form {
            Section {
                Button {
                    showStubAlert = true
                } label: {
                    Label("Экспорт сообщений", systemImage: "square.and.arrow.up")
                }
                
                Button {
                    showStubAlert = true
                } label: {
                    Label("Импорт сообщений", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Резервное копирование")
            } footer: {
                Text("Сообщения хранятся на устройстве. Создайте резервную копию для переноса на другое устройство.")
            }
        }
        .navigationTitle("Чаты")
        .navigationBarTitleDisplayMode(.inline)
        .alert("В разработке", isPresented: $showStubAlert) {
            Button("ОК") {}
        } message: {
            Text("Функция резервного копирования будет доступна в ближайшем обновлении.")
        }
    }
}

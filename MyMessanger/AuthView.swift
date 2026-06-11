//
//  AuthView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//


import SwiftUI

enum AuthMethod {
    case phone
    case email
}

struct AuthView: View {
    
    @Environment(AppRouter.self) var router
    
    @State private var authMethod: AuthMethod = .email
    
    @State private var isLoginMode: Bool = true

    // EULA-гейт регистрации (App Store Guideline 1.2). Тот же ключ читает RootView
    // для уже вошедших пользователей.
    @AppStorage("didAcceptEULA") private var didAcceptEULA: Bool = false
    
    @State private var phoneNumber: String = ""
    // SMS-вход скрыт до реализации серверной отправки кода (см. закомментированные phoneAuthSection/sendSMS/verifyCode ниже):
    // @State private var smsCode: String = ""
    // @State private var isCodeSent: Bool = false
    
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var name: String = ""
    @State private var nickname: String = ""
    @State private var isPhoneValid: Bool = false
    @State private var isNicknameValid: Bool = true
    
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    enum AuthField {
        case name, nickname, phone, email, password, confirmPassword
    }
    
    @FocusState private var focusedField: AuthField?
    
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    
    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    // SMS-вход скрыт до реализации серверной отправки кода (App Store: не показываем нерабочие функции).
                    // Единственный рабочий способ — email; переключатель способа входа убран.

                    Text(headerText)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    
                    emailAuthSection
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    
                    if isLoading {
                        ProgressView()
                            .padding()
                    }
                    
                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(Color.red)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal)
                    }
                    
                    //Spacer()
                }
                .padding(.vertical, 20)
                .padding(.bottom, 60)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: errorMessage)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isPhoneValid)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isNicknameValid)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showPasswordError)
                /*
                 .contentShape(Rectangle())
                 .onTapGesture {
                 hideKeyboard()
                 }
                 */
                
                
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focusedField) { oldValue, newValue in
                if oldValue == .nickname && newValue != .nickname {
                    validateNickname()
                }
                
                if oldValue == .phone && newValue != .phone {
                    validatePhone()
                }
            }
            //.ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: authMethod) { _, _ in errorMessage = nil
            }
        }
    }
    
    private var headerText: String {
        return "Вход по Email"
    }
    
    // SMS-вход скрыт для ревью App Store (нет рабочей серверной отправки кода).
    // Восстановить вместе с requestSMS/verifyCode в SupabaseAuthService, когда появится backend SMS.
    /*
    private var phoneAuthSection: some View {
        VStack(spacing: 16) {
            if !isCodeSent {
                TextField("Номер телефона", text: $phoneNumber)
                    .keyboardType(.phonePad)
                    .submitLabel(.next)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)


                Button(action: sendSMS) {
                    Text("Получить код")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(phoneNumber.count > 10 ? Color.blue : Color.gray)
                        .cornerRadius(12)
                        .foregroundColor(.white)
                }
                .disabled(phoneNumber.count <= 10 || isLoading)

            } else {
                TextField("Код из СМС", text: $smsCode)
                    .keyboardType(.numberPad)
                    .submitLabel(.done)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                Button(action: verifyCode) {
                    Text("Войти")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(smsCode.count == 4 ? Color.blue : Color.gray)
                        .foregroundColor(Color.white)
                        .cornerRadius(12)
                }
                .disabled(smsCode.count != 4 || isLoading)
            }
        }
        .padding(.horizontal)
    }
    */
    
    private var emailAuthSection: some View {
        VStack(spacing: 16) {
            
            Picker("Режим Email", selection: $isLoginMode.animation(.easeInOut)) {
                Text("Вход").tag(true)
                Text("Регистрация").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 8)
            
            if !isLoginMode {
                TextField("Ваше имя", text: $name)
                    .submitLabel(.next)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                TextField("Никнейм (без @)", text: $nickname)
                    .focused($focusedField, equals: .nickname)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(!isNicknameValid ? Color.red : Color.clear, lineWidth: 1)
                    )
                    .onChange(of: nickname) { _, _ in
                        withAnimation {
                            isNicknameValid = true
                        }
                    }
                
                if !isNicknameValid {
                    Text("Этот никнейм уже занят")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.leading, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Номер телефона", text: $phoneNumber)
                        .focused($focusedField, equals: .phone)
                        .keyboardType(.phonePad)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(!isPhoneValid && !phoneNumber.isEmpty ? Color.red : Color.clear, lineWidth: 1)
                        )
                        .onChange(of: phoneNumber) { oldValue, newValue in
                            let formatted = formatPhoneNumber(newValue)
                            
                            if phoneNumber != formatted {
                                if newValue.starts(with: "8") && formatted.starts(with:"+7") {
                                    haptic.impactOccurred()
                                }
                                phoneNumber = formatted
                            }
                            
                            if !isPhoneValid {
                                withAnimation {
                                    isPhoneValid = true
                                }
                            }
                        }
                    
                    if !isPhoneValid && !phoneNumber.isEmpty {
                        Text("Этот номер уже зарегистрирован")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.leading, 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .submitLabel(.next)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            
            SecureField("Пароль", text: $password)
                .submitLabel(.next)
                .onSubmit {
                    hideKeyboard()
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            if !isLoginMode {
                SecureField("Повторите пароль", text: $confirmPassword)
                    .submitLabel(.done)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                if showPasswordError {
                    Text("Пароли не совпадают")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // EULA-гейт регистрации (App Store Guideline 1.2)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $didAcceptEULA) {
                        Text("Я принимаю условия использования")
                            .font(.callout)
                    }
                    NavigationLink {
                        ScrollView {
                            Text(LegalTexts.termsOfUse)
                                .font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle("Условия использования")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Text("Читать условия использования")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 4)
            }


            Button(action: submitEmailAuth) {
                Text(isLoginMode ? "Войти" : "Создать аккаунт")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isValidEmailForm ? Color.blue : Color.gray)
                    .cornerRadius(12)
                    .foregroundColor(Color.white)
            }
            .disabled(!isValidEmailForm || isLoading)
        }
        .padding(.horizontal)
    }
    
    private var isValidEmailForm: Bool {
        let basicValid = email.contains("@") && email.count > 5 && password.count >= 6
        if isLoginMode {
            return basicValid
        } else {
            return basicValid &&
            !name.isEmpty &&
            !nickname.isEmpty && isNicknameValid &&
            cleanPhoneNumber.count >= 11 &&
            password == confirmPassword &&
            isPhoneValid &&
            didAcceptEULA
        }
    }
    
    private var showPasswordError: Bool {
        !password.isEmpty && !confirmPassword.isEmpty && password != confirmPassword
    }
    
    // SMS-вход скрыт для ревью App Store — восстановить вместе с phoneAuthSection, когда появится backend SMS.
    /*
    private func sendSMS() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await router.authService.requestSMS(phoneNumber: phoneNumber)
                await MainActor.run {
                    isCodeSent = true
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Ошибка отправки кода: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func verifyCode() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                _ = try await router.authService.verifyCode(code: smsCode)
                await MainActor.run {
                    router.state = .main
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Неверный код"
                    isLoading = false
                }
            }
        }
    }
    */
    
    private func submitEmailAuth() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                if isLoginMode {
                    _ = try await router.authService.loginWithEmail(email: email, password: password)
                } else {
                    _ = try await router.authService.registerWithEmail(
                        email: email,
                        password: password,
                        name: name,
                        nickname: nickname,
                        phoneNumber: cleanPhoneNumber
                    )
                }
                
                await MainActor.run {
                    router.state = .main
                }
            } catch {
                print("Error: \(error.localizedDescription)")
                let errorText = error.localizedDescription.contains("already registered") ? "Пользователь уже зарегистрирован" : error.localizedDescription
                await MainActor.run {
                    errorMessage = isLoginMode ? "Ошибка, Неверный логин или пароль" : "Ошибка регистрации: \(errorText)"
                    isLoading = false
                }
            }
        }
    }
    
    private func validatePhone() {
        let cleanPhone = cleanPhoneNumber
        
        guard cleanPhone.count >= 11 else {
            withAnimation { isPhoneValid = true }
            return
        }
        
        Task {
            do {
                let exists = try await router.authService.checkUserExists(phoneNumber: cleanPhone)
                
                await MainActor.run {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        self.isPhoneValid = !exists
                    }
                }
            } catch {
                print("СЕРВЕР: Ошибка проверки телефона: \(error.localizedDescription)")
            }
        }
    }
    
    private func validateNickname() {
        let cleanNick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNick.isEmpty else {
            isNicknameValid = true
            return
        }
        
        Task {
            do {
                let exists = try await router.authService.checkNicknameExists(nickname: cleanNick)
                await MainActor.run {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        self.isNicknameValid = !exists
                    }
                }
            } catch {
                print("СЕРВЕР: Ошибка проверки никнейма: \(error)")
            }
        }
    }
    
    private var cleanPhoneNumber: String {
        let digits = phoneNumber.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return digits.isEmpty ? "" : "+\(digits)"
    }
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private func formatPhoneNumber(_ number: String) -> String {
    var digits = number.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    
    guard !digits.isEmpty else { return "" }
    
    if digits.first == "8" {
        digits.removeFirst()
        digits = "7" + digits
    } else if !number.hasPrefix("+") && digits.first == "9" && digits.count == 10 {
        digits = "7" + digits
    }
    
    var formatted = ""
    
    if digits.hasPrefix("7") {
        formatted = "+7"
        digits.removeFirst()
        
        let mask = " (XXX) XXX-XX-XX"
        var maskIndex = mask.startIndex
        var digitIndex = digits.startIndex
        
        while digitIndex < digits.endIndex && maskIndex < mask.endIndex {
            if mask[maskIndex] == "X" {
                formatted.append(digits[digitIndex])
                digitIndex = digits.index(after: digitIndex)
            } else {
                formatted.append(mask[maskIndex])
            }
            maskIndex = mask.index(after: maskIndex)
        }
    } else {
        formatted = "+" + digits
    }
    
    if formatted.hasPrefix("+7") && formatted.count > 18 {
        return String(formatted.prefix(18))
        
    }
    return formatted
}


#Preview {
    AuthView()
        .environment(AppRouter())
}




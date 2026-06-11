//
//  BlurHash.swift
//  MyMessanger
//
//  BlurHash encoder/decoder — compact base83 image placeholder.
//  Based on https://github.com/woltapp/blurhash (MIT License).
//

import UIKit

// MARK: - BlurHash Encoder

/// Все методы помечены `nonisolated` — BlurHash работает с сырыми CGImage/Data,
/// не зависит от UIKit MainActor'а и безопасно вызывается из Task.detached.
enum BlurHash {
    
    /// Кодирует CGImage в BlurHash строку (~20-30 символов).
    /// Принимает CGImage (не UIImage) для совместимости с Swift 6 concurrency.
    nonisolated static func encode(_ cgImage: CGImage, numberOfComponents components: (Int, Int) = (4, 3)) -> String? {
        let pixelWidth = 32 // кодируем из micro-image для скорости
        let pixelHeight = Int(round(Float(pixelWidth) / max(Float(cgImage.width) / Float(cgImage.height), 0.01)))
        
        guard let data = encodePixels(cgImage: cgImage, width: pixelWidth, height: max(pixelHeight, 1)) else {
            return nil
        }
        
        let (numX, numY) = components
        
        var factors: [(Float, Float, Float)] = []
        for j in 0..<numY {
            for i in 0..<numX {
                let factor = multiplyBasis(pixels: data, width: pixelWidth, height: max(pixelHeight, 1), basisX: i, basisY: j)
                factors.append(factor)
            }
        }
        
        let dc = factors.first!
        let ac = Array(factors.dropFirst())
        
        var hash = ""
        
        // Size flag
        let sizeFlag = (numX - 1) + (numY - 1) * 9
        hash += encode83(sizeFlag, length: 1)
        
        // Quantised maximum AC value
        let maximumValue: Float
        if ac.isEmpty {
            maximumValue = 1
            hash += encode83(0, length: 1)
        } else {
            let actualMaximum = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max()!
            let quantisedMaximum = max(0, min(82, Int(floor(actualMaximum * 166 - 0.5))))
            maximumValue = Float(quantisedMaximum + 1) / 166
            hash += encode83(quantisedMaximum, length: 1)
        }
        
        // DC value
        hash += encode83(encodeDC(dc), length: 4)
        
        // AC values
        for factor in ac {
            hash += encode83(encodeAC(factor, maximumValue: maximumValue), length: 2)
        }
        
        return hash
    }
    
    /// Декодирует BlurHash строку в UIImage.
    nonisolated static func decode(_ blurHash: String, width: Int = 32, height: Int = 32, punch: Float = 1) -> UIImage? {
        guard blurHash.count >= 6 else { return nil }
        
        let sizeFlag = decode83(String(blurHash[blurHash.startIndex]))
        let numY = (sizeFlag / 9) + 1
        let numX = (sizeFlag % 9) + 1
        
        let quantisedMaximum = decode83(String(blurHash[blurHash.index(blurHash.startIndex, offsetBy: 1)]))
        let maximumValue = Float(quantisedMaximum + 1) / 166
        
        guard blurHash.count == 4 + 2 * numX * numY else { return nil }
        
        var colors: [(Float, Float, Float)] = []
        
        // DC
        let dcStart = blurHash.index(blurHash.startIndex, offsetBy: 2)
        let dcEnd = blurHash.index(blurHash.startIndex, offsetBy: 6)
        let dcValue = decode83(String(blurHash[dcStart..<dcEnd]))
        colors.append(decodeDC(dcValue))
        
        // AC
        for i in 1..<numX * numY {
            let start = 4 + i * 2
            let acStart = blurHash.index(blurHash.startIndex, offsetBy: start)
            let acEnd = blurHash.index(blurHash.startIndex, offsetBy: start + 2)
            let acValue = decode83(String(blurHash[acStart..<acEnd]))
            colors.append(decodeAC(acValue, maximumValue: maximumValue * punch))
        }
        
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0
                var g: Float = 0
                var b: Float = 0
                
                for j in 0..<numY {
                    for i in 0..<numX {
                        let basis = cos((Float.pi * Float(x) * Float(i)) / Float(width)) *
                                    cos((Float.pi * Float(y) * Float(j)) / Float(height))
                        let color = colors[i + j * numX]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                
                let offset = 4 * x + y * bytesPerRow
                pixels[offset] = UInt8(clamping: Int(linearToSRGB(r) * 255 + 0.5))
                pixels[offset + 1] = UInt8(clamping: Int(linearToSRGB(g) * 255 + 0.5))
                pixels[offset + 2] = UInt8(clamping: Int(linearToSRGB(b) * 255 + 0.5))
                pixels[offset + 3] = 255
            }
        }
        
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Private Helpers

private extension BlurHash {
    
    nonisolated static func encodePixels(cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
    
    nonisolated static func multiplyBasis(pixels: [UInt8], width: Int, height: Int, basisX: Int, basisY: Int) -> (Float, Float, Float) {
        var r: Float = 0
        var g: Float = 0
        var b: Float = 0
        let bytesPerRow = width * 4
        let norm: Float = basisX == 0 && basisY == 0 ? 1 : 2
        
        for y in 0..<height {
            for x in 0..<width {
                let basis = norm *
                    cos((Float.pi * Float(basisX) * Float(x)) / Float(width)) *
                    cos((Float.pi * Float(basisY) * Float(y)) / Float(height))
                let offset = 4 * x + y * bytesPerRow
                r += basis * sRGBToLinear(Float(pixels[offset]) / 255)
                g += basis * sRGBToLinear(Float(pixels[offset + 1]) / 255)
                b += basis * sRGBToLinear(Float(pixels[offset + 2]) / 255)
            }
        }
        
        let scale = 1 / Float(width * height)
        return (r * scale, g * scale, b * scale)
    }
    
    nonisolated static func encodeDC(_ value: (Float, Float, Float)) -> Int {
        let r = linearToSRGB(value.0)
        let g = linearToSRGB(value.1)
        let b = linearToSRGB(value.2)
        return (Int(round(r * 255)) << 16) + (Int(round(g * 255)) << 8) + Int(round(b * 255))
    }
    
    nonisolated static func decodeDC(_ value: Int) -> (Float, Float, Float) {
        let r = Float(value >> 16) / 255
        let g = Float((value >> 8) & 255) / 255
        let b = Float(value & 255) / 255
        return (sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b))
    }
    
    nonisolated static func encodeAC(_ value: (Float, Float, Float), maximumValue: Float) -> Int {
        func quantise(_ v: Float) -> Int {
            return max(0, min(18, Int(floor(signPow(v / maximumValue, 0.5) * 9 + 9.5))))
        }
        return quantise(value.0) * 19 * 19 + quantise(value.1) * 19 + quantise(value.2)
    }
    
    nonisolated static func decodeAC(_ value: Int, maximumValue: Float) -> (Float, Float, Float) {
        let r = Float(value / (19 * 19))
        let g = Float((value / 19) % 19)
        let b = Float(value % 19)
        return (
            signPow((r - 9) / 9, 2) * maximumValue,
            signPow((g - 9) / 9, 2) * maximumValue,
            signPow((b - 9) / 9, 2) * maximumValue
        )
    }
    
    nonisolated static func sRGBToLinear(_ value: Float) -> Float {
        if value <= 0.04045 { return value / 12.92 }
        return pow((value + 0.055) / 1.055, 2.4)
    }
    
    nonisolated static func linearToSRGB(_ value: Float) -> Float {
        let v = max(0, min(1, value))
        if v <= 0.0031308 { return v * 12.92 }
        return 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    
    nonisolated static func signPow(_ value: Float, _ exp: Float) -> Float {
        return copysign(pow(abs(value), exp), value)
    }
}

// MARK: - Base83

extension BlurHash {
    nonisolated static var base83Chars: [Character] {
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".map { $0 }
    }
    
    nonisolated static func pow83(_ exp: Int) -> Int {
        var result = 1
        for _ in 0..<exp { result *= 83 }
        return result
    }
    
    nonisolated static func encode83(_ value: Int, length: Int) -> String {
        let chars = base83Chars
        var result = ""
        for i in 1...length {
            let digit = (value / pow83(length - i)) % 83
            result.append(chars[digit])
        }
        return result
    }
    
    nonisolated static func decode83(_ string: String) -> Int {
        let chars = base83Chars
        var value = 0
        for char in string {
            if let index = chars.firstIndex(of: char) {
                value = value * 83 + chars.distance(from: chars.startIndex, to: index)
            }
        }
        return value
    }
}


// Малює іконку застосунку 1024×1024: swift scripts/make-icon.swift <вихідний.png>
import AppKit
import SwiftUI

let cyan = Color(red: 0.35, green: 0.78, blue: 1.0)
let violet = Color(red: 0.62, green: 0.47, blue: 1.0)
let pink = Color(red: 1.0, green: 0.46, blue: 0.76)

struct AppIcon: View {
    // Ті самі пропорції, що й у смужок у рядку меню
    let heights: [CGFloat] = [0.4, 0.72, 1.0, 0.6, 0.34]
    let barWidth: CGFloat = 82
    let spacing: CGFloat = 46
    let maxHeight: CGFloat = 500

    var body: some View {
        let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous)
        let barsWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing

        ZStack {
            // Сітка іконок macOS: 824×824 у полотні 1024
            ZStack {
                LinearGradient(colors: [Color(red: 0.15, green: 0.15, blue: 0.29), Color(red: 0.03, green: 0.035, blue: 0.08)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [violet.opacity(0.42), .clear], center: .center, startRadius: 0, endRadius: 430)
            }
            .frame(width: 824, height: 824)
            .clipShape(squircle)
            .overlay(squircle.strokeBorder(Color.white.opacity(0.11), lineWidth: 3))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

            LinearGradient(colors: [cyan, violet, pink], startPoint: .leading, endPoint: .trailing)
                .frame(width: barsWidth, height: maxHeight)
                .mask {
                    HStack(spacing: spacing) {
                        ForEach(heights.indices, id: \.self) { i in
                            Capsule().frame(width: barWidth, height: maxHeight * heights[i])
                        }
                    }
                }
                .shadow(color: violet.opacity(0.55), radius: 36)
        }
        .frame(width: 1024, height: 1024)
    }
}

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let ok: Bool = MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { return false }
    return (try? png.write(to: URL(fileURLWithPath: output))) != nil
}
print(ok ? "Іконку збережено: \(output)" : "Не вдалося намалювати іконку")
exit(ok ? 0 : 1)

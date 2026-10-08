import SwiftUI

// MARK: - Otto design tokens
// Brand: River sage #5A8A6B, Cream paper #F5EDDD, Pelt brown #9B7A55,
//        Warm cream #E8D4B0, Wax seal #C8543A, Ink #1A2A1F, Bark #5A4030

enum OttoColor {
    // Canvas / backgrounds
    static let canvas    = Color(hex: "#F5EDDD")
    static let surface   = Color(hex: "#FBF6EA")
    static let surfaceAlt = Color(hex: "#EFE5D0")

    // Text
    static let ink       = Color(hex: "#1A2A1F")
    static let bark      = Color(hex: "#5A4030")
    static let barkSoft  = Color(hex: "#8A6F58")

    // Brand
    static let sage      = Color(hex: "#5A8A6B")
    static let sageDark  = Color(hex: "#456D54")
    static let pelt      = Color(hex: "#9B7A55")
    static let cream     = Color(hex: "#E8D4B0")
    static let wax       = Color(hex: "#C8543A")

    // Lines / chips
    static let line      = Color(hex: "#1A2A1F").opacity(0.10)
    static let lineSoft  = Color(hex: "#1A2A1F").opacity(0.06)
    static let chip      = Color(hex: "#1A2A1F").opacity(0.05)
}

enum OttoFont {
    static func serif(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        var descriptor = UIFontDescriptor(name: "Georgia", size: size)
        var traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight == .bold ? UIFont.Weight.bold : UIFont.Weight.regular]
        if italic {
            let existing = descriptor.symbolicTraits
            descriptor = descriptor.withSymbolicTraits(existing.union(.traitItalic)) ?? descriptor
        }
        return Font(UIFont(descriptor: descriptor, size: size))
    }

    static func serifBold(size: CGFloat) -> Font { serif(size: size, weight: .bold) }
    static func serifBoldItalic(size: CGFloat) -> Font { serif(size: size, weight: .bold, italic: true) }
}

// MARK: - Hex color helper
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Shared UI components

struct OttoPillButton: View {
    let title: String
    var isDestructive: Bool = false
    var isSecondary: Bool = false
    var isFullWidth: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: isFullWidth ? .infinity : nil)
                .padding(.horizontal, isFullWidth ? 22 : 22)
                .padding(.vertical, 14)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(borderColor, lineWidth: isDestructive || isSecondary ? 1 : 0)
                )
        }
    }

    private var background: Color {
        if isDestructive { return .clear }
        if isSecondary { return .clear }
        return OttoColor.sage
    }
    private var foreground: Color {
        if isDestructive { return OttoColor.wax }
        if isSecondary { return OttoColor.ink }
        return .white
    }
    private var borderColor: Color {
        if isDestructive { return OttoColor.wax }
        if isSecondary { return OttoColor.line }
        return .clear
    }
}

struct OttoSectionCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background(OttoColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(OttoColor.lineSoft, lineWidth: 0.5)
            )
    }
}

struct OttoAvatarCircle: View {
    let name: String
    let size: CGFloat
    var hue: Color = OttoColor.sage

    var body: some View {
        Circle()
            .fill(hue.opacity(0.25))
            .frame(width: size, height: size)
            .overlay(
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(hue)
            )
    }
}

struct OttoEyebrow: View {
    let text: String
    var color: Color = OttoColor.barkSoft

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(2)
            .foregroundStyle(color)
    }
}

struct OttoMascot: View {
    enum Pose { case hero, floating, sleeping, friends }
    let pose: Pose
    let width: CGFloat

    var body: some View {
        let (imageName, aspect): (String, CGFloat) = {
            switch pose {
            case .hero:     return ("OttoHero",     484.0/515.0)
            case .floating: return ("OttoFloating",  526.0/352.0)
            case .sleeping: return ("OttoSleeping",  498.0/308.0)
            case .friends:  return ("OttoFriends",   612.0/408.0)
            }
        }()
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width / aspect)
    }
}

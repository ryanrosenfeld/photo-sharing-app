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
    static let barkSoft  = Color(hex: "#6F5844")   // 5.3:1+ on canvas/surface (was #8A6F58, 4.0:1)

    // Brand. sage (3.4:1 on canvas) is for fills and decoration only; use sageDark for text and for fills behind white text.
    static let sage      = Color(hex: "#5A8A6B")
    static let sageDark  = Color(hex: "#456D54")
    static let pelt      = Color(hex: "#9B7A55")
    static let cream     = Color(hex: "#E8D4B0")
    static let wax       = Color(hex: "#A8452C")   // 4.7:1+ as text on canvas (was #C8543A, 3.8:1)

    // Lines / chips
    static let line      = Color(hex: "#1A2A1F").opacity(0.10)
    static let lineSoft  = Color(hex: "#1A2A1F").opacity(0.06)
    static let chip      = Color(hex: "#1A2A1F").opacity(0.05)
}

enum OttoFont {
    /// Georgia that scales with Dynamic Type, relative to the text style closest to `size`.
    static func serif(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let name = weight == .bold
            ? (italic ? "Georgia-BoldItalic" : "Georgia-Bold")
            : (italic ? "Georgia-Italic" : "Georgia")
        return .custom(name, size: size, relativeTo: textStyle(for: size))
    }

    static func serifBold(size: CGFloat) -> Font { serif(size: size, weight: .bold) }
    static func serifBoldItalic(size: CGFloat) -> Font { serif(size: size, weight: .bold, italic: true) }

    /// System font that scales with Dynamic Type. Use instead of `.system(size:)`.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(textStyle(for: size), design: .default, weight: weight)
    }

    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: return .caption2
        case ..<12.5: return .caption
        case ..<13.5: return .footnote
        case ..<15.5: return .subheadline
        case ..<16.5: return .callout
        case ..<18.5: return .body
        case ..<20.5: return .title3
        case ..<24: return .title2
        case ..<30: return .title
        default: return .largeTitle
        }
    }
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

// MARK: - Liquid Glass (iOS 26) with a material fallback for iOS 17-25

extension View {
    /// Liquid Glass on iOS 26+, a thin material elsewhere. Use for controls and floating chrome only, never for content.
    @ViewBuilder
    func ottoGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(OttoColor.lineSoft, lineWidth: 0.5))
        }
    }

    @available(iOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        return interactive ? g.interactive() : g
    }
}

/// Groups nearby glass shapes so they blend and share one sampling pass on iOS 26.
struct OttoGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
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
                .font(.body.weight(.semibold))
                .frame(maxWidth: isFullWidth ? .infinity : nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .modifier(PillStyle(isDestructive: isDestructive, isSecondary: isSecondary))
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    private struct PillStyle: ViewModifier {
        let isDestructive: Bool
        let isSecondary: Bool
        func body(content: Content) -> some View {
            if #available(iOS 26, *) {
                if isDestructive || isSecondary {
                    content.buttonStyle(.glass).tint(isDestructive ? OttoColor.wax : OttoColor.ink)
                } else {
                    content.buttonStyle(.glassProminent).tint(OttoColor.sageDark)
                }
            } else {
                if isDestructive || isSecondary {
                    content.buttonStyle(.bordered).tint(isDestructive ? OttoColor.wax : OttoColor.ink)
                } else {
                    content.buttonStyle(.borderedProminent).tint(OttoColor.sageDark)
                }
            }
        }
    }
}

struct OttoSectionCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background(OttoColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
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
        Text(text)
            .font(.footnote.weight(.semibold))
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

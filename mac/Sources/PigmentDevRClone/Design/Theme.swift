import AppKit
import CoreText
import RCloneKit
import SwiftUI

// MARK: - Brand tokens

enum Brand {
    static let orange = Color(hex: 0xEB5E28)
    static let ink = Color(hex: 0x0B0B0B)
    static let cobalt = Color(hex: 0x2141F5)
    static let yellow = Color(hex: 0xFFC72C)
    static let green = Color(hex: 0x17A673)
    static let paper = Color(hex: 0xF3F4F5)
    static let gray = Color(hex: 0xE1E3E5)
    static let line = Color(hex: 0xC9CDD2)
    static let secondary = Color(hex: 0x4A4F55)
    static let muted = Color(hex: 0x8C9197)
    static let stage = Color(hex: 0x191919)
    static let red = Color(hex: 0xD93B3B)

    static let nsOrange = NSColor(hex: 0xEB5E28)
}

enum Theme {
    static let cardRadius: CGFloat = 24
    static let buttonRadius: CGFloat = 16
    static let pillRadius: CGFloat = 999

    /// Primary text: Ink on light, Paper on dark.
    static let text = Color(light: 0x0B0B0B, dark: 0xF3F4F5)
    static let textSecondary = Color(light: 0x4A4F55, dark: 0xB4B8BD)
    static let textMuted = Color(light: 0x8C9197, dark: 0x8C9197)
    static let hairline = Color(light: 0xC9CDD2, dark: 0x3A3D41)
    static let track = Color(lightA: (0x0B0B0B, 0.07), darkA: (0xFFFFFF, 0.10))
    static let solidCard = Color(light: 0xFFFFFF, dark: 0x232425)
    static let backdrop = Color(light: 0xF3F4F5, dark: 0x191919)

    static func tone(_ t: StateLabel.Tone) -> Color {
        switch t {
        case .neutral: return textMuted
        case .active: return Brand.orange
        case .success: return Brand.green
        case .warning: return Color(light: 0xC98A00, dark: 0xFFC72C)
        case .danger: return Brand.red
        case .paused: return Brand.cobalt
        }
    }
}



// MARK: - Fonts

enum PDFont {
    nonisolated(unsafe) private(set) static var registered = false

    /// Registers the bundled Red Hat OFL fonts for this process. Falls back silently to the system font.
    static func register() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../../../Resources/Fonts").standardized,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts")
        ].compactMap { $0 }
        for dir in candidates {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let fonts = files.filter { $0.pathExtension.lowercased() == "ttf" || $0.pathExtension.lowercased() == "otf" }
            guard !fonts.isEmpty else { continue }
            for url in fonts { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
            registered = NSFont(name: "Red Hat Display", size: 12) != nil || NSFont(name: "RedHatDisplay-Regular", size: 12) != nil
            if registered { return }
        }
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        registered ? .custom("Red Hat Display", size: size).weight(weight) : .system(size: size, weight: weight, design: .default)
    }

    static func text(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font {
        registered ? .custom("Red Hat Text", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat = 10.5, _ weight: Font.Weight = .bold) -> Font {
        registered ? .custom("Red Hat Mono", size: size).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
    }

    static func numbers(_ size: CGFloat = 12, _ weight: Font.Weight = .medium) -> Font {
        text(size, weight).monospacedDigit()
    }
}

// MARK: - Glass

/// The one place Liquid Glass is used. macOS 26+: `.glassEffect`; older or Reduce Transparency: material/solid + hairline.
struct PDGlassModifier<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(Theme.solidCard))
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        } else if #available(macOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .background(shape.fill((tint ?? .clear).opacity(0.10)))
                .overlay(shape.strokeBorder(Color.white.opacity(scheme == .dark ? 0.10 : 0.55), lineWidth: 0.75))
                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.06), radius: 14, y: 6)
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.22)) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func pdGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(PDGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    func pdGlass(radius: CGFloat = Theme.cardRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        pdGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint, interactive: interactive)
    }

    /// Groups glass shapes so they blend/morph on macOS 26.
    @ViewBuilder func pdGlassContainer(spacing: CGFloat = 16) -> some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }

    @ViewBuilder func pdBackgroundExtension() -> some View {
        if #available(macOS 26, *) { self.backgroundExtensionEffect() } else { self }
    }
}

// MARK: - Buttons

struct PDPrimaryButton: ViewModifier {
    var tint: Color = Brand.orange
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent).tint(tint).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
        }
    }
}

struct PDSecondaryButton: ViewModifier {
    var large = true
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass).controlSize(large ? .large : .regular)
        } else {
            content.buttonStyle(.bordered).controlSize(large ? .large : .regular)
        }
    }
}

extension View {
    func pdPrimary(_ tint: Color = Brand.orange) -> some View { modifier(PDPrimaryButton(tint: tint)) }
    func pdSecondary(large: Bool = true) -> some View { modifier(PDSecondaryButton(large: large)) }
}

/// Small round icon button used inside rows.
struct IconButton: View {
    var symbol: String
    var help: String
    var tint: Color = Theme.textSecondary
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover ? Brand.orange : tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.track.opacity(hover ? 1.6 : 1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Components

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pdGlass(radius: Theme.cardRadius, tint: tint)
    }
}

/// Red Hat Mono uppercase label.
struct SectionLabel: View {
    var text: String
    var color: Color = Theme.textMuted
    init(_ text: String, color: Color = Theme.textMuted) { self.text = text; self.color = color }
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(PDFont.mono(10.5))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(PDFont.display(30, .black))
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(PDFont.text(13.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

struct Pill: View {
    var text: String
    var symbol: String? = nil
    var color: Color = Theme.textSecondary
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(PDFont.text(11.5, .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct StatusBadge: View {
    var label: StateLabel
    var body: some View {
        Pill(text: label.title, symbol: label.symbol, color: Theme.tone(label.tone))
            .accessibilityLabel(label.title + (label.detail.map { ", " + $0 } ?? ""))
    }
}

/// Thin capsule progress bar in brand orange.
struct ProgressTrack: View {
    var fraction: Double
    var tint: Color = Brand.orange
    var height: CGFloat = 6
    var indeterminate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geo.size.width * CGFloat(min(1, max(0, fraction)))))
                    .opacity(fraction <= 0 && !indeterminate ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Fmt.percent(fraction * 100))
    }
}

/// Provider glyph in a soft tinted circle.
struct ProviderIcon: View {
    var id: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: providerSymbol(id))
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.14)))
            .overlay(Circle().strokeBorder(color.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    var color: Color {
        switch id {
        case "drive", "gcs": return Brand.green
        case "onedrive", "azureblob", "dropbox", "box": return Brand.cobalt
        case "s3", "b2", "mega": return Brand.orange
        case "pcloud", "protondrive": return Color(hex: 0x7A4FE0)
        case "sftp", "ftp", "webdav", "local": return Theme.textSecondary
        default: return Brand.orange
        }
    }
}

/// Soft, static backdrop that gives the glass something to refract. Drawn once; no animation.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Theme.backdrop
            Canvas { ctx, size in
                let w = size.width, h = size.height
                ctx.addFilter(.blur(radius: min(w, h) * 0.18))
                let o = scheme == .dark ? 0.20 : 0.16
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.55, y: -h * 0.25, width: w * 0.6, height: h * 0.7)), with: .color(Brand.orange.opacity(o)))
                ctx.fill(Path(ellipseIn: CGRect(x: -w * 0.15, y: h * 0.45, width: w * 0.55, height: h * 0.7)), with: .color(Brand.cobalt.opacity(o * 0.7)))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.30, y: h * 0.70, width: w * 0.35, height: h * 0.45)), with: .color(Brand.yellow.opacity(o * 0.55)))
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Brand.orange)
            Text(LocalizedStringKey(title)).font(PDFont.display(18, .heavy)).foregroundStyle(Theme.text)
            Text(LocalizedStringKey(message)).font(PDFont.text(13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
    init(lightA: (UInt32, Double), darkA: (UInt32, Double)) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
                ? NSColor(hex: darkA.0, alpha: darkA.1) : NSColor(hex: lightA.0, alpha: lightA.1)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Label on the leading side, brand-tinted switch on the trailing side (mirrors in RTL).
struct PDSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch).tint(Brand.orange).controlSize(.small)
        }
    }
}

/// Glass capsule tab bar (orange selected pill).
struct GlassTabs<T: Hashable & Identifiable>: View {
    var items: [T]
    @Binding var selection: T
    var title: (T) -> String
    var symbol: ((T) -> String)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { t in
                Button { selection = t } label: {
                    HStack(spacing: 6) {
                        if let symbol { Image(systemName: symbol(t)).font(.system(size: 11.5, weight: .semibold)) }
                        Text(LocalizedStringKey(title(t))).font(PDFont.text(12.5, .semibold))
                    }
                    .foregroundStyle(selection == t ? Color.white : Theme.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(selection == t ? Brand.orange : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == t ? .isSelected : [])
            }
        }
        .padding(5)
        .pdGlass(in: Capsule())
    }
}

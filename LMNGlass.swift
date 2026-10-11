//
//  LMNGlass.swift
//  Lumen
//
//  The parameter half of the Swift engine: everything the alert look is made
//  of lives in a plain object so it can cross the Swift/Objective-C boundary
//  without a C struct, and so the restyler can keep reading `style.cornerRadius`
//  exactly as it did before.
//
//  Objective-C owns the *injection* (walking UIAlertController's private view
//  tree with KVC and class-name matching); Swift owns the *appearance*. The one
//  thing the two share is this file and `LMNGlassPanelView.swift`.
//

import UIKit

/// Every tunable the renderer reads.
///
/// Objective-C sees this as `LMNGlassParams` with the very same property names
/// the old C struct used, which is why moving off the struct needed no changes
/// at the call sites that only read values.
@objc(LMNGlassParams)
public final class LMNGlassParams: NSObject {

    // MARK: - Panel

    @objc public var blurIntensity: CGFloat = 18.0
    @objc public var refractionWidth: CGFloat = 9.0
    @objc public var highlightIntensity: CGFloat = 0.51
    @objc public var tintConcentration: CGFloat = 0.45
    @objc public var cornerRadius: CGFloat = 35.0

    // MARK: - Controls that sit on the glass

    /// Target height of an action capsule. The host lays the row out; the
    /// restyler centres a capsule of this height inside it, so a shorter row
    /// simply yields a shorter capsule rather than clipping.
    ///
    /// Fixed, not preference-backed — see the note on the same pair of values in
    /// `LMNGlassStyle.h`. `current()` assigns the constant rather than reading
    /// the store.
    @objc public var buttonHeight: CGFloat = 48.0

/// Gap between a capsule and the card edge.
    ///
    /// Measured off real screenshots at 3.0 px/pt, not assumed. The reference
    /// iOS 27 sheet puts the card's outer margin at 4.1% of the card width; on a
    /// 393pt phone card that is about 16pt, which is why this constant is 16.0.
    ///
    /// The previous store-backed value read as 0 on a device (nothing ever wrote
    /// it), which is what put the pills flush against the card edge. See the note
    /// on the same pair of values in `LMNGlassStyle.h`.
    @objc public var buttonInset: CGFloat = 16.0

    @objc public var fieldCornerRadius: CGFloat = 14.0
    @objc public var fieldFillAlpha: CGFloat = 0.10
    @objc public var fieldBorderWidth: CGFloat = 1.0

    // MARK: - Capsule material

    /// Which of the three colour schemes the glass is drawn in (1.2.0).
    ///
    /// This is a whole-palette decision, not a tint on top of one: it selects
    /// the veil, the tint, the specular, the blur strength and whether the
    /// card is a dark or a light surface. See `LMNGlassTheme` in
    /// LMNGlassStyle.h for where the three names come from.
    @objc public var theme: LMNGlassTheme = .obsidian

    // MARK: - Entrance

    @objc public var fadeEnabled: Bool = false
    @objc public var fadeDuration: CGFloat = 0.25

    // 1.2.3: which of the three entrance animations plays. An Int rather
    // than a Swift enum so the Objective-C renderer reads it as NSInteger
    // without a bridging cast, and so a stored 0/1/2 means the same thing
    // on both sides.
    @objc public var entrance: Int = 0

    // MARK: - Per-layer colour overrides (1.2.36)
    //
    // 这些是可空的「覆盖色」。非 nil 时，渲染器用它替换对应层的主题派生色；
    // nil（缺键/解析失败）则沿用主题。主题继续当预设，覆盖色叠加其上 —— 老安装
    // 全部缺键，行为与 1.2.35 完全一致，零回归。
    //
    // 卡片层
    @objc public var cardFillColor: UIColor? = nil
    @objc public var cardBorderColor: UIColor? = nil
    /// 0 = 沿用默认 1.5pt（不覆盖描边宽度）
    @objc public var cardBorderWidth: CGFloat = 0.0
    @objc public var cardGlossColor: UIColor? = nil
    // 按钮·主要（蓝）
    @objc public var buttonFillPrimary: UIColor? = nil
    @objc public var buttonBorderPrimary: UIColor? = nil
    @objc public var buttonTextPrimary: UIColor? = nil
    // 按钮·删除（红）
    @objc public var buttonFillDestructive: UIColor? = nil
    @objc public var buttonBorderDestructive: UIColor? = nil
    @objc public var buttonTextDestructive: UIColor? = nil
    // 按钮·次要（中性）
    @objc public var buttonFillSecondary: UIColor? = nil
    @objc public var buttonBorderSecondary: UIColor? = nil
    @objc public var buttonTextSecondary: UIColor? = nil
    // 文字层
    @objc public var titleTextColor: UIColor? = nil
    @objc public var messageTextColor: UIColor? = nil
    // 背景遮罩
    @objc public var scrimColor: UIColor? = nil

    @objc public override init() {
        super.init()
    }

    /// A shallow copy, so the renderer can mutate without touching the caller's
    /// object.
    @objc public func copyParams() -> LMNGlassParams {
        let clone = LMNGlassParams()
        clone.blurIntensity = blurIntensity
        clone.refractionWidth = refractionWidth
        clone.highlightIntensity = highlightIntensity
        clone.tintConcentration = tintConcentration
        clone.cornerRadius = cornerRadius
        clone.buttonHeight = buttonHeight
        clone.buttonInset = buttonInset
        clone.fieldCornerRadius = fieldCornerRadius
        clone.fieldFillAlpha = fieldFillAlpha
        clone.fieldBorderWidth = fieldBorderWidth
        clone.theme = theme
        clone.fadeEnabled = fadeEnabled
        clone.fadeDuration = fadeDuration
        clone.entrance = entrance
        // 1.2.36: 覆盖色（UIColor 不可变，赋值即 retain，无需深拷贝）
        clone.cardFillColor = cardFillColor
        clone.cardBorderColor = cardBorderColor
        clone.cardBorderWidth = cardBorderWidth
        clone.cardGlossColor = cardGlossColor
        clone.buttonFillPrimary = buttonFillPrimary
        clone.buttonBorderPrimary = buttonBorderPrimary
        clone.buttonTextPrimary = buttonTextPrimary
        clone.buttonFillDestructive = buttonFillDestructive
        clone.buttonBorderDestructive = buttonBorderDestructive
        clone.buttonTextDestructive = buttonTextDestructive
        clone.buttonFillSecondary = buttonFillSecondary
        clone.buttonBorderSecondary = buttonBorderSecondary
        clone.buttonTextSecondary = buttonTextSecondary
        clone.titleTextColor = titleTextColor
        clone.messageTextColor = messageTextColor
        clone.scrimColor = scrimColor
        return clone
    }
}

/// Preference keys. Kept spelled out next to the reader so a typo is a compile
/// error rather than a silently ignored setting.
private enum LMNKey {
    static let enabled = "glassEnabled"
    static let blurIntensity = "glassBlurIntensity"
    static let refractionWidth = "glassRefractionWidth"
    static let highlightIntensity = "glassHighlightIntensity"
    static let tintConcentration = "glassTintConcentration"
    static let cornerRadius = "glassCornerRadius"
    static let fieldCornerRadius = "glassFieldCornerRadius"
    static let fieldFillAlpha = "glassFieldFillAlpha"
    static let fieldBorderWidth = "glassFieldBorderWidth"
    // 1.2.0: the theme picker. The key is spelled with the case name equal
    // to the key, which is the rule the gate enforces for the keys it checks.
    static let glassTheme = "glassTheme"
    static let fadeEnabled = "glassFadeEnabled"
    static let fadeDuration = "glassFadeDuration"
    static let entrance = "glassEntrance"
    // 1.2.36: 逐层颜色覆盖键。缺键或解析失败 = nil = 沿用主题。
    static let cardFillColor = "glassCardFill"
    static let cardBorderColor = "glassCardBorder"
    static let cardBorderWidth = "glassCardBorderWidth"
    static let cardGlossColor = "glassCardGloss"
    static let buttonFillPrimary = "glassBtnFillPrimary"
    static let buttonBorderPrimary = "glassBtnBorderPrimary"
    static let buttonTextPrimary = "glassBtnTextPrimary"
    static let buttonFillDestructive = "glassBtnFillDestructive"
    static let buttonBorderDestructive = "glassBtnBorderDestructive"
    static let buttonTextDestructive = "glassBtnTextDestructive"
    static let buttonFillSecondary = "glassBtnFillSecondary"
    static let buttonBorderSecondary = "glassBtnBorderSecondary"
    static let buttonTextSecondary = "glassBtnTextSecondary"
    static let titleTextColor = "glassTitleText"
    static let messageTextColor = "glassMessageText"
    static let scrimColor = "glassScrim"
    // 1.2.34. Not on the settings page, and that is deliberate: the on-screen
    // diagnostics are a developer's tool, not a preference, so there is no row
    // for it and no writer for it. It exists so a device being diagnosed can ask
    // for the banners back; absent, which is every normal install, means OFF.
    static let debugReports = "debugReports"
}

/// The theme the picker writes, as opposed to the palette the renderer draws.
///
/// 1.2.2 splits these apart, and the split is the point. The picker writes
/// 0/1/2 -- those raw values stay the reference package's own, so a value
/// means the same thing in both -- but 2 now means 自动: follow the
/// system's dark mode. A palette is what the renderer actually needs, and
/// 明昼 is only one of the two answers 自动 can give.
///
/// One type for both would let a stored value reach the renderer, which is
/// the same one-name-two-meanings mistake that 平涂 and the tvOS switch
/// were removed for.
enum LMNGlassThemeChoice: Int {
    case obsidian = 0
    case cinema = 1
    case automatic = 2
}

/// The parameter engine.
@objc(LMNGlass)
public final class LMNGlass: NSObject {

    // MARK: - Reading preferences

    /// Reads through CFPreferences rather than `UserDefaults(suiteName:)` on
    /// purpose: the restyle runs inside sandboxed host applications, and
    /// CFPreferences is the API that sees the values a jailbroken settings
    /// bundle wrote from another process -- where it is allowed to.
    ///
    /// 1.2.26: the claim above used to be unconditional, and it is wrong inside
    /// a sandboxed host. The on-screen note exists because that was measured,
    /// not because it was suspected.
    ///
    /// Where the settings bundle's own domain lands on disk.
    ///
    /// Written by the same daemon that CFPreferences reads through, and
    /// world-readable, so it is the one copy of these values a sandboxed host
    /// can still get at. Hardcoded rather than derived: the domain is a
    /// constant either way, and a path built at runtime is a path that can be
    /// built wrong.
    private static let preferencesFilePath =
        "/var/mobile/Library/Preferences/" + LMNPreferenceDomain + ".plist"

    /// The stored value for `key`, or nil when there is not one to be had.
    ///
    /// 1.2.26. CFPreferences first, always -- it is the supported API, it is
    /// what the settings page itself reads through, and it is what answers in
    /// Settings and in SpringBoard. It is NOT what answers inside a sandboxed
    /// host application, which is where this renderer spends its life: there the
    /// daemon declines to hand one process another domain's values, the read
    /// comes back empty, and every caller fell through to its own default.
    /// That is not a hypothetical: the on-screen note exists because it
    /// happened, and what it said was `store=unreadable` in a process whose
    /// settings page showed 自动 the whole time.
    ///
    /// The file is the fallback, not the replacement. It is read only when the
    /// daemon said no, so the supported path stays the fast path and the
    /// supported path stays the one that wins.
    private static func storedValue(_ key: String) -> Any? {
        if let value = CFPreferencesCopyAppValue(key as CFString,
                                                LMNPreferenceDomain as CFString) {
            return value
        }
        guard let contents = NSDictionary(contentsOfFile: preferencesFilePath),
              let stored = contents[key] else {
            return nil
        }
        return stored
    }

    /// Both storage shapes are real: this page writes an NSNumber, while a
    /// stock PSSegmentCell -- or a plist edited by hand -- writes the string
    /// "2". Treating a string as unreadable is how a perfectly good setting
    /// used to arrive as its own default.
    private static func storedNumber(_ key: String) -> Double? {
        guard let value = storedValue(key) else { return nil }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
        guard let value = storedNumber(key) else { return fallback }
        return CGFloat(value)
    }

    private static func flag(_ key: String, _ fallback: Bool) -> Bool {
        guard let value = storedNumber(key) else { return fallback }
        return value != 0.0
    }

    /// 1.2.36: read a stored colour override. Accepts "#RRGGBB" or "#RRGGBBAA"
    /// (the leading '#' is optional). Absent or unparseable -> nil, which means
    /// "follow the theme" for that layer.
    private static func storedColor(_ key: String) -> UIColor? {
        guard let value = storedValue(key) as? String else { return nil }
        return UIColor(lmn_hex: value)
    }

    // MARK: - Public API

    /// The master switch. Defaults ON so an existing install keeps working
    /// across the upgrade.
    @objc public static func enabled() -> Bool {
        return flag(LMNKey.enabled, true)
    }

    /// 1.2.34. Whether the replacement may draw its diagnostics ON SCREEN.
    ///
    /// Three banners exist -- "presentation lost", "theme store unusable", and
    /// the scrim sweep's own report -- and every one of them was written because
    /// the device was believed to have no log to read. On the device this is
    /// built for that is no longer true, and a black bar over an unrelated alert
    /// is read as a defect of its own, because it is one. So the probe keeps
    /// logging unconditionally and the bar is drawn only when this asks for it.
    ///
    /// Read through the same store as everything else here, which is what makes
    /// the answer mean something inside a sandboxed host: CFPreferences first,
    /// then the world-readable copy of the plist. Absent key = OFF.
    @objc public static func debugReports() -> Bool {
        return flag(LMNKey.debugReports, false)
    }

    /// The shipped look. These are the values measured off the iOS 27
    /// reference: a 35pt panel corner, a 48pt capsule inset 16pt from the card
    /// edge.
    @objc public static func defaults() -> LMNGlassParams {
        return LMNGlassParams()
    }

    // MARK: - The three themes (1.2.0)

    /// Whether the last resolution found a stored theme that could not be
    /// turned into one of the three choices -- an out-of-range number, or a
    /// string that is not one. A key that is simply absent is NOT this: that is
    /// an install nobody has configured yet, and it resolves to 自动.
    ///
    /// There is no log on the device to read, so this is the only way the user
    /// could ever find out. A silent fallback is the failure this file keeps
    /// running into -- a setting that resolves to something the user never
    /// chose, drawn with no indication that it was chosen at all.
    @objc public static func themeWasUnreadable() -> Bool {
        return _themeUnreadable
    }

    private static var _themeUnreadable = false

    /// The palette to draw, resolved from the stored choice.
    ///
    /// Takes a trait collection rather than reading one itself. The callers
    /// that matter all have a better answer than `UITraitCollection.current`:
    /// the restyler has the controller being styled, the replacement has
    /// itself, the panel has its own view. Passing it also keeps the
    /// resolution visible at the call site instead of hidden in here.
    ///
    /// The stored value is read as a number and treated as UNUSABLE rather than
    /// trusted: it comes from a preferences plist that a hand edit or an older
    /// build can put out of range, and this process may not be able to see the
    /// store at all -- the restyle runs inside sandboxed host applications,
    /// where an empty read is a normal outcome rather than a bug.
    ///
    /// 1.2.25: unusable used to resolve to 曜石玻璃, because 0 was both the read
    /// fallback and the bottom of the enum. "This process cannot see your
    /// setting" and "you picked obsidian" were therefore the same value, so a
    /// process that could not read the store drew a dark card and a 0.32 scrim
    /// over a light app while the settings page showed 自动. Unusable now means
    /// 自动: follow the system, which is the one answer that cannot be wrong
    /// about a screen the user can see.
    @objc(resolvedThemeForTraits:)
    public static func resolvedTheme(for traits: UITraitCollection) -> LMNGlassTheme {
        // -1 is not a value the picker can write, so "absent" and "out of
        // range" arrive here as one thing and are answered one way.
        // 1.2.27: "absent" and "present but unusable" are NOT one thing, and
        // 1.2.26 printed them with the same line. Absent is the ordinary state
        // of an install where nobody has touched the picker, and it resolves to
        // 自动, which is correct -- so it must not raise an alarm. Only a value
        // that exists and cannot be turned into one of the three choices is a
        // fault, and that is the only case worth a line on screen.
        let stored = storedNumber(LMNKey.glassTheme)
        let choice = stored.flatMap { LMNGlassThemeChoice(rawValue: Int($0)) }
        _themeUnreadable = (stored != nil && choice == nil)
        switch choice ?? .automatic {
        case .obsidian:
            return .obsidian
        case .cinema:
            return .cinema
        case .automatic:
            // 自动 follows the SYSTEM: 明昼 when it is off, 曜石玻璃 when it
            // is on. Not 影院暗色 -- that one is a deliberate choice ("拥有更深
            // 背景"), and 自动 should not quietly become the more extreme look.
            //
            // 1.2.25: the system, not the host. The host's own trait collection
            // is the wrong authority here, because a window can carry its own
            // `overrideUserInterfaceStyle`: one screen of one app deciding
            // locally, which has nothing to do with whether the system is in
            // dark mode -- and 自动 is documented as following the system. That
            // is what put a dark sheet on a light screen. The host's traits stay
            // as the fallback for a screen that has not been told either.
            let system = UIScreen.main.traitCollection.userInterfaceStyle
            let effective: UIUserInterfaceStyle =
                (system == .unspecified) ? traits.userInterfaceStyle : system
            return effective == .dark ? .obsidian : .daylight
        }
    }

    /// The same answer with no trait collection in hand.
    @objc public static func resolvedTheme() -> LMNGlassTheme {
        return resolvedTheme(for: UITraitCollection.current)
    }

    /// Whether a theme is drawn as a dark surface.
    ///
    /// One place answers this, because "is the glass dark" is used to pick the
    /// material, the text colours and the capsule fills, and those three must
    /// never disagree.
    @objc public static func isDarkTheme(_ theme: LMNGlassTheme) -> Bool {
        return theme != .daylight
    }

    /// The live look: defaults with whatever the user has set laid over them,
    /// every value clamped into the range the renderer supports.
    ///
    /// Takes a trait collection because 自动 needs one to resolve, and it has
    /// to resolve HERE rather than in the view: `params.theme` is read by the
    /// capsule fills, the text colours and the panel's palette switch, and
    /// those three must never disagree. Resolving once, in the single place
    /// that builds the params, makes that structural instead of a convention.
    @objc(currentForTraits:)
    public static func current(for traits: UITraitCollection) -> LMNGlassParams {
        // The bounds are C macros from LMNGlassStyle.h; Swift types them as
        // Double, and CGFloat happens to be Double on arm64. Spelled out
        // explicitly so a platform where that is not true fails here rather
        // than silently clamping against the wrong type.
        let params = LMNGlassParams()
        params.blurIntensity = clampValue(
            number(LMNKey.blurIntensity, params.blurIntensity),
            minimum: CGFloat(LMNGlassBlurMinimum),
            maximum: CGFloat(LMNGlassBlurMaximum))
        params.refractionWidth = clampValue(
            number(LMNKey.refractionWidth, params.refractionWidth),
            minimum: CGFloat(LMNGlassRefractionMinimum),
            maximum: CGFloat(LMNGlassRefractionMaximum))
        params.highlightIntensity = clampValue(
            number(LMNKey.highlightIntensity, params.highlightIntensity),
            minimum: CGFloat(LMNGlassHighlightMinimum),
            maximum: CGFloat(LMNGlassHighlightMaximum))
        params.tintConcentration = clampValue(
            number(LMNKey.tintConcentration, params.tintConcentration),
            minimum: CGFloat(LMNGlassTintMinimum),
            maximum: CGFloat(LMNGlassTintMaximum))
        params.cornerRadius = clampValue(
            number(LMNKey.cornerRadius, params.cornerRadius),
            minimum: CGFloat(LMNGlassRadiusMinimum),
            maximum: CGFloat(LMNGlassRadiusMaximum))
        // Capsule geometry is NOT read from the store (1.1.1). `glassButtonHeight`
        // and `glassButtonInset` used to be read here like every other knob, but
        // nothing ever wrote them — not Root.plist, not LMNDefaultValues() — so a
        // value left behind by an older build stayed in effect permanently and
        // invisibly. They are clamped against the same range so an edited
        // constant still cannot produce geometry the renderer will not draw.
        params.buttonHeight = clampValue(
            LMNGlassParams().buttonHeight,
            minimum: CGFloat(LMNGlassButtonHeightMinimum),
            maximum: CGFloat(LMNGlassButtonHeightMaximum))
        params.buttonInset = clampValue(
            LMNGlassParams().buttonInset,
            minimum: CGFloat(LMNGlassButtonInsetMinimum),
            maximum: CGFloat(LMNGlassButtonInsetMaximum))
        params.fieldCornerRadius = clampValue(
            number(LMNKey.fieldCornerRadius, params.fieldCornerRadius),
            minimum: CGFloat(LMNGlassFieldRadiusMinimum),
            maximum: CGFloat(LMNGlassFieldRadiusMaximum))
        params.fieldFillAlpha = clampValue(
            number(LMNKey.fieldFillAlpha, params.fieldFillAlpha),
            minimum: CGFloat(LMNGlassFieldFillMinimum),
            maximum: CGFloat(LMNGlassFieldFillMaximum))
        params.fieldBorderWidth = clampValue(
            number(LMNKey.fieldBorderWidth, params.fieldBorderWidth),
            minimum: CGFloat(LMNGlassFieldBorderMinimum),
            maximum: CGFloat(LMNGlassFieldBorderMaximum))
        params.theme = resolvedTheme(for: traits)
        params.fadeEnabled = flag(LMNKey.fadeEnabled, params.fadeEnabled)
        params.fadeDuration = clampValue(
            number(LMNKey.fadeDuration, params.fadeDuration),
            minimum: CGFloat(LMNGlassFadeDurationMinimum),
            maximum: CGFloat(LMNGlassFadeDurationMaximum))
        // 1.2.3: the chosen entrance animation. Read as a clamped integer
        // so a stray non-integer in the store cannot reach the switch as
        // garbage. The default (0 = 聚焦弹入) is the prior hardcoded look.
        let entranceRaw = clampValue(
            number(LMNKey.entrance, CGFloat(params.entrance)),
            minimum: CGFloat(LMNGlassEntranceMinimum),
            maximum: CGFloat(LMNGlassEntranceMaximum))
        params.entrance = Int(entranceRaw)
        // 1.2.36: 逐层颜色覆盖。缺键或解析失败 -> nil -> 沿用主题。
        params.cardFillColor = storedColor(LMNKey.cardFillColor)
        params.cardBorderColor = storedColor(LMNKey.cardBorderColor)
        params.cardBorderWidth = clampValue(
            number(LMNKey.cardBorderWidth, params.cardBorderWidth),
            minimum: 0.0, maximum: 6.0)
        params.cardGlossColor = storedColor(LMNKey.cardGlossColor)
        params.buttonFillPrimary = storedColor(LMNKey.buttonFillPrimary)
        params.buttonBorderPrimary = storedColor(LMNKey.buttonBorderPrimary)
        params.buttonTextPrimary = storedColor(LMNKey.buttonTextPrimary)
        params.buttonFillDestructive = storedColor(LMNKey.buttonFillDestructive)
        params.buttonBorderDestructive = storedColor(LMNKey.buttonBorderDestructive)
        params.buttonTextDestructive = storedColor(LMNKey.buttonTextDestructive)
        params.buttonFillSecondary = storedColor(LMNKey.buttonFillSecondary)
        params.buttonBorderSecondary = storedColor(LMNKey.buttonBorderSecondary)
        params.buttonTextSecondary = storedColor(LMNKey.buttonTextSecondary)
        params.titleTextColor = storedColor(LMNKey.titleTextColor)
        params.messageTextColor = storedColor(LMNKey.messageTextColor)
        params.scrimColor = storedColor(LMNKey.scrimColor)
        return params
    }

    /// The same params with no trait collection in hand.
    @objc public static func current() -> LMNGlassParams {
        return current(for: UITraitCollection.current)
    }

    /// NaN and infinity both land on the minimum: a preferences plist edited by
    /// hand must never be able to produce a layer geometry the renderer will
    /// happily pass to Core Animation.
    @objc(clampValue:minimum:maximum:)
    public static func clampValue(_ value: CGFloat,
                                  minimum: CGFloat,
                                  maximum: CGFloat) -> CGFloat {
        if value.isNaN || value.isInfinite { return minimum }
        if value < minimum { return minimum }
        if value > maximum { return maximum }
        return value
    }

    // MARK: - Geometry

    /// Continuously-curved ("squircle") silhouette.
    ///
    /// A plain rounded rect reads as a visibly cheaper shape next to real glass,
    /// so the continuous corner is built explicitly from cubic segments. The
    /// corner stretches `1.528 * r` along each edge; if that reached past half
    /// the shorter side, opposite corners would overlap and the fill path would
    /// self-intersect — which clips the top and bottom of the panel and tears
    /// the background. The radius is therefore clamped so the curve always stays
    /// inside the shorter half, even on a short alert.
    @objc(squirclePathInRect:cornerRadius:)
    public static func squirclePath(in rect: CGRect,
                                    cornerRadius: CGFloat) -> UIBezierPath {
        let minDim = min(rect.width, rect.height)
        if minDim <= 0.0 {
            return UIBezierPath(rect: rect)
        }
        let maxRadius = (minDim - 1.0) / (2.0 * 1.528)
        let r = max(0.0, min(cornerRadius, maxRadius))
        if r <= 0.5 {
            return UIBezierPath(rect: rect)
        }

        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX
        let maxY = rect.maxY
        let arc = r * 1.528
        let control = r * 0.42

        let path = UIBezierPath()
        path.move(to: CGPoint(x: minX + arc, y: minY))
        path.addLine(to: CGPoint(x: maxX - arc, y: minY))
        path.addCurve(to: CGPoint(x: maxX, y: minY + arc),
                      controlPoint1: CGPoint(x: maxX - control, y: minY),
                      controlPoint2: CGPoint(x: maxX, y: minY + control))
        path.addLine(to: CGPoint(x: maxX, y: maxY - arc))
        path.addCurve(to: CGPoint(x: maxX - arc, y: maxY),
                      controlPoint1: CGPoint(x: maxX, y: maxY - control),
                      controlPoint2: CGPoint(x: maxX - control, y: maxY))
        path.addLine(to: CGPoint(x: minX + arc, y: maxY))
        path.addCurve(to: CGPoint(x: minX, y: maxY - arc),
                      controlPoint1: CGPoint(x: minX + control, y: maxY),
                      controlPoint2: CGPoint(x: minX, y: maxY - control))
        path.addLine(to: CGPoint(x: minX, y: minY + arc))
        path.addCurve(to: CGPoint(x: minX + arc, y: minY),
                      controlPoint1: CGPoint(x: minX, y: minY + control),
                      controlPoint2: CGPoint(x: minX + control, y: minY))
        path.close()
        return path
    }
}

/// 1.2.36: hex <-> UIColor for the colour overrides. Shared by the runtime and
/// the settings bundle (the bundle re-implements the same parse in Objective-C,
/// since it compiles no Swift).
extension UIColor {
    @objc(lmn_initWithHex:)
    public convenience init?(lmn_hex hex: String) {
        let raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        var str = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if str.count == 6 { str.append("FF") }
        guard str.count == 8, let value = UInt64(str, radix: 16) else {
            return nil
        }
        let r = Double((value >> 24) & 0xFF) / 255.0
        let g = Double((value >> 16) & 0xFF) / 255.0
        let b = Double((value >> 8) & 0xFF) / 255.0
        let a = Double(value & 0xFF) / 255.0
        self.init(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b),
                  alpha: CGFloat(a))
    }

    @objc(lmn_hexString)
    public func lmn_hexString() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let pack: UInt64 = (UInt64(r * 255.0 + 0.5) << 24)
            | (UInt64(g * 255.0 + 0.5) << 16)
            | (UInt64(b * 255.0 + 0.5) << 8)
            | UInt64(a * 255.0 + 0.5)
        return String(format: "#%08llX", pack)
    }
}

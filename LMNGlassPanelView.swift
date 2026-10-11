//
//  LMNGlassPanelView.swift
//  Lumen
//
//  The glass surface itself, and the capsule material that sits on it.
//
//  iOS 16 ships no `UIGlassEffect`, so the whole treatment is hand stacked:
//  blur -> frost veil -> tint -> top specular -> refracted edge -> inner rim,
//  every layer sharing one squircle mask so the fills and the strokes stay
//  aligned no matter how the radius is tuned.
//

import UIKit

@objc(LMNGlassPanelView)
public final class LMNGlassPanelView: UIView {

    // MARK: - Layer stack

    private let blurView = UIVisualEffectView()
    private let veilLayer = CAGradientLayer()
    private let tintLayer = CAGradientLayer()
    private let highlightLayer = CAGradientLayer()
    private let refractLayer = CAShapeLayer()
    private let rimLayer = CAShapeLayer()

    /// The live parameters. Reading this back is how the restyler re-applies a
    /// slider change to a panel that is already on screen.
    @objc public private(set) var params: LMNGlassParams

    /// Whether the current params draw a dark surface. Derived, never stored —
    /// see the note on `init(frame:params:)`.
    private var isDark: Bool {
        return LMNGlass.isDarkTheme(params.theme)
    }

    // MARK: - Life cycle

    /// The theme is read out of `params` rather than passed alongside it.
    ///
    /// It used to be a separate `dark` argument plus a settable
    /// `darkAppearance` property, which gave two sources of truth for the same
    /// question — and 1.2.0 adds a third answer to it, because the theme is no
    /// longer a boolean. Whatever drives the appearance now has to change
    /// `params`, so the material and the palette can never disagree.
    @objc(initWithFrame:params:)
    public init(frame: CGRect, params: LMNGlassParams) {
        self.params = params
        super.init(frame: frame)

        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = false

        blurView.isUserInteractionEnabled = false
        blurView.clipsToBounds = true
        blurView.frame = bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.effect = LMNGlassPanelView.blurEffect(
            dark: LMNGlass.isDarkTheme(params.theme))
        addSubview(blurView)

        // The frost body. This is the layer the *material* is made of, and it is
        // deliberately NOT scaled by 底色浓度: with the slider driving the veil
        // directly, a low default left a light card at roughly nine percent
        // white — the alert became a window rather than glass, and whatever the
        // host app had on screen read straight through the sheet. The slider now
        // only modulates the tint on top of a body that is always present, so
        // the panel reads as glass at every slider value.
        veilLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        veilLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        layer.addSublayer(veilLayer)

        tintLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        tintLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        layer.addSublayer(tintLayer)

        // The top specular. iOS 27 tightened the highlight from a diagonal
        // streak to a horizontal one, so this gradient runs straight down the
        // vertical axis and stays close to the top edge.
        highlightLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        highlightLayer.endPoint = CGPoint(x: 0.0, y: 1.0)
        highlightLayer.locations = [0.0, 0.16, 0.52]
        layer.addSublayer(highlightLayer)

        // The refracted edge: a wide, heavily blurred stroke just inside the
        // silhouette. This is what sells physical depth rather than a flat
        // translucent rectangle.
        refractLayer.fillColor = UIColor.clear.cgColor
        layer.addSublayer(refractLayer)

        rimLayer.fillColor = UIColor.clear.cgColor
        layer.addSublayer(rimLayer)

        apply(params: params)
    }

    public required init?(coder: NSCoder) {
        self.params = LMNGlass.defaults()
        super.init(coder: coder)
    }

    // Not `-setFrame:`. UIView exposes `frame` as a property in Swift, so there
    // is no `setFrame(_:)` to override — spelling it that way is a hard compile
    // error ("does not override any method from its superclass"). UIKit calls
    // this after the bounds change instead, which is when the layer frames have
    // to be recomputed.
    public override func layoutSubviews() {
        super.layoutSubviews()
        if !bounds.isEmpty {
            apply(params: params)
        }
    }

    // MARK: - Material

    @objc public static func blurEffect(dark: Bool) -> UIBlurEffect {
        let style: UIBlurEffect.Style = dark ? .systemUltraThinMaterialDark
                                             : .systemUltraThinMaterialLight
        return UIBlurEffect(style: style)
    }

    /// 1.2.36: 把颜色压暗 `amount`（0..1）用于覆盖色的双层渐变底档。
    private static func lmn_darkened(_ color: UIColor, by amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = max(0.0, 1.0 - amount)
        return UIColor(red: r * k, green: g * k, blue: b * k, alpha: a)
    }

    // MARK: - Applying parameters

    @objc(applyParams:)
    public func apply(params newParams: LMNGlassParams) {
        params = newParams

        let bounds = self.bounds
        if bounds.isEmpty { return }

        let radius = params.cornerRadius
        veilLayer.frame = bounds
        tintLayer.frame = bounds
        highlightLayer.frame = bounds
        refractLayer.frame = bounds
        rimLayer.frame = bounds

        // 1.2.37: 卡片填充 / 高光覆盖不再在此设置 —— 下方主题 switch 会无条件重写
        // veil/tint/highlight 三层，早设会被覆盖。覆盖色改在本方法末尾、switch
        // 之后应用，确保优先于主题调色板（修复 1.2.36 中覆盖色不生效的缺陷）。

        // UIVisualEffectView exposes no public blur radius on iOS 16, so
        // 模糊强度 modulates the material's alpha instead. The floor is high on
        // purpose: at a low slider value the material would otherwise nearly
        // vanish, which is half of why the sheet once stopped reading as frosted
        // glass. Even at zero the material keeps most of its strength.
        // The bounds arrive from Objective-C as C macros, which Swift types as
        // Double; CGFloat is Double on arm64 but is spelled out so the file
        // still builds if that ever stops being true.
        let blurLow = CGFloat(LMNGlassBlurMinimum)
        let blurSpan = CGFloat(LMNGlassBlurMaximum) - blurLow
        let blurRatio = blurSpan > 0.0
            ? (params.blurIntensity - blurLow) / blurSpan
            : 0.0
        // Qualified with the type: `blurAlpha` is a static member, and calling a
        // static member by its bare name from an instance method is a hard
        // compile error in Swift ("static member cannot be used on instance of
        // type"), not a warning -- -Werror would not have softened it.
        blurView.alpha = LMNGlassPanelView.blurAlpha(for: params.theme,
                                                     ratio: blurRatio)

        let theme = params.theme
        switch theme {
        case .cinema:
            // 影院暗色 — "拥有更深背景".
            //
            // The body is the darkest of the three and the backdrop behind it
            // is dimmed the hardest, which is what makes a card read as sitting
            // in a dark room. The specular is pulled down with it: a bright
            // highlight on a near-opaque panel looks like a reflection on
            // paint, not on glass.
            veilLayer.colors = [
                UIColor(white: 0.0, alpha: 0.62).cgColor,
                UIColor(white: 0.0, alpha: 0.50).cgColor,
            ]
            tintLayer.colors = [
                UIColor(white: 0.09, alpha: 1.0).cgColor,
                UIColor(white: 0.04, alpha: 1.0).cgColor,
            ]
            highlightLayer.colors = [
                UIColor(white: 1.0, alpha: 0.52).cgColor,
                UIColor(white: 1.0, alpha: 0.12).cgColor,
                UIColor.clear.cgColor,
            ]
        case .daylight:
            // 明昼 — "适合浅色界面".
            //
            // The only light surface, and it keeps the 1.1.1 correction: the
            // card DARKENS and desaturates what is behind it instead of
            // bleaching it, which is what a measured reference does. Painted
            // white it read as a flat sheet with the host showing through
            // nowhere.
            veilLayer.colors = [
                UIColor(white: 0.62, alpha: 0.34).cgColor,
                UIColor(white: 0.55, alpha: 0.42).cgColor,
            ]
            tintLayer.colors = [
                UIColor(red: 0.78, green: 0.80, blue: 0.85, alpha: 0.55).cgColor,
                UIColor(red: 0.70, green: 0.73, blue: 0.80, alpha: 0.62).cgColor,
            ]
            highlightLayer.colors = [
                UIColor(white: 1.0, alpha: 0.96).cgColor,
                UIColor(white: 1.0, alpha: 0.22).cgColor,
                UIColor.clear.cgColor,
            ]
        case .obsidian:
            // 曜石玻璃 — "强调通透层次", and the default.
            //
            // This is the iOS 27 stack, reworked in 1.1.1: a veil that seats
            // the card below the brightness of its surroundings plus a cool
            // neutral tint on top, with the blur underneath still carrying the
            // backdrop. Of the three it lets the most of the host through,
            // which is what "通透层次" is asking for — the layering has to be
            // visible, not implied.
            veilLayer.colors = [
                UIColor(white: 0.0, alpha: 0.38).cgColor,
                UIColor(white: 0.0, alpha: 0.28).cgColor,
            ]
            tintLayer.colors = [
                UIColor(white: 0.15, alpha: 1.0).cgColor,
                UIColor(white: 0.07, alpha: 1.0).cgColor,
            ]
            highlightLayer.colors = [
                UIColor(white: 1.0, alpha: 0.74).cgColor,
                UIColor(white: 1.0, alpha: 0.20).cgColor,
                UIColor.clear.cgColor,
            ]
        @unknown default:
            // An enum value this renderer does not know. Falling through to
            // the default palette keeps the card drawn; returning here would
            // leave the layers holding whatever the last alert put in them.
            veilLayer.colors = [
                UIColor(white: 0.0, alpha: 0.38).cgColor,
                UIColor(white: 0.0, alpha: 0.28).cgColor,
            ]
            tintLayer.colors = [
                UIColor(white: 0.15, alpha: 1.0).cgColor,
                UIColor(white: 0.07, alpha: 1.0).cgColor,
            ]
            highlightLayer.colors = [
                UIColor(white: 1.0, alpha: 0.74).cgColor,
                UIColor(white: 1.0, alpha: 0.20).cgColor,
                UIColor.clear.cgColor,
            ]
        }

        veilLayer.isHidden = false
        veilLayer.opacity = 1.0

        tintLayer.isHidden = params.tintConcentration <= 0.001
        tintLayer.opacity = Float(params.tintConcentration)
        highlightLayer.isHidden = params.highlightIntensity <= 0.001
        highlightLayer.opacity = Float(params.highlightIntensity)

        let refractLow = CGFloat(LMNGlassRefractionMinimum)
        let refractionSpan = CGFloat(LMNGlassRefractionMaximum) - refractLow
        let refractionRatio = refractionSpan > 0.0
            ? (params.refractionWidth - refractLow) / refractionSpan
            : 0.0
        refractLayer.isHidden = params.refractionWidth <= 0.001
        refractLayer.lineWidth = max(1.0, params.refractionWidth)
        if isDark {
            refractLayer.strokeColor =
                UIColor(white: 1.0, alpha: 0.14 + 0.32 * refractionRatio).cgColor
            refractLayer.shadowColor =
                UIColor(white: 1.0, alpha: 0.40 + 0.36 * refractionRatio).cgColor
        } else {
            // 1.1.1: the light appearance lights its edge instead of darkening it.
            //
            // The dark hairline was justified in the comment below as "a white
            // rim is invisible on a light panel" — which is true, and is also why
            // the device showed a dark band hugging the card and then a dark ring
            // around each capsule. The reference does the opposite: it carries a
            // BRIGHT white refractive outline around the glass and around each
            // pill, and that outline is a large part of what reads as glass. The
            // card face itself is now a mid grey (see the fill stack above), so a
            // white rim has something to sit against and is genuinely visible.
            //
            // The dark branch is untouched: a bright edge on near-black glass is
            // what sells the thickness there, and that half measured correct.
            refractLayer.strokeColor =
                UIColor(white: 1.0, alpha: 0.30 + 0.45 * refractionRatio).cgColor
            refractLayer.shadowColor =
                UIColor(white: 1.0, alpha: 0.22 + 0.30 * refractionRatio).cgColor
        }
        refractLayer.shadowOpacity = 1.0
        refractLayer.shadowRadius = max(1.0, params.refractionWidth * 0.55)
        refractLayer.shadowOffset = .zero

        // The perimeter. On the light card this is a bright hairline rather than the
        // iOS 27 darkened edge: measured against the reference, the light glass
        // carries a luminous outline top to bottom, and with the face now a mid
        // grey that outline is what separates the card from whatever is behind
        // it. The dark branch keeps the darkened edge, which is correct there.
        rimLayer.lineWidth = 1.5
        rimLayer.strokeColor = (isDark
            ? UIColor(white: 0.0, alpha: 0.40)
            : UIColor(white: 1.0, alpha: 0.55)).cgColor

        // 1.2.36: 卡片描边覆盖。
        if let border = params.cardBorderColor {
            rimLayer.strokeColor = border.cgColor
        }
        if params.cardBorderWidth > 0.0 {
            rimLayer.lineWidth = params.cardBorderWidth
        }

        // 1.2.37: 卡片填充 / 高光覆盖 —— 必须放在主题 switch 之后，否则会被主题调色板覆盖。
        // 主题分支对 veil/tint/highlight 三层是无条件赋值，1.2.36 把覆盖色写在 switch 之前，等于无效。
        if let fill = params.cardFillColor {
            let stops: [CGColor] = [
                fill.cgColor,
                LMNGlassPanelView.lmn_darkened(fill, by: 0.18).cgColor,
            ]
            veilLayer.colors = stops
            tintLayer.colors = stops
        }
        if let gloss = params.cardGlossColor {
            highlightLayer.colors = [
                gloss.withAlphaComponent(0.70).cgColor,
                gloss.withAlphaComponent(0.15).cgColor,
                UIColor.clear.cgColor,
            ]
            // 覆盖色是用户显式选择：即便「高光强度」滑块为 0，也强制显示该层。
            highlightLayer.isHidden = false
            highlightLayer.opacity = Float(params.highlightIntensity > 0.001
                                          ? params.highlightIntensity : 1.0)
        }

        let fillPath = LMNGlass.squirclePath(in: bounds, cornerRadius: radius)
        blurView.layer.mask = LMNGlassPanelView.maskLayer(fillPath, bounds)
        tintLayer.mask = LMNGlassPanelView.maskLayer(fillPath, bounds)
        veilLayer.mask = LMNGlassPanelView.maskLayer(fillPath, bounds)
        highlightLayer.mask = LMNGlassPanelView.maskLayer(fillPath, bounds)

        let inset = CGRectInset(bounds, params.refractionWidth * 0.5,
                                params.refractionWidth * 0.5)
        refractLayer.path = LMNGlass.squirclePath(in: inset,
                                                  cornerRadius: radius).cgPath
        rimLayer.path = LMNGlass.squirclePath(in: CGRectInset(bounds, 0.5, 0.5),
                                              cornerRadius: radius).cgPath
    }

    private static func maskLayer(_ path: UIBezierPath,
                                  _ bounds: CGRect) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = path.cgPath
        return mask
    }

    /// How much of the material shows through, per theme.
    ///
    /// UIVisualEffectView exposes no public blur radius on iOS 16, so 模糊强度
    /// modulates the material's alpha. The floor is high on purpose: at a low
    /// slider value the material would otherwise nearly vanish, which is half
    /// of why the sheet once stopped reading as frosted glass.
    ///
    /// 影院暗色 sits highest (a deeper background means less of the host should
    /// read through) and 曜石玻璃 keeps the most headroom for the slider to
    /// open the card up, which is what "通透层次" asks for.
    private static func blurAlpha(for theme: LMNGlassTheme,
                                  ratio: CGFloat) -> CGFloat {
        switch theme {
        case .cinema:
            return 0.80 + 0.20 * ratio
        case .daylight:
            return 0.66 + 0.34 * ratio
        case .obsidian:
            return 0.70 + 0.30 * ratio
        @unknown default:
            return 0.70 + 0.30 * ratio
        }
    }

    // MARK: - Capsule material

    /// One source of truth for the capsule look, shared by the runtime and the
    /// alert-row restyler.
    ///
    /// The material is theme-dependent throughout: a white hairline border and
    /// a white fill are invisible on a light card, so 明昼 inverts both -- a
    /// fill DARKER than the card, and a bright rim that has something pale to
    /// sit against. That inversion is what stops the light-mode capsules
    /// disappearing.
    ///
    /// 1.2.0: the flat-fill mode this used to carry is gone. It existed because
    /// two references disagreed -- the iOS 27 sheet is real glass, the other was
    /// flat vector art with no gradient anywhere on the pill -- and the answer to
    /// that disagreement is the theme picker, not a second material for the
    /// pills that silently ignores every slider above it.
    @objc(glassFillForRole:theme:params:)
    public static func glassFill(forRole role: LMNGlassButtonRole,
                                 theme: LMNGlassTheme,
                                 params: LMNGlassParams?) -> UIColor {
        // 1.2.36: 覆盖色优先。非 nil 直接返回用户色，跳过主题派生。
        if let p = params {
            switch role {
            case .primary:
                if let c = p.buttonFillPrimary { return c }
            case .destructive:
                if let c = p.buttonFillDestructive { return c }
            case .secondary:
                if let c = p.buttonFillSecondary { return c }
            @unknown default:
                break
            }
        }
        switch role {
        case .primary:
            // A tinted glass blue rather than a flat block: part of the card
            // still shows through, which is what separates this from the pre-26
            // solid blue button.
            return UIColor(red: 0.0, green: 0.478, blue: 1.0,
                           alpha: accentAlpha(for: theme))
        case .destructive:
            return UIColor(red: 0.937, green: 0.267, blue: 0.231,
                           alpha: accentAlpha(for: theme) - 0.06)
        case .secondary:
            // The neutral capsule.
            //
            // 1.1.1: on a real device this was white at 0.78 alpha over a white
            // card, which measured as luma 243 against a card at 231 -- about 5%
            // brighter, and the cancel capsule (inset 0, so indistinguishable
            // from the card) measured 248 against 250, i.e. the same colour as
            // the card it sat on. The pills were invisible.
            //
            // The reference solves this the other way round: its neutral pill
            // measures luma ~183 sitting on a card face at ~198. The pill is
            // DARKER than the card, not lighter. That is also what a real piece
            // of glass does -- it shades what is behind it -- and it makes the
            // capsule legible without needing a heavy border.
            return neutralFill(for: theme)
        @unknown default:
            return neutralFill(for: theme)
        }
    }

    /// How hard the accent carries, per theme. 影院暗色 pulls it down with the
    /// rest of the card; 明昼 lifts it so it survives against a pale surface.
    private static func accentAlpha(for theme: LMNGlassTheme) -> CGFloat {
        switch theme {
        case .cinema:
            return 0.70
        case .daylight:
            return 0.82
        case .obsidian:
            return 0.78
        @unknown default:
            return 0.78
        }
    }

    private static func neutralFill(for theme: LMNGlassTheme) -> UIColor {
        switch theme {
        case .cinema:
            return UIColor(white: 1.0, alpha: 0.10)
        case .daylight:
            return UIColor(white: 0.32, alpha: 0.20)
        case .obsidian:
            return UIColor(white: 1.0, alpha: 0.14)
        @unknown default:
            return UIColor(white: 1.0, alpha: 0.14)
        }
    }

    @objc(glassBorderForRole:theme:params:)
    public static func glassBorder(forRole role: LMNGlassButtonRole,
                                   theme: LMNGlassTheme,
                                   params: LMNGlassParams?) -> UIColor {
        // 1.2.36: 覆盖色优先。
        if let p = params {
            switch role {
            case .primary:
                if let c = p.buttonBorderPrimary { return c }
            case .destructive:
                if let c = p.buttonBorderDestructive { return c }
            case .secondary:
                if let c = p.buttonBorderSecondary { return c }
            @unknown default:
                break
            }
        }
        if LMNGlass.isDarkTheme(theme) {
            switch role {
            case .primary, .destructive:
                return UIColor(white: 1.0, alpha: 0.28)
            case .secondary:
                return UIColor(white: 0.0, alpha: 0.20)
            @unknown default:
                return UIColor(white: 0.0, alpha: 0.20)
            }
        }
        switch role {
        case .primary, .destructive:
            return UIColor(white: 1.0, alpha: 0.30)
        case .secondary:
            // Bright, matching the reference: its neutral pill carries a
            // luminous outline (luma ~203 at the shoulder against a 183 body).
            // Since the light pill body is now darker than the card rather than
            // lighter, the old dark hairline would double up with the body's own
            // shading and swallow the edge. White reads as the lit rim of the
            // glass.
            return UIColor(white: 1.0, alpha: 0.65)
        @unknown default:
            return UIColor(white: 1.0, alpha: 0.65)
        }
    }

    @objc(glassTitleForRole:theme:params:)
    public static func glassTitle(forRole role: LMNGlassButtonRole,
                                  theme: LMNGlassTheme,
                                  params: LMNGlassParams?) -> UIColor {
        // 1.2.36: 覆盖色优先。
        if let p = params {
            switch role {
            case .primary:
                if let c = p.buttonTextPrimary { return c }
            case .destructive:
                if let c = p.buttonTextDestructive { return c }
            case .secondary:
                if let c = p.buttonTextSecondary { return c }
            @unknown default:
                break
            }
        }
        switch role {
        case .primary, .destructive:
            return .white
        case .secondary:
            return LMNGlass.isDarkTheme(theme)
                ? UIColor.white
                : UIColor(white: 0.05, alpha: 1.0)
        @unknown default:
            return .white
        }
    }

    @objc(glassGlossAlphaForTheme:)
    public static func glassGlossAlpha(theme: LMNGlassTheme) -> CGFloat {
        // On a dark capsule the sheen is a faint lift. On a light one it has to
        // be strong enough to read as the bright top edge of the pill, since the
        // fill and the card behind it are both pale. 影院暗色 takes the least:
        // its body is already nearly opaque, so a strong sheen there reads as a
        // reflection on paint rather than on glass.
        switch theme {
        case .cinema:
            return 0.20
        case .daylight:
            return 0.55
        case .obsidian:
            return 0.28
        @unknown default:
            return 0.28
        }
    }

    @objc(glassShadowOpacityForRole:theme:)
    public static func glassShadowOpacity(forRole role: LMNGlassButtonRole,
                                          theme: LMNGlassTheme) -> CGFloat {
        if LMNGlass.isDarkTheme(theme) {
            // 影院暗色 sits on a deeper card and needs the least help separating
            // from it; a heavy shadow there just darkens an already dark join.
            return theme == .cinema ? 0.28 : 0.35
        }
        switch role {
        case .primary, .destructive:
            return 0.22
        case .secondary:
            // Shallow on purpose: a heavy shadow under a near-white pill over a
            // near-white card reads as a dirty smudge, not as depth.
            return 0.12
        @unknown default:
            return 0.12
        }
    }

    @objc(styleButton:role:theme:params:)
    public static func style(_ button: UIButton?,
                             role: LMNGlassButtonRole,
                             theme: LMNGlassTheme,
                             params: LMNGlassParams?) {
        guard let button = button else { return }

        // UIAlertAction buttons carry a background image on some iOS releases;
        // it would sit on top of every colour set below.
        button.setBackgroundImage(nil, for: .normal)
        button.setBackgroundImage(nil, for: .highlighted)
        button.backgroundColor = .clear
        button.layer.masksToBounds = true
        button.layer.cornerCurve = .continuous
        button.titleLabel?.font = .systemFont(ofSize: 17.0, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75

        button.backgroundColor = glassFill(forRole: role, theme: theme,
                                            params: params)

        // Lit edge plus a darkened floating depth: a thin border and a soft dark
        // shadow give the capsule glass thickness.
        button.layer.borderWidth = 1.0
        button.layer.borderColor =
            glassBorder(forRole: role, theme: theme, params: params).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity =
            Float(glassShadowOpacity(forRole: role, theme: theme))
        button.layer.shadowRadius = 3.0
        button.layer.shadowOffset = CGSize(width: 0.0, height: 1.0)

        let title = glassTitle(forRole: role, theme: theme, params: params)
        button.setTitleColor(title, for: .normal)
        button.setTitleColor(title.withAlphaComponent(0.7), for: .highlighted)
        button.setTitleColor(title.withAlphaComponent(0.4), for: .disabled)
        button.tintColor = title
    }

    @objc(pillButtonWithTitle:role:theme:params:)
    public static func pillButton(title: String,
                                  role: LMNGlassButtonRole,
                                  theme: LMNGlassTheme,
                                  params: LMNGlassParams?) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        style(button, role: role, theme: theme, params: params)
        return button
    }
}

#import <UIKit/UIKit.h>

#import <math.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// The one header both languages share.
//
// Lumen is a Swift-first hybrid: Swift owns the *appearance* (LMNGlass.swift
// holds the parameters, LMNGlassPanelView.swift draws the glass) and
// Objective-C owns the *injection* (LMNAlertRestyler.m walks UIAlertController's
// private view tree). Theos cannot hook Swift code, so the hook layer has to
// stay Objective-C; the two halves meet through Lumen-Bridging-Header.h, which
// imports exactly this file.
//
// That is also why this header must stay tiny. Everything it declares is
// visible to Swift, so anything here that names a class Swift also defines
// would be a duplicate-interface error.
// ---------------------------------------------------------------------------

/// Preference domain. This string is *also* the CFPreferences key store, so
/// changing it silently reverts every tuned parameter back to its default.
extern NSString *const LMNPreferenceDomain;

/// Posted (CFNotification) whenever the preference domain changes, including
/// changes made by another process.
extern CFStringRef const LMNGlassPreferencesChangedNotification;

/// The three capsule roles. Declared here rather than next to the renderer so
/// that the Swift engine can see it through the bridging header without also
/// importing the renderer's Objective-C interface — which would collide with
/// the Swift class of the same name.
typedef NS_ENUM(NSInteger, LMNGlassButtonRole) {
    LMNGlassButtonRoleSecondary = 0,
    LMNGlassButtonRolePrimary,
    LMNGlassButtonRoleDestructive,
};

/// The PALETTE the renderer draws. Not what the picker writes.
///
/// The three palettes are NOT invented here — they are the three looks the
/// reference package ships, read out of its own settings bundle, whose footer
/// defined each one in its own words:
///
///     曜石玻璃强调通透层次，影院暗色拥有更深背景，明昼适合浅色界面。
///
///     obsidian  — emphasises translucency and layering
///     cinema    — a deeper background
///     daylight  — for light interfaces
///
/// 1.2.2 split this type from the stored choice, and the split is the point.
/// The picker still writes the reference's own 0/1/2, but its 2 means 自动:
/// follow the system's dark mode. So 自动 resolves to `daylight` or `obsidian`
/// depending on the system, and 明昼 stopped being directly selectable — it is
/// what 自动 gives you in light mode. The stored values live in
/// `LMNGlassThemeChoice` (Swift) so that a stored number cannot reach a
/// renderer, where it would mean a different palette here than it does there.
///
/// A palette decides the APPEARANCE, including whether the glass is dark or
/// light. That is deliberate: choosing 影院暗色 is choosing a dark card, and it
/// is not undone by the system being light — otherwise the control the user set
/// would be overridden by something they did not set. 自动 is the one choice
/// that asks the system, and it asks once, where the parameters are built.
typedef NS_ENUM(NSInteger, LMNGlassTheme) {
    LMNGlassThemeObsidian = 0,
    LMNGlassThemeCinema = 1,
    LMNGlassThemeDaylight = 2,
};

// Slider bounds, and the clamp limits the Swift engine applies to whatever the
// preference store hands back. Shared by the runtime and the settings bundle so
// a stored value can never fall outside the range the renderer supports.
//
// These are read from Swift too (a plain `#define` of a float literal arrives
// there as a Double, which is exactly CGFloat on arm64).
#define LMNGlassBlurMinimum 0.0
#define LMNGlassBlurMaximum 40.0
#define LMNGlassRefractionMinimum 0.0
#define LMNGlassRefractionMaximum 30.0
#define LMNGlassHighlightMinimum 0.0
#define LMNGlassHighlightMaximum 1.0
#define LMNGlassTintMinimum 0.0
#define LMNGlassTintMaximum 1.0
#define LMNGlassRadiusMinimum 12.0
#define LMNGlassRadiusMaximum 60.0

// Capsule geometry.
//
// These are CONSTANTS, not preference-backed knobs, and that is a deliberate
// 1.1.1 change. They used to be read from the store like the five sliders, but
// no UI ever wrote them: they were absent from Root.plist and from
// LMNDefaultValues(), so "恢复默认设置" could not restore them either. A value
// left behind by an older build therefore stayed in effect forever with no way
// to see or change it — which is exactly how the pill ended up 8pt from the
// card edge instead of the 16pt the geometry below specifies.
//
// They are still clamped against a range rather than used raw, so the geometry
// stays inside what the renderer can draw even if a constant is edited wrong.
#define LMNGlassButtonHeightMinimum 36.0
#define LMNGlassButtonHeightMaximum 60.0
#define LMNGlassButtonInsetMinimum 0.0
#define LMNGlassButtonInsetMaximum 24.0

// The inset a two-up row uses on the edge that faces the OTHER pill, as a
// fraction of the outer inset.
//
// 1.1.4 CORRECTION, and the 1.1.4 value was itself wrong. History, because the
// error is instructive:
//
//   0.9  came from a real iOS 27 sheet: outer margin 21px, inner gap 19px.
//        A true measurement of a DIFFERENT layout than the one being matched.
//   0.70 came from re-measuring the target reference and getting 23/33 = 0.697.
//        Both numbers were wrong. They came from _diff_ref.py, which hardcoded
//        the grey pill's right edge as 185px (it is 197) and the card margin as
//        33px (it is 20), and which also compared a points constant against a
//        pixels measurement in the same subtraction.
//
// Measured off the target image, with the arithmetic closed against the card
// width (_refproof114.py, reproducible):
//
//     card 362px, pill 156px, outer margin 20px, inner gap 10px
//     closure: 20 + 156 + 10 + 156 + 20 = 362   EXACT
//
// So the observed gap/margin is 0.5. But this constant is NOT that ratio. In
// the two-up branch the width is (spaceWidth - 2*outer - 2*inner)/2 and the
// second pill starts at spaceWidth/2 + inner, which makes the gap between the
// pills exactly 2*inner. Therefore:
//
//     gap / margin = 2 * LMNGlassButtonInnerRatio
//     => ratio     = 0.5 / 2 = 0.25
//
// And 0.25 is confirmed independently: it predicts a gap of 10px and a pill of
// 156px, reproducing BOTH measured numbers at once from the card width. At 0.70
// the gap comes out 28px against a measured 10px and the pill 5.8% narrow; at
// 0.9 it is 36px and 8.3% narrow.
//
// So this is 0.25 — HALF the ratio read off the image, because the code's
// geometry counts the inset twice.
#define LMNGlassButtonInnerRatio 0.25

// Text fields that sit on the glass, and the entrance fade. Not exposed on the
// settings page (they hold their iOS 27 calibrated values), but still clamped
// so a hand-edited preferences plist cannot produce broken layer geometry.
#define LMNGlassFieldRadiusMinimum 0.0
#define LMNGlassFieldRadiusMaximum 30.0
#define LMNGlassFieldFillMinimum 0.0
#define LMNGlassFieldFillMaximum 0.6
#define LMNGlassFieldBorderMinimum 0.0
#define LMNGlassFieldBorderMaximum 3.0
#define LMNGlassFadeDurationMinimum 0.05
#define LMNGlassFadeDurationMaximum 1.0

// The appearance animation the replacement renderer plays. One of three
// (1.2.3): 0 = 聚焦弹入 (focus pop-in), 1 = 上浮 (float up), 2 = 淡入
// (fade in). Bounded so a hand-edited plist cannot select a style index the
// renderer's switch does not have a case for. Swift reads these through the
// bridging header as Doubles (CGFloat on arm64).
#define LMNGlassEntranceMinimum 0
#define LMNGlassEntranceMaximum 2

NS_ASSUME_NONNULL_END

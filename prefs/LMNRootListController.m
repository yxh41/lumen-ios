#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

#import <math.h>
#import <notify.h>

#import "LMNGlassStyle.h"

// ---------------------------------------------------------------------------
// One page.
//
// The appearance itself is Swift and lives in the injected dylib; this bundle
// only writes the preference store and wakes the runtime up. That is why the
// page no longer carries an in-cell glass preview: the "预览弹窗" button below
// presents a real UIAlertController, which the tweak restyles, so the preview
// *is* the product rather than a re-implementation of it that can drift.
//
// The bundle therefore compiles no Swift at all — see prefs/Makefile.
// ---------------------------------------------------------------------------

#pragma mark - Preference plumbing

static NSString *const LMNKeyGlassEnabled = @"glassEnabled";
static NSString *const LMNKeyGlassEntrance = @"glassEntrance";
static NSString *const LMNKeyBlurIntensity = @"glassBlurIntensity";
static NSString *const LMNKeyRefractionWidth = @"glassRefractionWidth";
static NSString *const LMNKeyHighlightIntensity = @"glassHighlightIntensity";
static NSString *const LMNKeyTintConcentration = @"glassTintConcentration";
static NSString *const LMNKeyCornerRadius = @"glassCornerRadius";

// 1.2.0: the three themes. The raw values are the reference package's own --
// its theme picker is a PSSegmentCell over ['0','1','2'] -- so a value written
// by either package means the same thing here.
//
// 1.2.2: the third title is 自动 rather than the reference's 明昼, and the raw
// value still means what it meant: follow the system's dark mode, resolving to
// 明昼 when it is light and 曜石玻璃 when it is dark. The resolution lives in
// LMNGlass.resolvedThemeForTraits: -- this page only writes the number.
static NSString *const LMNKeyGlassTheme = @"glassTheme";

/// The five panel knobs, with the iOS 27 calibrated default of each. "恢复默认
/// 设置" writes exactly these, so the button and LMNGlass.swift must agree —
/// a default that drifts between the two makes "restore" restore something the
/// renderer never shipped.
static NSDictionary<NSString *, NSNumber *> *LMNDefaultValues(void) {
    return @{
        LMNKeyBlurIntensity : @18.0,
        LMNKeyRefractionWidth : @9.0,
        LMNKeyHighlightIntensity : @0.51,
        LMNKeyTintConcentration : @0.45,
        LMNKeyCornerRadius : @35.0,
        // 1.2.0. The theme restores to 曜石玻璃. Leaving it out of this table
        // would be the 1.1.0/1.1.1 trap in a new dress: "恢复默认设置" would
        // silently keep whichever theme the user had picked while claiming to
        // have returned every setting to the shipped look.
        LMNKeyGlassTheme : @2,
        // 1.2.3. The entrance restores to 聚焦弹入 (0) -- the look the
        // renderer shipped with before the choice existed.
        LMNKeyGlassEntrance : @0,
    };
}

/// `CFPreferencesCopyAppValue` takes exactly (key, applicationID) and returns a
/// retained value, or NULL when the key was never written.
static id LMNCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)LMNPreferenceDomain);
    return CFBridgingRelease(value);
}

static CGFloat LMNReadPreferenceFloat(NSString *key, CGFloat fallback) {
    id value = LMNCopyPreference(key);
    if ([value isKindOfClass:[NSNumber class]]) {
        return (CGFloat)[(NSNumber *)value doubleValue];
    }
    return fallback;
}

static BOOL LMNReadPreferenceFlag(NSString *key, BOOL fallback) {
    id value = LMNCopyPreference(key);
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue];
    }
    return fallback;
}

static void LMNWritePreference(NSString *key, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          (__bridge CFPropertyListRef)value,
                          (__bridge CFStringRef)LMNPreferenceDomain,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)LMNPreferenceDomain,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
}

/// 1.2.37: 删除单个偏好键（用于单格清除颜色覆盖），回到「跟随主题」。
static void LMNDeletePreference(NSString *key) {
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          NULL,
                          (__bridge CFStringRef)LMNPreferenceDomain,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)LMNPreferenceDomain,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
}

/// Wake the runtime up so a parameter change is visible on the next alert, and
/// repaint any alert that is already on screen.
///
/// The notification is declared as a CFStringRef, and `notify_post` wants a C
/// string — casting the CFStringRef itself to `const char *` posts the address
/// of the __CFString struct as the notification name, which matches nothing the
/// runtime registered. Convert the characters instead.
///
/// 1.2.42: moved above the preset helpers because LMNApplyColorPreset calls it,
/// and C has no implicit declarations (this is a -Werror build).
static void LMNNotifyParametersChanged(void) {
    char name[256];
    if (CFStringGetCString(LMNGlassPreferencesChangedNotification, name,
                           sizeof(name), kCFStringEncodingUTF8)) {
        notify_post(name);
    }
}

#pragma mark - 1.2.42 colour presets

/// 1.2.42: 方案库所在的键。一个字典 { 方案名: { 覆盖键: 值 } }，和其它偏好同一个域，
/// 因此同样会被同步到 world-readable 副本 —— 不过运行时并不需要读它：LMNGlass 只认
/// 下面那 16 个覆盖键，方案只是"一次性把它们写进去"的快捷方式。
static NSString *const LMNKeyColorPresets = @"glassColorPresets";

/// 1.2.43: ColorSettings.plist 里方案槽位的 id 前缀。槽位本身是 plist 声明的普通
/// 行（cellClass = LMNColorPresetCell），代码靠这个前缀认出它们。
static NSString *LMNColorPresetSlotPrefix(void) {
    return @"LMNColorPresetSlot";
}

/// The layers a preset covers. One list, used by "恢复颜色默认", by 保存 and by
/// 应用 -- two lists would drift, and a layer missed by one of them would
/// silently keep its old colour after switching schemes.
///
/// Note the shape: fifteen of these are hex colour strings and one
/// (glassCardBorderWidth) is a NUMBER. Saving and applying copy the stored value
/// verbatim rather than round-tripping it through the hex helpers, so the width
/// is never fed to LMNColorFromHex and never silently falls back to 跟随主题.
static NSArray<NSString *> *LMNColorOverrideKeys(void) {
    return @[
        @"glassCardFill", @"glassCardBorder", @"glassCardBorderWidth",
        @"glassCardGloss",
        @"glassBtnFillPrimary", @"glassBtnBorderPrimary", @"glassBtnTextPrimary",
        @"glassBtnFillDestructive", @"glassBtnBorderDestructive",
        @"glassBtnTextDestructive",
        @"glassBtnFillSecondary", @"glassBtnBorderSecondary",
        @"glassBtnTextSecondary",
        @"glassTitleText", @"glassMessageText", @"glassScrim",
    ];
}

static NSDictionary<NSString *, NSDictionary *> *LMNCopyPresets(void) {
    id value = LMNCopyPreference(LMNKeyColorPresets);
    if ([value isKindOfClass:[NSDictionary class]]) {
        return value;
    }
    return @{};
}

/// Writing an empty dictionary DELETES the key: `__bridge` of an empty
/// dictionary is still a value, so the key has to be removed explicitly or an
/// abandoned `glassColorPresets` key sits in the store forever.
static void LMNWritePresets(NSDictionary<NSString *, NSDictionary *> *presets) {
    if (presets.count == 0) {
        LMNDeletePreference(LMNKeyColorPresets);
        return;
    }
    LMNWritePreference(LMNKeyColorPresets, presets);
}

/// Every layer that is currently overriding the theme, verbatim. A layer that is
/// following the theme is simply absent, which is what lets applying a preset
/// return the layers it does not cover back to 跟随主题.
static NSDictionary *LMNCopyCurrentColorOverrides(void) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    for (NSString *key in LMNColorOverrideKeys()) {
        id value = LMNCopyPreference(key);
        if (value != nil) {
            snapshot[key] = value;
        }
    }
    return [snapshot copy];
}

/// Apply a preset: each of the sixteen layers is either written from the preset
/// or DELETED. Deleting matters -- without it a layer the preset does not cover
/// would keep the colour it had before the switch instead of going back to
/// following the theme.
static void LMNApplyColorPreset(NSDictionary *preset) {
    for (NSString *key in LMNColorOverrideKeys()) {
        id value = preset[key];
        if (value != nil) {
            LMNWritePreference(key, value);
        } else {
            LMNDeletePreference(key);
        }
    }
    CFPreferencesSynchronize((__bridge CFStringRef)LMNPreferenceDomain,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost);
    LMNNotifyParametersChanged();
}

/// 1.2.42: 沿响应链向上找到承载该 cell 的视图控制器。cell 自己并不持有 controller
/// 引用，而应用/删除方案都要弹出确认弹窗，只有 controller 能稳定地 present。
static UIViewController *LMNHostViewControllerFor(UIResponder *start) {
    UIResponder *next = start;
    while (next != nil) {
        if ([next isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)next;
        }
        next = next.nextResponder;
    }
    return nil;
}

/// Declared here, ahead of LMNColorPresetCell, because that cell has to call
/// back into the page once a preset is applied or deleted, and Objective-C does
/// not let the same class be declared twice.
@interface LMNColorSettingsController : PSListController
/// 1.2.42: 重建整页。每一个 LMNColorCell 都在构造时缓存了自己的色板，所以应用方案
/// 后只刷新方案行是不够的 —— 16 个色格必须全部重建。
- (void)lmn_rebuildColorPage;
@end

/// 1.2.36: hex <-> UIColor（与 LMNGlass.swift 的 UIColor(lmn_hex:) 同规则）。
/// 设置 bundle不编译 Swift，故在 Objective-C 里重实现一份。
static UIColor *LMNColorFromHex(NSString *hex) {
    NSString *str = [hex stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([str hasPrefix:@"#"]) {
        str = [str substringFromIndex:1];
    }
    if (str.length == 6) {
        str = [str stringByAppendingString:@"FF"];
    }
    if (str.length != 8) {
        return nil;
    }
    unsigned long long value = 0;
    if (str && sscanf([str UTF8String], "%llX", &value) != 1) {
        return nil;
    }
    CGFloat r = ((value >> 24) & 0xFF) / 255.0;
    CGFloat g = ((value >> 16) & 0xFF) / 255.0;
    CGFloat b = ((value >> 8) & 0xFF) / 255.0;
    CGFloat a = (value & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static NSString *LMNHexFromColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02lX%02lX%02lX%02lX",
        (long)(r * 255.0 + 0.5), (long)(g * 255.0 + 0.5),
        (long)(b * 255.0 + 0.5), (long)(a * 255.0 + 0.5)];
}

#pragma mark - Slider cell

typedef NS_ENUM(NSInteger, LMNValueStyle) {
    LMNValueStylePoints2 = 0,
    LMNValueStylePoints0,
    LMNValueStyleRatio,
    LMNValueStylePercent,
};

@interface LMNGlassSliderCell : PSTableCell
@property(nonatomic, strong) UILabel *titleLabelView;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, copy) NSString *preferenceKey;
@property(nonatomic, assign) CGFloat minimumValue;
@property(nonatomic, assign) CGFloat maximumValue;
@property(nonatomic, assign) CGFloat defaultValue;
@property(nonatomic, assign) CGFloat inputStep;
@property(nonatomic, assign) LMNValueStyle valueStyle;
@end

@implementation LMNGlassSliderCell

+ (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return 76.0;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (self != nil) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        // The custom layout owns the title, so the inherited label would
        // otherwise render a duplicate caption underneath the slider.
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;

        _preferenceKey = [[specifier propertyForKey:@"preferenceKey"] copy];
        _minimumValue = [[specifier propertyForKey:@"minimumValue"] doubleValue];
        _maximumValue = [[specifier propertyForKey:@"maximumValue"] doubleValue];
        _defaultValue = [[specifier propertyForKey:@"defaultValue"] doubleValue];
        _inputStep = [[specifier propertyForKey:@"inputStep"] doubleValue];
        if (_inputStep <= 0.0 || !isfinite(_inputStep)) {
            _inputStep = 0.01;
        }
        NSString *styleName =
            [specifier propertyForKey:@"valueStyle"] ?: @"ratio";
        if ([styleName isEqualToString:@"points0"]) {
            _valueStyle = LMNValueStylePoints0;
        } else if ([styleName isEqualToString:@"percent"]) {
            _valueStyle = LMNValueStylePercent;
        } else if ([styleName isEqualToString:@"ratio"]) {
            _valueStyle = LMNValueStyleRatio;
        } else {
            _valueStyle = LMNValueStylePoints2;
        }

        _titleLabelView = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabelView.text = specifier.name;
        _titleLabelView.font = [UIFont systemFontOfSize:16.0];
        _titleLabelView.textColor = [UIColor labelColor];
        [self.contentView addSubview:_titleLabelView];

        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0
                                                             weight:UIFontWeightRegular];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];

        _slider = [[UISlider alloc] initWithFrame:CGRectZero];
        _slider.minimumValue = (float)_minimumValue;
        _slider.maximumValue = (float)_maximumValue;
        [_slider setValue:(float)[self normalizedValue:LMNReadPreferenceFloat(
                                                       _preferenceKey,
                                                       _defaultValue)]
                animated:NO];
        [_slider addTarget:self
                    action:@selector(sliderChanged:)
          forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self
                    action:@selector(sliderReleased:)
          forControlEvents:UIControlEventTouchUpInside |
                          UIControlEventTouchUpOutside];
        [self.contentView addSubview:_slider];

        [self updateValueLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    self.titleLabelView.frame = CGRectMake(16.0, 8.0, width * 0.6, 22.0);
    self.valueLabel.frame = CGRectMake(width * 0.6, 8.0, width * 0.4 - 16.0, 22.0);
    self.slider.frame = CGRectMake(16.0, 36.0, width - 32.0, 32.0);
}

- (CGFloat)normalizedValue:(CGFloat)value {
    if (!isfinite(value)) {
        value = self.defaultValue;
    }
    value = MAX(self.minimumValue, MIN(self.maximumValue, value));
    value = round(value / self.inputStep) * self.inputStep;
    return MAX(self.minimumValue, MIN(self.maximumValue, value));
}

- (NSString *)formattedValue:(CGFloat)value {
    switch (self.valueStyle) {
        case LMNValueStylePoints0:
            return [NSString stringWithFormat:@"%ld pt", (long)lround(value)];
        case LMNValueStylePercent:
            return [NSString stringWithFormat:@"%ld%%",
                                              (long)lround(value * 100.0)];
        case LMNValueStyleRatio:
            return [NSString stringWithFormat:@"%.2f", value];
        case LMNValueStylePoints2:
        default:
            return [NSString stringWithFormat:@"%.2f pt", value];
    }
}

- (void)updateValueLabel {
    self.valueLabel.text = [self formattedValue:[self normalizedValue:self.slider.value]];
}

- (void)sliderChanged:(UISlider *)slider {
    slider.value = (float)[self normalizedValue:slider.value];
    [self updateValueLabel];
    LMNNotifyParametersChanged();
}

- (void)sliderReleased:(UISlider *)slider {
    (void)slider;
    [self commitValue];
}

- (void)commitValue {
    if (self.preferenceKey.length == 0) {
        return;
    }
    CGFloat value = [self normalizedValue:self.slider.value];
    LMNWritePreference(self.preferenceKey, @(value));
    LMNNotifyParametersChanged();
}

@end

#pragma mark - Theme cell
//
// The three themes (1.2.0) are picked with a segmented control, and it is built
// here rather than declared as a bare PSSegmentCell for the same reason the
// sliders are: this page does not use Preferences' own plist domain anywhere.
// Every row writes through LMNWritePreference into com.zlhkf.lumen, which is
// the domain the injected runtime reads with CFPreferencesCopyAppValue. A stock
// PSSegmentCell reads and writes through the specifier's `key` + `defaults`
// pair instead; Root.plist declares neither, so a stock cell would render the
// three titles, move when tapped, and persist nothing — the picker would look
// correct and do nothing, which is exactly the failure this page's other rows
// are written to avoid.
//
// The plist still names PSSegmentCell as the row's `cell` and adds this class
// as `cellClass`, the same pairing the slider rows use (PSStaticTextCell +
// LMNGlassSliderCell): `cell` is the placeholder PSListController reads for
// geometry and grouping, and `cellClass` is what actually gets instantiated.
//
// 1.2.3: this cell is no longer theme-only. The 出现动画 (entrance) row reuses
// it verbatim — it is keyed entirely off `preferenceKey` and `validTitles`, so
// any PSSegmentCell that needs to write an integer index as an NSNumber into
// LMNPreferenceDomain (the domain the Swift runtime reads from) can point at it.
// A stock PSSegmentCell would persist through the bundle's own defaults domain
// as a STRING, which is the bug that made all three entrance choices look
// identical (the renderer's number(_:) only accepts NSNumber and fell back to
// 0 every time). Do not special-case the theme here; keep it generic.
@interface LMNGlassThemeCell : PSTableCell
@property(nonatomic, strong) UISegmentedControl *segmentedControl;
@property(nonatomic, copy) NSString *preferenceKey;
@end

@implementation LMNGlassThemeCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (self != nil) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        // The control carries its own captions, so the inherited labels would
        // render a duplicate row title behind it.
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;

        _preferenceKey = [[specifier propertyForKey:@"preferenceKey"] copy];
        NSArray<NSString *> *titles = [specifier propertyForKey:@"validTitles"];
        _segmentedControl =
            [[UISegmentedControl alloc] initWithItems:titles ?: @[]];
        _segmentedControl.apportionsSegmentWidthsByContent = NO;
        [_segmentedControl addTarget:self
                              action:@selector(themeChanged:)
                    forControlEvents:UIControlEventValueChanged];
        // Read the store rather than the specifier's `defaultValue`: an install
        // that already picked a theme must keep it, and the value has to come
        // from the same place the runtime reads it from.
        // `numberOfSegments` is NSUInteger, so it is narrowed once here rather
        // than compared against an NSInteger at each use: the comparison is
        // what -Werror flags (-Wsign-compare), and it is also the comparison
        // that would do the wrong thing for a negative stored value if the
        // usual arithmetic conversions were left to decide.
        NSInteger segments = (NSInteger)_segmentedControl.numberOfSegments;
        // Read only with a key in hand: CFPreferencesCopyAppValue does not
        // accept a NULL key, so a specifier that lost its preferenceKey would
        // take the Settings app down on this row.
        NSInteger raw = 0;
        if (_preferenceKey.length > 0) {
            raw = (NSInteger)lround(LMNReadPreferenceFloat(_preferenceKey, 0.0));
        }
        if (raw < 0 || raw >= segments) {
            // Nothing usable in the store, so fall back to what THIS row
            // declares rather than to a constant: the cell draws both 配色 and
            // 出现动画, whose defaults are 2 and 0 respectively, and a single
            // hardcoded fallback is how 配色 came to show 自动 while the
            // renderer read 0.
            raw = (NSInteger)lround(
                [[specifier propertyForKey:@"defaultValue"] doubleValue]);
            if (raw < 0 || raw >= segments) {
                raw = 0;
            }
        }
        // Guarded on a non-empty control: assigning a segment index to a
        // control with no segments is a range exception, and a specifier that
        // lost its validTitles would be exactly that control.
        if (segments > 0) {
            _segmentedControl.selectedSegmentIndex = raw;
        }
        [self.contentView addSubview:_segmentedControl];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    self.segmentedControl.frame = CGRectMake(16.0, 7.0, width - 32.0, 30.0);
}

- (void)themeChanged:(UISegmentedControl *)control {
    if (self.preferenceKey.length == 0) {
        return;
    }
    LMNWritePreference(self.preferenceKey, @(control.selectedSegmentIndex));
    LMNNotifyParametersChanged();
}

@end

#pragma mark - Colour cell

/// 1.2.36: 一个色格。左侧标题，右侧色板；点击弹出系统取色器，选色后把
/// #RRGGBBAA 写入对应 preferenceKey（与 LMNGlass.swift 读取端同格式）。缺键时
/// 色板显示「跟随主题」占位，写回即覆盖该层。
@interface LMNColorCell : PSTableCell
@property(nonatomic, strong) UILabel *swatchLabel;
@property(nonatomic, strong) UIView *swatch;
@property(nonatomic, strong) UILabel *titleView;
@property(nonatomic, copy) NSString *preferenceKey;
@end

@implementation LMNColorCell

+ (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return 52.0;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (self != nil) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;

        _preferenceKey = [[specifier propertyForKey:@"preferenceKey"] copy];

        _swatch = [[UIView alloc] initWithFrame:CGRectZero];
        _swatch.layer.cornerRadius = 6.0;
        _swatch.layer.masksToBounds = YES;
        _swatch.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        _swatch.layer.borderColor = [UIColor separatorColor].CGColor;
        [self.contentView addSubview:_swatch];

        _swatchLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _swatchLabel.font = [UIFont monospacedSystemFontOfSize:11.0
                                                         weight:UIFontWeightRegular];
        _swatchLabel.textColor = [UIColor secondaryLabelColor];
        _swatchLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_swatchLabel];

        _titleView = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleView.text = specifier.name;
        _titleView.font = [UIFont systemFontOfSize:16.0];
        _titleView.textColor = [UIColor labelColor];
        [self.contentView addSubview:_titleView];

        // 点按整格弹取色器（selectionStyle=None，故用手势而非选中态）。
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(lmn_presentPicker)];
        [self.contentView addGestureRecognizer:tap];

        // 1.2.37: 长按整格弹出确认，单独清除该格的颜色覆盖（不影响其它格）。
        UILongPressGestureRecognizer *longPress =
            [[UILongPressGestureRecognizer alloc]
                initWithTarget:self action:@selector(lmn_presentClear:)];
        longPress.minimumPressDuration = 0.6;
        [self.contentView addGestureRecognizer:longPress];

        [self lmn_refresh];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat h = CGRectGetHeight(self.contentView.bounds);
    _titleView.frame = CGRectMake(16.0, 0.0, width - 140.0, h);
    _swatch.frame = CGRectMake(width - 60.0, (h - 26.0) * 0.5, 44.0, 26.0);
    _swatchLabel.frame = CGRectMake(width - 116.0, (h - 22.0) * 0.5, 52.0, 22.0);
}

- (void)lmn_refresh {
    if (_preferenceKey.length == 0) {
        return;
    }
    NSString *hex = LMNCopyPreference(_preferenceKey);
    UIColor *color = LMNColorFromHex(hex);
    if (color != nil) {
        _swatch.backgroundColor = color;
        _swatchLabel.text = [hex uppercaseString];
    } else {
        _swatch.backgroundColor = [UIColor secondarySystemFillColor];
        _swatchLabel.text = @"跟随主题";
    }
}

- (void)lmn_presentPicker {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *picker =
            [[UIColorPickerViewController alloc] init];
        picker.supportsAlpha = YES;
        NSString *hex = LMNCopyPreference(_preferenceKey);
        UIColor *initial = LMNColorFromHex(hex);
        if (initial != nil) {
            picker.selectedColor = initial;
        }
        picker.delegate = (id<UIColorPickerViewControllerDelegate>)self;
        UIViewController *host = [self lmn_hostViewController];
        if (host != nil) {
            [host presentViewController:picker animated:YES completion:nil];
        }
    }
}

- (UIViewController *)lmn_hostViewController {
    UIResponder *next = self;
    while (next != nil) {
        if ([next isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)next;
        }
        next = next.nextResponder;
    }
    return nil;
}

- (void)lmn_presentClear:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if (_preferenceKey.length == 0) {
        return;
    }
    // 本格已是「跟随主题」（没有存值）则无需清除。
    if (LMNCopyPreference(_preferenceKey) == nil) {
        return;
    }
    UIViewController *host = [self lmn_hostViewController];
    if (host == nil) {
        return;
    }
    NSString *title = [NSString stringWithFormat:@"清除「%@」的颜色覆盖？",
                                                self.titleView.text];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:@"清除后该层恢复「跟随主题」。其余格子不受影响。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction * _Nonnull __unused action) {
        LMNDeletePreference(self.preferenceKey);
        LMNNotifyParametersChanged();
        [self lmn_refresh];
        NSLog(@"[lumen] 1.2.37 cleared color key %@", self.preferenceKey);
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

- (void)colorPickerViewControllerDidFinish:
        (UIColorPickerViewController *)viewController {
    if (_preferenceKey.length > 0) {
        LMNWritePreference(_preferenceKey, LMNHexFromColor(viewController.selectedColor));
        LMNNotifyParametersChanged();
    }
    [self lmn_refresh];
}

@end

#pragma mark - 1.2.42 colour preset cell

/// 1.2.42: 一个已保存的方案。左侧名称，右侧两个小色块 —— 卡片填充与主要按钮填充，
/// 这两层最能代表一套配色的观感，比列出全部十六格可读得多。
///
/// 交互与色格对齐：轻点应用，长按删除，两者都要确认。删除只动方案库本身，不动当前
/// 颜色设置 —— 否则"整理方案"会顺手把用户正在用的配色也改掉。
@interface LMNColorPresetCell : PSTableCell
@property(nonatomic, strong) UILabel *presetNameLabel;
@property(nonatomic, strong) UIView *cardSwatch;
@property(nonatomic, strong) UIView *buttonSwatch;
@property(nonatomic, copy) NSString *presetName;
@end

@implementation LMNColorPresetCell

+ (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return 52.0;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (self != nil) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;

        // 1.2.43: 名字只从 presetName 取。槽位行在 plist 里没有方案可显示时这个名字
        // 是空的，cell 就画成「暂无保存的方案」占位 —— 不再回落到 specifier.name，
        // 那是 plist 里给槽位写的通用标签，显示出来会莫名其妙。
        _presetName = [[specifier propertyForKey:@"presetName"] copy];

        _presetNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _presetNameLabel.font = [UIFont systemFontOfSize:16.0];
        _presetNameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_presetNameLabel];

        _cardSwatch = [self lmn_makeSwatch];
        _buttonSwatch = [self lmn_makeSwatch];
        [self.contentView addSubview:_cardSwatch];
        [self.contentView addSubview:_buttonSwatch];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(lmn_applyTapped)];
        [self.contentView addGestureRecognizer:tap];

        UILongPressGestureRecognizer *longPress =
            [[UILongPressGestureRecognizer alloc]
                initWithTarget:self action:@selector(lmn_deletePressed:)];
        longPress.minimumPressDuration = 0.6;
        [self.contentView addGestureRecognizer:longPress];

        [self lmn_refresh];
    }
    return self;
}

- (UIView *)lmn_makeSwatch {
    UIView *swatch = [[UIView alloc] initWithFrame:CGRectZero];
    swatch.layer.cornerRadius = 5.0;
    swatch.layer.masksToBounds = YES;
    swatch.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    swatch.layer.borderColor = [UIColor separatorColor].CGColor;
    return swatch;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    _presetNameLabel.frame = CGRectMake(16.0, 0.0, width - 108.0, height);
    _cardSwatch.frame = CGRectMake(width - 70.0, (height - 22.0) * 0.5, 22.0, 22.0);
    _buttonSwatch.frame = CGRectMake(width - 40.0, (height - 22.0) * 0.5, 22.0, 22.0);
}

- (void)lmn_refresh {
    if (_presetName.length == 0) {
        // 空槽位：一个没有名字的行就是「还没有方案」的占位。
        _presetNameLabel.text = @"暂无保存的方案";
        _presetNameLabel.textColor = [UIColor secondaryLabelColor];
        _cardSwatch.hidden = YES;
        _buttonSwatch.hidden = YES;
        return;
    }
    _presetNameLabel.text = _presetName;
    _presetNameLabel.textColor = [UIColor labelColor];
    _cardSwatch.hidden = NO;
    _buttonSwatch.hidden = NO;
    NSDictionary *preset = LMNCopyPresets()[_presetName];
    if (![preset isKindOfClass:[NSDictionary class]]) {
        preset = nil;
    }
    // A preset that does not cover a layer simply leaves that layer on 跟随主题
    // when applied, so an absent key here is a real state rather than a broken
    // save -- draw it as the neutral placeholder instead of a random colour.
    UIColor *card = LMNColorFromHex(preset[@"glassCardFill"]);
    UIColor *button = LMNColorFromHex(preset[@"glassBtnFillPrimary"]);
    _cardSwatch.backgroundColor = card ?: [UIColor secondarySystemFillColor];
    _buttonSwatch.backgroundColor = button ?: [UIColor secondarySystemFillColor];
}

- (void)lmn_applyTapped {
    if (_presetName.length == 0) {
        return;
    }
    NSDictionary *preset = LMNCopyPresets()[_presetName];
    if (![preset isKindOfClass:[NSDictionary class]]) {
        return;
    }
    UIViewController *host = LMNHostViewControllerFor(self);
    if (host == nil) {
        return;
    }
    NSString *title = [NSString stringWithFormat:@"应用配色「%@」？", _presetName];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:@"将覆盖当前 16 层颜色设置；方案未包含的层恢复「跟随主题」。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"应用"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction * _Nonnull __unused action) {
        LMNApplyColorPreset(preset);
        NSLog(@"[lumen] 1.2.42 applied color preset %@", self.presetName);
        if ([host isKindOfClass:[LMNColorSettingsController class]]) {
            [(LMNColorSettingsController *)host lmn_rebuildColorPage];
        }
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

- (void)lmn_deletePressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if (_presetName.length == 0) {
        return;
    }
    UIViewController *host = LMNHostViewControllerFor(self);
    if (host == nil) {
        return;
    }
    NSString *title = [NSString stringWithFormat:@"删除配色「%@」？", _presetName];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:@"仅删除这个方案，当前颜色设置不受影响。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction * _Nonnull __unused action) {
        NSMutableDictionary *all = [LMNCopyPresets() mutableCopy];
        [all removeObjectForKey:self.presetName];
        // Deleting the last preset must delete the KEY too, not leave an empty
        // dictionary behind -- LMNWritePresets does that.
        LMNWritePresets(all);
        NSLog(@"[lumen] 1.2.42 deleted color preset %@", self.presetName);
        if ([host isKindOfClass:[LMNColorSettingsController class]]) {
            [(LMNColorSettingsController *)host lmn_rebuildColorPage];
        }
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Colour settings page

/// 1.2.36: 自定义颜色子页。加载 ColorSettings.plist，并实现「恢复颜色默认」。
///
/// 1.2.42: 页面顶部多了一个「配色方案」分组。
///
/// 1.2.43: 方案行改为 plist 声明的固定槽位（数量上限见 ColorSettings.plist），代码
/// 只负责把方案名填进去、并收掉多余的空槽。1.2.42 的「代码拼 specifier」做法让
/// Preferences 在建行时 doesNotRecognizeSelector → abort。
@implementation LMNColorSettingsController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *items =
            [[self loadSpecifiersFromPlistName:@"ColorSettings" target:self] mutableCopy];
        // 1.2.43: 行已经在 plist 里了，这里只把方案名填进槽位、并收掉多余的空槽。
        [self lmn_layoutPresetSlotsIn:items];
        _specifiers = items;
    }
    return _specifiers;
}

- (void)lmn_rebuildColorPage {
    // 先清缓存再取一次，让 -specifiers 重新拼装动态行；然后才请求重绘。只调
    // reloadSpecifiers 不够 —— 它重绘的是 _specifiers 里已有的那份旧数组。
    _specifiers = nil;
    (void)[self specifiers];
    [self reloadSpecifiers];
}

/// 方案行的名字写进 plist 已声明的槽位。
///
/// 1.2.43: 行本身不再由代码生成。1.2.42 用 [PSSpecifier preferenceSpecifierNamed:]
/// 拼行、再用 setProperty:forKey:@"cellClass" 挂自定义 cell，Preferences 在建这一行
/// 时直接 doesNotRecognizeSelector → abort（reloadSpecifiers →
/// tableView:cellForRowAtIndexPath: → ___forwarding___）。本 bundle 每一个自定义
/// cell（LMNColorCell / LMNGlassSliderCell / LMNGlassThemeCell）都是 plist 声明的，
/// 那条路径是验证过的；代码拼的那条不是，而且这里没法编译验证。
///
/// 所以 plist 里放固定 20 个槽位（cellClass 与所有其它行完全同构），代码只决定
/// 显示前几个、每个叫什么。槽位用尽就只显示前 20 个。
- (void)lmn_layoutPresetSlotsIn:(NSMutableArray *)items {
    NSMutableArray<NSNumber *> *slotIndexes = [NSMutableArray array];
    for (NSUInteger index = 0; index < items.count; index++) {
        PSSpecifier *specifier = items[index];
        if (![specifier isKindOfClass:[PSSpecifier class]]) {
            continue;
        }
        NSString *identifier = [specifier propertyForKey:@"id"];
        if ([identifier hasPrefix:LMNColorPresetSlotPrefix()]) {
            [slotIndexes addObject:@(index)];
        }
    }
    if (slotIndexes.count == 0) {
        NSLog(@"[lumen] 1.2.43 no preset slots in ColorSettings.plist");
        return;
    }
    NSDictionary<NSString *, NSDictionary *> *presets = LMNCopyPresets();
    NSArray<NSString *> *names = [[presets allKeys]
        sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    // 没有方案时保留一格，让 cell 显示「暂无保存的方案」—— 一个只有标题和按钮的
    // 空分组看起来像坏了。
    NSUInteger keep = MIN(names.count, slotIndexes.count);
    if (keep == 0) {
        keep = 1;
    }
    if (names.count > slotIndexes.count) {
        NSLog(@"[lumen] 1.2.43 showing %lu of %lu presets (slot pool full)",
              (unsigned long)slotIndexes.count, (unsigned long)names.count);
    }
    // 删掉多余槽位。被删的下标全部在保留的之后，所以先删不会挪动要保留的那些。
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
    for (NSUInteger index = keep; index < slotIndexes.count; index++) {
        [drop addIndex:[slotIndexes[index] unsignedIntegerValue]];
    }
    [items removeObjectsAtIndexes:drop];
    for (NSUInteger index = 0; index < keep; index++) {
        PSSpecifier *row = items[[slotIndexes[index] unsignedIntegerValue]];
        NSString *name = index < names.count ? names[index] : @"";
        [row setProperty:name forKey:@"presetName"];
    }
}

- (void)saveColorPreset:(PSSpecifier *)specifier {
    (void)specifier;
    NSDictionary *snapshot = LMNCopyCurrentColorOverrides();
    // Saving "everything follows the theme" would produce a preset that applies
    // to nothing -- applying it would look like the button simply did not work.
    if (snapshot.count == 0) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"当前没有自定义颜色"
                             message:@"十六层都在「跟随主题」。先给任意一层设色，再保存方案。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        NSLog(@"[lumen] 1.2.42 refused empty color preset");
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"保存配色方案"
                         message:[NSString stringWithFormat:@"将保存当前 %lu 层颜色覆盖。",
                                  (unsigned long)snapshot.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"方案名称";
        // Pre-filled with a name that cannot collide, so tapping 保存 straight
        // away does what it looks like it does.
        textField.text = [NSString stringWithFormat:@"配色 %lu",
                          (unsigned long)(LMNCopyPresets().count + 1)];
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction * _Nonnull __unused action) {
        NSString *name = [[alert.textFields.firstObject text]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length == 0) {
            NSLog(@"[lumen] 1.2.42 rejected blank color preset name");
            return;
        }
        if (LMNCopyPresets()[name] != nil) {
            [self lmn_confirmOverwritePreset:name snapshot:snapshot];
            return;
        }
        [self lmn_storePreset:snapshot name:name];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 同名已存在时再问一次。第二次 present 必须等系统弹窗自己的消失动画走完：UIKit
/// 在 dismiss 进行中收到新的 present 会直接丢弃它，弹窗就"点了没反应"。
- (void)lmn_confirmOverwritePreset:(NSString *)name snapshot:(NSDictionary *)snapshot {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"「%@」已存在", name]
                             message:@"保存将覆盖同名方案。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"覆盖"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction * _Nonnull __unused action) {
            [self lmn_storePreset:snapshot name:name];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)lmn_storePreset:(NSDictionary *)snapshot name:(NSString *)name {
    NSMutableDictionary *all = [LMNCopyPresets() mutableCopy];
    all[name] = snapshot;
    LMNWritePresets(all);
    NSLog(@"[lumen] 1.2.42 saved color preset %@ (%lu layers)", name,
          (unsigned long)snapshot.count);
    [self lmn_rebuildColorPage];
}

- (void)restoreColorDefaults:(PSSpecifier *)specifier {
    (void)specifier;
    // 1.2.42: 空方案 = 十六层全部删除 = 跟随主题。与应用方案走同一条路径，不再单独
    // 维护一份键列表 —— 两份列表迟早会不一致，而漏掉的那层会悄悄留着旧颜色。
    LMNApplyColorPreset(@{});
    [self lmn_rebuildColorPage];
}

@end

#pragma mark - Root list

@interface LMNRootListController : PSListController
@end

@implementation LMNRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

/// The page is described by Root.plist rather than built in code.
/// PSListController reconciles its specifier array against grouping metadata
/// that only the plist carries; constructing the same groups in code made the
/// settings app abort on open. Overriding `-specifiers` alone is also required:
/// PSListController calls `-loadSpecifiers` itself and assigns the result here,
/// so overriding both hooks gives the array two construction paths that
/// overwrite each other.
- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (NSNumber *)masterEnabled:(PSSpecifier *)specifier {
    (void)specifier;
    return @(LMNReadPreferenceFlag(LMNKeyGlassEnabled, YES));
}

- (void)setMasterEnabled:(id)value specifier:(PSSpecifier *)specifier {
    (void)specifier;
    LMNWritePreference(LMNKeyGlassEnabled, value);
    LMNNotifyParametersChanged();
}

- (void)restoreDefaults:(PSSpecifier *)specifier {
    (void)specifier;
    NSDictionary<NSString *, NSNumber *> *defaults = LMNDefaultValues();
    [defaults enumerateKeysAndObjectsUsingBlock:^(
        NSString *key, NSNumber *value, BOOL *stop) {
        (void)stop;
        LMNWritePreference(key, value);
    }];
    LMNNotifyParametersChanged();
    // The slider cells cache their value at construction, so the page has to be
    // rebuilt for the restored numbers to show.
    [self reloadSpecifiers];
}

- (void)previewAlert:(PSSpecifier *)specifier {
    (void)specifier;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"标题文字"
                         message:@"这是当前设置的弹窗效果。可以返回调整圆角、宽度和按钮"
                                 @"外观，再次打开预览。"
                  preferredStyle:UIAlertControllerStyleAlert];
    // Nominate the first action so Settings can actually demonstrate the accent
    // capsule. The restyler keys the blue off `preferredAction` rather than
    // "whichever ordinary action comes first" (the reference light-mode sheet is
    // all-neutral), so without this the preview would come out entirely neutral
    // and the accent would be invisible in Settings.
    UIAlertAction *accent = [UIAlertAction actionWithTitle:@"第一个选项"
                                                    style:UIAlertActionStyleDefault
                                                  handler:nil];
    [alert addAction:accent];
    alert.preferredAction = accent;
    [alert addAction:[UIAlertAction actionWithTitle:@"第二个选项"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"第三个长文字选项"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除"
                                              style:UIAlertActionStyleDestructive
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"选中文本";
    }];
    [self presentViewController:alert animated:YES completion:nil];
}

/// The reference package's own preview shape: a rounded-square card carrying a
/// title, a paragraph, and two capsules side by side.
///
/// Worth having as its own row rather than another button on 预览弹窗: this is
/// the alert most screenshots of the reference show, and 预览弹窗 -- five
/// actions plus a text field -- cannot show it. Nothing here is drawn by hand;
/// it is a real UIAlertController, so what the page shows is what the tweak
/// does to a real alert.
- (void)previewCompactAlert:(PSSpecifier *)specifier {
    (void)specifier;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"玻璃已就绪"
                         message:@"这是完全独立绘制的窗口。系统弹窗只提供标题、正文和操作数据，"
                                 @"视觉层级与交互均由 Lumen 接管。"
                  preferredStyle:UIAlertControllerStyleAlert];
    // `preferredAction` is what keys the accent capsule, so the primary button
    // has to be nominated rather than merely added first -- see previewAlert:.
    UIAlertAction *primary = [UIAlertAction actionWithTitle:@"继续探索"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil];
    [alert addAction:primary];
    alert.preferredAction = primary;
    [alert addAction:[UIAlertAction actionWithTitle:@"稍后"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)previewActionSheet:(PSSpecifier *)specifier {
    (void)specifier;
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"标题文字"
                         message:@"这是操作菜单样式。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"第一个选项"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"第二个选项"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"第三个长文字选项"
                                              style:UIAlertActionStyleDestructive
                                            handler:nil]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds),
                   1.0, 1.0);
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

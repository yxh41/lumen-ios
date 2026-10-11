#import "LMNAlertRestyler.h"

#import <objc/runtime.h>

#import "LMNGlassStyle.h"

// The appearance half is Swift. Theos generates Lumen-Swift.h from
// LMNGlass.swift / LMNGlassPanelView.swift and puts its directory on the
// include path, so this is how Objective-C sees LMNGlass, LMNGlassParams and
// LMNGlassPanelView.
//
// `LMNGlassStyle.h` is still imported directly — for the preference domain, the
// change notification, the capsule role enum and the clamp bounds. It is also
// the only header the bridging header names, which is why it must never grow an
// @interface for a class Swift defines.
#import "Lumen-Swift.h"

static const void *LMNPanelKey = &LMNPanelKey;
static const void *LMNRowCapsuleKey = &LMNRowCapsuleKey;
static const void *LMNRowShineKey = &LMNRowShineKey;
static const void *LMNGrabberKey = &LMNGrabberKey;

/// Darwin notification callback. Declared up front because `+bootstrap` uses it
/// before the definition at the bottom of this file.
static void LMNGlassPreferenceChangedCallback(CFNotificationCenterRef center,
                                              void *observer, CFStringRef name,
                                              const void *object,
                                              CFDictionaryRef userInfo);

/// One-shot-per-process diagnostic (defined further down). Declared up front
/// because helpers defined above its definition -- LMNRecolorLabel and the
/// LMNAlertCards geometric fallback -- call it, and the compiler is C99-strict
/// under -Werror, which rejects an implicit declaration.
static void LMNProbe(NSString *format, ...);

#pragma mark - View discovery

/// A single action row on iOS 16 is a `_UIAlertControllerActionView`, so its
/// class name *contains* "ActionView". The card search used to look for that
/// name, which matched the first ROW instead of the sheet. The glass panel was
/// then injected into one action row — on screen that is the floating capsule
/// sitting over "第一个选项" — while the real card kept its opaque background,
/// so the sheet stayed a plain white slab with no glass anywhere. Rows are used
/// to *derive* the card now, never as the card itself.
static BOOL LMNClassNameHasActionView(UIView *view) {
    NSString *name = NSStringFromClass([view class]);
    return [name rangeOfString:@"ActionView"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL LMNSubtreeHasActionView(UIView *view) {
    if (LMNClassNameHasActionView(view)) {
        return YES;
    }
    for (UIView *subview in view.subviews) {
        if (LMNSubtreeHasActionView(subview)) {
            return YES;
        }
    }
    return NO;
}

/// Leaf rows only: a container that itself holds a row is a sheet, not a row.
static void LMNCollectActionRows(UIView *view, NSMutableArray<UIView *> *rows) {
    if (LMNClassNameHasActionView(view)) {
        BOOL holdsAnotherRow = NO;
        for (UIView *subview in view.subviews) {
            if (LMNSubtreeHasActionView(subview)) {
                holdsAnotherRow = YES;
                break;
            }
        }
        if (!holdsAnotherRow) {
            [rows addObject:view];
            return;
        }
    }
    for (UIView *subview in view.subviews) {
        LMNCollectActionRows(subview, rows);
    }
}

/// Opacity of a colour, read straight off its `CGColor`.
///
/// `getWhite:alpha:` was the previous way to pull the alpha out, and it is not a
/// plain accessor: it FAILS for any colour that is not a pure grey. `systemGray6`
/// — (0.949, 0.949, 0.969), a background iOS hands plenty of alert containers —
/// is rejected outright, so a tinted opaque background was classified as "no
/// background here" and left in place. The panel is inserted at index 0, so
/// anything opaque above it hides the glass completely: the alert keeps its
/// native slab while the capsules (drawn by an independent, unconditional pass)
/// turn glass. That is the exact "buttons are ours, background is not" split.
/// Opacity is the property these callers are actually asking about, and
/// `CGColorGetAlpha` answers it in every colour space.
static CGFloat LMNColorAlpha(UIColor *color) {
    if (color == nil) {
        return 0.0;
    }
    return CGColorGetAlpha(color.CGColor);
}

static BOOL LMNViewIsLikelyBackgroundHolder(UIView *view) {
    // Content classes are never background holders: clearing their paint would
    // erase what they show (an icon, a label, a button face) or our own glass.
    // UIScrollView and UIStackView are deliberately NOT excluded — an alert
    // frequently carries its opaque background on one of those containers, and
    // excluding them left that background in place (the "背景覆不到位" symptom).
    if ([view isKindOfClass:[UIImageView class]] ||
        [view isKindOfClass:[UILabel class]] ||
        [view isKindOfClass:[UIButton class]] ||
        [view isKindOfClass:[UITextField class]] ||
        [view isKindOfClass:[UIVisualEffectView class]] ||
        [view isKindOfClass:[LMNGlassPanelView class]]) {
        return NO;
    }
    // Test opacity, not brightness: a dark-mode alert card is near-black, and
    // a brightness test would happily leave that background in place. The 0.9
    // floor also catches the 0.92–0.97 "milky" materials some system sheets
    // use, which read as opaque on screen but survived the old 0.99 test.
    // Asking getWhite: for the alpha additionally demanded a pure grey, which
    // silently exempted every tinted background — see LMNColorAlpha.
    return LMNColorAlpha(view.backgroundColor) > 0.9;
}

/// UIAlertController draws its solid card on one or two nested container views
/// whose alpha is fully opaque. Clear them so the glass underneath can show
/// through, but only for views that really are the card background.
static void LMNClearOpaqueBackgrounds(UIView *view, CGRect cardBounds,
                                      NSInteger depth) {
    if (view == nil || depth < 0) {
        return;
    }
    // Never recurse into our own glass: the effect-view neutralisation below
    // would blank the panel's blur along with the alert's native backdrop.
    if ([view isKindOfClass:[LMNGlassPanelView class]]) {
        return;
    }
    // iOS 16 paints the alert's milky backdrop with a UIVisualEffectView that
    // sits above the panel we insert at index 0. Left in place it hides the
    // glass entirely and the finished alert reads as a plain opaque sheet, so
    // drop the effect and let the panel be the only material on screen.
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        ((UIVisualEffectView *)view).effect = nil;
        view.backgroundColor = [UIColor clearColor];
    }
    CGFloat width = CGRectGetWidth(cardBounds);
    if (width > 0.0 && CGRectGetWidth(view.bounds) >= width * 0.9 &&
        LMNViewIsLikelyBackgroundHolder(view)) {
        view.backgroundColor = [UIColor clearColor];
    }
    for (UIView *subview in view.subviews) {
        LMNClearOpaqueBackgrounds(subview, cardBounds, depth - 1);
    }
}

/// Hide the hairline separators inside an alert card.
///
/// iOS draws a `_UIInterfaceActionVibrantSeparatorView` between action rows and
/// around the action group. On a glass card those hairlines are the host's own
/// chrome still showing through -- the vertical rule between a two-up button
/// pair, and the edge line along the top of the action group, both visible in
/// the reported permission-dialog screenshots. The Liquid Glass reference hides
/// exactly this class for the same reason. Only the paint goes and the views
/// stay in the tree, so no layout that references them is disturbed.
static void LMNHideActionSeparators(UIView *view) {
    for (UIView *subview in view.subviews) {
        NSString *name = NSStringFromClass([subview class]);
        if ([name rangeOfString:@"Separator"
                        options:NSCaseInsensitiveSearch].location != NSNotFound) {
            subview.hidden = YES;
            subview.alpha = 0.0;
            continue;
        }
        LMNHideActionSeparators(subview);
    }
}

static void LMNCollectButtons(UIView *view, NSMutableArray<UIButton *> *result) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIButton class]]) {
            [result addObject:(UIButton *)subview];
        }
        LMNCollectButtons(subview, result);
    }
}

/// Whether `button` is one of an action row's own controls, i.e. whether
/// LMNStyleActionRow has already painted a capsule for it.
///
/// This is the seam between the two renderers that can both reach one button.
/// On iOS 16 an app alert's action is a `_UIAlertControllerActionView` — a plain
/// view with a label and no button in it — so `LMNCollectButtons` finds nothing
/// and the row's capsule is the only glass on screen. SpringBoard's system
/// dialogs (`_SBAlertController`, i.e. every notification / ATT / location
/// permission prompt) build the same rows out of REAL UIButtons, so both paths
/// hit the same control: the row pass inserts a pill behind the label, the card
/// pass then fills the button itself with the same material, its 1pt lit rim and
/// its drop shadow. Two concentric glass pills is the reported "the buttons have
/// another layer inside them".
///
/// The walk stops at `card` so it cannot escape into an unrelated part of the
/// tree, and it is deliberately the SAME predicate LMNCollectActionRows uses to
/// decide what a row is — otherwise the two passes could disagree about which
/// buttons they own and the double pill would come back on some other tree.
static BOOL LMNButtonIsInsideActionRow(UIButton *button, UIView *card) {
    if (button == nil) {
        return NO;
    }
    for (UIView *probe = button; probe != nil && probe != card;
         probe = probe.superview) {
        if (LMNClassNameHasActionView(probe)) {
            return YES;
        }
    }
    return NO;
}

/// Whether `row` sits inside a card this pass actually glassed.
///
/// This is the second half of the 1.2.7 guard, and it is the one that matters
/// when card RECOGNITION is what failed rather than the button pass. A capsule
/// is drawn behind the row's own label, so on a card that never received a panel
/// it is one of our pills floating on the host's own slab: the reported "the
/// window was not replaced but the buttons are ours" from the system permission
/// dialogs. The row pass runs unconditionally over the whole controller -- that
/// is deliberate and documented, because on an app alert it recovers the cancel
/// row of an action sheet whose second card was not recognised -- so nothing
/// else stops it from decorating a presentation we never glassed.
///
/// Tying the two together is what makes the system-dialog path all-or-nothing:
/// either the card is glassed and its rows get capsules, or nothing of ours is
/// drawn at all and the dialog keeps its native skin. The panel is the marker
/// because it is exactly the thing whose absence the user sees.
static BOOL LMNRowSitsOnGlass(UIView *row) {
    for (UIView *probe = row; probe != nil; probe = probe.superview) {
        LMNGlassPanelView *panel = objc_getAssociatedObject(probe, LMNPanelKey);
        if (panel != nil && !CGRectIsEmpty(panel.bounds)) {
            return YES;
        }
    }
    return NO;
}

static void LMNCollectTextFields(UIView *view,
                                NSMutableArray<UITextField *> *result) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UITextField class]]) {
            [result addObject:(UITextField *)subview];
        }
        LMNCollectTextFields(subview, result);
    }
}

static void LMNCollectLabels(UIView *view, NSMutableArray<UILabel *> *result) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            [result addObject:(UILabel *)subview];
        }
        LMNCollectLabels(subview, result);
    }
}

static BOOL LMNViewIsInsideTextField(UIView *view, UIView *root) {
    UIView *probe = view;
    while (probe != nil && probe != root) {
        if ([probe isKindOfClass:[UITextField class]]) {
            return YES;
        }
        probe = probe.superview;
    }
    return NO;
}

/// A card must never be the screen-sized presentation container: painting the
/// glass over that would veil the whole screen instead of the sheet.
static BOOL LMNCardLooksLikeCard(UIView *card, UIView *root) {
    if (card == nil || card == root) {
        return NO;
    }
    CGFloat width = CGRectGetWidth(card.bounds);
    CGFloat height = CGRectGetHeight(card.bounds);
    if (width <= 0.0 || height <= 0.0) {
        return NO;
    }
    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    if (rootWidth > 0.0 && rootHeight > 0.0 && width >= rootWidth * 0.99 &&
        height >= rootHeight * 0.99) {
        return NO;
    }
    return YES;
}

/// Whether this presentation is a SYSTEM dialog -- SpringBoard's notification /
/// ATT / location permission prompts -- which Lumen restyles in place and never
/// replaces.
///
/// The signal that separates a system dialog from an app alert is NOT simply
/// the concrete class. `_SBAlertController`, SpringBoard's controller for those
/// prompts, **IS a `UIAlertController` subclass**, and the modern ATT / location
/// / notification prompts present as a bare `UIAlertController` with no private
/// subclass at all -- so `[controller class] != [UIAlertController class]` is
/// FALSE for them, and they silently fell into the App branch:
///
///   * The all-or-nothing guard (restyleController:, `cards.count == 0`) never
///     fired, so a dialog whose card was not recognised was not left native.
///   * LMNStyleAllActionRows ran with `requireGlass == NO`, so it painted
///     Lumen's capsules on the host's own buttons even when the card was never
///     glassed -- "the window was not replaced but the buttons are ours", the
///     exact split the user still saw on 1.2.10 permission dialogs.
///
/// The reliable signal is the CONTEXT, not the class: Lumen only reaches the
/// in-place restyler (and only declines to REPLACE) inside SpringBoard. Any
/// alert restyled in place there is a system dialog. So this returns YES when
/// replacement is forbidden here (SpringBoard), and otherwise keeps the
/// concrete-class test as a secondary signal for the private subclasses. Keying
/// on the context is what makes the guard and `requireGlass` engage for the bare
/// `UIAlertController` permission prompts, and it leaves the App branch -- a
/// plain `UIAlertController` outside SpringBoard -- untouched.
///
/// Duplicated from LMNModernAlertController.m's LMNReplacementIsForbiddenHere
/// rather than shared: keeping this file free of the replacement renderer's
/// linkage is what lets the two renderers compile and gate independently.
static BOOL LMNIsSpringBoardProcess(void) {
    static BOOL isSB = NO;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        NSString *host = [NSBundle.mainBundle.bundleIdentifier lowercaseString];
        NSString *name = NSProcessInfo.processInfo.processName;
        isSB = ([host isEqualToString:@"com.apple.springboard"]
                || [name isEqualToString:@"SpringBoard"]);
    }
    return isSB;
}

static BOOL LMNControllerIsSystemDialog(UIViewController *controller) {
    if (controller == nil) {
        return NO;
    }
    // 1.2.11: a bare UIAlertController presented in SpringBoard (ATT / location /
    // notification prompts) is a system dialog even though its concrete class is
    // exactly UIAlertController. Replacement is declined there, so "replacement
    // is forbidden here" is the trustworthy signal; the class test is a fallback
    // for the private subclasses.
    if (LMNIsSpringBoardProcess()) {
        return YES;
    }
    return [controller class] != [UIAlertController class];
}

/// Mirror of LMNClearOpaqueBackgrounds for the views ABOVE the card.
///
/// LMNClearOpaqueBackgrounds only walks DOWN from the card, so a card can be
/// perfectly transparent and still sit on an opaque host panel that stops the
/// glass blur from sampling the app behind it -- the finished alert then reads
/// as a flat slab with no backdrop showing through. Walk up from the card and
/// clear any opaque, non-full-screen background holder, but stop short of the
/// full-screen presentation container or the screen dimming would be wiped out
/// too.
static void LMNClearOpaqueAncestors(UIView *card, UIView *root, NSInteger limit) {
    UIView *probe = card.superview;
    for (NSInteger level = 0; probe != nil && probe != root && level < limit;
         level++, probe = probe.superview) {
        // A UIVisualEffectView above the card (e.g. a backdrop FX) blocks the
        // panel's blur just like an opaque background: neutralise it the same
        // way the down-walk does, so the glass samples the app behind it.
        if ([probe isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)probe).effect = nil;
            probe.backgroundColor = [UIColor clearColor];
            continue;
        }
        // A full-bleed view is normally the dimming / presentation container.
        // Keep a *semi-transparent* scrim, but DO clear a full-bleed OPAQUE
        // backdrop -- that one blocks the glass exactly like a smaller host and
        // was being preserved by mistake.
        if (!LMNCardLooksLikeCard(probe, root)) {
            if (LMNColorAlpha(probe.backgroundColor) > 0.9) {
                probe.backgroundColor = [UIColor clearColor];
            }
            continue;
        }
        CGFloat cardWidth = CGRectGetWidth(card.bounds);
        if (cardWidth <= 0.0 ||
            CGRectGetWidth(probe.bounds) < cardWidth * 0.9) {
            continue;
        }
        if (LMNViewIsLikelyBackgroundHolder(probe)) {
            probe.backgroundColor = [UIColor clearColor];
        }
    }
    // Also clear an opaque host that IS the controller's own view (root). The
    // loop above stops at root, so root was never inspected. Never climb past
    // root into the window -- a solid window background must stay put.
    if (root != nil && root != card) {
        if ([root isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)root).effect = nil;
            root.backgroundColor = [UIColor clearColor];
        } else if (!LMNCardLooksLikeCard(root, root)) {
            if (LMNColorAlpha(root.backgroundColor) > 0.9) {
                root.backgroundColor = [UIColor clearColor];
            }
        } else if (LMNViewIsLikelyBackgroundHolder(root)) {
            root.backgroundColor = [UIColor clearColor];
        }
    }
}

/// Climb from a row to the container that actually draws the sheet. Wrappers
/// above a row hug its width, so the first ancestor that is *wider* is the
/// full-bleed presentation view and the climb stops there.
static UIView *LMNCardForActionRow(UIView *row, UIView *root) {
    UIView *card = row.superview;
    if (card == nil) {
        return nil;
    }
    while (card.superview != nil && card.superview != root) {
        UIView *parent = card.superview;
        if (CGRectGetWidth(parent.bounds) > CGRectGetWidth(card.bounds) * 1.02) {
            break;
        }
        if (!LMNCardLooksLikeCard(parent, root)) {
            break;
        }
        card = parent;
    }
    return card;
}

/// The card a row ultimately belongs to, found by climbing the same way
/// `LMNCardForActionRow` does but without needing the presentation root.
///
/// A row's own superview is NOT the card: UIKit nests a wrapper between them, and
/// the row is inset inside that wrapper. Insetting a capsule from the row
/// therefore measures the gap from the wrong rectangle. Climbing to the card lets
/// the geometry be expressed against the edge the user can actually see.
///
/// Returns nil rather than guessing when the climb hits something implausible, so
/// the caller can fall back to the row-relative behaviour.
static UIView *LMNFindOwningCard(UIView *row) {
    UIView *card = row.superview;
    if (card == nil) {
        return nil;
    }
    for (NSInteger depth = 0; depth < 4 && card.superview != nil; depth++) {
        UIView *parent = card.superview;
        CGFloat width = CGRectGetWidth(parent.bounds);
        // The card is the first ancestor that is at least as wide as the row plus
        // the row's own offset — i.e. the first one the row is inset *inside*.
        // Stop before climbing into the full-screen presentation container, which
        // would make every row look like it spans the screen.
        if (width > CGRectGetWidth(row.bounds) * 1.02) {
            break;
        }
        card = parent;
    }
    // A card that ended up as wide as the screen is the presentation view, not a
    // card; refuse it rather than insetting against the screen edge.
    UIView *root = row;
    while (root.superview != nil) {
        root = root.superview;
    }
    if (card == root) {
        return nil;
    }
    return card;
}

/// The glassed card a row actually sits on.
///
/// 1.2.12: the pill used to be inset against `LMNFindOwningCard`'s guess, which
/// is a SECOND and independent path from the one that glassed the card. On the
/// permission sheets that guess returns nil -- it refuses a card that equals the
/// root -- so the geometry silently fell back to the row's own content view, a
/// different and narrower rectangle than the sheet the user can actually see,
/// while the height stayed a fixed 48pt with nothing pulling it back inside the
/// card. That is the "按钮跟背景大小不协调" report: the pill was measured against
/// the wrong rectangle and poked out through the sheet's rounded corners.
///
/// Taking the card straight from LMNAlertCards removes the second guess, so the
/// pill is inset against exactly the sheet that was glassed.
static UIView *LMNGlassCardForRow(UIView *row, NSArray<UIView *> *cards) {
    for (UIView *card in cards) {
        if (card == row || [row isDescendantOfView:card]) {
            return card;
        }
    }
    return nil;
}

/// A gutter that stays proportional to the card it is spent against.
///
/// The theme's `buttonInset` is a flat point value (16 by default). That is
/// right for one card size and wrong at both ends: too small on a wide sheet,
/// so the pill reads as a slab, and large enough to eat a narrow sheet whole.
/// Clamping the authored value into a proportional band keeps the designer's
/// number wherever it is already sane and only intervenes at the extremes, so
/// two-button, three-button and map-bearing sheets all end up coordinated.
static CGFloat LMNAdaptiveGutter(CGFloat inset, CGFloat cardWidth) {
    if (cardWidth <= 0.0) {
        return inset;
    }
    CGFloat low = cardWidth * 0.025;
    CGFloat high = cardWidth * 0.075;
    if (low > high) {
        return inset;
    }
    return MAX(low, MIN(high, inset));
}

/// Fallback for a presentation whose rows cannot be identified: the card is the
/// largest subview that is not the full-screen container.
static UIView *LMNGeometricCard(UIView *root) {
    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    UIView *best = nil;
    CGFloat bestArea = 0.0;
    for (UIView *subview in root.subviews) {
        CGFloat width = CGRectGetWidth(subview.bounds);
        CGFloat height = CGRectGetHeight(subview.bounds);
        if (width <= 0.0 || height <= 0.0) {
            continue;
        }
        if (rootWidth > 0.0 && rootHeight > 0.0 && width >= rootWidth - 1.0 &&
            height >= rootHeight - 1.0) {
            continue;
        }
        CGFloat area = width * height;
        if (area > bestArea) {
            bestArea = area;
            best = subview;
        }
    }
    return best;
}

/// Recursive twin of LMNGeometricCard for the row-detection fallback: gather
/// every view at ANY depth that looks like a card (non-full-screen). The old
/// fallback only inspected the controller's direct children, so a card nested
/// one level deeper (root -> container -> card) was never found and the alert
/// stayed in its native skin — a large share of the "部分弹窗还是原样式"
/// reports. Width/height guards in the caller keep buttons and labels out.
static void LMNCollectGeometricCards(UIView *view, UIView *root,
                                     NSMutableArray<UIView *> *out) {
    for (UIView *subview in view.subviews) {
        if (LMNCardLooksLikeCard(subview, root)) {
            [out addObject:subview];
        }
        LMNCollectGeometricCards(subview, root, out);
    }
}

@interface UIView (LMNAlertCardLookup)
/// Private UIKit accessor. Spelled out rather than reached through
/// `performSelector:` because an unknown selector makes ARC warn -- and the
/// build is `-Werror`. Guarded with `respondsToSelector:` at every call site.
- (id)_viewControllerForAncestor;
@end

/// The view UIKit actually builds an alert on, and the view an action sheet
/// keeps its cancel action on.
///
/// Asked for by NAME, which is what the reference tweak for this
/// (tomaszpoliszuk/AlertController) does: it hooks `_UIAlertControllerView`
/// rather than searching for it, and that is precisely why its coverage has
/// none of the holes ours has -- a search can miss, a class cannot.
/// `NSClassFromString` returns nil on an iOS that renamed it, and every caller
/// treats nil as "fall back to the heuristics", so a rename degrades instead
/// of breaking.
static Class LMNAlertCardClass(void) {
    static Class cardClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cardClass = NSClassFromString(@"_UIAlertControllerView");
        LMNProbe(@"lumen 1.2.46 card class %@",
                 cardClass != nil ? NSStringFromClass(cardClass) : @"(nil)");
    });
    return cardClass;
}

static Class LMNAlertSheetCancelCardClass(void) {
    static Class cancelClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cancelClass = NSClassFromString(
            @"_UIAlertControlleriOSActionSheetCancelBackgroundView");
    });
    return cancelClass;
}

/// The class the two independent references actually name as the CARD.
///
/// `_UIAlertControllerView` -- the one Lumen has been asking for -- is the
/// alert's ROOT view, not its card (the Alpine package's binary names it
/// ALERT_ROOT and names `_UIAlertControllerPhoneTVMacView` the card; the Liquid
/// Glass reference finds its chrome by exactly this prefix). For an app alert
/// the root and the card are different objects, so asking for the root is
/// harmless: `LMNCardLooksLikeCard` rejects the root outright and the
/// heuristics find the card. For SpringBoard's system dialog the two collapse,
/// which before 1.2.11 left the class path empty and ran the row pass on a
/// native sheet -- the "the window was not replaced but the buttons are ours"
/// split. 1.2.11 closes it: `LMNAlertCards` now passes the in-place signal to
/// `LMNCollectCardsOfClass`, which adopts the root as the card on the system
/// path, so the sheet is glassed instead of left half-native.
///
/// Asked for by name only on the path that needs it (see LMNAlertCards). The
/// app path already recognises its card and must not have its card swapped out
/// from under the heuristics that are working.
static Class LMNAlertPhoneTVMacCardClass(void) {
    static Class cardClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cardClass = NSClassFromString(@"_UIAlertControllerPhoneTVMacView");
    });
    return cardClass;
}

static void LMNCollectCardsOfClass(UIView *view, Class wanted, UIView *root,
                                   BOOL allowRoot,
                                   NSMutableArray<UIView *> *out) {
    if (view == nil || wanted == nil) {
        return;
    }
    if ([view isKindOfClass:wanted]) {
        BOOL ok = LMNCardLooksLikeCard(view, root);
        // 1.2.11: on the in-place (system) path a SpringBoard sheet collapses
        // root == card, and the class we ask for by name (`_UIAlertControllerView`)
        // IS that root. LMNCardLooksLikeCard refuses a card that equals root, so
        // without this the class path found nothing there and the dialog fell
        // through to the heuristics -- the split the guard was meant to stop.
        // When the dialog is classified as a system one, accept the root as its
        // own card: it is a sized sheet, never the full-screen backdrop, and the
        // class gate above keeps the backdrop (a different class) out.
        if (!ok && allowRoot && view == root) {
            ok = YES;
        }
        if (ok && ![out containsObject:view]) {
            [out addObject:view];
        }
    }
    for (UIView *subview in view.subviews) {
        LMNCollectCardsOfClass(subview, wanted, root, allowRoot, out);
    }
}

/// Whether `view` is hosted by `controller`, asked through the same private
/// accessor the reference tweak uses. A card recognised by class would
/// otherwise be adopted on nothing but its position in the tree.
///
/// Unknown counts as yes: the accessor is private, so an iOS that drops it has
/// to degrade to the tree position rather than lose every card.
static BOOL LMNViewIsHostedBy(UIView *view, UIViewController *controller) {
    if (view == nil || controller == nil) {
        return NO;
    }
    if (![view respondsToSelector:@selector(_viewControllerForAncestor)]) {
        return YES;
    }
    id owner = [view _viewControllerForAncestor];
    if (![owner isKindOfClass:[UIViewController class]]) {
        return YES;
    }
    return owner == controller;
}

/// Every distinct card this controller draws. An action sheet puts the cancel
/// action in its own card, so those yield two — both get the glass.
///
/// Recomputed each pass rather than cached: the row list is a handful of views
/// and a cached card goes stale the moment UIKit rebuilds the sheet's content.
static NSArray<UIView *> *LMNAlertCards(UIViewController *controller) {
    UIView *root = controller.view;
    if (root == nil) {
        return @[];
    }
    // 1.2.11: on the in-place (system) path a SpringBoard sheet collapses
    // root == card, so let the class collector adopt the root as its own card.
    BOOL inPlaceSystem = LMNControllerIsSystemDialog(controller);

    // 1.1.12: ask UIKit for the card before guessing at it. Every alert is
    // built on a `_UIAlertControllerView`, and an action sheet's cancel action
    // sits on a view of its own; naming those classes is what the reference
    // tweak does instead of searching, and it is the reason that tweak's
    // coverage has none of the holes ours has -- the substring match on
    // "ActionView", the width-ratio climb and the "largest subview" geometric
    // guess below each silently return nothing for some trees, and a card that
    // is never recognised is a card that never gets glass.
    NSMutableArray<UIView *> *cards = [NSMutableArray array];
    Class cardClass = LMNAlertCardClass();
    if (cardClass != nil) {
        LMNCollectCardsOfClass(root, cardClass, root, inPlaceSystem, cards);
    }
    Class cancelClass = LMNAlertSheetCancelCardClass();
    if (cancelClass != nil) {
        LMNCollectCardsOfClass(root, cancelClass, root, inPlaceSystem, cards);
    }
    // 1.2.9: ask for the CARD by the name both references use, for EVERY
    // controller -- not only the system ones.
    //
    // 1.2.8 added this class but gated it behind
    // `![controller isKindOfClass:[UIAlertController class]]`, which is FALSE
    // for `_SBAlertController` (it IS a UIAlertController subclass -- see
    // LMNControllerIsSystemDialog). The gate written to switch the system path
    // ON therefore switched it OFF, and `_UIAlertControllerPhoneTVMacView` was
    // never searched anywhere. `_UIAlertControllerView`, the only class 1.1.12
    // asked for, is the alert's ROOT view, and LMNCardLooksLikeCard refuses a
    // card that is the root -- so on a system dialog the class path found
    // nothing and the outcome depended entirely on the heuristics, which is why
    // some dialogs came out glassed and others stayed native.
    //
    // `_UIAlertControllerPhoneTVMacView` is the card for an app alert too: the
    // Alpine binary names it CARD (against ALERT_ROOT for
    // `_UIAlertControllerView`) and the Liquid Glass reference finds both
    // alerts' chrome by this prefix. Searching it unconditionally makes
    // recognition deterministic instead of heuristic. Nothing that used to be
    // found is lost -- the app branch keeps the heuristics as its fallback, and
    // the innermost filter below still drops a nested container.
    Class phoneTVMac = LMNAlertPhoneTVMacCardClass();
    if (phoneTVMac != nil) {
        LMNCollectCardsOfClass(root, phoneTVMac, root, inPlaceSystem, cards);
    }
    NSMutableArray<UIView *> *owned = [NSMutableArray array];
    for (UIView *card in cards) {
        if (LMNViewIsHostedBy(card, controller)) {
            [owned addObject:card];
        }
    }
    LMNProbe(@"lumen 1.2.46 class cards=%lu owned=%lu",
             (unsigned long)cards.count, (unsigned long)owned.count);
    if (owned.count > 0) {
        cards = owned;
    } else {
        // Nothing recognised, so fall back to the pre-1.1.12 heuristics. Kept
        // rather than replaced: on an iOS that renames the private classes the
        // class path finds nothing, and guessing then beats drawing nothing.
        cards = [NSMutableArray array];
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        LMNCollectActionRows(root, rows);
        for (UIView *row in rows) {
            UIView *card = LMNCardForActionRow(row, root);
            if (!LMNCardLooksLikeCard(card, root)) {
                continue;
            }
            if (![cards containsObject:card]) {
                [cards addObject:card];
            }
        }
        if (cards.count == 0) {
            // Row detection missed every action row (private class-name drift,
            // or a sheet whose rows are not the usual
            // `_UIAlertControllerActionView`). The old fallback only inspected
            // the controller's direct children and returned nothing for a card
            // nested one level deeper, leaving the alert in its native skin.
            // Collect every card-like view at any depth, then let the innermost
            // filter below drop any container one.
            CGFloat rootWidth = CGRectGetWidth(root.bounds);
            CGFloat rootHeight = CGRectGetHeight(root.bounds);
            NSMutableArray<UIView *> *geo = [NSMutableArray array];
            LMNCollectGeometricCards(root, root, geo);
            for (UIView *candidate in geo) {
                CGFloat w = CGRectGetWidth(candidate.bounds);
                CGFloat h = CGRectGetHeight(candidate.bounds);
                if (rootWidth > 0.0 && w < rootWidth * 0.5) {
                    continue;
                }
                if (rootHeight > 0.0 && h < rootHeight * 0.2) {
                    continue;
                }
                if (![cards containsObject:candidate]) {
                    [cards addObject:candidate];
                }
            }
            LMNProbe(@"lumen 1.2.46 geometric fallback cards=%lu geo=%lu",
                     (unsigned long)cards.count, (unsigned long)geo.count);
            if (cards.count == 0) {
                UIView *fallback = LMNGeometricCard(root);
                if (LMNCardLooksLikeCard(fallback, root)) {
                    [cards addObject:fallback];
                }
            }
        }
    }
    if (cards.count == 0) {
        return @[];
    }

    // Keep only the innermost card where one contains another, so a nested
    // container is not painted twice.
    NSMutableArray<UIView *> *innermost = [NSMutableArray array];
    for (UIView *card in cards) {
        BOOL containsAnother = NO;
        for (UIView *other in cards) {
            if (other != card && [other isDescendantOfView:card]) {
                containsAnother = YES;
                break;
            }
        }
        if (!containsAnother) {
            [innermost addObject:card];
        }
    }
    return innermost;
}

static BOOL LMNAlertIsDark(UIViewController *controller) {
    // 1.2.2: the answer comes from the theme, which is why this needs the
    // controller now. The theme is either a fixed palette or 自动, and 自动 is
    // the one case where the system's appearance IS the answer -- so the trait
    // collection has to come from the alert being styled. Reading
    // UITraitCollection.current here would be reading the default: this runs
    // from -viewWillAppear:, which is early enough that 自动 would resolve to
    // 明昼 in a dark room.
    return [LMNGlass isDarkTheme:
        [LMNGlass resolvedThemeForTraits:controller.traitCollection]];
}

/// 1 for an alert, 0 for a sheet, as UIKit resolved it.
///
/// `preferredStyle` is what the caller asked for; `_resolvedStyle` is what
/// UIKit settled on, and the two differ whenever the presentation is coerced
/// (an alert displayed as a sheet, iPad popovers). The reference tweak reads
/// the resolved value, so the grabber decision does too. Asked through KVC
/// because the accessor is private, and falling back to `preferredStyle` when
/// it is missing -- the two enumerations happen to be numbered identically.
static long long LMNResolvedStyle(UIViewController *controller) {
    if ([controller respondsToSelector:@selector(_resolvedStyle)]) {
        id value = nil;
        @try {
            value = [controller valueForKey:@"_resolvedStyle"];
        }
        @catch (NSException *exception) {
            (void)exception;
            value = nil;
        }
        if ([value respondsToSelector:@selector(longLongValue)]) {
            return [value longLongValue];
        }
    }
    // A UIAlertController answers preferredStyle (1 = alert, 0 = sheet), and
    // SpringBoard's `_SBAlertController` inherits that accessor -- it IS a
    // UIAlertController subclass -- so a system dialog reports its real style
    // here rather than falling through to the default.
    if ([controller isKindOfClass:[UIAlertController class]]) {
        return (long long)((UIAlertController *)controller).preferredStyle;
    }
    return 1;
}

/// Which capsule a given action gets.
///
/// The accent is driven by `preferredAction`, not by "whichever ordinary action
/// happens to come first". The reference light-mode sheet (a container picker)
/// has three *neutral* pills and no coloured button anywhere, so defaulting the
/// first action to an accent blue painted a blue "默认" that the reference does
/// not have. iOS itself only ever emphasises an action the alert nominates plus
/// the destructive ones, so that is what is honoured here.
static LMNGlassButtonRole LMNRoleForAction(UIAlertAction *action,
                                           UIAlertAction *preferred) {
    if (action == nil) {
        return LMNGlassButtonRoleSecondary;
    }
    if (action.style == UIAlertActionStyleDestructive) {
        return LMNGlassButtonRoleDestructive;
    }
    if (action.style == UIAlertActionStyleCancel) {
        return LMNGlassButtonRoleSecondary;
    }
    if (preferred != nil && action == preferred) {
        return LMNGlassButtonRolePrimary;
    }
    return LMNGlassButtonRoleSecondary;
}

static void LMNStyleTextField(UITextField *field, LMNGlassTheme theme,
                              LMNGlassParams *params) {
    // 1.2.0: the theme decides the appearance. A text field only has two
    // ends -- light ink on a dark fill, or dark ink on a light one -- and
    // 曜石玻璃 and 影院暗色 share an end, so the three themes collapse to
    // that pair here instead of carrying a third palette nothing has
    // measured against the reference.
    BOOL dark = [LMNGlass isDarkTheme:theme];
    // A glass field: a mostly transparent fill with an edge that is actually
    // visible. Light mode darkens the edge here for the same reason the capsules
    // do — a white hairline on a white card cannot be seen, and the old fixed
    // white border left the field looking like a flat unoutlined rectangle.
    // No drop shadow: the field clips to bounds, which would cut one off.
    //
    // The stored fill is the dark-appearance value. Light appearance keeps the
    // 0.6 factor the two hard-coded values (0.10 dark / 0.06 light) already
    // had, so one slider moves both without changing the ratio between them.
    CGFloat lightFill = params.fieldFillAlpha * 0.6;
    field.backgroundColor =
        dark ? [UIColor colorWithWhite:1.0 alpha:params.fieldFillAlpha]
             : [UIColor colorWithWhite:0.0 alpha:lightFill];
    field.textColor = dark ? [UIColor whiteColor] : [UIColor blackColor];
    field.tintColor = dark ? [UIColor whiteColor] : [UIColor blackColor];
    field.layer.cornerRadius = params.fieldCornerRadius;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    field.layer.masksToBounds = YES;
    field.layer.borderWidth = params.fieldBorderWidth;
    field.layer.borderColor =
        dark ? [UIColor colorWithWhite:1.0 alpha:0.20].CGColor
             : [UIColor colorWithWhite:0.0 alpha:0.12].CGColor;
}

#pragma mark - Action rows

// The capsule material is defined once, on the Swift panel view, so a row
// styled here and a button styled there cannot drift apart. (An earlier build
// duplicated the tints in both files and the two silently diverged.)
static UIColor *LMNGlassRoleFill(LMNGlassButtonRole role,
                                 LMNGlassTheme theme) {
    // 1.2.36: 取实时覆盖色（缺键=nil=沿用主题）。覆盖与主题无关，故用
    // [LMNGlass current] 读一次 store 即可，不必把 params 透传进每个文本 styller。
    LMNGlassParams *params = [LMNGlass current];
    return [LMNGlassPanelView glassFillForRole:role theme:theme params:params];
}

static UIColor *LMNGlassRoleBorder(LMNGlassButtonRole role,
                                   LMNGlassTheme theme) {
    LMNGlassParams *params = [LMNGlass current];
    return [LMNGlassPanelView glassBorderForRole:role theme:theme params:params];
}

static UIColor *LMNGlassRoleTitle(LMNGlassButtonRole role,
                                  LMNGlassTheme theme) {
    LMNGlassParams *params = [LMNGlass current];
    return [LMNGlassPanelView glassTitleForRole:role theme:theme params:params];
}

/// The text an action row displays.
///
/// This used to look at UILabels only, and that is the root of two symptoms
/// measured together on a real device: the titles kept the host's tint, and the
/// destructive row never turned red. Both follow from the same failure — if the
/// row draws its title in something that is not a UILabel, this returns nil, so
/// no action ever matches, and `LMNRoleForAction(nil)` returns `.secondary` for
/// everything. The row still gets a correctly-shaped capsule, so the only
/// visible symptom is that the pill is the wrong colour and the text is the
/// host's — which reads as "styling partially worked".
///
/// So the title is read from a label OR a button, and the class of whichever was
/// found is reported by the probe at the call site.
static NSString *LMNTitleForActionRow(UIView *row) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LMNCollectLabels(row, labels);
    for (UILabel *label in labels) {
        if (label.text.length > 0) {
            return label.text;
        }
    }
    // A UIButton carries its title in a state-keyed dictionary rather than in a
    // `text` property, so it needs its own lookup. `titleForState:` with the
    // normal state is the documented accessor; the highlighted state is checked
    // too because a row that is momentarily highlighted would otherwise read as
    // untitled.
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    LMNCollectButtons(row, buttons);
    for (UIButton *button in buttons) {
        NSString *text = [button titleForState:UIControlStateNormal];
        if (text.length > 0) {
            return text;
        }
        text = [button titleForState:UIControlStateHighlighted];
        if (text.length > 0) {
            return text;
        }
    }
    return nil;
}

/// The very label `LMNTitleForActionRow` read its text from.
///
/// 1.2.15 needs to MOVE the title, not just recolour it, and the only view worth
/// moving is the one the text was actually read from. Same walk, same order, so
/// the two can never disagree about which label carries the title.
static UILabel *LMNTitleLabelForActionRow(UIView *row) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LMNCollectLabels(row, labels);
    for (UILabel *label in labels) {
        if (label.text.length > 0) {
            return label;
        }
    }
    return nil;
}

#pragma mark - Probe

/// One-shot-per-process probe.
///
/// Two symptoms on a real device could not be told apart by looking at the
/// screenshot alone:
///
///   * the row titles kept the host's tint (measured rgb(45,179,170)) instead of
///     the near-black `glassTitle(.secondary, light)`;
///   * the destructive action ("卸载") never got a red capsule.
///
/// Both are consistent with at least three different causes — the title not
/// being a UILabel at all, being recoloured by UIKit during layout, or being
/// drawn by a private view — and the three need three different fixes. Rather
/// than guess and spend a CI cycle plus a device round trip per guess, this
/// prints the facts that settle it in one run: what the row actually is, how
/// many labels and buttons it holds, whether the title matched an action, what
/// geometry the params resolved to, and the frame the capsule ended up with.
///
/// Everything goes to stderr through NSLog, so it lands in the usual syslog and
/// needs no file access — this tweak deliberately has no jailbreak file I/O so it
/// keeps roothide's "simple tweak" exemption.
static void LMNProbe(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[lumen-probe] %@", message);
}

static BOOL LMNSubtreeHasLabel(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            return YES;
        }
        if (LMNSubtreeHasLabel(subview)) {
            return YES;
        }
    }
    return NO;
}

/// iOS 16 draws an alert row's resting tint on a private
/// `_UIAlertControlleriOSHighlightedBackgroundView`. It is a SIBLING of the
/// row's content view, so it paints above everything added to the row itself.
///
/// This is the view that made 1.1.2 look like a no-op on a device. The capsule
/// was inserted at the row's index 0, this view sat above it, and what measured
/// on screen was this one: no lit border (the capsule has a 1pt white edge), a
/// perfectly flat interior (no gloss gradient) and a stadium that UIKit had
/// rounded itself. Every geometry fix landed underneath it.
static BOOL LMNClassNameIsHighlightBackground(UIView *view) {
    NSString *name = NSStringFromClass([view class]);
    return [name rangeOfString:@"HighlightedBackground"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;
}

/// Clear every one of those, at any depth. Returns how many were found so the
/// probe can distinguish "there was none" from "there was one and we cleared it".
static NSUInteger LMNClearHighlightBackgrounds(UIView *view) {
    NSUInteger cleared = 0;
    for (UIView *subview in view.subviews) {
        if (LMNClassNameIsHighlightBackground(subview)) {
            subview.backgroundColor = [UIColor clearColor];
            subview.layer.backgroundColor = [UIColor clearColor].CGColor;
            for (UIVisualEffectView *effect in subview.subviews) {
                if ([effect isKindOfClass:[UIVisualEffectView class]]) {
                    effect.effect = nil;
                }
            }
            cleared++;
            continue;
        }
        cleared += LMNClearHighlightBackgrounds(subview);
    }
    return cleared;
}

/// The view the host already uses as the row's body, so the capsule can be
/// parented INTO it instead of being added to the row.
///
/// Parenting matters more than it looks. Added to the row, the capsule is a
/// sibling of this content view and therefore underneath both the host's
/// background and its own label. Added at this view's index 0, it is above the
/// content view's own background and still below the label — which is exactly
/// the one slot where a fill can show without hiding the title.
///
/// The selection rules are the ones that survive contact with iOS 16: skip
/// hidden and fully transparent subviews, skip the highlight background, and
/// take the first subview that actually holds a label.
static UIView *LMNFindActionContentView(UIView *row) {
    UIView *fallback = nil;
    for (UIView *subview in row.subviews) {
        if (subview.hidden || subview.alpha < 0.01) {
            continue;
        }
        if (LMNClassNameIsHighlightBackground(subview)) {
            continue;
        }
        if (LMNSubtreeHasLabel(subview)) {
            return subview;
        }
        if (fallback == nil) {
            fallback = subview;
        }
    }
    return fallback;
}

/// On iOS 16 an alert action is a `_UIAlertControllerActionView` — a plain
/// UIView carrying a label — not a UIButton. Styling UIButtons alone therefore
/// styled nothing inside a real alert, which is why the sheet showed bare
/// coloured text with no capsules. This paints a *glass* capsule inside the row
/// (behind its label) and recolours the label, so each action reads as its own
/// liquid-glass button. The capsule is tracked on the row with an associated
/// object and re-framed every layout pass, so it survives UIKit rebuilding the
/// sheet's content and never stacks duplicates.
///
/// The capsule gets the iOS 27 treatment: a translucent tint fill, a lit edge
/// (thin white border) and a darkened floating shadow for depth, plus a
/// permanent top sheen (the "shine" Apple uses on glass controls). A touch-
/// toggle shine would need KVO on a private class we do not own, which crashes
/// Recolour a label's text to `ink`, handling BOTH a plain `text`/`textColor`
/// label and one drawn with an `attributedText` that carries
/// `NSForegroundColorAttributeName`. A host that uses an attributed string
/// ignores a plain `textColor` assignment (the attribute wins), which is why
/// some alert titles and message bodies kept the host's tint even after 1.1.8.
/// Rebuild the attributed string keeping every attribute except the foreground
/// colour, then force `ink`, so the readable colour lands without dropping the
/// host's font or paragraph style.
///
/// `lumen 1.2.46 recolor attributed` is a build marker: the string compiles into
/// __cstring so the verify gate can prove this code shipped, even though the
/// probe only fires on a device that actually has an attributed label.
static void LMNRecolorLabel(UILabel *label, UIColor *ink) {
    if (label == nil || ink == nil) {
        return;
    }
    if (label.attributedText != nil && label.attributedText.length > 0) {
        NSMutableAttributedString *restyled = [[NSMutableAttributedString alloc]
            initWithAttributedString:label.attributedText];
        NSRange full = NSMakeRange(0, restyled.length);
        [restyled removeAttribute:NSForegroundColorAttributeName range:full];
        [restyled addAttribute:NSForegroundColorAttributeName
                          value:ink
                          range:full];
        label.attributedText = restyled;
        LMNProbe(@"lumen 1.2.46 recolor attributed");
    } else {
        label.textColor = ink;
    }
    label.tintColor = ink;
}

/// on row dealloc, so the gloss is always on instead.
static void LMNStyleActionRow(UIView *row, UIAlertAction *action,
                              LMNGlassButtonRole role,
                              LMNGlassTheme theme,
                              LMNGlassParams *params,
                              UIView *glassCard) {
    if (row == nil) {
        return;
    }
    // The row itself must paint nothing. iOS gives the *cancel* row of an action
    // sheet an opaque white background (on iOS 16 it is a standalone card), and
    // because the capsule below is inset inside the row, that white showed both
    // around and behind it — which is why "取消" rendered as a solid white
    // plaster instead of a glass pill. Clearing the row, plus any full-width
    // opaque container inside it, is what turns it back into glass.
    row.backgroundColor = [UIColor clearColor];
    LMNClearOpaqueBackgrounds(row, row.bounds, 3);
    // The row also carries a pressed/highlight material; null it so the capsule
    // fill stays uniform.
    for (UIView *subview in row.subviews) {
        if ([subview isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)subview).effect = nil;
        }
    }
    // And the row draws its resting tint on a private highlight view that sits
    // ABOVE the row's content view — i.e. above anything added to the row. This
    // is the one that made 1.1.2 read as a no-op, so it goes first and the count
    // is reported.
    NSUInteger clearedHighlights = LMNClearHighlightBackgrounds(row);

    // 1.2.7: the row's own buttons, when it has any, must also stop painting.
    // LMNClearOpaqueBackgrounds deliberately exempts UIButton (clearing it would
    // erase a button FACE), so on a row built from real buttons -- which is how
    // SpringBoard's system dialogs draw theirs -- nothing else removes the
    // system's own button background. Left in place it sits between the row and
    // the capsule and reads as a third layer inside the pill. Only the paint is
    // cleared: the title colour is the row pass's job a few lines further down,
    // and the button has to stay hittable, so nothing is removed or disabled.
    NSMutableArray<UIButton *> *rowButtons = [NSMutableArray array];
    LMNCollectButtons(row, rowButtons);
    for (UIButton *button in rowButtons) {
        [button setBackgroundImage:nil forState:UIControlStateNormal];
        [button setBackgroundImage:nil forState:UIControlStateHighlighted];
        [button setBackgroundImage:nil forState:UIControlStateDisabled];
        button.backgroundColor = [UIColor clearColor];
        button.layer.borderWidth = 0.0;
        button.layer.shadowOpacity = 0.0;
    }

    // The capsule is parented into the host's own content view rather than into
    // the row. See LMNFindActionContentView: at the content view's index 0 it is
    // above that view's background and still below its label, which is the only
    // slot where a fill can show without hiding the title.
    UIView *content = LMNFindActionContentView(row);
    UIView *container = content != nil ? content : row;
    if (content != nil) {
        // The content view is the capsule's backdrop now, so its own paint has to
        // go or the glass is composited over an opaque slab and reads as plastic.
        content.backgroundColor = [UIColor clearColor];
        content.layer.backgroundColor = [UIColor clearColor].CGColor;
    }

    UIView *capsule = objc_getAssociatedObject(row, LMNRowCapsuleKey);
    if (capsule == nil) {
        capsule = [[UIView alloc] initWithFrame:CGRectZero];
        capsule.userInteractionEnabled = NO;
        // Deliberately NOT masksToBounds. A layer cannot draw a shadow outside
        // its own bounds when it clips, so the previous masksToBounds = YES
        // swallowed the depth shadow entirely — the iOS 27 "floating" look was
        // authored but never rendered.
        capsule.layer.masksToBounds = NO;
        // The creation-time default matches what the material block below sets
        // on every pass. It is overwritten a few lines later, but seeding the
        // other value here would be a second source of truth that disagrees
        // with the first for the lifetime of a freshly created capsule.
        capsule.layer.borderWidth = 1.0;
        capsule.layer.shadowColor = [UIColor colorWithWhite:0.0 alpha:1.0].CGColor;
        capsule.layer.shadowRadius = 3.0;
        capsule.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        objc_setAssociatedObject(row, LMNRowCapsuleKey, capsule,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Permanent glass gloss (top sheen), masked to the pill shape so it
        // cannot spill past the rounded ends.
        CAGradientLayer *shine = [CAGradientLayer layer];
        shine.startPoint = CGPointMake(0.5, 0.0);
        shine.endPoint = CGPointMake(0.5, 1.0);
        shine.locations = @[ @0.0, @0.55 ];
        // A shape layer masks by its own alpha, and it starts out with no fill,
        // so state the fill rather than relying on the default.
        CAShapeLayer *shineMask = [CAShapeLayer layer];
        shineMask.fillColor = [UIColor blackColor].CGColor;
        shine.mask = shineMask;
        [capsule.layer addSublayer:shine];
        objc_setAssociatedObject(capsule, LMNRowShineKey, shine,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Re-parent on every pass. A relayout can rebuild the content view, which
    // would leave the capsule attached to a detached view and invisible — the
    // same class of bug as the panel anchor in LMNRestyleCard.
    if (capsule.superview != container) {
        [container insertSubview:capsule atIndex:0];
    }
    CAGradientLayer *shine = objc_getAssociatedObject(capsule, LMNRowShineKey);

    // One source of truth for the material: the same class methods the settings
    // preview draws its buttons with, so the row and the preview cannot diverge.
    //
    // The silhouette was never the thing to get right: sampling the target
    // reference row by row, the pill's left edge insets track a circle of
    // r = height/2 to within ±1.2px, and the width is off by 3.5%. What had to
    // be matched was the material. (A second reference disagreed — flat vector
    // art, 115 unique colours in 78,182 pixels, a hard unantialiased edge,
    // rgb(55,138,221) identical at the top and the bottom of the pill. Up to
    // 1.1.14 that disagreement was a switch; 1.2.0 replaces it with the theme
    // picker, so the capsule always carries the specular gradient, the 1pt lit
    // rim and the drop shadow that the iOS 27 reference measures.)
    capsule.backgroundColor = LMNGlassRoleFill(role, params.theme);
    // A border colour at alpha 0 is invisible but the layer still reserves its
    // inset, which reads as a hairline seam. The width is stated outright
    // rather than through a conditional, so there is one number here and not a
    // choice that can be made differently two lines apart.
    capsule.layer.borderWidth = 1.0;
    capsule.layer.borderColor =
        LMNGlassRoleBorder(role, params.theme).CGColor;
    capsule.layer.shadowOpacity =
        (float)[LMNGlassPanelView glassShadowOpacityForRole:role
                                                     theme:params.theme];
    CGFloat gloss =
        [LMNGlassPanelView glassGlossAlphaForTheme:params.theme];
    shine.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:gloss].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
    ];
    // A gradient whose two stops are both fully transparent still gets
    // composited every frame, and on some iOS releases an all-transparent
    // CAGradientLayer over a masked parent has been observed to leave a faint
    // band where the mask's own antialiasing resolves. Hiding it is both
    // cheaper and provably zero.

    // iOS 27 geometry, measured off a real device rather than assumed.
    //
    // The pill is positioned in the CARD's coordinate space and only converted
    // into the container's at the very end. Two reasons, both learned the hard
    // way:
    //
    //  1. The row is not the card. UIKit already insets the row inside the card,
    //     so an inset taken from the row measures the gap from the wrong
    //     rectangle — on the cancel card, whose row spans the full card width,
    //     that put the pill flush against the edge.
    //  2. Since 1.1.3 the capsule is a subview of the row's CONTENT VIEW, not of
    //     the row, so row-relative coordinates are wrong by a second offset on
    //     top of everything else. Converting once, from a space both rectangles
    //     are meaningful in, is the only way to keep the two apart.
    CGRect rowBounds = row.bounds;
    if (!CGRectIsEmpty(rowBounds)) {
        // 1.2.12: the card LMNAlertCards actually glassed wins. The old climb is
        // kept only as a fallback for a row whose card was never recognised, and
        // the capsule's own container is the last resort -- so the arithmetic is
        // always expressed against the sheet the user can see.
        UIView *card = glassCard != nil ? glassCard : LMNFindOwningCard(row);
        // The space the arithmetic below is expressed in: the card when we found
        // one, otherwise the capsule's own container.
        UIView *space = card != nil ? card : container;
        CGFloat spaceWidth = CGRectGetWidth(space.bounds);
        CGFloat spaceHeight = CGRectGetHeight(space.bounds);
        // One margin for the clamps that remain, which only guard the
        // card-unresolved path. Proportional to the card so a small sheet is not
        // left with a hairline gutter and a large one keeps a visible border.
        CGFloat edgeMargin = MAX(6.0, spaceWidth * 0.025);

        BOOL sideBySide = NO;
        if (card != nil) {
            sideBySide = spaceWidth > 0.0 &&
                         CGRectGetWidth(rowBounds) < spaceWidth * 0.9;
        }

        // 1.2.13: the gutter is no longer an authored constant competing with
        // UIKit's layout; it is only the fallback for a row whose card could
        // not be resolved at all. `params.buttonInset` is still honoured there,
        // clamped into a proportional band so a narrow sheet is not eaten whole.
        CGFloat outer = LMNAdaptiveGutter(params.buttonInset, spaceWidth);
        CGFloat inner = outer * LMNGlassButtonInnerRatio;

        // 1.2.16: the row's title, and whether we are allowed to move it.
        //
        // 1.2.15 translates the title onto the pill's centre, which is what makes
        // a row we CAN move look right. A row we cannot (the title is not a
        // findable UILabel, or it does not live under the card whose coordinate
        // space the arithmetic below is expressed in) has to be centred
        // geometrically instead, and that decision has to be made BEFORE the
        // insets become a left/width pair. Deciding it here is also what stops
        // the un-movable case from being a branch that silently does nothing --
        // which on a device is indistinguishable from a build that never shipped.
        UILabel *titleLabel = LMNTitleLabelForActionRow(row);
        BOOL canMoveTitle = titleLabel != nil && [titleLabel isDescendantOfView:space];
        if (!canMoveTitle) {
            titleLabel = nil;
        }

        CGRect rowInCard = CGRectZero;
        BOOL haveRowInCard = NO;
        if (card != nil) {
            rowInCard = [row convertRect:rowBounds toView:card];
            haveRowInCard = !CGRectIsEmpty(rowInCard);
        }

        // 1.2.14: the pill is the row rect INSET, never grown.
        //
        // 1.2.13 grew it OUTWARD by a hairline `pad` on all four sides, on the
        // assumption that UIKit leaves a gutter around every row. It does not: the
        // action rows are packed edge to edge (a hairline apart) and the outermost
        // row is flush with the sheet's inner edge. So each `+pad` reached into the
        // neighbouring pill and pushed the outer pills out through the sheet's
        // rounded corner -- the reported "按钮重叠 / 没了半边". Nothing is added
        // now, so a pill can never reach past the row that owns it.
        //
        // The two insets are the ones the settings preview already draws its own
        // buttons with, so the sheet and the preview agree:
        //   * a side facing the SHEET gets `outer` -- the card's content margin;
        //   * a side shared with a NEIGHBOUR gets `inner` (= outer * the theme's
        //     inner ratio), so a two-up pair and a stacked list are both exactly
        //     `2 * inner` apart between pills.
        CGFloat left = outer;
        CGFloat width = spaceWidth - 2.0 * outer;
        CGFloat pillInsetL = outer;
        CGFloat pillInsetR = outer;
        if (haveRowInCard) {
            // A side faces the sheet when the row reaches the sheet's edge. A
            // full-bleed stacked list touches BOTH sides; a two-up pair touches
            // only its outer side, its inner side meeting its sibling mid-card.
            CGFloat edge = MAX(6.0, spaceWidth * 0.05);
            BOOL touchLeft = CGRectGetMinX(rowInCard) <= edge;
            BOOL touchRight = CGRectGetMaxX(rowInCard) >= spaceWidth - edge;
            pillInsetL = touchLeft ? outer : inner;
            pillInsetR = touchRight ? outer : inner;
            // 1.2.16: nothing to move, so move the pill instead. Splitting the
            // two insets evenly keeps the pill's width exactly as calibrated
            // and only slides it onto the row's centre -- which is where UIKit
            // put the title in the first place.
            if (!canMoveTitle) {
                CGFloat halfInset = (pillInsetL + pillInsetR) * 0.5;
                pillInsetL = halfInset;
                pillInsetR = halfInset;
            }
            left = CGRectGetMinX(rowInCard) + pillInsetL;
            width = CGRectGetWidth(rowInCard) - pillInsetL - pillInsetR;
        } else if (sideBySide) {
            BOOL leftHalf = CGRectGetMidX(rowInCard) < spaceWidth * 0.5;
            left = leftHalf ? outer : (spaceWidth * 0.5 + inner);
            CGFloat available = spaceWidth - 2.0 * outer - 2.0 * inner;
            if (available > 8.0) {
                width = available * 0.5;
            }
        }
        if (width < 8.0) {
            // Too narrow for both insets. Falling back to zero here is what let
            // the cancel pill span the entire card; keep the inset and let the
            // pill be narrower instead, which still reads as a pill.
            left = outer;
            width = spaceWidth - 2.0 * outer;
            if (width < 8.0) {
                left = 0.0;
                width = spaceWidth;
            }
        }
        // 1.2.12 added an edge clamp so a pill could never cross the card edge. 1.2.13
        // restricts it to the rows whose card was NOT resolved: on the
        // row-driven path the pill already sits where UIKit put the row, so
        // re-clamping it to a guessed margin would reintroduce exactly the
        // second authority this version removes.
        if (card != nil && spaceWidth > 0.0 && !haveRowInCard) {
            CGFloat rightLimit = spaceWidth - edgeMargin;
            if (left < edgeMargin) {
                left = edgeMargin;
            }
            if (left + width > rightLimit) {
                width = rightLimit - left;
            }
            if (width < 8.0) {
                left = edgeMargin;
                width = MAX(8.0, spaceWidth - 2.0 * edgeMargin);
            }
        }

        // 1.2.13 made the height follow the row, for the same reason the width
        // does. 1.2.14 keeps that but INSETS the row instead of growing it (see
        // above): a constant 48pt pill on a shorter row had to overhang, and an
        // outward `pad` made stacked pills overlap by 2 * pad. `params.buttonHeight`
        // remains the fallback for a row with no measurable height, and the clamp
        // below still bounds the result against the card.
        CGFloat height = params.buttonHeight;
        CGFloat top;
        if (haveRowInCard && CGRectGetHeight(rowInCard) > 0.0) {
            // Same rule vertically: inset the row, never grow it. Two stacked
            // pills then keep the same `2 * inner` gap a two-up pair has, instead
            // of overlapping by `pad` at every shared edge.
            CGFloat vInset = MIN(inner, CGRectGetHeight(rowInCard) * 0.25);
            height = CGRectGetHeight(rowInCard) - 2.0 * vInset;
            top = CGRectGetMinY(rowInCard) + vInset;
        } else {
            CGRect rowInSpace = [row convertRect:rowBounds toView:space];
            top = CGRectGetMidY(rowInSpace) - height * 0.5;
        }
        if (card != nil && spaceHeight > 0.0) {
            // Never taller than the card can hold with a margin top and bottom,
            // and never positioned so it crosses either edge. This is the last
            // line of defence for a row whose card was never resolved.
            CGFloat maxHeight = spaceHeight - 2.0 * edgeMargin;
            if (maxHeight > 8.0 && height > maxHeight) {
                height = maxHeight;
            }
            CGFloat lowest = spaceHeight - edgeMargin - height;
            if (top > lowest) {
                top = lowest;
            }
            if (top < edgeMargin) {
                top = edgeMargin;
            }
        }

        CGRect pillInSpace = CGRectMake(left, top, width, height);
        // The one and only coordinate conversion. Everything above is in the
        // card's (or the container's) space; the capsule's frame is not.
        capsule.frame = space == container
                            ? pillInSpace
                            : [container convertRect:pillInSpace fromView:space];

        // 1.2.15: put the row's title in the middle of the pill.
        //
        // 1.2.14 built the reference geometry -- `outer` against the sheet,
        // `inner` against the neighbouring pill -- but UIKit centres each row's
        // label in its OWN row, and a two-up pair's two rows are packed edge to
        // edge. So the two rectangles disagree, and measured off a real sheet
        // (weather permission dialog, card [31,837], rows [31,434]/[434,837]) the
        // left title centred on 232.5px while its pill centred on 250px: the
        // title sat 17.5px off the pill -- the reported "按钮里的字跟按钮没居中".
        //
        // Neither inset can simply be dropped: `outer` is the card's content
        // margin and `2 * inner` is the calibrated gap, and a symmetric inset
        // would force gap = 2 * margin (61px against a 30px margin), losing the
        // sheet's measured 48px / 27px look. So the LABEL is translated onto the
        // pill's centre instead, and the geometry stays the one the reference was
        // measured for.
        //
        // A `transform` rather than `center` is what makes the shift stick:
        // UIKit re-derives a view's centre on every layout pass, but it never
        // touches its transform, so a translated label stays translated across
        // the sheet rebuilding itself. Reading the centre back before each
        // re-apply would fold our own translation into the measurement (and
        // `convertPoint:` does follow the transform), so the transform is reset
        // to identity first and the offset is recomputed from scratch -- which
        // keeps the whole thing idempotent.
        //
        // 1.2.16 adds the vertical half, and it is an OPTICAL correction, not a
        // geometric one. Measured on the same sheet: the pill's rims sit at
        // y=425.5 and y=530.5 (a 106px pill centred on 478) while the glyph ink
        // spans y=464..510 (centred on 487) -- so the ink rides 9px low, with
        // 38.5px of air above it against only 20.5px below. UIKit centres the
        // label FRAME on the row; the CJK ink inside that frame does not sit on
        // the frame's centre. The correction is therefore expressed as a
        // fraction of the pill's own height (0.085 of 106px = 9px) rather than
        // as points, so it tracks the row height instead of assuming one.
        static const CGFloat LMNGlassInkDropRatio = 0.085;
        CGFloat labelDx = 0.0;
        CGFloat labelDy = 0.0;
        if (titleLabel != nil) {
            titleLabel.transform = CGAffineTransformIdentity;
            CGPoint labelCentre =
                [titleLabel convertPoint:CGPointMake(CGRectGetMidX(titleLabel.bounds),
                                                     CGRectGetMidY(titleLabel.bounds))
                                 toView:space];
            labelDx = CGRectGetMidX(pillInSpace) - labelCentre.x;
            labelDy = -height * LMNGlassInkDropRatio;
            if (fabs(labelDx) > 0.5 || labelDy < -0.5) {
                titleLabel.transform =
                    CGAffineTransformMakeTranslation(labelDx, labelDy);
            } else {
                labelDx = 0.0;
                labelDy = 0.0;
            }
        }

        CGFloat radius = CGRectGetHeight(capsule.bounds) * 0.5;
        capsule.layer.cornerRadius = radius;
        // The silhouette comes from an explicit CAShapeLayer mask rather than
        // from layer.cornerRadius.
        //
        // 1.1.2 concluded that kCACornerCurveContinuous degenerates at a stadium
        // radius and switched the capsule to kCACornerCurveCircular. That
        // diagnosis was wrong, and it cost a build: both independent references
        // read for this feature — Solert's open-source UIAlertController restyle
        // and the closed-source Liquidify, whose glass engine carries a
        // cc_updateDirectionalLensBorderForBounds:cornerRadius:cornerCurve:… —
        // run kCACornerCurveContinuous at exactly height/2 and get a clean
        // stadium, because a mask drawn with bezierPathWithRoundedRect clips the
        // layer's own corner rendering to the same path. So the curve was never
        // the problem; the mask is what makes the three renderers agree, and it
        // is also what guarantees the fill, the border, the gloss and the shadow
        // all follow one outline.
        CAShapeLayer *mask = [CAShapeLayer layer];
        mask.frame = capsule.bounds;
        mask.fillColor = [UIColor blackColor].CGColor;
        UIBezierPath *pill = [UIBezierPath bezierPathWithRoundedRect:capsule.bounds
                                                        cornerRadius:radius];
        mask.path = pill.CGPath;
        capsule.layer.mask = mask;
        // An explicit shadow path keeps the shadow the shape of the pill, and
        // stops UIKit from walking the row's contents on every frame.
        capsule.layer.shadowPath = pill.CGPath;
        shine.frame = capsule.bounds;
        CAShapeLayer *shineMask = (CAShapeLayer *)shine.mask;
        shineMask.frame = capsule.bounds;
        shineMask.path = pill.CGPath;

        // The probe keys are deliberately distinctive. `host=` alone would match
        // inside any longer word (`ghost=`, `ghost=`), and the binary gate in
        // verify-package.sh greps for these literals in __cstring — a marker that
        // can match by accident is not a marker.
        //
        // 1.2.0 reports the resolved theme alongside the capsule's border width
        // and shadow opacity. Those three are the whole theme: a build that
        // reads glassTheme but never reaches the material assignments would
        // render a picker that appears to do nothing, and a screenshot cannot
        // tell that apart from a mistyped preference key. Reporting the
        // resolved values settles it in one device run.
        LMNProbe(@"row cls=%@ title=%@ sideBySide=%d rowW=%.1f cardW=%.1f "
                 @"cardH=%.1f space=%@ passedCard=%d rowDriven=%d "
                 @"rowCard=(%.1f,%.1f,%.1f,%.1f) pillInL=%.1f pillInR=%.1f "
                 @"pillInV=%.1f labelDx=%.1f labelDy=%.1f inset=%.1f/%.1f h=%.1f "
                 @"capsule=(%.1f,%.1f,%.1f,%.1f) "
                 @"capsuleHost=%@ clearedHighlights=%lu "
                 @"theme=%ld border=%.1f shadow=%.2f gloss=%.2f",
                 NSStringFromClass([row class]), LMNTitleForActionRow(row),
                 sideBySide ? 1 : 0, CGRectGetWidth(rowBounds),
                 card != nil ? CGRectGetWidth(card.bounds) : 0.0,
                 card != nil ? CGRectGetHeight(card.bounds) : 0.0,
                 NSStringFromClass([space class]), glassCard != nil ? 1 : 0,
                 haveRowInCard ? 1 : 0,
                 rowInCard.origin.x, rowInCard.origin.y,
                 CGRectGetWidth(rowInCard), CGRectGetHeight(rowInCard),
                 pillInsetL, pillInsetR,
                 haveRowInCard ? inner : 0.0, labelDx, labelDy,
                 left, sideBySide ? inner : outer,
                 height, capsule.frame.origin.x, capsule.frame.origin.y,
                 capsule.frame.size.width, capsule.frame.size.height,
                 content != nil ? NSStringFromClass([content class])
                                : @"(row)",
                 (unsigned long)clearedHighlights,
                 (long)params.theme, (double)capsule.layer.borderWidth,
                 (double)capsule.layer.shadowOpacity, (double)gloss);
    }

    // Icon support (defensive). UIAlertAction has no public `image`, so probe
    // for one dynamically (some system sheets carry it) and stay silent when
    // absent — using it directly would not even compile under -Werror.
    UIImage *actionImage = nil;
    if ([action respondsToSelector:NSSelectorFromString(@"image")]) {
        id candidate = [action valueForKey:@"image"];
        if ([candidate isKindOfClass:[UIImage class]]) {
            actionImage = (UIImage *)candidate;
        }
    }
    if (actionImage != nil) {
        UIImageView *icon = nil;
        for (UIView *sub in capsule.subviews) {
            if ([sub isKindOfClass:[UIImageView class]]) {
                icon = (UIImageView *)sub;
                break;
            }
        }
        if (icon == nil) {
            icon = [[UIImageView alloc] initWithFrame:CGRectZero];
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.userInteractionEnabled = NO;
            [capsule addSubview:icon];
        }
        icon.image =
            [actionImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        icon.tintColor = LMNGlassRoleTitle(role, params.theme);
        CGFloat s = 22.0;
        icon.frame = CGRectMake(12.0,
                                (CGRectGetHeight(capsule.bounds) - s) * 0.5,
                                s, s);
    }

    // Text colour. On a real device the titles kept the host app's tint
    // (measured rgb(45,179,170)) instead of the near-black this function
    // returns, even though the capsule and the grabber were both placed exactly
    // where the code computes — so the restyler ran, and only the text was
    // missed.
    //
    // The likely reason is that iOS 16 does not draw the row title in a UILabel,
    // which is the only thing recoloured below. A UIButton title is handled as
    // well, and the probe reports which of the two the row actually holds so the
    // next build does not have to guess.
    UIColor *title = LMNGlassRoleTitle(role, theme);

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LMNCollectLabels(row, labels);
    for (UILabel *label in labels) {
        LMNRecolorLabel(label, title);
    }

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    LMNCollectButtons(row, buttons);
    for (UIButton *button in buttons) {
        [button setTitleColor:title forState:UIControlStateNormal];
        [button setTitleColor:[title colorWithAlphaComponent:0.7]
                     forState:UIControlStateHighlighted];
        button.tintColor = title;
        // A button that carries an attributed title is not recoloured by
        // setTitleColor:, exactly the same trap as the attributed label above.
        NSAttributedString *attrTitle =
            [button attributedTitleForState:UIControlStateNormal];
        if (attrTitle != nil && attrTitle.length > 0) {
            NSMutableAttributedString *restyled =
                [[NSMutableAttributedString alloc]
                    initWithAttributedString:attrTitle];
            NSRange full = NSMakeRange(0, restyled.length);
            [restyled removeAttribute:NSForegroundColorAttributeName
                                range:full];
            [restyled addAttribute:NSForegroundColorAttributeName
                              value:title
                              range:full];
            [button setAttributedTitle:restyled
                              forState:UIControlStateNormal];
        }
        // A button draws its title through its titleLabel, and UIKit re-applies
        // the tint during layout when this is left in place — which is what
        // would undo the line above on every relayout pass.
        //
        // Written as an explicit local rather than `button.titleLabel?.textColor`,
        // which is Swift: an optional chain cannot be the target of an assignment.
        UILabel *buttonTitle = button.titleLabel;
        if (buttonTitle != nil) {
            buttonTitle.textColor = title;
        }
    }

    LMNProbe(@"text cls=%@ labels=%lu buttons=%lu role=%ld want=%@",
             NSStringFromClass([row class]), (unsigned long)labels.count,
             (unsigned long)buttons.count, (long)role, title);
}

/// Recolour the alert's own text -- the title and the message body -- which
/// live in the card's header, NOT in an action row, so the per-row styler
/// (LMNStyleActionRowText above) never touches them. That is the "标题跟内容
/// 没覆盖到" symptom: the capsules and grabber land exactly where the code
/// computes (proving the restyler ran), but the header text keeps the host's
/// tint because nothing ever sets its colour.
///
/// Every label that is not inside an action row gets the readable ink
/// (near-black on a light glass, white on a dark one). Action-row labels keep
/// their role colour from the per-row styler and are skipped here.
///
/// 1.2.36: 标题/正文覆盖色。用 label.text 匹配 controller.title /
/// controller.message 精确命中，其余 header 标签沿用可读墨色。缺键=nil=沿用主题。
static void LMNStyleContentText(UIView *root, UIAlertController *controller,
                                LMNGlassParams *params) {
    LMNGlassTheme theme = params.theme;
    // 回落墨色取「主题派生的次要墨色」，显式传 nil 以避开按钮文字覆盖，
    // 保证 header 不被 buttonTextSecondary 影响。
    UIColor *fallbackInk =
        [LMNGlassPanelView glassTitleForRole:LMNGlassButtonRoleSecondary
                                      theme:theme params:nil];
    UIColor *titleInk = params.titleTextColor ?: fallbackInk;
    UIColor *messageInk = params.messageTextColor ?: fallbackInk;
    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    LMNCollectActionRows(root, rows);
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LMNCollectLabels(root, labels);
    for (UILabel *label in labels) {
        BOOL inRow = NO;
        for (UIView *row in rows) {
            if ([label isDescendantOfView:row]) {
                inRow = YES;
                break;
            }
        }
        if (inRow) {
            continue;
        }
        UIColor *ink = fallbackInk;
        if (controller.title.length > 0
            && [label.text isEqualToString:controller.title]) {
            ink = titleInk;
        } else if (controller.message.length > 0
                   && [label.text isEqualToString:controller.message]) {
            ink = messageInk;
        }
        LMNRecolorLabel(label, ink);
    }
    LMNProbe(@"content labels=%lu title=%@ msg=%@",
             (unsigned long)labels.count, titleInk, messageInk);
}

/// An action sheet on iOS 27 is a bottom sheet with a small grabber handle
/// centred at the top. The host puts nothing there, so we add one. Tracked on
/// the card with an associated object so relayout re-frames rather than stacks.
static void LMNStyleActionSheetGrabber(UIView *card, LMNGlassTheme theme) {
    if (card == nil) {
        return;
    }
    UIView *grabber = objc_getAssociatedObject(card, LMNGrabberKey);
    if (grabber == nil) {
        grabber = [[UIView alloc] initWithFrame:CGRectZero];
        grabber.userInteractionEnabled = NO;
        grabber.layer.masksToBounds = YES;
        objc_setAssociatedObject(card, LMNGrabberKey, grabber,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [card addSubview:grabber];
    }
    BOOL dark = [LMNGlass isDarkTheme:theme];
    grabber.backgroundColor =
        dark ? [UIColor colorWithWhite:1.0 alpha:0.35]
             : [UIColor colorWithWhite:0.0 alpha:0.20];
    CGRect b = card.bounds;
    if (!CGRectIsEmpty(b)) {
        CGFloat w = 36.0, h = 5.0;
        grabber.frame = CGRectMake((CGRectGetWidth(b) - w) * 0.5, 8.0, w, h);
        grabber.layer.cornerRadius = h * 0.5;
    }
}

/// Dump the presentation's whole view tree with the facts that decide card
/// recognition, so one device run settles every hypothesis at once.
///
/// Added for 1.1.5. Three symptoms are outstanding and they are NOT one bug:
/// some popups never get a background at all, some get one that is not a single
/// piece, and some are only partly converted. Each points at a different test:
///
///   - no background at all      -> the card was never recognised
///   - only part of it converted -> only one of SEVERAL cards was recognised
///   - buttons changed, card did not -> the row pass ran and the card pass did not
///
/// Card recognition currently derives every card from the action rows
/// (LMNAlertCards), and the rows are found by matching the private class name
/// against "ActionView" (LMNClassNameHasActionView). That is a string match on
/// an undocumented symbol, so whether it works is a property of the iOS build
/// and of which private view the host happens to use -- and the failure is
/// silent: an empty row list just falls through to the geometric fallback, which
/// returns exactly ONE card.
///
/// So this prints, per alert: every view in the tree with its class, width,
/// whether it contains an action row, whether it was chosen as a card, and the
/// alpha of its own background. That last one is what makes the difference
/// between "the card was not found" and "the card was found but its backdrop is
/// opaque", which look identical on screen and need opposite fixes.
///
/// Depth-limited so a pathological tree cannot produce an unbounded log.
static void LMNDumpViewTree(UIView *view, NSInteger depth, NSInteger maxDepth,
                            NSMutableString *out) {
    if (view == nil || depth > maxDepth) {
        return;
    }
    // Report the real alpha for any colour space. The old getWhite: probe
    // printed "nil" for a tinted background, which is exactly the case this
    // dump exists to catch -- so it was lying about the one thing that matters.
    BOOL hasAlpha = view.backgroundColor != nil;
    CGFloat alpha = hasAlpha ? LMNColorAlpha(view.backgroundColor) : 1.0;
    NSMutableString *pad = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) {
        [pad appendString:@"  "];
    }
    // One value per specifier, in order: pad, class, w, h, ACTIONROW, row,
    // card, background-nil marker, background alpha, OPAQUE, FX, GLASSPANEL.
    // This draft was wrong twice. It had `card=%d` with no argument, and then
    // a trailing `%@` with no value either -- and the first error shifted the
    // argument list left by one, so clang reported the damage four lines below
    // the cause instead of at it.
    [out appendFormat:@"%@%@ w=%.0f h=%.0f%@ row=%d card=%d bg=%@%.2f%@%@%@\n",
                      pad, NSStringFromClass([view class]),
                      CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds),
                      LMNClassNameHasActionView(view) ? @" ACTIONROW" : @"",
                      LMNClassNameHasActionView(view) ? 1 : 0,
                      objc_getAssociatedObject(view, LMNPanelKey) != nil ? 1 : 0,
                      hasAlpha ? @"" : @"nil",
                      hasAlpha ? alpha : 1.0,
                      hasAlpha && alpha > 0.99 ? @" OPAQUE" : @"",
                      [view isKindOfClass:[UIVisualEffectView class]] ? @" FX" : @"",
                      [view isKindOfClass:[LMNGlassPanelView class]] ? @" GLASSPANEL" : @""];
    for (UIView *subview in view.subviews) {
        LMNDumpViewTree(subview, depth + 1, maxDepth, out);
    }
}

/// Report the ancestors ABOVE the card as well, because they are where an
/// opaque backdrop survives: LMNClearOpaqueBackgrounds walks DOWN from the card
/// and never touches a container above it, so a card can be perfectly clean and
/// still sit on an opaque host panel that stops the blur from sampling anything.
static void LMNDumpAncestors(UIView *card, NSInteger limit) {
    NSMutableString *out = [NSMutableString string];
    UIView *probe = card.superview;
    NSInteger level = 0;
    while (probe != nil && level < limit) {
        BOOL hasAlpha = probe.backgroundColor != nil;
        CGFloat alpha = hasAlpha ? LMNColorAlpha(probe.backgroundColor) : 1.0;
        // %@ not %s: the "nil" marker is an NSString, and %s would take its
        // char* type and print the pointer. Clang rejects the mismatch outright
        // under -Werror, which is cheaper than reading a hex address.
        [out appendFormat:@"  ANCESTOR+%ld %@ w=%.0f bg=%@%.2f%@%@\n",
                          (long)level, NSStringFromClass([probe class]),
                          CGRectGetWidth(probe.bounds),
                          hasAlpha ? @"" : @"nil", alpha,
                          (hasAlpha && alpha > 0.99) ? @" OPAQUE" : @"",
                          [probe isKindOfClass:[UIVisualEffectView class]] ? @" FX" : @""];
        probe = probe.superview;
        level++;
    }
    LMNProbe(@"ancestors above card:\n%@", out);
}


/// The actions a controller we are restyling exposes.
///
/// `UIAlertController` answers directly, and SpringBoard's `_SBAlertController`
/// -- the class behind the system permission dialogs (notification / ATT /
/// location) -- IS a `UIAlertController` subclass, so it answers through the
/// same public `actions` property rather than exposing nothing.
///
/// (1.2.6 through 1.2.8 asserted the opposite -- that it was not a
/// `UIAlertController` -- and that false premise is what inverted every
/// system-dialog gate. The property is typed `NSArray<UIAlertAction *>`, so
/// reading `title` / `style` off an entry is safe. A dialog that reports no
/// actions yields an empty list and every row styles neutral, which is the
/// right shape for a "允许 / 不允许" pair.)
static NSArray<UIAlertAction *> *LMNActionsForController(UIViewController *controller) {
    if ([controller isKindOfClass:[UIAlertController class]]) {
        return ((UIAlertController *)controller).actions ?: @[];
    }
    return @[];
}

/// The nominated preferred action, or nil. `UIAlertController` nominates one;
/// `_SBAlertController` inherits the accessor and normally nominates nothing,
/// so no system-dialog row is forced to the accent.
static UIAlertAction *LMNPreferredActionForController(UIViewController *controller) {
    if ([controller isKindOfClass:[UIAlertController class]]) {
        return ((UIAlertController *)controller).preferredAction;
    }
    return nil;
}

/// All of the per-card work that used to live inline in `restyleAlertController:`.
/// Hoisted so the restyler can apply the identical treatment to every card an
/// `UIAlertController` draws — an action sheet keeps its cancel button on a
/// separate card, and both must be glassed. The controller is typed as the
/// superclass so the same pass also serves `_SBAlertController`.
static void LMNRestyleCard(UIView *card, UIViewController *controller,
                           LMNGlassParams *params) {
    card.backgroundColor = [UIColor clearColor];
    card.layer.masksToBounds = YES;
    card.layer.cornerRadius = params.cornerRadius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    // Four levels: depending on the iOS point release the alert's opaque
    // background sits on the card itself or on a container one or two levels
    // down, and a background that survives here is what makes the glass
    // invisible. The width guard keeps the walk away from real content.
    LMNClearOpaqueBackgrounds(card, card.bounds, 8);
    // 1.2.9: and the action-group hairlines with it. They are the host's own
    // chrome and read as native lines drawn across the glass -- see
    // LMNHideActionSeparators.
    LMNHideActionSeparators(card);

    // Walk UP as well: an opaque host above the card blocks the panel's blur
    // just as surely as an opaque child below it. See LMNClearOpaqueAncestors.
    LMNClearOpaqueAncestors(card, controller.view, 8);

    // 1.1.10 (方案2): unify the card's outer ring with the action capsule's
    // thin border. The panel draws a 9pt "refracted" halo (refractLayer) on top
    // of its 1.5pt rim; the capsule carries only a 1pt border, so the two read
    // as different weights. Zeroing the panel's refraction hides the halo
    // (refractLayer.isHidden at width <= 0.001) and leaves just the 1.5pt rim,
    // matching the capsule's thin ring. Geometry, fill, blur and capsule sizing
    // all stay on the live params; only the halo is zeroed, and on a private
    // copy so the resolved-value probe and the action rows are untouched.
    LMNGlassParams *panelParams = [params copyParams];
    panelParams.refractionWidth = 0.0;

    LMNGlassPanelView *panel = objc_getAssociatedObject(card, LMNPanelKey);
    if (panel == nil) {
        panel = [[LMNGlassPanelView alloc] initWithFrame:card.bounds
                                                  params:panelParams];
        panel.frame = card.bounds;
        panel.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [card insertSubview:panel atIndex:0];
        objc_setAssociatedObject(card, LMNPanelKey, panel,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The fade only runs here, in the branch that *creates* the panel.
        // restyleAlertController: is called from viewWillAppear, viewDidAppear
        // and viewDidLayoutSubviews, so every later pass takes the `else`
        // branch — the glass fades in once per alert, not once per layout.
        if (params.fadeEnabled) {
            panel.alpha = 0.0;
            [UIView animateWithDuration:params.fadeDuration
                                  delay:0.0
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                                 panel.alpha = 1.0;
                             }
                             completion:nil];
        }
    } else {
        if (panel.superview != card) {
            // A relayout can detach the panel from its card; re-anchor it so
            // the glass does not silently vanish between layout passes.
            [card insertSubview:panel atIndex:0];
        }
        panel.frame = card.bounds;
        // No appearance to set any more: the panel reads the theme out of
        // the params it was built with. A second appearance argument was
        // the second source of truth 1.1.2 removed -- and it is what let a
        // 明昼 card come out dark whenever the system was in dark mode.
        [panel applyParams:panelParams];
    }

    NSArray<UIAlertAction *> *actions = LMNActionsForController(controller);
    UIAlertAction *preferred = LMNPreferredActionForController(controller);
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    LMNCollectButtons(card, buttons);
    for (UIButton *button in buttons) {
        if (LMNViewIsInsideTextField(button, card)) {
            continue;
        }
        NSString *title = [button titleForState:UIControlStateNormal];
        UIAlertAction *match = nil;
        for (UIAlertAction *action in actions) {
            if (action.title == title || [action.title isEqualToString:title]) {
                match = action;
                break;
            }
        }
        // An unmatched button used to be skipped outright, which left it
        // carrying the host's own background and tint inside an otherwise glass
        // card. Styling it neutral is the same call LMNStyleAllActionRows makes
        // for an unmatched row: the shape still has to be glass for the card to
        // read as one material.
        LMNGlassButtonRole role = LMNRoleForAction(match, preferred);
        // 1.2.7: a button that belongs to an action row is NOT given glass of
        // its own. LMNStyleActionRow already drew a capsule behind that row's
        // label, so filling the button as well put a second pill — with its own
        // rim and shadow — inside the first, which is the "按钮里面还多套一层"
        // report from the system permission dialogs. Those rows are built from
        // real UIButtons (an app alert's are not), so only this guard keeps the
        // two renderers from stacking. The title colour is left to the row
        // pass, which applies the same role ink to every label and button it
        // finds, so dropping the fill here loses no readability.
        //
        // The host's own button background still has to go, or it would read as
        // a third layer: an opaque system button face that the capsule behind it
        // cannot show through.
        if (LMNButtonIsInsideActionRow(button, card)) {
            [button setBackgroundImage:nil forState:UIControlStateNormal];
            [button setBackgroundImage:nil forState:UIControlStateHighlighted];
            button.backgroundColor = [UIColor clearColor];
            button.layer.borderWidth = 0.0;
            button.layer.shadowOpacity = 0.0;
            LMNProbe(@"lumen 1.2.46 row button title=%@ role=%ld capsule-owned",
                     title, (long)role);
            continue;
        }
        [LMNGlassPanelView styleButton:button
                                  role:role
                                 theme:params.theme
                                params:params];
        CGFloat half = CGRectGetHeight(button.bounds) * 0.5;
        button.layer.cornerRadius =
            MAX(1.0, MIN(half, params.buttonHeight * 0.5));
        LMNProbe(@"card button title=%@ matched=%@ role=%ld",
                 title, match != nil ? match.title : @"(nil)", (long)role);
    }

    // The action *rows* are styled by LMNStyleAllActionRows, once, over the
    // whole controller — see the note there for why they are not styled per
    // card.

    NSMutableArray<UITextField *> *textFields = [NSMutableArray array];
    LMNCollectTextFields(card, textFields);
    for (UITextField *field in textFields) {
        LMNStyleTextField(field, params.theme, params);
    }
}

/// Style every action row the presentation draws.
///
/// This runs over the whole controller rather than per card on purpose. An
/// action sheet splits its actions across two cards, and when the second card
/// is not recognised as a card the per-card pass never reaches its rows — which
/// is exactly how the cancel button kept its opaque white background and its
/// system tint colour while every other row got a proper capsule. Rows that
/// match no action are styled neutral rather than skipped, for the same reason:
/// a row left alone keeps the opaque background that is being fixed.
static void LMNStyleAllActionRows(UIViewController *controller,
                                  LMNGlassTheme theme,
                                  LMNGlassParams *params,
                                  BOOL requireGlass,
                                  NSArray<UIView *> *cards) {
    UIView *root = controller.view;
    if (root == nil) {
        return;
    }
    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    LMNCollectActionRows(root, rows);
    if (rows.count == 0) {
        return;
    }
    // Consume each action as it is matched, so a sheet whose two cards happen to
    // carry the same title still maps one-to-one instead of both rows claiming
    // the first action.
    NSMutableArray<UIAlertAction *> *available =
        [NSMutableArray arrayWithArray:LMNActionsForController(controller)];
    UIAlertAction *preferred = LMNPreferredActionForController(controller);
    for (UIView *row in rows) {
        // 1.2.8: on the system dialogs a row is only dressed when its own card
        // was glassed. The unconditional pass below is what makes an app alert
        // recover a cancel row whose second card was not recognised, but on a
        // dialog we never glassed it is also what put our capsules on the
        // system's own buttons -- "the window was not replaced but the buttons
        // are ours". See LMNRowSitsOnGlass.
        if (requireGlass && !LMNRowSitsOnGlass(row)) {
            LMNProbe(@"lumen 1.2.46 row left native (no glass) cls=%@",
                     NSStringFromClass([row class]));
            continue;
        }
        NSString *title = LMNTitleForActionRow(row);
        UIAlertAction *match = nil;
        for (UIAlertAction *action in available) {
            if (title != nil && [action.title isEqualToString:title]) {
                match = action;
                break;
            }
        }
        if (match != nil) {
            [available removeObject:match];
        }
        LMNGlassButtonRole role = LMNRoleForAction(match, preferred);
        // A nil match is not cosmetic: LMNRoleForAction(nil) is `.secondary`, so
        // an unmatched destructive row silently gets a neutral capsule. That is
        // the whole reason "卸载" stayed grey on a real device, and it is
        // invisible in a screenshot because the row still gets a pill — just the
        // wrong colour. Print enough here to tell "no title could be read" apart
        // from "title read but did not match any action".
        LMNProbe(@"match title=%@ matched=%@ role=%ld remaining=%lu",
                 title, match != nil ? match.title : @"(nil)", (long)role,
                 (unsigned long)available.count);
        LMNStyleActionRow(row, match, role, theme, params,
                          LMNGlassCardForRow(row, cards));
    }
}

#pragma mark - Restyler

@interface LMNAlertRestyler ()
/// Shared implementation behind `restyleAlertController:` and
/// `restyleSystemAlertController:`. Declared here so both entry points can call
/// it even though it is defined below them.
+ (void)restyleController:(UIViewController *)controller
                addToLive:(BOOL)addToLive;
@end

@implementation LMNAlertRestyler

+ (NSHashTable<UIAlertController *> *)liveAlerts {
    static NSHashTable<UIAlertController *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

+ (void)bootstrap {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            LMNGlassPreferenceChangedCallback, LMNGlassPreferencesChangedNotification,
            NULL, CFNotificationSuspensionBehaviorCoalesce);
    });
}

+ (void)restyleAlertController:(UIAlertController *)controller {
    [self restyleController:controller addToLive:YES];
}

+ (void)restyleSystemAlertController:(UIViewController *)controller {
    // System permission dialogs (SpringBoard's `_SBAlertController`) are
    // transient and are not user-styled content, so they are restyled in place
    // but never tracked as live alerts. This is the entry that closes the gap
    // the app-alert lifecycle hooks leave: those hooks never fire on a
    // controller that is not a UIAlertController.
    [self restyleController:controller addToLive:NO];
}

+ (void)restyleController:(UIViewController *)controller
                addToLive:(BOOL)addToLive {
    if (controller == nil) {
        return;
    }
    // The master switch lives in Swift (LMNGlass reads the preference store).
    // When it is off, never restyle: an alert that is already on screen must not
    // flicker back to the native look halfway through its presentation.
    if (![LMNGlass enabled]) {
        return;
    }
    NSArray<UIView *> *cards = LMNAlertCards(controller);
    // Resolved against the alert's own traits, so 自动 is answered by the
    // appearance the user is actually looking at.
    LMNGlassParams *params =
        [LMNGlass currentForTraits:controller.traitCollection];
    BOOL dark = LMNAlertIsDark(controller);

    // The values the renderer actually resolved to, after clamping. In 1.1.1 the
    // capsule geometry is no longer read from the preference store at all, so
    // this line is the only place that proves the constants took effect — the
    // symptom it explains (a pill sitting 8pt from the card edge instead of 16)
    // is otherwise only visible as pixels.
    LMNProbe(@"params dark=%d radius=%.1f blur=%.1f refract=%.1f "
             @"highlight=%.2f tint=%.2f buttonHeight=%.1f buttonInset=%.1f",
             dark ? 1 : 0, params.cornerRadius, params.blurIntensity,
             params.refractionWidth, params.highlightIntensity,
             params.tintConcentration, params.buttonHeight,
             params.buttonInset);

    for (UIView *card in cards) {
        if (CGRectIsEmpty(card.bounds)) {
            continue;
        }
        LMNRestyleCard(card, controller, params);
    }

    // 1.1.5: what the tree actually looks like, and how many cards came out of
    // the recogniser. `rows` is reported separately from `cards` because the
    // symptom "the buttons changed but the background did not" means rows > 0
    // and cards == 0, while "only part of it changed" means cards == 1 when the
    // presentation draws more than one card — and the two need opposite fixes.
    NSMutableArray<UIView *> *probeRows = [NSMutableArray array];
    LMNCollectActionRows(controller.view, probeRows);
    {
        NSMutableString *tree = [NSMutableString string];
        LMNDumpViewTree(controller.view, 0, 8, tree);
        LMNProbe(@"=== alert tree: actions=%lu rows=%lu cards=%lu root=%.0fx%.0f "
                 @"style=%ld",
                 (unsigned long)LMNActionsForController(controller).count,
                 (unsigned long)probeRows.count,
                 (unsigned long)cards.count,
                 CGRectGetWidth(controller.view.bounds),
             CGRectGetHeight(controller.view.bounds),
             (long)LMNResolvedStyle(controller));
        LMNProbe(@"tree:\n%@", tree);
        for (UIView *card in cards) {
            LMNProbe(@"CARD %@ %.0fx%.0f at (%.0f,%.0f)",
                      NSStringFromClass([card class]),
                      CGRectGetWidth(card.bounds), CGRectGetHeight(card.bounds),
                      card.frame.origin.x, card.frame.origin.y);
            LMNDumpAncestors(card, 8);
        }
    }

    // 1.2.8: the system dialogs are all-or-nothing.
    //
    //     The row pass below is deliberately unconditional -- on an app alert it
    //     recovers the cancel row of a sheet whose second card was not
    //     recognised, which beats leaving an opaque white button on screen. On a
    //     system dialog that same unconditional pass is what filled the buttons
    //     with our capsules while the card stayed native: the reported "the
    //     window was not replaced but the buttons are ours". Recolouring the
    //     title and message is worse still, because those sit on a card whose
    //     background we did not clear -- white ink on a white dialog.
    //
    //     So on this path a missing card is not a partial restyle to be salvaged
    //     with heuristics. It means the presentation is one we cannot theme, and
    //     the honest result is to leave every pixel of it alone.
    //
    //     The guard used to read `![controller isKindOfClass:[UIAlertController
    //     class]] && cards.count == 0`. `_SBAlertController` IS a
    //     UIAlertController, so that first conjunct was always false and the
    //     guard never fired at all -- see LMNControllerIsSystemDialog. Asking
    //     for the concrete class is what makes it engage.
    if (LMNControllerIsSystemDialog(controller) && cards.count == 0) {
        LMNProbe(@"lumen 1.2.46 system dialog left native: rows=%lu cards=0",
                 (unsigned long)probeRows.count);
        return;
    }

    // Rows are styled across the whole controller rather than per card: an
    // action sheet keeps its cancel button on a second card, and a per-card pass
    // silently missed it whenever that second card was not recognised. This also
    // runs when no card was found at all — the rows still get their capsules,
    // which beats leaving an opaque white cancel button on screen.
    LMNStyleAllActionRows(controller, params.theme, params,
                          LMNControllerIsSystemDialog(controller), cards);

    // The alert title and message are header content, not action rows, so the
    // per-row text styler never recolours them. Do it here, across the whole
    // controller, so they pick up the readable ink instead of the host tint.
    // The same resolved palette the capsules got, not a fresh read: the ink
    // and the buttons have to come from one answer.
    LMNStyleContentText(controller.view, (UIAlertController *)controller, params);

    // An action sheet is a bottom sheet with a grabber at the top of its first
    // card. The host draws no such handle, so add one to read as iOS 27.
    if (LMNResolvedStyle(controller) == 0 && cards.count > 0) {
        LMNStyleActionSheetGrabber(cards.firstObject, params.theme);
    }

    if (addToLive && [controller isKindOfClass:[UIAlertController class]]) {
        [[self liveAlerts] addObject:(UIAlertController *)controller];
    }
}

+ (void)refreshLiveAlerts {
    if (![LMNGlass enabled]) {
        return;
    }
    for (UIAlertController *controller in [[self liveAlerts] allObjects]) {
        [self restyleAlertController:controller];
    }
}

+ (void)alertsDidChangeAppearance {
    // 1.2.0: a system dark/light flip no longer changes the glass. The theme
    // is the user's choice now (曜石玻璃 / 影院暗色 / 明昼) and it is read
    // fresh from the store on every pass, so 明昼 stays light in dark mode --
    // which is the whole point of the picker. This hook is kept as a
    // defensive repaint: rebuilding the panel re-reads the theme, so an alert
    // that is already on screen picks up a change whatever caused it.
    if (![LMNGlass enabled]) {
        return;
    }
    for (UIAlertController *controller in [[self liveAlerts] allObjects]) {
        for (UIView *card in LMNAlertCards(controller)) {
            LMNGlassPanelView *panel = objc_getAssociatedObject(card, LMNPanelKey);
            if (panel != nil) {
                [panel removeFromSuperview];
                objc_setAssociatedObject(card, LMNPanelKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        [self restyleAlertController:controller];
    }
}

@end

static void LMNGlassPreferenceChangedCallback(CFNotificationCenterRef center,
                                              void *observer, CFStringRef name,
                                              const void *object,
                                              CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    [LMNAlertRestyler refreshLiveAlerts];
}

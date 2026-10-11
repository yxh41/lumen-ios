//
//  LMNModernAlertController.m
//  Lumen
//
//  1.1.13. The replacement renderer -- see the header for why it exists.
//
//  Design constraints, in the order they matter:
//
//   1. Read ONLY public API off the source alert. The whole point of this class
//      is that nothing here depends on UIKit's private alert view tree, because
//      depending on it is what made the restyler's coverage incomplete.
//   2. Keep the host's contract. Every action handler fires, text field values
//      are copied back into the source alert before the handler runs (the host
//      reads `alert.textFields[i].text`, not our field), and the controller
//      dismisses the way the system alert would.
//   3. Degrade, never crash. `replacementForAlertController:` returns nil on
//      anything unexpected and the caller presents the system alert instead.
//

#import "LMNModernAlertController.h"

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#import "LMNGlassStyle.h"
// The appearance half is Swift; Theos generates this from LMNGlass.swift and
// LMNGlassPanelView.swift. Same import LMNAlertRestyler.m makes.
#import "Lumen-Swift.h"

/// Keys for the two associations this file owns.
///
/// Both are pointers to their own storage rather than selectors: an
/// `objc_setAssociatedObject` key has to be a constant address, and a static
/// variable is the only thing guaranteed to be one.
static void *LMNCapturedHandlerKey = &LMNCapturedHandlerKey;
static void *LMNReplacementKey = &LMNReplacementKey;

/// 1.2.23. Marks a source alert that has a replacement standing in for it, so the
/// in-place restyler leaves it alone. It is presented for real now (invisible,
/// and not taking touches), so its own lifecycle hooks DO fire -- and what the
/// restyler would draw into it must not be drawn, or the pixels we do draw are
/// the only ones the user sees twice over.
static void *LMNReplacedAlertKey = &LMNReplacedAlertKey;

/// 1.2.21. Stamped onto the replacement's own root view, so it can be recognised
/// later without needing the controller to still exist.
///
/// That independence is the whole point. A view is held by its superview, so a
/// view can outlive the controller that made it -- and the moment it does, every
/// check written as "ask the controller" silently becomes "do nothing". A
/// full-screen view of ours sitting in the host page's own view tree at alpha 0
/// eats the touches that would have asked for the next alert, so the host never
/// calls `presentViewController:` at all and no repair at the presentation site
/// can ever run.
static NSString *const LMNReplacementRootIdentifier = @"lumen.replacement.root";

// Geometry. The 270pt panel width and the 20pt content margin are UIKit's own
// alert metrics, so a replaced alert sits where the system one did instead of
// being a differently sized card in the same place.
static const CGFloat LMNModernPanelWidth = 270.0;
static const CGFloat LMNModernContentMargin = 20.0;
static const CGFloat LMNModernStackSpacing = 10.0;
static const CGFloat LMNModernOuterInset = 24.0;
static const CGFloat LMNModernSheetInset = 10.0;
static const CGFloat LMNModernButtonSpacing = 8.0;
static const CGFloat LMNModernFieldHeight = 36.0;
static const CGFloat LMNModernBackdropAlpha = 0.32;

/// How hard the backdrop dims, per theme.
///
/// This is what 影院暗色 actually IS: the reference's own footer describes it
/// as "拥有更深背景", and the card alone cannot carry that — a deep card on a
/// lightly dimmed screen still reads as bright, because the brightest thing
/// around it sets the level the eye judges the card against. 明昼 takes the
/// least: a heavy scrim over a light interface is the one thing that makes a
/// light card look like a dark card with a pale rectangle on it.
static CGFloat LMNModernBackdropAlphaForTheme(LMNGlassTheme theme) {
    switch (theme) {
        case LMNGlassThemeCinema:
            return 0.52;
        case LMNGlassThemeDaylight:
            return 0.18;
        case LMNGlassThemeObsidian:
            return 0.32;
    }
    return LMNModernBackdropAlpha;
}

/// Prefix matches LMNAlertRestyler's probe so one grep of the device log finds
/// both renderers. Not gated on DEBUG: the build marker in this file has to be
/// readable off a shipped dylib too.
static void LMNModernProbe(NSString *message) {
    NSLog(@"[lumen-probe] %@", message);
}

/// 1.2.34. Whether the replacement is allowed to draw its diagnostics on screen.
///
/// Three of these banners exist -- "presentation lost", "theme store unusable",
/// and the scrim sweep's own report -- and each one was written because the
/// device was believed to have no log to read. That is no longer true, and a
/// black bar appearing over an unrelated alert is itself read as a defect, which
/// is exactly what happened. So the probe keeps logging unconditionally -- the
/// log was never the problem -- and the bar is drawn only when the preference
/// asks for it. Absent key = OFF.
///
/// The answer comes from LMNGlass, which reads the store the way it reads
/// everything else: CFPreferences first, then the world-readable copy of the
/// plist. That is what makes the flag mean something inside a sandboxed host,
/// where a plain UserDefaults lookup would always see nothing and the banner
/// would be unreachable in the one place it is ever drawn.
static BOOL LMNOnScreenDiagnosticsEnabled(void) {
    static BOOL enabled = NO;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        enabled = [LMNGlass debugReports];
    }
    return enabled;
}

/// Whether this process is one the replacement renderer has to stay out of.
///
/// Lumen's filter is `com.apple.UIKit`, and that is a FRAMEWORK filter: it
/// injects into every process that links UIKit. SpringBoard links UIKit, so
/// SpringBoard is one of them.
///
/// Replacing an alert there is not the same operation as replacing one in an
/// app. SpringBoard's alert lives on SpringBoard's own window, which sits
/// BEHIND the foreground application, so a replacement drawn into it is
/// invisible and untappable while an app is in front. The alert is then never
/// dismissed, SpringBoard stays in its "an alert is up" state, and the gesture
/// SpringBoard suppresses while that state holds is the swipe up to the home
/// screen.
///
/// That is exactly the reported shape: in-app touches keep working because the
/// app is a different process, and the home gesture stops responding because
/// SpringBoard is the process that would have handled it. Nothing in the app is
/// misbehaving, which is why the report named no particular operation -- the
/// trigger is a system alert the user never saw replaced.
///
/// So the replacement declines here and the hook falls through to %orig, which
/// presents the system alert unchanged. The in-place restyler is not affected
/// and still runs in SpringBoard, where it has been stable since 1.1.x.
static BOOL LMNReplacementIsForbiddenHere(void) {
    static BOOL forbidden = NO;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        // Both the identifier and the process name are checked. The identifier
        // is the documented answer; the name costs nothing and covers a host
        // whose bundle identifier is not what the docs say it is.
        NSString *host = [NSBundle.mainBundle.bundleIdentifier lowercaseString];
        NSString *name = NSProcessInfo.processInfo.processName;
        forbidden = ([host isEqualToString:@"com.apple.springboard"]
                     || [name isEqualToString:@"SpringBoard"]);
    }
    return forbidden;
}

/// 1.2.40: read a private attributed property (`attributedTitle` or
/// `attributedMessage`) without crashing when it does not exist, and only return
/// it when it is a non-empty `NSAttributedString`.
///
/// TrollStore's install confirmation is built from exactly this: a plain
/// `UIAlertController` whose public `title`/`message` are empty and whose whole
/// content -- the app icon and the Metadata / Sandboxing / Capabilities /
/// Accessible Containers sections, in colour -- lives in these properties. The
/// self-drawn card used to read only the public pair, so it drew an empty shell.
/// It now reads the rich pair and renders it, which is what lets the WHOLE alert
/// be ours rather than a native card with our buttons on it.
static NSAttributedString *LMNAlertAttributedString(UIAlertController *alert,
                                                    NSString *key) {
    if (alert == nil || key == nil) {
        return nil;
    }
    NSAttributedString *value = nil;
    @try {
        id raw = [alert valueForKey:key];
        if ([raw isKindOfClass:[NSAttributedString class]] && [raw length] > 0) {
            value = raw;
        }
    } @catch (NSException *exception) {
        (void)exception;
        value = nil;
    }
    return value;
}

/// 1.2.19: every replacement this process has built, kept weakly.
///
/// The registry exists because this version fixes a failure that no amount of
/// care at the dismissal site can rule out. A replacement that outlives its own
/// dismissal blocks its presenter for the rest of the process, and the evidence
/// is invisible: the exit has already taken the panel's alpha to 0, so what is
/// left on screen is a transparent view holding a presentation nobody can see.
///
/// 1.2.18 tried to prevent that by guessing how long the teardown takes -- one
/// turn of the main queue -- and the guess was wrong. This does not guess. It
/// records every replacement, and the next time an alert is about to be
/// replaced it removes anything of ours that should already be gone. The repair
/// therefore does not depend on knowing WHY the teardown stalled, which is the
/// one thing two versions in a row got wrong.
static NSHashTable<LMNModernAlertController *> *LMNLiveReplacements(void) {
    static NSHashTable<LMNModernAlertController *> *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

/// 1.2.24. Declared here rather than in the header because nothing outside this
/// file calls them: the two internals of the scrim removal, and the single pass
/// it repeats. Declaring them also means the order the methods happen to be
/// written in cannot decide whether they compile.
@interface LMNModernAlertController (LMNSystemScrim)
+ (BOOL)lmn_hideSystemScrimIn:(UIView *)container
                    presented:(UIView *)presented
                      geometry:(BOOL)geometry
                        depth:(NSUInteger)depth;
+ (void)lmn_hideSystemScrimForAlert:(UIAlertController *)alert;
- (void)lmn_hideSystemScrimPass;
- (void)lmn_takeOutNewScrims;
- (void)lmn_restoreTakenScrims;
+ (void)lmn_takeDimmingOutOf:(UIView *)view
                        hide:(BOOL)hide
                        undo:(NSMutableArray *)undo;
- (BOOL)lmn_startDismissalWithCompletion:(void (^ _Nullable)(void))completion;
- (void)lmn_takeOutPresentationDimmingView;
- (void)lmn_reportScrimDiagnosis;
+ (void)lmn_reportThemeFallback:(NSString *)detail
                       inWindow:(UIWindow *)hostWindow;
+ (void)lmn_presentDiagnostic:(NSString *)text
                     inWindow:(UIWindow *)hostWindow;
@end

@implementation LMNModernAlertController {
    UIAlertController *_sourceAlert;
    UIView *_backdropView;
    UIView *_panelView;
    LMNGlassPanelView *_glassView;
    UIStackView *_contentStack;
    // 1.2.34. The content lives in a scroll view: a list of options has no
    // natural end, and a card that may not grow past the screen has to scroll
    // instead of tearing its own layout apart.
    UIScrollView *_contentScrollView;
    // 1.2.46. The capsules live in a stack of their own (a sibling of the body
    // scroller, pinned to the card's bottom edge) that sits INSIDE its own
    // scroll view, so a sheet with many buttons scrolls the action list instead
    // of overflowing. 1.2.45 put the stack on the bottom edge; 1.2.46 wraps it
    // in _actionScrollView (see viewDidLoad).
    UIScrollView *_actionScrollView;
    UIStackView *_actionStack;
    NSMutableArray<UIButton *> *_actionButtons;
    NSMutableArray<UITextField *> *_replacementTextFields;
    NSLayoutConstraint *_panelCenterYConstraint;
    NSLayoutConstraint *_panelBottomConstraint;
    BOOL _didAnimateIn;
    // 1.2.22. The replacement now lives in a window of its own instead of in the
    // host's presentation chain. That is the whole fix: five versions tried to
    // repair what handing the host a presentation does to the host, and the
    // on-screen probe finally showed the repair never even gets a chance -- the
    // host stops calling presentViewController: altogether once its own
    // `presentedViewController` is left standing. Not using that chain removes
    // the failure instead of chasing it.
    UIWindow *_hostWindow;
    UIWindow *_previousKeyWindow;
    // 1.2.19. Set the moment an exit begins, and read only afterwards. It is the
    // one piece of state that lets the sweep below tell "still on screen because
    // the user is looking at it" from "still installed because the teardown
    // stalled" -- the difference this whole version exists to act on.
    BOOL _teardownRequested;
    // 1.2.28. The scene's views as they were the instant before the alert went
    // up. See the section at the bottom for why the difference is the only
    // reliable description of UIKit's scrim.
    // 1.2.33. How many passes may still take something out of the screen.
    // Bounded on purpose -- see lmn_hideSystemScrimPass.
    NSInteger _scrimSweepPasses;
    // 1.2.31. Set the moment the source alert's dismissal is ASKED FOR, which
    // is now the moment the fade begins rather than a quarter of a second
    // later. Read by the teardown, which in that case only has the local half
    // left to do -- the caller's block belongs to the dismissal's completion.
    BOOL _dismissalStarted;
    NSHashTable *_sceneInventory;
    // 1.2.30. What was taken out, as blocks that put it back -- each one
    // carrying the view WEAKLY and the value it is restoring. A block rather
    // than a table because a scrim can be taken out by clearing its colour, by
    // dropping its blur, or by hiding the view, and the undo has to know which.
    NSMutableArray *_scrimUndo;
}

@synthesize sourceAlert = _sourceAlert;

- (instancetype)initWithAlertController:(UIAlertController *)alert {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _sourceAlert = alert;
        _actionButtons = [[NSMutableArray alloc] init];
        _replacementTextFields = [[NSMutableArray alloc] init];
        // OverFullScreen is what keeps the presenting view on screen behind us,
        // which is the only reason the glass has anything to blur. A normal
        // full-screen presentation removes it and the panel blurs black.
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 1.2.28: the inventory and the undo list are ordinary strong ivars, so ARC
    // drops them right here. Nothing has to be nilled by hand -- the delayed
    // passes hold weak references to this controller, and the restore holds the
    // undo list itself rather than reading it back through `self`.
}

#pragma mark - 1.2.22: a window of our own

/// Put the replacement on screen WITHOUT touching the host's presentation chain.
///
/// Returns NO when there is no scene to put a window in, and the caller then
/// falls back to presenting it -- the path every earlier version used.
///
/// Why this exists, stated plainly: handing the host a presentation sets
/// `host.presentedViewController`, and the host is entitled to look at that
/// before presenting anything. Five versions tried to guarantee the value is
/// cleared again, and the 1.2.21 probe showed the attempt is pointless -- on the
/// second tap the host never calls `presentViewController:` at all, so no repair
/// downstream of that call can ever run. Nothing is presented to the host here,
/// so nothing of ours can be left standing in anything of the host's: not in its
/// `presentedViewController`, not in its view tree.
- (BOOL)lmn_showInScene:(UIWindowScene *)scene hostWindow:(UIWindow *)hostWindow {
    if (_hostWindow != nil) {
        return YES;
    }
    if (scene == nil) {
        return NO;
    }

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = (hostWindow != nil) ? hostWindow.frame
                                       : UIScreen.mainScreen.bounds;
    // Above the app and its status bar, below nothing that matters: this is where
    // UIKit itself puts an alert that is not part of the app's own hierarchy.
    window.windowLevel = UIWindowLevelAlert;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = self;
    _previousKeyWindow = hostWindow;
    _hostWindow = window;

    // 1.2.33: AND ARM THE ENTRANCE BEFORE THE WINDOW CAN DRAW.
    //
    // -viewWillAppear: is where the entrance is armed, and it is called as the
    // window becomes visible -- which is the right moment for the invitation and
    // not early enough to be a guarantee. A single frame drawn before it lands
    // shows the card and the shade at full strength. Doing it here, with the
    // view loaded and the window still off screen, makes that frame impossible
    // rather than unlikely.
    [self loadViewIfNeeded];
    if (!_didAnimateIn) {
        _backdropView.alpha = 0.0;
        _panelView.alpha = 0.0;
        // Build marker: compiles into __cstring, so a shipped dylib can be
        // proved to carry the early arming without anyone reading a log.
        LMNModernProbe(@"lumen 1.2.46 entrance armed before the window");
    }
    // Key so the root view controller gets its appearance callbacks (the
    // entrance depends on -viewWillAppear:) and so a field can take the keyboard.
    // `hostWindow` is remembered above and made key again on the way out.
    [window makeKeyAndVisible];
    return YES;
}

/// Take the window away and give the host's window its key status back.
///
/// The two references are lifted into locals and the ivars cleared BEFORE the
/// window is let go: the window holds this controller as its root view
/// controller, so releasing it can deallocate `self` -- and nothing may touch an
/// ivar after that point.
- (void)lmn_hideHostWindow {
    UIWindow *window = _hostWindow;
    UIWindow *restore = _previousKeyWindow;
    _hostWindow = nil;
    _previousKeyWindow = nil;
    if (window == nil) {
        return;
    }
    window.hidden = YES;
    // The view stays in the hidden window; `lmn_ensureRootViewGone:` has already
    // been asked to detach it, and does so without going through `self`.
    if (restore != nil && !restore.isHidden) {
        [restore makeKeyAndVisible];
    }
}

/// Under UIModalPresentationOverFullScreen the presented controller owns the
/// status bar, and a dark glass panel under a dark-on-black bar is unreadable
/// for as long as the alert is up -- which is the whole time the user is
/// looking at it.
- (UIStatusBarStyle)preferredStatusBarStyle {
    return [self lmn_isDark] ? UIStatusBarStyleLightContent
                             : UIStatusBarStyleDefault;
}

#pragma mark - Appearance helpers

- (BOOL)lmn_isDark {
    // 1.2.2: the theme decides, and 自动 is the one choice that means "ask
    // the system". So the trait collection is read from this controller --
    // which is in a window by the time anything asks -- and never from
    // UITraitCollection.current, which -viewDidLoad is too early for.
    return [LMNGlass isDarkTheme:
        [LMNGlass resolvedThemeForTraits:self.traitCollection]];
}

- (BOOL)lmn_isSheet {
    return self.sourceAlert.preferredStyle == UIAlertControllerStyleActionSheet;
}

/// Which capsule material an action gets.
///
/// `preferredAction` is UIKit's own "this is the one the user probably wants"
/// marker and it is public API, so the accent follows the host's choice rather
/// than a guess. A single-action alert gets the accent too: there is nothing to
/// choose between and a neutral lone button reads as disabled.
- (LMNGlassButtonRole)lmn_roleForAction:(UIAlertAction *)action {
    if (action.style == UIAlertActionStyleDestructive) {
        return LMNGlassButtonRoleDestructive;
    }
    if (action == self.sourceAlert.preferredAction
        || self.sourceAlert.actions.count == 1) {
        return LMNGlassButtonRolePrimary;
    }
    return LMNGlassButtonRoleSecondary;
}

#pragma mark - View

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    // See LMNReplacementRootIdentifier: the view has to be recognisable on its
    // own, because it can outlive this controller.
    self.view.accessibilityIdentifier = LMNReplacementRootIdentifier;

    UIView *backdrop = [[UIView alloc] initWithFrame:self.view.bounds];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth
                                | UIViewAutoresizingFlexibleHeight;
    backdrop.backgroundColor =
        [[UIColor blackColor] colorWithAlphaComponent:
            LMNModernBackdropAlphaForTheme(
                [LMNGlass resolvedThemeForTraits:self.traitCollection])];
    // 1.2.36: 背景遮罩覆盖色。
    {
        LMNGlassParams *scrimParams =
            [LMNGlass currentForTraits:self.traitCollection];
        if (scrimParams.scrimColor != nil) {
            backdrop.backgroundColor = scrimParams.scrimColor;
        }
    }
    [self.view addSubview:backdrop];
    _backdropView = backdrop;

    // A system alert does not dismiss when you tap outside it; a sheet does.
    // Wiring the gesture up unconditionally and deciding in the handler keeps
    // the two styles sharing one build path.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(lmn_backdropTapped:)];
    [backdrop addGestureRecognizer:tap];

    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = UIColor.clearColor;
    panel.accessibilityViewIsModal = YES;
    [self.view addSubview:panel];
    _panelView = panel;

    LMNGlassParams *params =
        [LMNGlass currentForTraits:self.traitCollection];
    // 方案2 (1.1.10), carried over to the replacement: the card is drawn with
    // refraction zeroed, so its outer edge is the one thin rim rather than a
    // 9pt halo -- the same weight as the capsule border, which is what the
    // user asked for in 1.1.10. The panel gets a PRIVATE COPY: `params` keeps
    // the live refraction for everything else, so zeroing here cannot leak
    // into the capsule geometry or the text fields further down.
    //
    // This was missing in 1.1.13 -- the replacement handed the panel the live
    // params and so drew the halo the in-place path had deliberately removed,
    // which is why a replaced alert's card edge did not match its buttons.
    LMNGlassParams *panelParams = [params copyParams];
    panelParams.refractionWidth = 0.0;
    LMNGlassPanelView *glass =
        [[LMNGlassPanelView alloc] initWithFrame:panel.bounds
                                          params:panelParams];
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth
                             | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:glass];
    _glassView = glass;

    // 1.2.34: THE CONTENT SCROLLS, BECAUSE A LIST OF OPTIONS HAS NO LAST ROW.
    //
    // Everything below used to be pinned to the card on all four edges, and the
    // card's height is capped by the safe area. Pin a stack that needs more
    // height than the cap to the card's top AND bottom and the graph has no
    // solution: the
    // stack is forced to the card's height while each capsule insists on its
    // own, so Auto Layout breaks the capsule heights and the rows overlap. That
    // is the deformed list, and it cannot scroll because there is no scroller.
    //
    // So one is put in, and the card is sized by the content rather than by the
    // stack's edges: a low-priority height equality makes the card hug its
    // content while the content fits, and the required safe-area inequalities in
    // -lmn_activatePanelConstraints: win once it does not -- which is the point
    // at which the equality gives way and the content scrolls inside a card of
    // screen height. A short alert lays out exactly as it did; a long one is a
    // list instead of a pile.
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    // The card is already placed against the safe area, so the scroller must not
    // inset its content again for it.
    scroll.contentInsetAdjustmentBehavior =
        UIScrollViewContentInsetAdjustmentNever;
    [panel addSubview:scroll];
    _contentScrollView = scroll;

    // 1.2.35: the card is a squircle whose corner radius (defaults to 35pt,
    // user-tunable via 圆角) is larger than the 20pt content inset, so when a
    // long list is scrolled to its last row that row's square capsule corners
    // land inside the card's corner-exclusion zone and poke past the rounded
    // silhouette -- the "最下边一个按钮出边框" regression from 1.2.34. The
    // panel and glass view do not clip to the squircle; only the scroll clips,
    // and it clips rectilinearly. Clipping the scroll to the card's own radius
    // makes every corner of the content conform to the card, which is what
    // keeps the last button inside the frame at any scroll offset.
    scroll.layer.cornerRadius = params.cornerRadius;
    if (@available(iOS 13.0, *)) {
        scroll.layer.cornerCurve = kCACornerCurveContinuous;
    }
    // 1.2.45: only the TOP corners are the card's any more. The action row owns
    // the card's bottom edge now, so the scroller's two bottom corners are
    // interior edges -- rounding them would slice the content against a
    // boundary the user cannot see, on every alert, to keep a silhouette the
    // scroller no longer touches.
    scroll.layer.maskedCorners =
        kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    scroll.clipsToBounds = YES;
    LMNModernProbe(@"lumen 1.2.35 scroll clips to card radius");

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = LMNModernStackSpacing;
    stack.layoutMarginsRelativeArrangement = YES;
    // 1.2.45: top / left / right only. The bottom padding moved to the action
    // row below the scroller (see below), which is where the gap between the
    // last line of the body and the first capsule has to be measured from once
    // the two are separate views -- keeping it here as well would double it.
    stack.layoutMargins =
        UIEdgeInsetsMake(LMNModernContentMargin, LMNModernContentMargin,
                         0.0, LMNModernContentMargin);
    [scroll addSubview:stack];
    _contentStack = stack;

    // 1.2.46: THE ACTION AREA SCROLLS TOO.
    //
    // 1.2.45 put the capsules on the card's bottom edge as a fixed-height row,
    // so a long BODY kept its buttons on screen (the AppFix fix). But a SHEET
    // with many buttons -- a model picker with a dozen-plus rows -- now
    // overflowed the opposite way: the row is pinned to the bottom and cannot
    // grow past the safe area, so Auto Layout breaks the capsule heights and
    // the rows overlap, and there was no scroller to fall back on (the
    // "按钮过多的时候滑不动" report, an action sheet with ~15 model buttons).
    // The native sheet scrolls its action list, so Lumen's must too.
    //
    // So the action row becomes its own scroll view, mirroring the body
    // scroller exactly: the capsules still live in a stack of their own
    // (_actionStack, off the body scroller, so 1.2.45 holds), but that stack
    // now sits inside _actionScrollView, pinned to its content layout guide, and
    // the scroll view carries a low-priority height-hug of its own. A short
    // list hugs its content; a long one scrolls inside the same safe-area-capped
    // card. The body scroller and the action scroller now share the cap the way
    // two independent scroll areas do: each hugs when it fits, each scrolls
    // when it does not, and neither can push the other off the card.
    UIScrollView *actionScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    actionScroll.translatesAutoresizingMaskIntoConstraints = NO;
    actionScroll.showsVerticalScrollIndicator = YES;
    // The card is already placed against the safe area, so the scroller must
    // not inset its content again for it.
    actionScroll.contentInsetAdjustmentBehavior =
        UIScrollViewContentInsetAdjustmentNever;
    actionScroll.layer.cornerRadius = params.cornerRadius;
    if (@available(iOS 13.0, *)) {
        actionScroll.layer.cornerCurve = kCACornerCurveContinuous;
    }
    // 1.2.46: only the BOTTOM corners are the card's any more. The body
    // scroller owns the top edge (see above); this one owns the bottom, so its
    // two top corners are interior edges and must not be rounded -- rounding
    // them would slice the capsules against a boundary the user cannot see.
    actionScroll.layer.maskedCorners =
        kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    actionScroll.clipsToBounds = YES;
    [panel addSubview:actionScroll];
    _actionScrollView = actionScroll;

    UIStackView *actions = [[UIStackView alloc] initWithFrame:CGRectZero];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    actions.axis = UILayoutConstraintAxisVertical;
    actions.alignment = UIStackViewAlignmentFill;
    actions.spacing = LMNModernStackSpacing;
    actions.layoutMarginsRelativeArrangement = YES;
    // The top margin is exactly the spacing the content stack used to put
    // between its last row and the first capsule, so a short alert lays out as
    // it always did. The other three are the card's own content inset.
    actions.layoutMargins =
        UIEdgeInsetsMake(LMNModernStackSpacing, LMNModernContentMargin,
                         LMNModernContentMargin, LMNModernContentMargin);
    [actionScroll addSubview:actions];
    _actionStack = actions;
    // Build marker: proves in a shipped dylib that the action area is its own
    // scroll view, without anyone having to read a log.
    LMNModernProbe(@"lumen 1.2.46 action area scrolls independently");

    [NSLayoutConstraint activateConstraints:@[
        // The body scroller: three edges on the card, and its bottom on the
        // action scroll's TOP rather than on the card. That one edge is what
        // makes the body scroller, and never the capsules, the view that gives
        // way when the safe area caps the card -- 1.2.45's fix, preserved.
        [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:actionScroll.topAnchor],

        // The action scroll: the card's own width, and the card's bottom edge.
        // Its HEIGHT is not named here on purpose -- it is whatever the capsules
        // need, capped by its own low-priority hug below, so this view neither
        // squeezes the capsules nor stretches past the safe area.
        [actionScroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [actionScroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [actionScroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],

        // The body stack lives inside the body scroller's content guide.
        [stack.leadingAnchor
            constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor
            constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor
            constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor
            constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        // One axis only: the content is exactly as wide as the card.
        [stack.widthAnchor
            constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        // The action stack lives inside the action scroll's content guide, the
        // same way the body stack does -- so it scrolls when it overflows.
        [actions.leadingAnchor
            constraintEqualToAnchor:actionScroll.contentLayoutGuide.leadingAnchor],
        [actions.trailingAnchor
            constraintEqualToAnchor:actionScroll.contentLayoutGuide.trailingAnchor],
        [actions.topAnchor
            constraintEqualToAnchor:actionScroll.contentLayoutGuide.topAnchor],
        [actions.bottomAnchor
            constraintEqualToAnchor:actionScroll.contentLayoutGuide.bottomAnchor],
        // One axis only: the action list is exactly as wide as the card.
        [actions.widthAnchor
            constraintEqualToAnchor:actionScroll.frameLayoutGuide.widthAnchor],
    ]];

    // The body hug. Low priority on purpose: it is what keeps a short alert the
    // size of its content, and it is the constraint that gives way -- never one
    // of the required safe-area ones -- when the body is taller than the screen.
    NSLayoutConstraint *contentHeight =
        [scroll.heightAnchor constraintEqualToAnchor:stack.heightAnchor];
    contentHeight.priority = UILayoutPriorityDefaultLow;
    contentHeight.active = YES;

    // The action hug. Same idea, mirrored: a short action list hugs its
    // content, and the low-priority equality gives way to the required
    // safe-area cap so a long list scrolls instead of overlapping.
    NSLayoutConstraint *actionHeight =
        [actionScroll.heightAnchor constraintEqualToAnchor:actions.heightAnchor];
    actionHeight.priority = UILayoutPriorityDefaultLow;
    actionHeight.active = YES;

    [self lmn_activatePanelConstraints];
    [self lmn_buildContent];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(lmn_keyboardWillChange:)
               name:UIKeyboardWillChangeFrameNotification
             object:nil];
}

- (void)lmn_activatePanelConstraints {
    UIView *panel = _panelView;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    if ([self lmn_isSheet]) {
        _panelBottomConstraint =
            [panel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                               constant:-LMNModernSheetInset];
        [NSLayoutConstraint activateConstraints:@[
            [panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                                constant:LMNModernSheetInset],
            [panel.trailingAnchor
                constraintEqualToAnchor:self.view.trailingAnchor
                               constant:-LMNModernSheetInset],
            _panelBottomConstraint,
            [panel.topAnchor
                constraintGreaterThanOrEqualToAnchor:safe.topAnchor
                                            constant:LMNModernContentMargin],
        ]];
        return;
    }

    _panelCenterYConstraint =
        [panel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        _panelCenterYConstraint,
        [panel.widthAnchor constraintEqualToConstant:LMNModernPanelWidth],
        // The fixed width is UIKit's own, but a hand-edited device or a
        // Split View width must still not push the card off screen, so the
        // inequalities bound it rather than the constant alone.
        [panel.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor
                                        constant:LMNModernOuterInset],
        [panel.trailingAnchor
            constraintLessThanOrEqualToAnchor:self.view.trailingAnchor
                                     constant:-LMNModernOuterInset],
        [panel.topAnchor
            constraintGreaterThanOrEqualToAnchor:safe.topAnchor
                                        constant:LMNModernContentMargin],
        [panel.bottomAnchor
            constraintLessThanOrEqualToAnchor:safe.bottomAnchor
                                     constant:-LMNModernContentMargin],
    ]];
}

#pragma mark - Content

- (void)lmn_buildContent {
    UIAlertController *alert = self.sourceAlert;
    // 1.2.36: 标题/正文覆盖色（缺键=nil=沿用系统可读墨色）。
    LMNGlassParams *textParams = [LMNGlass currentForTraits:self.traitCollection];

    // 1.2.40: prefer the private attributed forms when present. A host that
    // leaves the public title/message empty and puts everything in
    // attributedTitle / attributedMessage (TrollStore's install confirmation)
    // otherwise renders as a blank card. Reading the rich pair here is what
    // makes the WHOLE alert ours: the card, the icon, the coloured sections and
    // the buttons are all drawn by this class instead of being split between a
    // native card and our capsules.
    NSAttributedString *richTitle = LMNAlertAttributedString(alert, @"attributedTitle");
    NSAttributedString *richMessage = LMNAlertAttributedString(alert, @"attributedMessage");

    if (richTitle.length > 0 || alert.title.length > 0) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        if (richTitle.length > 0) {
            label.attributedText = richTitle;
        } else {
            label.text = alert.title;
            label.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
            label.textColor = textParams.titleTextColor ?: [UIColor labelColor];
        }
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [_contentStack addArrangedSubview:label];
    }

    if (richMessage.length > 0 || alert.message.length > 0) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        if (richMessage.length > 0) {
            label.attributedText = richMessage;
            // The rich body is a multi-section report, not a one-line subtitle:
            // left-aligned reads the way the host laid it out. (An absent
            // paragraph style lets the label's own alignment apply.)
            label.textAlignment = NSTextAlignmentLeft;
        } else {
            label.text = alert.message;
            label.font = [UIFont systemFontOfSize:13.0];
            label.textColor = textParams.messageTextColor ?: [UIColor secondaryLabelColor];
            label.textAlignment = NSTextAlignmentCenter;
        }
        label.numberOfLines = 0;
        [_contentStack addArrangedSubview:label];
    }

    [self lmn_addTextFields];
    [self lmn_addActions];
}

/// New fields rather than the source alert's own, and copied back on dismiss.
///
/// Moving the real `UITextField`s out of the alert's view hierarchy would
/// reparent views UIKit still believes it owns, and its state for them (first
/// responder bookkeeping, the keyboard observer, the layout pass that positions
/// them) is not something this class can safely take over. So the fields are
/// mirrors, and `lmn_copyTextFieldsBack` makes the host's
/// `alert.textFields[i].text` read what the user typed.
- (void)lmn_addTextFields {
    LMNGlassParams *params =
        [LMNGlass currentForTraits:self.traitCollection];
    BOOL dark = [self lmn_isDark];

    // 1.2.38: index the loop. The mirror has to know which source field it
    // stands in for, so the editingChanged handler can write back to the right
    // one and re-fire the host's own input signal. (See lmn_mirrorFieldChanged:.)
    NSArray<UITextField *> *sources = self.sourceAlert.textFields;
    for (NSUInteger idx = 0; idx < sources.count; idx++) {
        UITextField *source = sources[idx];
        UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
        field.placeholder = source.placeholder;
        field.text = source.text;
        field.keyboardType = source.keyboardType;
        field.returnKeyType = source.returnKeyType;
        field.secureTextEntry = source.isSecureTextEntry;
        field.autocorrectionType = source.autocorrectionType;
        field.autocapitalizationType = source.autocapitalizationType;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.borderStyle = UITextBorderStyleNone;
        field.font = [UIFont systemFontOfSize:15.0];
        field.textColor = [UIColor labelColor];

        field.backgroundColor =
            dark ? [UIColor colorWithWhite:1.0
                                     alpha:MAX(0.06, params.fieldFillAlpha)]
                 : [UIColor colorWithWhite:0.0
                                     alpha:MAX(0.05, params.fieldFillAlpha)];
        field.layer.cornerRadius = params.fieldCornerRadius;
        field.layer.cornerCurve = kCACornerCurveContinuous;
        field.layer.borderWidth = params.fieldBorderWidth;
        field.layer.borderColor =
            (dark ? [UIColor colorWithWhite:1.0 alpha:0.22]
                  : [UIColor colorWithWhite:0.0 alpha:0.14]).CGColor;
        field.layer.masksToBounds = YES;

        UIView *padding =
            [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 12.0, 10.0)];
        field.leftView = padding;
        field.leftViewMode = UITextFieldViewModeAlways;

        [NSLayoutConstraint activateConstraints:@[
            [field.heightAnchor
                constraintEqualToConstant:LMNModernFieldHeight],
        ]];

        // 1.2.38: tag the mirror with its source index so the editingChanged
        // handler can find the matching real field, and forward every keystroke
        // to it. The host (e.g. GitHub's 2FA "批准" button) gates an action's
        // enabled state on the REAL field's editingChanged -- a mirror that
        // never signals it leaves that action disabled forever, no matter what
        // the user types. Forwarding replicates the native signal precisely.
        field.tag = (NSInteger)idx;
        [field addTarget:self
                  action:@selector(lmn_mirrorFieldChanged:)
        forControlEvents:UIControlEventEditingChanged];

        [_contentStack addArrangedSubview:field];
        [_replacementTextFields addObject:field];
    }
    // Build marker: proves the text-field edit forwarding was compiled in.
    LMNModernProbe(@"lumen 1.2.46 text field edit forwarding armed");
}

- (void)lmn_addActions {
    NSArray<UIAlertAction *> *actions = self.sourceAlert.actions;
    if (actions.count == 0) {
        // 1.2.45: the row is a sibling of the scroller now, and an empty stack
        // still reserves its own layout margins. Zero them so an alert with no
        // actions does not carry a phantom strip of padding under its body.
        _actionStack.layoutMargins = UIEdgeInsetsZero;
        return;
    }

    LMNGlassParams *params =
        [LMNGlass currentForTraits:self.traitCollection];
    LMNGlassTheme theme = params.theme;

    // Two actions go side by side, which is UIKit's own rule for an alert with
    // a pair of buttons. A sheet always stacks, because its rows are wide and
    // full-width and that is what the style looks like.
    BOOL sideBySide = (actions.count == 2
                       && self.sourceAlert.textFields.count == 0
                       && ![self lmn_isSheet]);

    // 1.2.45: into `_actionStack`, not `_contentStack`. That is the whole fix:
    // a capsule added to the scroller's stack belongs to the scrolling content
    // and can be pushed off the card, while one in the action row cannot.
    if (sideBySide) {
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentFill;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = LMNModernButtonSpacing;
        for (NSUInteger index = 0; index < actions.count; index++) {
            [row addArrangedSubview:[self lmn_buttonForAction:actions[index]
                                                        index:index
                                                        theme:theme
                                                       params:params]];
        }
        [_actionStack addArrangedSubview:row];
        return;
    }

    for (NSUInteger index = 0; index < actions.count; index++) {
        [_actionStack
            addArrangedSubview:[self lmn_buttonForAction:actions[index]
                                                   index:index
                                                   theme:theme
                                                  params:params]];
    }
}

- (UIButton *)lmn_buttonForAction:(UIAlertAction *)action
                            index:(NSUInteger)index
                            theme:(LMNGlassTheme)theme
                           params:(LMNGlassParams *)params {
    // Tagged with the index rather than holding the action: the action array
    // belongs to the source alert and stays the single source of truth, so the
    // tap handler re-reads it instead of trusting a captured pointer.
    UIButton *button =
        [LMNGlassPanelView pillButtonWithTitle:action.title
                                          role:[self lmn_roleForAction:action]
                                         theme:theme
                                        params:params];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = (NSInteger)index;
    button.enabled = action.isEnabled;
    // The capsule is a stadium, so the corner is half the height -- the
    // renderer sets the material and the border, not the silhouette.
    button.layer.cornerRadius = params.buttonHeight * 0.5;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [NSLayoutConstraint activateConstraints:@[
        [button.heightAnchor constraintEqualToConstant:params.buttonHeight],
    ]];
    [button addTarget:self
                  action:@selector(lmn_actionTapped:)
        forControlEvents:UIControlEventTouchUpInside];

    [_actionButtons addObject:button];
    return button;
}

#pragma mark - Entrance and exit

/// 1.1.14: the entrance, and why it lives here rather than in
/// `-viewDidAppear:`.
///
/// Presenting with UIModalTransitionStyleCrossDissolve runs a system
/// transition that fades the whole view in over ~0.35s. The entrance used to
/// be started in `-viewDidAppear:`, which UIKit calls AFTER that transition has
/// finished -- so the card was drawn at full opacity for the entire fade, then
/// was snapped to alpha 0 and scale 0.92 the moment the transition ended, then
/// sprang back. Visible as the card appearing, blinking out, and appearing
/// again: the "闪一下" this version removes.
///
/// Setting the start state in `-viewWillAppear:` puts it in place BEFORE the
/// transition begins, so the card's own fade-and-scale runs alongside the
/// system fade instead of after it. One entrance, no reset frame.
///
/// The layout pass is forced first. LMNGlassPanelView draws its material in
/// `-layoutSubviews` and returns early on an empty bounds, so without it the
/// first frame can be a card with no glass in it at all -- a second, quieter
/// flicker on the same frames.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_didAnimateIn) {
        return;
    }
    _didAnimateIn = YES;

    // 1.2.2: resolve the theme now instead of trusting what -viewDidLoad
    // left behind. -viewDidLoad runs before the view is in a window, so its
    // trait collection is still the default and 自动 would have resolved to
    // 明昼 in a dark room. Here the traits are real -- and the card is still
    // at alpha 0, because the entrance is armed a few lines below, so the
    // correction happens before anything is on screen. That is the same
    // reason the entrance itself lives in this method rather than in
    // -viewDidAppear:.
    [self lmn_applyResolvedTheme];

    // 1.2.38: re-sync button enabled states from the host's actions on arrival.
    // The host may have enabled/disabled actions between creation and
    // presentation; the snapshot taken in lmn_buttonForAction: would otherwise
    // be stale the moment the card appears.
    [self lmn_syncActionEnabledStates];

    [self.view layoutIfNeeded];

    // 1.2.32: THE SHADE FADES IN TOO, AND IT HAS TO DO IT ITSELF.
    //
    // The card has had an entrance since 1.1.14; the full-screen shade never
    // did. It sat at alpha 1 from the instant the window appeared, so the whole
    // screen went dark in one frame -- which is what a flash is, and it is the
    // report this version answers.
    //
    // The host's transition cannot cover for it. Since 1.2.22 the replacement
    // lives in a window of its own, and the host's CrossDissolve fades the
    // host's presentation rather than our window. Nothing fades our window but
    // us, in either branch below.
    _backdropView.alpha = 0.0;
    // Build marker: compiles into __cstring, so a shipped dylib can be proved
    // to carry the shade's entrance without anyone reading a log.
    LMNModernProbe(@"lumen 1.2.46 shade entrance armed");

    UIView *panel = _panelView;
    // A host that presents with animated:NO gets no system transition, so an
    // entrance would be a card that fades in on its own after everything else
    // has already settled -- which reads as a lag, not as an entrance.
    //
    // The card is left instant here, as it was. The shade is not: an instant
    // full-screen darkening is the one part of the arrival that reads as a
    // defect by itself, so it runs a short fade even when nothing else moves.
    if (!animated) {
        panel.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            _backdropView.alpha = 1.0;
        }
                         completion:nil];
        return;
    }

    // 1.2.3: the entrance is now a CHOICE of three styles, read from the
    // preference. The start state is still armed here (alpha 0 / a transform)
    // so it is in place before the system CrossDissolve -- the same invariant
    // rule 11o enforces. The choice only changes the start transform and the
    // spring; the end state is always identity at alpha 1.
    NSInteger entrance = [LMNGlass currentForTraits:self.traitCollection].entrance;
    CGFloat duration = 0.28;
    CGFloat damping = 0.86;
    CGFloat velocity = 0.30;
    panel.alpha = 0.0;
    switch (entrance) {
        case 1: // 上浮 float-up: rises from 24pt below
            panel.transform = CGAffineTransformMakeTranslation(0.0, 24.0);
            duration = 0.34;
            damping = 0.80;
            velocity = 0.6;
            break;
        case 2: // 淡入 fade-in: no movement, pure alpha
            panel.transform = CGAffineTransformIdentity;
            duration = 0.30;
            damping = 1.0;
            velocity = 0.0;
            break;
        default: // 0 聚焦弹入 focus pop-in: scales up from 0.92
            panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
            break;
    }
    [UIView animateWithDuration:duration
                          delay:0.0
         usingSpringWithDamping:damping
          initialSpringVelocity:velocity
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        panel.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
        // 1.2.32: the shade arrives with the card, over the same spring, which
        // is how a native alert and its dimming view arrive together.
        _backdropView.alpha = 1.0;
    }
                     completion:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // One path for both callers, so the panel and the capsules cannot end up
    // on different palettes -- which is what two paths produced the first time
    // the theme was split.
    [self lmn_applyResolvedTheme];
}

/// Re-resolve the theme and repaint everything that depends on it.
///
/// Called from -viewWillAppear: (where the trait collection first means
/// something) and from -traitCollectionDidChange: (where it can change while
/// the alert is up). One path for both, because two paths is how the panel
/// and the buttons end up on different palettes.
- (void)lmn_applyResolvedTheme {
    LMNGlassParams *params =
        [LMNGlass currentForTraits:self.traitCollection];

    // The panel gets its own copy with the refraction zeroed -- 方案2
    // (1.1.10), carried over to the replacement in 1.1.14. Built here the
    // same way -viewDidLoad builds it: three lines, and the two sites have
    // to agree on the zeroing or a replaced card's edge stops matching its
    // capsule border.
    LMNGlassParams *panelParams = [params copyParams];
    panelParams.refractionWidth = 0.0;
    [_glassView applyParams:panelParams];

    // The scrim is per theme: 影院暗色 is "拥有更深背景", and that lives in
    // the backdrop as much as in the card.
    _backdropView.backgroundColor =
        [[UIColor blackColor] colorWithAlphaComponent:
            LMNModernBackdropAlphaForTheme(params.theme)];
    // 1.2.36: 背景遮罩覆盖色。
    if (params.scrimColor != nil) {
        _backdropView.backgroundColor = params.scrimColor;
    }

    BOOL dark = [LMNGlass isDarkTheme:params.theme];

    // 1.2.29: the card is a surface of its own, and a dark card wants the dark
    // appearance for everything UIKit draws on it.
    //
    // The labels built in -lmn_buildContent are coloured with `labelColor` and
    // `secondaryLabelColor`. Both are DYNAMIC, and they resolve against the
    // trait collection they are drawn in -- which is this window's. The window
    // inherits the host application's, and the host is LIGHT: the system is not
    // in dark mode and the app does not force it. The picker's 自动 is the
    // control that says to follow the system, and following the system is what
    // chose the dark palette, so the card went dark while its text stayed the
    // colour a light card would want. The title survived on weight; the 13pt
    // message under it did not survive at all.
    //
    // Overriding it on the window fixes the labels, the text fields, their
    // placeholders and the keyboard in one place, rather than pinning a literal
    // at each of them. It cannot feed back into the theme resolution:
    // `resolvedTheme` asks `UIScreen.main` FIRST and only falls back to these
    // traits when the screen has not been told either, so the palette stays the
    // system's answer.
    if (_hostWindow != nil) {
        _hostWindow.overrideUserInterfaceStyle =
            dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    }

    for (UITextField *field in _replacementTextFields) {
        field.backgroundColor =
            dark ? [UIColor colorWithWhite:1.0
                                     alpha:MAX(0.06, params.fieldFillAlpha)]
                 : [UIColor colorWithWhite:0.0
                                     alpha:MAX(0.05, params.fieldFillAlpha)];
        field.layer.borderColor =
            (dark ? [UIColor colorWithWhite:1.0 alpha:0.22]
                  : [UIColor colorWithWhite:0.0 alpha:0.14]).CGColor;
    }

    [self lmn_recolorButtons];
    // Under UIModalPresentationOverFullScreen this controller owns the
    // status bar, and its style follows lmn_isDark.
    [self setNeedsStatusBarAppearanceUpdate];

    // 1.2.25: say so when the store could not be read. The card above is
    // already the right one either way now that an unusable choice resolves to
    // 自动 -- but a palette nobody chose is worth one line on screen, once,
    // because this is the only feedback channel this device has.
    if ([LMNGlass themeWasUnreadable]) {
        NSString *themeName = [LMNGlass isDarkTheme:params.theme] ? @"曜石玻璃"
                                                                : @"明昼";
        [LMNModernAlertController
            lmn_reportThemeFallback:[NSString stringWithFormat:
                                      @"store=unusable rendered=%@ system=%@",
                                      themeName,
                                      UIScreen.mainScreen.traitCollection
                                          .userInterfaceStyle == UIUserInterfaceStyleDark
                                          ? @"dark" : @"light"]
                          inWindow:self.view.window ?: _previousKeyWindow];
    }
}

- (void)lmn_recolorButtons {
    NSArray<UIAlertAction *> *actions = self.sourceAlert.actions;
    if (actions.count == 0) {
        return;
    }
    LMNGlassParams *params =
        [LMNGlass currentForTraits:self.traitCollection];
    NSUInteger count = MIN(_actionButtons.count, actions.count);
    for (NSUInteger index = 0; index < count; index++) {
        UIButton *button = _actionButtons[index];
        [LMNGlassPanelView styleButton:button
                                  role:[self lmn_roleForAction:actions[index]]
                                 theme:params.theme
                                params:params];
        button.layer.cornerRadius = params.buttonHeight * 0.5;
    }
}

#pragma mark - Interaction

- (void)lmn_backdropTapped:(UIGestureRecognizer *)recognizer {
    (void)recognizer;
    if (![self lmn_isSheet]) {
        return;
    }
    [self lmn_dismissPanelWithCompletion:nil];
}

- (void)lmn_actionTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    NSArray<UIAlertAction *> *actions = self.sourceAlert.actions;
    if (index < 0 || (NSUInteger)index >= actions.count) {
        return;
    }
    UIAlertAction *action = actions[(NSUInteger)index];
    if (!action.isEnabled) {
        return;
    }

    // Values first: the host's block reads `alert.textFields[i].text`, so the
    // mirror has to have landed before it runs or every handler sees an empty
    // field.
    [self lmn_copyTextFieldsBack];

    // 1.2.17: DISMISS BEFORE FIRING, or the host cannot present anything.
    //
    // This is what made "拍照 / 选择照片和视频 / 添加文件" do nothing. All three
    // handlers present a picker, and UIKit refuses a presentation from a
    // controller that is already presenting -- so the handler DID run, its
    // `presentViewController:` was dropped with a console warning, and all the
    // user saw was the alert close over an empty result. 取消 has nothing to
    // present, which is exactly why it was the only one that appeared to work
    // and why the failure looked like "the buttons aren't wired to anything".
    //
    // UIKit's own order is the same one: the alert is dismissed, and only then
    // does the handler run. But "then" has to mean a turn LATER, not the same
    // turn -- see below.
    //
    // 1.2.17 fired the handler directly in the dismissal completion and that
    // did fix the refused presentation -- but it introduced a worse failure: the
    // FIRST action worked, and after it the app could not present anything again
    // in that process until it was restarted. An `animated:NO` dismissal runs
    // its completion as soon as UIKit has been told to tear the presentation
    // down, which is not the same as the presenter having been released: our
    // replacement can still be its `presentedViewController` at that instant. A
    // host that presents from there is refused, and that refusal is what wedges
    // the presenter for good. It is invisible, too, because the dismissal above
    // has already taken this view's alpha to 0 -- the stale panel sits there
    // unseen, holding the presentation.
    //
    // 1.2.18 tried to buy the teardown that completion does not guarantee by
    // hopping one main-queue turn first. Reported as unchanged -- same symptom,
    // same one-action-per-process ceiling -- so the turn was not what was
    // missing. 1.2.19 stops timing it at all: see lmn_tearDownWithCompletion:
    // (the presenter is asked directly), lmn_assertRemovedAndRun: (the result is
    // checked a turn later and taken out by hand if it survived), and
    // lmn_sweepRetiredReplacements (the next presentation repairs whatever one
    // of those still missed). The extra hop stays because it costs nothing
    // against a 0.18s fade and keeps one more turn between the dismissal and
    // the host's block.
    [self lmn_dismissPanelWithCompletion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [LMNModernAlertController fireHandlerForAction:action];
        });
    }];

    // Build marker: compiles into __cstring so `verify-package.sh` can prove the
    // dismiss-before-fire ordering shipped, in both arch slices, without anyone
    // having to read a log. LMNModernProbe takes a single message (not variadic).
    LMNModernProbe(@"lumen 1.2.46 dismiss-before-fire");
}

- (void)lmn_copyTextFieldsBack {
    NSArray<UITextField *> *source = self.sourceAlert.textFields;
    NSUInteger count = MIN(source.count, _replacementTextFields.count);
    for (NSUInteger index = 0; index < count; index++) {
        source[index].text = _replacementTextFields[index].text;
    }
}

/// 1.2.38: a mirror field changed. Write the text into the source field the
/// host actually reads, then re-fire the host's own editingChanged signal on
/// that real field. Hosts that enable an action on input (GitHub's 2FA
/// "批准" button is the reported case) listen on the REAL field -- so the
/// mirror must drive it, or the gating logic never runs. Finally, re-sync
/// every button's enabled state from its action's live `isEnabled`, because
/// the host's handler has just (possibly) flipped one.
- (void)lmn_mirrorFieldChanged:(UITextField *)mirror {
    NSUInteger index = (NSUInteger)mirror.tag;
    NSArray<UITextField *> *source = self.sourceAlert.textFields;
    if (index < source.count) {
        source[index].text = mirror.text;
        [source[index] sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    [self lmn_syncActionEnabledStates];
}

/// 1.2.38: the buttons snapshot `action.isEnabled` once at creation
/// (lmn_buttonForAction:), but a host can flip an action's enabled state
/// later -- typically from the text-field signal this class now forwards.
/// Re-reading every action's live `isEnabled` and pushing it onto the
/// matching button keeps the replacement in lockstep with the host, so a
/// button that the host enabled becomes tappable here too.
- (void)lmn_syncActionEnabledStates {
    NSArray<UIAlertAction *> *actions = self.sourceAlert.actions;
    for (UIButton *button in _actionButtons) {
        NSInteger index = button.tag;
        if (index < 0 || (NSUInteger)index >= actions.count) {
            continue;
        }
        UIAlertAction *action = actions[(NSUInteger)index];
        button.enabled = action.isEnabled;
    }
}

- (void)lmn_dismissPanelWithCompletion:(void (^ _Nullable)(void))completion {
    UIView *root = self.view;

    // Marked BEFORE the fade rather than after it, so the sweep below can
    // recognise a replacement that began to go away even if it never finished
    // doing so.
    _teardownRequested = YES;

    // 1.2.31: AND ASK UIKIT TO CLOSE THE ALERT IN THE SAME TURN.
    //
    // The order used to be: fade for 0.25s, and only then dismiss. UIKit's own
    // shade belongs to the alert it is presenting, so it could not leave until
    // the dismissal was asked for -- which made the screen go dim, then ours
    // fade, then theirs fade, in sequence, for 0.5s against a native 0.25s. That
    // is the "takes twice as long", and it is also why lengthening the fade in
    // 1.2.29 made the exit feel worse rather than better.
    //
    // Asked for here, the two fade together: our scrim over 0.25s, theirs over
    // UIKit's own dismissal. One motion, and the motion is UIKit's.
    BOOL handedToDismissal = [self lmn_startDismissalWithCompletion:completion];

    // Whichever half owns the caller's block, exactly one of them ends up with
    // it. Passing it on twice is how an exit gets two endings, and the host
    // would then act on "the alert closed" twice.
    void (^owned)(void) = nil;
    if (!handedToDismissal) {
        owned = completion;
    }

    // 1.2.19: exactly one caller gets through, whichever arrives first -- the
    // fade's own completion, or the timed backstop below. Both predecessors hung
    // the entire teardown off the animation completion, which is the one thing
    // this sequence is least able to vouch for: if it never runs, nothing is
    // dismissed, nothing is logged, and the presentation stays up at alpha 0.
    __weak typeof(self) weakSelf = self;
    __block BOOL handedOff = NO;
    void (^proceed)(void) = ^{
        if (handedOff) {
            return;
        }
        handedOff = YES;
        LMNModernAlertController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf lmn_tearDownWithCompletion:owned];
        } else if (owned != nil) {
            owned();
        }
    };

    // 1.2.29: A CROSS-DISSOLVE, THE WAY UIKIT'S OWN ALERT GOES AWAY.
    //
    // The exit used to fade for 0.18s on an ease-IN curve while also scaling the
    // card to 0.94 (or sliding a sheet down 40pt). Ease-in accelerates into
    // an abrupt stop, and the scale is a gesture a native alert does not make: a
    // native alert and the shade behind it simply dissolve together, at the same
    // rate, in one motion.
    //
    // So the card no longer moves, the fade runs for 0.25s -- the duration
    // `UIModalTransitionStyleCrossDissolve` uses, and the one the entrance is
    // already measured against -- and it eases in and out rather than in.
    [UIView animateWithDuration:0.25
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        root.alpha = 0.0;
    }
                     completion:^(BOOL finished) {
        (void)finished;
        proceed();
    }];

    // The backstop. 0.40s is comfortably past the 0.18s fade, and if the fade's
    // completion has already run then `handedOff` makes this a no-op rather than
    // a second dismissal.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), proceed);
}

/// Ask UIKit to close the source alert -- now, with animation, and once.
///
/// The caller's block is handed to the DISMISSAL, because "the alert went away"
/// is what the host is waiting for and a dismissal's completion is the only
/// place that is true. Everything else the teardown does -- the window, the
/// reverse link, the view left in a window -- is local and can happen on the
/// fade's own schedule.
///
/// The 0.90s backstop is not decoration. 1.2.18 lost the host's block exactly
/// once by hanging it off a single completion, and "the alert closed" is the
/// only feedback either the host or the user ever gets.
- (BOOL)lmn_startDismissalWithCompletion:(void (^ _Nullable)(void))completion {
    if (_dismissalStarted) {
        return YES;
    }
    UIAlertController *alert = self.sourceAlert;
    if (alert == nil || alert.presentingViewController == nil) {
        return NO;
    }
    _dismissalStarted = YES;

    void (^completionCopy)(void) = [completion copy];
    __weak typeof(self) weakSelf = self;
    __block BOOL finished = NO;
    void (^finish)(void) = ^{
        if (finished) {
            return;
        }
        finished = YES;
        LMNModernAlertController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf lmn_restoreTakenScrims];
            [strongSelf lmn_unparkSourceAlert];
            [strongSelf lmn_assertRemovedAndRun:completionCopy];
        } else if (completionCopy != nil) {
            completionCopy();
        }
    };

    LMNModernProbe(@"lumen 1.2.46 dismissal started with the fade");
    [alert dismissViewControllerAnimated:YES completion:finish];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.90 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        finish();
    });
    return YES;
}

/// The teardown proper.
///
/// 1.2.19. Both earlier versions asked the PRESENTED controller to dismiss
/// itself and trusted UIKit to forward that to the presenter. Forwarding is not
/// observable from here -- it has no completion of its own, and by the time any
/// completion does run there is no public way to tell whether the presenter has
/// actually let go. Asking the presenter directly does: it is the object the
/// presentation belongs to, so this is the form of the request whose result can
/// be checked afterwards.
- (void)lmn_tearDownWithCompletion:(void (^ _Nullable)(void))completion {
    // The reverse link is dropped here as well as in the override below, because
    // the presenter dismisses without going through that override and a cycle
    // left standing leaks a controller plus its source alert per alert.
    [self lmn_detachFromSourceAlert];

    // Captured now, checked later, and not through `self`: by the time the
    // dismissal has been acknowledged this controller may already be gone, and a
    // view left behind by a controller that no longer exists is invisible to
    // every check that starts by asking the controller.
    [LMNModernAlertController lmn_ensureRootViewGone:self.view];

    // 1.2.31: when the dismissal was already asked for -- which is now the
    // normal case, at the moment the fade began -- this method has only the
    // local half left: the reverse link, done above, and the window. The
    // caller's block and the restore belong to that dismissal's own completion,
    // and running them here as well is how an exit gets two endings.
    if (_dismissalStarted) {
        if (_hostWindow != nil) {
            [self lmn_hideHostWindow];
        }
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^after)(void) = ^{
        LMNModernAlertController *strongSelf = weakSelf;
        // 1.2.28: put back whatever the scrim sweep took out. In the ordinary
        // case the view it removed belonged to the presentation and is already
        // deallocated, so this is a no-op over a weak table of dead entries. In
        // every other case it is the difference between one wrong guess and a
        // host view that stays hidden for the rest of the process' life.
        [strongSelf lmn_restoreTakenScrims];
        // Whatever happened, the source alert is no longer ours to style.
        [strongSelf lmn_unparkSourceAlert];
        if (strongSelf == nil) {
            if (completion != nil) {
                completion();
            }
            return;
        }
        [strongSelf lmn_assertRemovedAndRun:completion];
    };

    // 1.2.23: our window goes away first and immediately. Then the alert UIKit
    // is really presenting is dismissed THROUGH UIKit -- not around it -- because
    // that is the only route by which the host gets the dismissal it has been
    // waiting for since the first tap.
    BOOL hadWindow = (_hostWindow != nil);
    if (hadWindow) {
        [self lmn_hideHostWindow];
    }
    UIAlertController *alert = self.sourceAlert;
    if (alert != nil && alert.presentingViewController != nil) {
        [alert dismissViewControllerAnimated:NO completion:after];
        return;
    }
    if (hadWindow) {
        after();
        return;
    }

    UIViewController *presenter = self.presentingViewController;
    if (presenter != nil) {
        [presenter dismissViewControllerAnimated:NO completion:after];
        return;
    }
    [super dismissViewControllerAnimated:NO completion:after];
}

/// The self-check this version owes 1.2.18's report.
///
/// One turn after the dismissal has been acknowledged, look at what is actually
/// still there. A replacement that survived is invisible -- the fade has taken
/// its alpha to 0 already -- and it is why the host cannot present again: it is
/// still somebody's `presentedViewController`. Take it out by hand before the
/// host's block is allowed to run, because "the alert closed" is the only
/// feedback either the host or the user gets.
- (void)lmn_assertRemovedAndRun:(void (^ _Nullable)(void))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        LMNModernAlertController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            if (completion != nil) {
                completion();
            }
            return;
        }
        // `isBeingDismissed` is respected rather than fought: a teardown that is
        // genuinely still running gets to finish. Anything else still installed
        // after a full turn is stalled by definition, and taken out here.
        // `lmn_sweepRetiredReplacements` is the layer that catches whatever this
        // politeness leaves behind.
        if (![strongSelf lmn_isRemoved] && !strongSelf.isBeingDismissed) {
            LMNModernProbe(@"lumen 1.2.46 self-check took out a stale panel");
            [strongSelf lmn_forceRemove];
        }
        if (completion != nil) {
            completion();
        }
    });
}

/// Gone means gone: no presenter still holding it, and no view still in a window
/// that is actually showing. 1.2.22 -- a hidden window of our own is not a view
/// left behind; it is the normal resting state after a window-hosted alert goes
/// away, and `lmn_ensureRootViewGone:` detaches the view from it a turn later.
- (BOOL)lmn_isRemoved {
    if (self.presentingViewController != nil) {
        return NO;
    }
    if ([self isViewLoaded]) {
        UIWindow *window = self.view.window;
        if (window != nil && !window.isHidden) {
            return NO;
        }
    }
    return YES;
}

/// Take a surviving replacement out, using progressively less polite means.
///
/// The view is only pulled out of the tree after the presentation has been asked
/// twice and declined: that ordering keeps this from ever being the FIRST thing
/// that happens to an alert that is simply mid-dismissal.
- (void)lmn_forceRemove {
    UIViewController *presenter = self.presentingViewController;
    if (presenter != nil) {
        [presenter dismissViewControllerAnimated:NO completion:nil];
    } else {
        [super dismissViewControllerAnimated:NO completion:nil];
    }
    [self lmn_detachFromSourceAlert];
    if ([self isViewLoaded] && self.view.window != nil) {
        [self.view removeFromSuperview];
    }
}

#pragma mark - 1.2.41 lifecycle guard

/// Take every replacement down when the app leaves the foreground.
///
/// The replacement lives in a window of its own at UIWindowLevelAlert, sized to
/// the host window -- a full-screen layer that swallows every touch. Every
/// teardown path hides it (lmn_hideHostWindow), but a path that never RUNS leaves
/// it standing. The one that matters here: an app that is backgrounded or
/// interrupted while a replacement is on screen never delivers a dismissal, so
/// none of those paths is ever reached. What is left is the worst possible
/// failure -- an invisible (or stale) full-screen window eating every touch, so
/// the app looks dead and the only way out is to swipe up and start again.
///
/// The two nets already in place do not cover it: lmn_sweepRetiredReplacements
/// and lmn_clearLingeringRootViewsIn: both only run at the NEXT presentation, so
/// an app that is already wedged -- or that simply never presents again -- is
/// never repaired by either. This fires on the transition instead.
///
/// DidEnterBackground, deliberately, and not WillResignActive: resigning active
/// happens for transient interruptions (a banner, Control Center, a Face ID
/// prompt) where the alert is still legitimately the user's task and must stay.
/// Entering the background is unambiguous -- the user has gone, and nothing of
/// ours may be waiting when they come back.
+ (void)lmn_installLifecycleGuard {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(lmn_applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
        // Build marker: proves the guard is compiled in.
        LMNModernProbe(@"lumen 1.2.46 background guard installed");
    });
}

+ (void)lmn_applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    NSArray *known = LMNLiveReplacements().allObjects;
    if (known.count == 0) {
        return;
    }
    LMNModernProbe(@"lumen 1.2.46 background guard took down a replacement");
    for (LMNModernAlertController *controller in known) {
        [controller lmn_abandonForBackground];
    }
}

/// Everything a teardown would have done, done at once and without animation.
/// The user is no longer looking at this app, so there is nothing to animate and
/// nothing to wait for -- and the source alert is dismissed too, because a parked
/// alert still holding the host's `presentedViewController` is the other half of
/// the wedge (the host then cannot present anything ever again).
- (void)lmn_abandonForBackground {
    UIAlertController *alert = self.sourceAlert;
    [self lmn_detachFromSourceAlert];
    [self lmn_unparkSourceAlert];
    [self lmn_hideHostWindow];
    if ([self isViewLoaded] && self.view.window != nil) {
        [self.view removeFromSuperview];
    }
    if (alert != nil && alert.presentingViewController != nil) {
        [alert dismissViewControllerAnimated:NO completion:nil];
    }
    [LMNLiveReplacements() removeObject:self];
}

/// Drop the reverse link to the source alert. Idempotent: it is called from three
/// places, and none of them may assume the others have run.
- (void)lmn_detachFromSourceAlert {
    UIAlertController *alert = self.sourceAlert;
    if (alert == nil) {
        return;
    }
    objc_setAssociatedObject(alert, LMNReplacementKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Remove every replacement that should already be gone.
///
/// Called before a new alert is replaced. Only one is ever legitimately on
/// screen at a time and this runs before the new one exists, so anything found
/// here has outlived its cycle.
///
/// 1.2.20 widens what counts as evidence, because 1.2.19's single test could not
/// see the failure it shipped to fix. A replacement can outlive its cycle in two
/// shapes, and they leave different traces:
///
///   * it began to go away and never finished -- `_teardownRequested` is set, and
///     it is usually still somebody's `presentedViewController`, which is what
///     stops the host presenting anything again;
///   * UIKit has already let go of it -- `presentingViewController` is nil -- yet
///     its view is still installed in SOME hierarchy. That is an orphan, and it
///     is the shape that explains "the host page has to be popped and re-entered
///     before anything works again": a full-screen view at alpha 0 sitting in the
///     page's own tree, swallowing the touches that would have asked for the next
///     alert. No presentation is ever attempted, so no amount of care at the
///     presentation site can help; the view has to come out.
///
/// `isBeingPresented` is skipped: one on its way in is not a leftover, and the
/// entrance is exactly the window in which the second trace above is briefly and
/// legitimately true.
+ (void)lmn_sweepRetiredReplacements {
    NSArray *known = LMNLiveReplacements().allObjects;
    for (LMNModernAlertController *controller in known) {
        if (controller.isBeingPresented) {
            continue;
        }
        BOOL retired = controller->_teardownRequested;
        BOOL orphaned = (controller.presentingViewController == nil
                         && [controller isViewLoaded]
                         && controller.view.window != nil);
        if (!retired && !orphaned) {
            continue;
        }
        if ([controller lmn_isRemoved]) {
            continue;
        }
        LMNModernProbe(@"lumen 1.2.46 sweep removed a stalled replacement");
        [controller lmn_forceRemove];
    }
}

/// Whether `view` is one of our replacement root views.
///
/// Deliberately not an `isKindOfClass:` test on the controller: this has to give
/// the right answer after that controller has been deallocated.
+ (BOOL)lmn_isReplacementRoot:(UIView *)view {
    return [view.accessibilityIdentifier isEqualToString:LMNReplacementRootIdentifier];
}

/// Make sure `rootView` is not still installed in something.
///
/// 1.2.21. The view is captured BEFORE the dismissal is requested, so this runs
/// whether or not the controller that made it is still alive. 1.2.19's self-check
/// began with `weakSelf` and returned early when it came back nil -- which is
/// exactly the case it needed to handle, because a view is held by its superview
/// and therefore CAN outlive its controller.
///
/// Checked twice. One check is a bet on timing, and this version is done betting
/// on timing.
+ (void)lmn_ensureRootViewGone:(UIView *)rootView {
    if (rootView == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [LMNModernAlertController lmn_detachRootView:rootView];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [LMNModernAlertController lmn_detachRootView:rootView];
    });
}

+ (void)lmn_detachRootView:(UIView *)rootView {
    if (rootView.superview == nil) {
        return;
    }
    LMNModernProbe(@"lumen 1.2.46 removed a lingering root view");
    [rootView removeFromSuperview];
}

/// Remove every stamped view still installed in `window`, whatever made it.
///
/// Called at presentation time, when no replacement of ours is legitimately on
/// screen, so anything found is a leftover -- including one whose controller has
/// already gone and which no controller-side check can see any more.
+ (void)lmn_clearLingeringRootViewsIn:(UIWindow *)window {
    if (window == nil) {
        return;
    }
    NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (stack.count > 0 && visited < 5000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visited += 1;
        if ([LMNModernAlertController lmn_isReplacementRoot:view]) {
            LMNModernProbe(@"lumen 1.2.46 removed a lingering root view");
            [view removeFromSuperview];
            continue;
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

/// 1.2.21: the only channel that exists.
///
/// There is no log to read on the device, so when a presentation of ours does not
/// land, say so on screen and say what was in the way. This costs nothing in the
/// healthy case: it is called only after the replacement has had a turn to appear
/// and has not.
+ (void)lmn_reportPresentationLost:(NSString *)detail
                          inWindow:(UIWindow *)hostWindow {
    LMNModernProbe([@"lumen 1.2.46 presentation lost "
                    stringByAppendingString:detail]);
    // 1.2.34: the log keeps the record, the banner is opt-in. See
    // LMNOnScreenDiagnosticsEnabled for why the bar was taken off the screen.
    if (!LMNOnScreenDiagnosticsEnabled()) {
        return;
    }
    [self lmn_presentDiagnostic:
        [@"LUMEN: alert presentation lost\n"
            stringByAppendingString:detail]
                       inWindow:hostWindow];
}

/// The one diagnostic window, shared by every reporter.
///
/// Kept in a single place so that "is this drawn at all?" is answered once, by
/// its callers, instead of being re-decided inside each banner's own copy of
/// this code -- which is how the scrim sweep came to borrow the theme reporter's
/// headline and announce a normal outcome as a fault.
+ (void)lmn_presentDiagnostic:(NSString *)text
                     inWindow:(UIWindow *)hostWindow {
    UIWindowScene *scene = hostWindow.windowScene;
    UIWindow *report = (scene != nil)
        ? [[UIWindow alloc] initWithWindowScene:scene]
        : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    report.frame = UIScreen.mainScreen.bounds;
    report.windowLevel = UIWindowLevelAlert + 1.0;
    report.backgroundColor = UIColor.clearColor;
    // A diagnostic must never become part of the failure it is reporting.
    report.userInteractionEnabled = NO;

    UILabel *label = [[UILabel alloc]
        initWithFrame:CGRectMake(8.0, 64.0,
                                 CGRectGetWidth(report.bounds) - 16.0, 140.0)];
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor =
        [[UIColor blackColor] colorWithAlphaComponent:0.85];
    label.font = [UIFont monospacedSystemFontOfSize:11.0
                                             weight:UIFontWeightRegular];
    label.numberOfLines = 0;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [report addSubview:label];
    report.hidden = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        report.hidden = YES;
    });
}

/// 1.2.25: the same channel, for the other silent fallback.
///
/// The theme is resolved from a preferences store this process may not be able
/// to see at all -- the restyle runs inside sandboxed host applications. Until
/// now an unreadable store was indistinguishable from "you picked 曜石玻璃", so
/// a light app drew a dark card and nobody could tell why. The fallback itself
/// is fixed; this says it out loud, once, in the one place the user can see:
/// the screen.
///
/// Said only when it happened. A process that reads the store normally never
/// shows this, which is what makes it worth anything when it does appear.
+ (void)lmn_reportThemeFallback:(NSString *)detail
                       inWindow:(UIWindow *)hostWindow {
    static BOOL reported = NO;
    if (reported) {
        return;
    }
    reported = YES;

    LMNModernProbe([@"lumen 1.2.46 theme store unusable "
                    stringByAppendingString:detail]);
    // 1.2.34: opt-in, like the other two. The probe above is the record.
    if (!LMNOnScreenDiagnosticsEnabled()) {
        return;
    }
    [self lmn_presentDiagnostic:
        [@"LUMEN: 配色设置读不到，已按系统外观渲染\n"
            stringByAppendingString:detail]
                       inWindow:hostWindow];
}

/// 1.2.23: put the source alert out of sight, without taking its touches away
/// from anything.
///
/// The replacement has been faking the alert's entire lifecycle since 1.1.13:
/// the source alert was read from and never presented, so UIKit ran none of the
/// lifecycle it normally runs. Six versions of repairs failed against that,
/// and the last of them explained why -- the host simply stopped asking. A host
/// that keeps "an alert is up" in its own page state has nothing to clear that
/// state, because the one thing it was waiting for -- being told the alert went
/// away -- never happened. Leaving the page worked because that state lives on
/// the page.
///
/// So the source alert is presented for real now, and only its pixels are
/// replaced. `loadViewIfNeeded` then alpha 0 and interaction off: the alert is
/// genuinely there (UIKit's transitions, its `presentedViewController`, and every
/// dismissal callback the host may be waiting for all behave normally), and
/// nothing of it is visible or clickable -- the replacement is drawn above it in
/// a window of its own.
- (void)lmn_parkSourceAlertInvisibly {
    UIAlertController *alert = self.sourceAlert;
    if (alert == nil) {
        return;
    }
    [alert loadViewIfNeeded];
    alert.view.alpha = 0.0;
    alert.view.userInteractionEnabled = NO;
    objc_setAssociatedObject(alert, LMNReplacedAlertKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Undo the parking, which is what dismissal needs: a presented alert that is
/// still transparent and still refusing touches would be the state this whole
/// sequence exists to avoid.
- (void)lmn_unparkSourceAlert {
    UIAlertController *alert = self.sourceAlert;
    if (alert == nil) {
        return;
    }
    if ([alert isViewLoaded]) {
        alert.view.userInteractionEnabled = YES;
        alert.view.alpha = 1.0;
    }
    objc_setAssociatedObject(alert, LMNReplacedAlertKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Whether this alert has a replacement standing in for it. The in-place restyler
/// asks, because this alert is presented and its lifecycle hooks do fire.
+ (BOOL)lmn_isReplacedAlert:(UIAlertController *)alert {
    if (alert == nil) {
        return NO;
    }
    return objc_getAssociatedObject(alert, LMNReplacedAlertKey) != nil;
}

#pragma mark - 1.2.24: one scrim, not two

/// 1.2.24. Presenting the real alert fixed the presentation, and the bill for
/// that arrived as a second scrim.
///
/// UIKit dims the screen for the alert it presents. The replacement dims the
/// screen again, in the window it owns above that one. Two translucent black
/// layers over the same pixels do not read as "one slightly darker scrim": they
/// read as a shadow the native alert never had, and they go away at different
/// moments -- the replacement's fades out with the panel, UIKit's is torn out
/// when the source alert is dismissed a beat later. That is the "closes twice".
///
/// So the one UIKit installed is found and taken out, and the replacement's own
/// backdrop stays: it is the scrim the theme actually describes (明昼 light,
/// 影院 deep), which is the one thing UIKit's fixed grey cannot be.
static BOOL LMNModernViewIsSystemScrim(UIView *view, UIView *container,
                                       NSUInteger depth, BOOL geometry) {
    if (view == nil || container == nil) {
        return NO;
    }
    // UIKit names its scrims after what they do, and the name is the one signal
    // that survives a private class being renamed between releases.
    NSString *name = NSStringFromClass([view class]);
    if ([name rangeOfString:@"Dimming"
                    options:NSCaseInsensitiveSearch].location != NSNotFound
        || [name rangeOfString:@"Scrim"
                       options:NSCaseInsensitiveSearch].location != NSNotFound
        || [name rangeOfString:@"Darkening"
                       options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    // Geometry, but only right next to a presentation container that is a
    // container OF ITS OWN. When the container is the host's own window there
    // is no telling a scrim from the host's UI by shape alone -- a full-bleed
    // translucent dark view at the top of a window is something an app has a
    // perfectly good reason to own -- so the name is the only evidence allowed
    // there. 1.2.27 makes this reachable: UIModalPresentationOverFullScreen
    // presents into the host window rather than into a container of its own.
    if (!geometry || depth > 1) {
        return NO;
    }
    CGRect bounds = container.bounds;
    CGRect frame = view.frame;
    if (CGRectIsEmpty(bounds) || CGRectIsEmpty(frame)) {
        return NO;
    }
    if (CGRectGetWidth(frame) < CGRectGetWidth(bounds) * 0.9
        || CGRectGetHeight(frame) < CGRectGetHeight(bounds) * 0.9) {
        return NO;
    }
    // A blur laid over the whole container is a scrim too, whatever it is named.
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        return ((UIVisualEffectView *)view).effect != nil;
    }
    if (view.opaque) {
        return NO;
    }
    UIColor *color = view.backgroundColor;
    if (color == nil) {
        return NO;
    }
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    // A named or patterned colour is not in a convertible RGB space; leaving it
    // alone is the safe answer, because a scrim is always plain.
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return NO;
    }
    if (alpha <= 0.01 || alpha >= 0.99) {
        return NO;
    }
    // A scrim is dark. A translucent app background is not, and must survive.
    return (red <= 0.4 && green <= 0.4 && blue <= 0.4);
}

/// Walk the presentation's own container and neutralise every scrim in it.
///
/// Only two branches are ever skipped: the presented view itself, and anything
/// that contains it. Everything else here was put in this container by the
/// presentation, which is exactly the set that has no business dimming a screen
/// the replacement is already dimming.
+ (BOOL)lmn_hideSystemScrimIn:(UIView *)container
                    presented:(UIView *)presented
                      geometry:(BOOL)geometry
                        depth:(NSUInteger)depth {
    if (container == nil || depth > 5) {
        return NO;
    }
    BOOL took = NO;
    for (UIView *sub in container.subviews) {
        if (sub == presented) {
            continue;
        }
        // 1.2.29. A wrapper that CONTAINS the presented view is searched, not
        // skipped. UIKit puts the alert and the scrim in the SAME transition
        // view, side by side, so "skip anything containing the alert" skipped
        // the only view guaranteed to be next to the scrim -- which is why this
        // hunt never reported a hit in four builds. Containing the alert
        // exempts a view from being taken out; it does not exempt it from being
        // looked inside.
        BOOL holdsPresented = (presented != nil
                               && [presented isDescendantOfView:sub]);
        if (!holdsPresented
            && LMNModernViewIsSystemScrim(sub, container, depth, geometry)) {
            if (!sub.isHidden) {
                sub.hidden = YES;
                took = YES;
            }
            if (sub.alpha > 0.0) {
                sub.alpha = 0.0;
            }
            continue;
        }
        if ([self lmn_hideSystemScrimIn:sub presented:presented
                               geometry:geometry depth:depth + 1]) {
            took = YES;
        }
    }
    return took;
}

+ (void)lmn_hideSystemScrimForAlert:(UIAlertController *)alert {
    if (alert == nil || ![alert isViewLoaded]) {
        return;
    }
    UIView *presented = alert.view;
    // The presentation container is where UIKit puts both the presented view and
    // the scrim it dims with. `superview` is the fallback for a presentation that
    // has not published one yet.
    UIView *container = alert.presentationController.containerView;
    if (container == nil) {
        container = presented.superview;
    }
    if (container == nil || container == presented) {
        return;
    }
    // Shape is evidence only when the presentation owns its container. See
    // LMNModernViewIsSystemScrim.
    BOOL geometry = (container != presented.window);
    if ([self lmn_hideSystemScrimIn:container presented:presented
                            geometry:geometry depth:0]) {
        // Build marker, once per process: it compiles into __cstring so the
        // shipped dylib can be proved to carry this path, per architecture.
        static BOOL reported = NO;
        if (!reported) {
            reported = YES;
            LMNModernProbe(@"lumen 1.2.46 took out a system scrim");
        }
    }
}

/// Repeat the parking and take the system scrim out again.
///
/// Neither is a one-shot. UIKit's own presentation transition sets the presented
/// view's alpha when it finishes -- "parked invisible" is not a state it knows
/// about -- and a scrim installed during a transition is not necessarily in the
/// tree the instant `presentViewController:` returns. So both are re-asserted
/// every time the alert is known to be up: from the presentation site, and again
/// from `-viewDidAppear:`, which is the moment UIKit has finished its own
/// transition and therefore the moment it can have undone the parking.
+ (void)lmn_reassertParkedAlert:(UIAlertController *)alert {
    if (alert == nil || ![alert isViewLoaded]) {
        return;
    }
    if (alert.view.alpha > 0.0) {
        alert.view.alpha = 0.0;
    }
    if (alert.view.userInteractionEnabled) {
        alert.view.userInteractionEnabled = NO;
    }
    [self lmn_hideSystemScrimForAlert:alert];
}

/// Called once from the presentation site; the repeats are scheduled here rather
/// than at the call site so every path that puts an alert up gets them.
- (void)lmn_hideSystemScrim {
    [self lmn_hideSystemScrimPass];
    __weak typeof(self) weakSelf = self;
    // Three passes across half a second. The scrim is installed during the
    // presentation transition, and a transition is the one thing whose timing
    // this tweak is least able to vouch for -- the same mistake 1.2.18 made when
    // it guessed that a teardown takes one turn of the main queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf lmn_hideSystemScrimPass];
    });
    // 1.2.33: and more of them, because the presentation is animated now and an
    // animated transition has more than one moment at which it can set the
    // presented view's alpha. The parking has to be re-asserted across all of
    // them, or the real alert surfaces through the replacement's shade for the
    // length of a fade.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf lmn_hideSystemScrimPass];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf lmn_hideSystemScrimPass];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf lmn_hideSystemScrimPass];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf lmn_hideSystemScrimPass];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf lmn_hideSystemScrimPass];
    });
    // 1.2.31. The report that only appears when the fix did NOT land. If nothing
    // was taken out of the screen by this point, the shade is still there and
    // the next round should not have to guess again -- so the class names the
    // presentation actually built are put on screen for a screenshot.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf lmn_reportScrimDiagnosis];
    });
}

/// One line, on screen, only when nothing was found.
- (void)lmn_reportScrimDiagnosis {
    if (_scrimUndo == nil || _scrimUndo.count > 0) {
        return;
    }
    static BOOL reported = NO;
    if (reported) {
        return;
    }
    reported = YES;

    UIAlertController *alert = self.sourceAlert;
    if (alert == nil) {
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    UIPresentationController *controller = alert.presentationController;
    if (controller != nil) {
        [names addObject:NSStringFromClass([controller class])];
    }
    UIView *container = controller.containerView;
    if (container == nil) {
        container = alert.view.superview;
    }
    NSUInteger seen = 0;
    for (UIView *sub in container.subviews) {
        if (seen >= 3) {
            break;
        }
        NSString *name = NSStringFromClass([sub class]);
        if (name.length > 22) {
            name = [name substringToIndex:22];
        }
        [names addObject:name];
        seen += 1;
    }
    NSString *detail = [@"dim=none pc=" stringByAppendingString:
        [names componentsJoinedByString:@","]];

    UIWindow *reportWindow = self.view.window;
    if (reportWindow == nil) {
        reportWindow = _previousKeyWindow;
    }
    LMNModernProbe([@"lumen 1.2.46 scrim report " stringByAppendingString:detail]);
    // 1.2.34: IN ITS OWN WORDS.
    //
    // This used to call `lmn_reportThemeFallback:`, so a sweep that found
    // nothing announced itself as an unreadable colour store -- a false alarm,
    // and on a normal outcome: an action sheet's presentation need not yield a
    // scrim to take out, so a sheet reported a fault every time. That is the
    // black bar in the user's screenshot, and it also cost a whole investigation
    // the wrong lead. It says what it means now, and it is opt-in like the other
    // two.
    if (!LMNOnScreenDiagnosticsEnabled()) {
        return;
    }
    [LMNModernAlertController
        lmn_presentDiagnostic:[@"LUMEN: 系统遮罩没找到 (sweep empty)\n"
                             stringByAppendingString:detail]
                     inWindow:reportWindow];
}

/// A pass costs nothing once the alert is gone: the reverse link is dropped at
/// teardown, so a late pass finds no source and does nothing.
- (void)lmn_hideSystemScrimPass {
    if (_sourceAlert == nil) {
        return;
    }
    [LMNModernAlertController lmn_reassertParkedAlert:_sourceAlert];

    // 1.2.33: AND NOTHING IS TAKEN OUT ONCE THE SHADE COULD HAVE BEEN SEEN.
    //
    // The passes keep re-asserting the parking for as long as the alert is up --
    // that part is free and it is what keeps an animated transition from
    // revealing the parked alert. Taking things out is a different kind of act
    // and it does not stay free: a dim removed halfway through its own fade-in
    // is a dip, and a dim removed after it has arrived is a flash, which is the
    // defect being fixed here seen from the other side.
    //
    // So the removals happen on the first two passes only: the one that runs
    // synchronously inside the presentation, and the one at 0.05s. Both are
    // before the shade can have been seen, and the ones after them are the ones
    // that could only ever make it worse.
    if (_scrimSweepPasses >= 2) {
        return;
    }
    _scrimSweepPasses += 1;

    // 1.2.28: and now the one the hunt could not name, found by subtraction.
    [self lmn_takeOutNewScrims];
    // 1.2.31: and finally the one it can be asked for by name.
    [self lmn_takeOutPresentationDimmingView];
}

/// The presentation controller's own dimming view, if it has one -- asked for
/// directly rather than searched for.
///
/// Four versions looked for this view by describing it: a class name containing
/// Dimming, then a shape, then a subtraction against an inventory, then the
/// wrapper it sits in. All four reported nothing, and the user's own comparison
/// says the shade was there the whole time. Describing a private view is
/// guessing at a name; this is not a description, it is the key.
///
/// `UIPresentationController` keeps the view it dims with in a private ivar. A
/// key that is not there is an exception, not a crash, and it costs one @try on
/// a path that runs four times per alert. When the key IS there, what comes back
/// is not a look-alike -- it is the object, and it is taken out the same way
/// everything else the sweep finds is.
- (void)lmn_takeOutPresentationDimmingView {
    UIAlertController *alert = self.sourceAlert;
    if (alert == nil || _scrimUndo == nil) {
        return;
    }
    UIPresentationController *controller = alert.presentationController;
    if (controller == nil) {
        return;
    }
    UIView *dimming = nil;
    @try {
        id value = [controller valueForKey:@"_dimmingView"];
        if ([value isKindOfClass:[UIView class]]) {
            dimming = (UIView *)value;
        }
    } @catch (NSException *exception) {
        // No such key on this release. That is the whole cost of asking.
        (void)exception;
        return;
    }
    if (dimming == nil || dimming.isHidden) {
        return;
    }
    LMNModernProbe([@"lumen 1.2.46 took out a presentation dimming view: "
                    stringByAppendingString:NSStringFromClass([dimming class])]);
    [LMNModernAlertController lmn_takeDimmingOutOf:dimming
                                              hide:YES
                                              undo:_scrimUndo];
}

#pragma mark - 1.2.28: the scrim, found by subtraction

/// Every view in the given windows, recorded as a weak set.
///
/// Iterative rather than recursive: a host's view tree is however deep the host
/// made it, and a walk that stops at a fixed depth is one more way to miss the
/// thing being looked for.
static NSHashTable *LMNInventoryViews(NSArray<UIWindow *> *windows) {
    NSHashTable *table = [NSHashTable weakObjectsHashTable];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:windows];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view == nil || [table containsObject:view]) {
            continue;
        }
        [table addObject:view];
        [stack addObjectsFromArray:view.subviews];
    }
    return table;
}

/// Whether a colour is a screen being dimmed.
///
/// Near-black and translucent, and nothing else -- an opaque dark surface is a
/// surface, and a pale transparent one is not a shade. One predicate, used both
/// to recognise a scrim and to decide whether a view's colour is worth taking
/// out, so the two can never disagree about what counts.
static BOOL LMNColorIsDimming(UIColor *color) {
    if (color == nil) {
        return NO;
    }
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    // A named or patterned colour is not in a convertible RGB space; leaving it
    // alone is the safe answer, because a scrim is always plain.
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return NO;
    }
    return (alpha > 0.01 && alpha < 0.99
            && red <= 0.5 && green <= 0.5 && blue <= 0.5);
}

/// Whether a view that arrived with the presentation is the scrim.
///
/// Three tests, in order: it covers nearly all of the screen; it is not opaque;
/// and it dims -- a near-black translucent colour, a blur, or a class named for
/// the job. The first two are what make the third safe to be loose about: the
/// only views offered here are the ones the presentation created, so an app's
/// own full-screen dark UI is never a candidate.
static BOOL LMNViewIsScrimShaped(UIView *view, CGRect frame, CGRect bounds) {
    if (view == nil) {
        return NO;
    }
    // Already invisible. Not a candidate, and hiding it would only put it in the
    // restore list for nothing.
    if (view.isHidden || view.alpha <= 0.01) {
        return NO;
    }
    if (view.opaque) {
        return NO;
    }
    if (CGRectIsEmpty(bounds) || CGRectIsEmpty(frame)) {
        return NO;
    }
    if (CGRectGetWidth(frame) < CGRectGetWidth(bounds) * 0.9
        || CGRectGetHeight(frame) < CGRectGetHeight(bounds) * 0.9) {
        return NO;
    }

    // Named for what it does. The cheapest true positive there is, and the only
    // one that does not depend on how the view happens to be painted.
    NSString *name = NSStringFromClass([view class]);
    if ([name rangeOfString:@"Dimming"
                    options:NSCaseInsensitiveSearch].location != NSNotFound
        || [name rangeOfString:@"Scrim"
                       options:NSCaseInsensitiveSearch].location != NSNotFound
        || [name rangeOfString:@"Darkening"
                       options:NSCaseInsensitiveSearch].location != NSNotFound
        || [name rangeOfString:@"Backdrop"
                       options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    // A blur is a scrim whatever it is called.
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        return ((UIVisualEffectView *)view).effect != nil;
    }

    // Otherwise it dims by painting: near-black and translucent. UIKit can set
    // the LAYER's background with no `backgroundColor` beside it, so both are
    // read -- asking only the property walks straight past the one being looked
    // for.
    UIColor *color = view.backgroundColor;
    if (color == nil && view.layer.backgroundColor != NULL) {
        color = [UIColor colorWithCGColor:view.layer.backgroundColor];
    }
    if (LMNColorIsDimming(color)) {
        return YES;
    }
    // The catch-all: a scrim is a LEAF. It paints one flat translucent wash and
    // holds nothing, so a new full-bleed, non-opaque view with no subviews is
    // taken to be the dimming view whatever it is called and however it is
    // painted -- including the case where it is painted by a backdrop layer or
    // a layer filter and has no `backgroundColor` to inspect at all.
    return (view.subviews.count == 0);
}

/// Take the dimming out of a view, and remember how to put it back.
///
/// Both halves are done rather than either, and the reason is 1.2.28's own bug:
///
///   * taking the view out is what removes it from the screen;
///   * clearing its dimming is what keeps it invisible if anything puts the view
///     back -- and something did. 1.2.28 restored every scrim it had taken out,
///     in the dismissal's own completion, and a shade UIKit had not finished
///     tearing down was switched back ON for the last frames of the exit. That
///     flash at the end of a smooth fade is what "disappears very hard" was
///     describing.
///
/// With both, a restore that should not have happened shows nothing anyway.
+ (void)lmn_takeDimmingOutOf:(UIView *)view
                        hide:(BOOL)hide
                        undo:(NSMutableArray *)undo {
    if (view == nil) {
        return;
    }
    __weak UIView *weakView = view;

    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)view;
        UIVisualEffect *effect = effectView.effect;
        if (effect != nil) {
            effectView.effect = nil;
            [undo addObject:^{
                UIVisualEffectView *strong = (UIVisualEffectView *)weakView;
                if (strong == nil || strong.window == nil) {
                    return;
                }
                strong.effect = effect;
            }];
        }
    }

    if (LMNColorIsDimming(view.backgroundColor)) {
        UIColor *background = view.backgroundColor;
        view.backgroundColor = UIColor.clearColor;
        [undo addObject:^{
            UIView *strong = weakView;
            if (strong == nil || strong.window == nil) {
                return;
            }
            strong.backgroundColor = background;
        }];
    }

    if (view.layer.backgroundColor != NULL) {
        UIColor *layerBackground =
            [UIColor colorWithCGColor:view.layer.backgroundColor];
        if (LMNColorIsDimming(layerBackground)) {
            view.layer.backgroundColor = NULL;
            [undo addObject:^{
                UIView *strong = weakView;
                if (strong == nil || strong.window == nil) {
                    return;
                }
                strong.layer.backgroundColor = layerBackground.CGColor;
            }];
        }
    }

    // A shade laid down by a layer filter has no colour here to read, and
    // there is nothing portable to drop it with: `CALayer.filters` is
    // macOS-only. That shape is caught by the leaf rule instead -- a view that
    // paints like that holds nothing, so it is taken out whole.

    if (hide) {
        BOOL wasHidden = view.isHidden;
        CGFloat alpha = view.alpha;
        view.hidden = YES;
        view.alpha = 0.0;
        [undo addObject:^{
            UIView *strong = weakView;
            if (strong == nil || strong.window == nil) {
                return;
            }
            strong.hidden = wasHidden;
            strong.alpha = alpha;
        }];
    }
}

/// Walk one window and take out every scrim that was not there before.
+ (void)lmn_takeOutScrimsIn:(UIView *)container
                     window:(UIWindow *)window
                     before:(NSHashTable *)before
                  presented:(UIView *)presented
                       undo:(NSMutableArray *)undo {
    if (container == nil) {
        return;
    }
    CGRect bounds = window.bounds;
    for (UIView *sub in container.subviews) {
        if (sub == presented) {
            continue;
        }
        // A wrapper that CONTAINS the presented view is looked INSIDE rather
        // than skipped, and it is never taken out -- the alert lives in it.
        //
        // UIKit presents into a transition view it installs in the host window,
        // and it puts the alert and the scrim in that wrapper SIDE BY SIDE. So
        // "skip anything that contains the presented view" skipped the one view
        // guaranteed to be next to the scrim, and four versions of this search
        // never got within reach of what they were looking for.
        BOOL holdsPresented = (presented != nil
                               && [presented isDescendantOfView:sub]);
        if (holdsPresented) {
            // 1.2.30. And the wrapper has to be read AS A SURFACE, not only as
            // a container.
            //
            // The shade does not have to be a view of its own. On some
            // presentations it is the wrapper's own background -- the transition
            // view is what dims -- and in that shape the thing being searched
            // for is a PROPERTY of the view that everything else has to be
            // searched through. No view-shaped search can ever find it, which is
            // the other reason the shade survived every version of this hunt.
            // Its dimming is taken out here instead.
            if (!sub.opaque && LMNColorIsDimming(sub.backgroundColor)) {
                [self lmn_takeDimmingOutOf:sub hide:NO undo:undo];
            }
            [self lmn_takeOutScrimsIn:sub window:window before:before
                            presented:presented undo:undo];
            continue;
        }
        // `frame` is in the superview's coordinates, which is only the window's
        // at the top of the tree; convert so "full-bleed" means the same thing
        // at every level.
        CGRect frame = (sub.superview != nil)
            ? [sub.superview convertRect:sub.frame toView:window]
            : sub.frame;
        if (![before containsObject:sub]
            && LMNViewIsScrimShaped(sub, frame, bounds)) {
            [self lmn_takeDimmingOutOf:sub hide:YES undo:undo];
            LMNModernProbe([@"lumen 1.2.46 took a new scrim out: "
                            stringByAppendingString:NSStringFromClass([sub class])]);
            continue;
        }
        [self lmn_takeOutScrimsIn:sub window:window before:before
                        presented:presented undo:undo];
    }
}

/// Take out whatever the presentation brought with it.
///
/// The inventory is the scene's views immediately before `%orig`. Anything
/// full-bleed, translucent and dark that is not in it WAS the presentation's --
/// there is no third thing a presentation adds to a window that looks like that.
- (void)lmn_takeOutNewScrims {
    if (_sceneInventory == nil || _scrimUndo == nil) {
        return;
    }
    UIWindowScene *scene = _hostWindow.windowScene;
    if (scene == nil) {
        return;
    }
    UIView *presented = (_sourceAlert != nil && _sourceAlert.isViewLoaded)
        ? _sourceAlert.view
        : nil;
    for (UIWindow *window in scene.windows) {
        // Our own window holds the replacement's backdrop, which is the scrim
        // meant to be on screen. It is above every one of these anyway, so
        // walking it could only ever take out the wrong layer.
        if (window == _hostWindow) {
            continue;
        }
        [LMNModernAlertController lmn_takeOutScrimsIn:window
                                              window:window
                                              before:_sceneInventory
                                           presented:presented
                                                undo:_scrimUndo];
    }
}

/// Put back everything that was taken out -- later, and only if it is still
/// installed somewhere.
///
/// Everything the sweep touches was created by the presentation, so by the time
/// this runs the presentation has almost always taken it away again and there is
/// nothing to put back. It exists for the other case: the sweep misread a view
/// that is still the host's, and a hidden host view is the kind of bug that
/// reads as "the app is broken" with nothing pointing back here.
///
/// 1.2.30, and this is the fix for the reported "hard" exit. 1.2.28 ran this in
/// the dismissal's own completion, which is the one moment a
/// presentation-owned view can still be in the tree AND already condemned. The
/// shade was switched back on for the last frames of a fade that had until then
/// been perfectly smooth -- the flash is the hardness. So it waits until the
/// presentation is certainly gone, and each undo checks that its view still has
/// a window before touching it. A view the presentation made has no window by
/// then; a view the sweep misread has one, and is still put back.
///
/// The undo list, not `self`: this controller is usually deallocated before the
/// delay is up, and the list is what the blocks need to survive it.
- (void)lmn_restoreTakenScrims {
    NSMutableArray *undo = _scrimUndo;
    _scrimUndo = nil;
    if (undo.count == 0) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Build marker: the delay and the window guard ARE the fix for the
        // "hard" exit, and a comparison does not survive into the binary as a
        // string -- so this line is what a shipped dylib can be proved to carry.
        LMNModernProbe(@"lumen 1.2.46 scrim undo ran late");
        for (void (^restore)(void) in undo) {
            restore();
        }
    });
}

/// Record what the scene looked like before the alert went up.
///
/// Called from the presentation site, immediately before `%orig`, because that
/// is the moment whose difference the sweep is going to read.
- (void)lmn_recordSceneInventory:(UIWindowScene *)scene {
    if (scene == nil) {
        return;
    }
    _sceneInventory = LMNInventoryViews(scene.windows);
    if (_scrimUndo == nil) {
        _scrimUndo = [NSMutableArray array];
    }
}

/// Which controller the replacement should actually be presented from.
///
/// `requested` is what the host asked for, and it comes back unchanged unless it
/// is already presenting something -- a repair path for the no-scene fallback
/// only.
///
/// 1.2.20: the place 1.2.19 chose -- the top of the `presentedViewController`
/// chain -- is wrong when what sits at the top is one of OURS. A stale
/// replacement has no window of its own left to present from, so presenting from
/// it is refused too. 1.2.19 stepped out of one refusal and straight into
/// another, which is why it changed nothing about the reported symptom.
///
/// The window's root is used instead. Under
/// `UIModalPresentationOverFullScreen` the presented view fills the window
/// regardless of who presented it, so the result is visually identical -- and the
/// root is an instance the host has not been through this with.
+ (UIViewController *)lmn_presenterFor:(UIViewController *)requested {
    if (requested.presentedViewController == nil) {
        return requested;
    }

    // Blocked. When the top of the chain is NOT ours, that top is the right
    // answer: it is where UIKit would have put the presentation anyway.
    UIViewController *top = requested;
    NSUInteger hops = 0;
    while (top.presentedViewController != nil && hops < 8) {
        top = top.presentedViewController;
        hops += 1;
    }
    if (![top isKindOfClass:[LMNModernAlertController class]]) {
        return top;
    }

    // The top is one of ours: stale, and unusable as a presenter. Go to the
    // window root instead, stopping short of any Lumen controller in its chain.
    UIWindow *window = requested.view.window;
    UIViewController *root = window.rootViewController;
    if (root == nil || root == requested) {
        return requested;
    }
    UIViewController *candidate = root;
    hops = 0;
    while (candidate.presentedViewController != nil
           && ![candidate.presentedViewController
                   isKindOfClass:[LMNModernAlertController class]]
           && hops < 8) {
        candidate = candidate.presentedViewController;
        hops += 1;
    }
    return candidate;
}

/// Every dismiss aimed at this controller still lands here -- a forced foreground
/// dismiss from the host, or one forwarded by Tweak.xm from the never-presented
/// source alert -- so the reverse link cannot survive by way of an unvisited
/// path. `lmn_tearDownWithCompletion:` drops the same link itself, because asking
/// the presenter directly bypasses this override entirely.
///
/// Both ends of that pair are retains: the association set in
/// `replacementForAlertController:` and the `_sourceAlert` ivar. Leaving both
/// standing is a cycle, and a cycle here leaks a controller plus its source
/// alert for every alert the process ever showed.
- (void)dismissViewControllerAnimated:(BOOL)flag
                           completion:(void (^ _Nullable)(void))completion {
    [self lmn_detachFromSourceAlert];
    [self lmn_hideHostWindow];

    // 1.2.23: what UIKit is presenting is the SOURCE alert, so that is what has
    // to be dismissed -- and dismissing it through itself (rather than around it)
    // is what delivers the dismissal callbacks the host is waiting for.
    UIAlertController *alert = self.sourceAlert;
    if (alert != nil && alert.presentingViewController != nil) {
        [alert dismissViewControllerAnimated:flag completion:completion];
        return;
    }

    // No source alert of ours is presented (the no-scene fallback presents this
    // controller directly).
    [super dismissViewControllerAnimated:flag completion:completion];
}

- (void)lmn_keyboardWillChange:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    id raw = info[UIKeyboardFrameEndUserInfoKey];
    if (![raw isKindOfClass:[NSValue class]]) {
        return;
    }
    CGRect keyboard = [(NSValue *)raw CGRectValue];
    CGRect local = [self.view convertRect:keyboard fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(local);
    if (overlap < 0.0 || !isfinite(overlap)) {
        overlap = 0.0;
    }

    if ([self lmn_isSheet]) {
        _panelBottomConstraint.constant = -LMNModernSheetInset - overlap;
    } else {
        // Lift by half the overlap: enough to clear the keyboard on a centred
        // card without pinning it to the top of the screen.
        _panelCenterYConstraint.constant = (overlap > 0.0) ? -overlap * 0.5
                                                           : 0.0;
    }
    [UIView animateWithDuration:0.25
                     animations:^{
        [self.view layoutIfNeeded];
    }];
}

#pragma mark - The factory

+ (void)captureHandler:(void (^)(UIAlertAction *))handler
             forAction:(UIAlertAction *)action {
    if (action == nil || handler == nil) {
        return;
    }
    objc_setAssociatedObject(action, LMNCapturedHandlerKey, handler,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

+ (BOOL)fireHandlerForAction:(UIAlertAction *)action {
    if (action == nil) {
        return NO;
    }
    void (^handler)(UIAlertAction *) =
        objc_getAssociatedObject(action, LMNCapturedHandlerKey);
    if (handler == nil) {
        return NO;
    }
    handler(action);
    return YES;
}

+ (UIViewController *)replacementForAlertController:(UIAlertController *)alert {
    if (alert == nil || ![LMNGlass enabled]) {
        return nil;
    }
    // First, before anything is built: clear away any replacement left standing
    // by the PREVIOUS cycle. Only one is ever legitimately on screen and none has
    // been made yet for this alert, so anything found here is ours to remove --
    // and removing it here is what keeps a stalled teardown from costing the host
    // every later presentation in this process.
    [self lmn_sweepRetiredReplacements];
    // 1.2.41: the guard is installed here, once, before this process has ever
    // made a replacement -- so there is no window in which one exists and the
    // background transition would go unhandled. Cheap: dispatch_once.
    [self lmn_installLifecycleGuard];
    // Before any of the preference gates: hosts that must never see a
    // replacement at all. See LMNReplacementIsForbiddenHere -- in SpringBoard a
    // replacement is invisible, cannot be dismissed, and wedges the swipe up to
    // the home screen.
    if (LMNReplacementIsForbiddenHere()) {
        // Reported once per process. Without this the run is indistinguishable
        // from "the tweak did not load": both produce no replacement and no
        // other output.
        static BOOL reported = NO;
        if (!reported) {
            reported = YES;
            LMNModernProbe(@"replacement declined host=SpringBoard reason="
                           @"the system alert there owns the home gesture");
        }
        return nil;
    }
    // 1.2.40: RICH CONTENT IS DRAWN BY US NOW, NOT DECLINED.
    //
    // 1.2.39 answered this same report by declining -- handing the alert back to
    // UIKit so the in-place restyler could keep the host's real card. That kept
    // the content but produced the half-done look the user then photographed:
    // the restyler found the action rows and re-skinned the capsules while the
    // card background stayed native. Buttons ours, everything else theirs.
    //
    // The content is rendered here instead. TrollStore's install confirmation is
    // the reported case: the public `title` and `message` are empty and the icon
    // plus the Metadata / Sandboxing / Capabilities / Accessible Containers /
    // Accessible Keychain Groups sections live in the private `attributedTitle`
    // / `attributedMessage`. Those are ordinary NSAttributedStrings, so
    // -lmn_buildContent can drop them straight into a label -- icon, colours and
    // all -- inside our own card. One uniform glass alert instead of a mixed one.
    //
    // Declining is now reserved for content that genuinely cannot be READ: a
    // child view controller behind an empty public title/message and with no
    // rich text to fall back on.
    NSAttributedString *checkTitle =
        LMNAlertAttributedString(alert, @"attributedTitle");
    NSAttributedString *checkMessage =
        LMNAlertAttributedString(alert, @"attributedMessage");
    BOOL hasRichText = (checkTitle.length > 0 || checkMessage.length > 0);
    if (!hasRichText && alert.title.length == 0 && alert.message.length == 0
        && alert.childViewControllers.count > 0) {
        LMNModernProbe(@"lumen 1.2.46 declined unreadable custom-content alert");
        return nil;
    }
    // 1.2.2: no preference gate here any more. The master switch is the only
    // switch, so an alert is either replaced or left alone -- and with the two
    // sub-switches gone there is no combination left that produces a
    // half-covered alert. What stays below is the STRUCTURAL test: an alert
    // with nothing in it cannot be drawn, and declining is better than
    // presenting an empty card.
    // Nothing drawable: an alert with no title, no message, no actions and no
    // fields is not a thing this class can render, and presenting an empty
    // glass card would be worse than letting UIKit have it.
    // 1.2.40: rich text counts as something to draw, so an alert that carries all
    // of its content in attributedTitle/attributedMessage (and nothing in the
    // public pair) is no longer mistaken for "nothing to draw" and declined.
    if (alert.actions.count == 0 && alert.title.length == 0
        && alert.message.length == 0 && alert.textFields.count == 0
        && !hasRichText) {
        return nil;
    }

    // "lumen 1.2.46 replacement" is a build marker: it compiles into the
    // dylib's string table, so grepping a shipped package proves which build
    // is installed even when the syslog is not being watched.
    LMNModernProbe(@"lumen 1.2.46 replacement");

    UIViewController *replacement = nil;
    @try {
        LMNModernAlertController *controller =
            [[LMNModernAlertController alloc] initWithAlertController:alert];
        objc_setAssociatedObject(alert, LMNReplacementKey, controller,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Weak: the association above is the owning reference. The registry only
        // needs to SEE the controller, never to keep it alive.
        [LMNLiveReplacements() addObject:controller];
        replacement = controller;
    }
    @catch (NSException *exception) {
        (void)exception;
        replacement = nil;
    }
    return replacement;
}

+ (UIViewController *)replacementForSourceAlert:(UIAlertController *)alert {
    if (alert == nil) {
        return nil;
    }
    return objc_getAssociatedObject(alert, LMNReplacementKey);
}

@end

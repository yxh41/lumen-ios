#import <UIKit/UIKit.h>

#import "LMNAlertRestyler.h"
#import "LMNModernAlertController.h"

// Block parameters, spelled as typedefs rather than inline.
//
// Logos parses a hook's declaration to rewrite `%orig`, and its parser reads
// `completion:(void (^ __nullable)(void))completion` as a parameter NAMED
// `__nullablecompletion` -- the nullability qualifier and the name run together,
// the block signature is lost, and every use of `completion` in the body comes
// back "use of undeclared identifier" while the parameter itself is reported
// unused. The types are identical either way; only the spelling differs.
typedef void (^LMNPresentCompletion)(void);
typedef void (^LMNActionHandler)(UIAlertAction *action);

// 1.2.20. Caps the presentation repair in the hook below at one hop. The
// substitute path re-enters `presentViewController:animated:completion:`, and
// these hooks run on the main thread only -- so one plain flag is enough to make
// recursion impossible rather than merely unlikely.
static BOOL lmnPresentationRepairInFlight = NO;

// === System alert support ===
//
// A system permission dialog (notification / ATT / location / camera --
// SpringBoard's `_SBAlertController`) is reached the SAME way the reference
// AlertController plugin reaches it: in place, through `UIAlertController`'s
// own lifecycle hooks below, and through no other trigger.
//
// `_SBAlertController` IS a `UIAlertController` subclass, so those hooks fire
// on it (it does not override them without calling super), and
// `restyleController:` already branches on `LMNControllerIsSystemDialog` to
// treat it as a system dialog. There is deliberately NO second trigger -- no
// `_UIAlertControllerInterfaceActionGroupView` hook and no `dispatch_async`
// deferral -- because two triggers racing on one dialog is exactly what
// produced the "half native, half ours" / "replacement plus ours" overlap:
// the async pass re-ran `restyleController:` on a view tree the synchronous
// pass had already mutated, and the two card reads disagreed. One trigger,
// one synchronous pass, deterministic result. The replacement renderer
// (presentViewController:) is declined for system dialogs in SpringBoard by
// LMNReplacementIsForbiddenHere, so a system dialog is restyled in place once
// and never replaced. See 1.2.46.

/// 1.1.13: the interception point.
///
/// Everything else in this file works on an alert UIKit has ALREADY built: it
/// walks the finished view tree, decides which view is the card, and inserts a
/// panel into it. When that decision fails the panel is never drawn -- while
/// the capsules always are, because `LMNStyleAllActionRows` runs
/// unconditionally. That split is exactly the reported symptom, "the buttons
/// are ours but the background is still the system's", and no amount of
/// cleverer guessing removes it: recognition is the price of admission.
///
/// Intercepting at presentation removes the guess. The `UIAlertController` is
/// never handed to UIKit at all; a Lumen-drawn controller is presented instead
/// and reads the source alert's public properties. Nothing is recognised, so
/// there is no state in which recognition fails.
///
/// The hook is on `UIViewController` rather than on `UIAlertController`
/// because the alert is not the presenter -- it is the argument.
%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)flag
                   completion:(LMNPresentCompletion)completion {
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        // 1.2.21: before anything else, take out any of our root views still
        // installed in this window. None of ours is legitimately on screen at
        // this moment, so anything found is a leftover -- and this finds the ones
        // whose controller is already gone, which no controller-side check can.
        [LMNModernAlertController lmn_clearLingeringRootViewsIn:self.view.window];
        UIViewController *replacement = [LMNModernAlertController
            replacementForAlertController:(UIAlertController *)
                                              viewControllerToPresent];
        if (replacement != nil) {
            // Captured before anything is shown, so the check below cannot
            // quietly re-read a state that has already moved on.
            UIWindow *hostWindow = self.view.window;
            NSString *requestedClass = NSStringFromClass([self class]);

            // 1.2.22: DO NOT PRESENT IT.
            //
            // Five versions tried to repair what handing the host a presentation
            // does to the host, and the on-screen probe settled it: on the second
            // tap the host never calls this method at all. Once its own
            // `presentedViewController` is left standing -- by anything -- the
            // host is entitled to stop asking, and every repair written
            // downstream of this call is then unreachable. That is why 1.2.21's
            // probe stayed silent: there was nothing to report, because nothing
            // was ever attempted.
            //
            // So the replacement goes into a window of its own instead. The
            // host's presentation chain is not entered, so it cannot be left
            // dirty; nothing of ours enters the host's view tree either, so
            // nothing of ours can eat a tap there. The alert still covers the
            // screen, still dims what is behind it, and still owns the status
            // bar -- under UIModalPresentationOverFullScreen it filled the window
            // anyway, and this fills its own window the same way.
            UIAlertController *sourceAlert =
                (UIAlertController *)viewControllerToPresent;

            // 1.2.23: LET UIKIT PRESENT THE REAL ALERT. Only the pixels are ours.
            //
            // Since 1.1.13 the replacement faked the alert's whole lifecycle: the
            // source alert was read from and never presented, so UIKit ran none of
            // what it normally runs for one. Six versions of repairs failed
            // against that, and 1.2.21's probe said why -- the host stopped
            // asking. A host that keeps "an alert is up" in its own page state has
            // nothing to clear that state, because the one thing it waits for --
            // being told the alert went away -- never happened. Leaving the page
            // worked because that state lives on the page.
            //
            // So the alert is presented for real, un-animated, and parked
            // invisible BEFORE it goes up: alpha 0, interaction off. UIKit's
            // transitions, the host's `presentedViewController`, and every
            // dismissal callback the host may be relying on all behave normally.
            // The replacement is drawn above it, in a window of its own.
            if ([replacement isKindOfClass:[LMNModernAlertController class]]) {
                LMNModernAlertController *ours =
                    (LMNModernAlertController *)replacement;
                [ours lmn_parkSourceAlertInvisibly];

                // 1.2.27: DO NOT LET UIKIT DIM AT ALL.
                //
                // 1.2.24 removed the second scrim by looking for UIKit's: walk
                // the presentation's container, take out anything named
                // Dimming/Scrim/Darkening or shaped like a full-bleed
                // translucent scrim. It never found it. Two screenshots pin
                // the arithmetic down -- a white background measures 209 with
                // our 明昼 alone and 167 with a 0.20 underneath, and 1.2.26
                // measures 167 -- so UIKit's scrim is still there, and guessing
                // at a private class name is what four versions already did.
                //
                // OverFullScreen is the documented style that covers the
                // presenting content and adds no scrim of its own, which is
                // exactly the contract wanted here: the alert is genuinely
                // presented (1.2.23 fixed the stall that way) and genuinely
                // invisible, and the only shade on screen is the one the theme
                // describes. Nothing else about the presentation changes -- the
                // lifecycle, the host's `presentedViewController` and every
                // dismissal callback behave as they do for any other style.
                //
                // The hunt below stays as the net for the case where UIKit
                // declines the request.
                sourceAlert.modalPresentationStyle =
                    UIModalPresentationOverFullScreen;

                // 1.2.28: TAKE THE SCENE'S INVENTORY BEFORE IT CHANGES.
                //
                // This is the other half of the subtraction, and it has to happen
                // here: after `%orig` the scrim is already in the tree and there
                // is nothing left to subtract from. Everything the sweep finds
                // missing from this inventory was put there by the presentation.
                [ours lmn_recordSceneInventory:hostWindow.windowScene];

                // 1.2.33: ANIMATED, OR UIKIT'S DIM ARRIVES IN ONE FRAME.
                //
                // Since 1.2.23 the alert is presented for real, and it was
                // presented with animated:NO -- "an invisible thing has no need
                // of an animation", which is true of the ALERT and false of
                // what comes with it. UIKit installs and fades in its dimming
                // view as part of the presentation transition; ask for the
                // transition to be instant and the dim is not skipped, it is
                // placed at full strength in a single frame. That is the flash
                // the user reported, and it is the one layer the replacement
                // does not draw and therefore has never been able to fade.
                //
                // The alert stays parked at alpha 0 through the whole thing --
                // -viewDidAppear:, -viewDidLayoutSubviews: and the passes below
                // all re-assert it -- so the transition itself remains
                // invisible.
                %orig(sourceAlert, YES, nil);

                // 1.2.24: the alert is up for real now, so UIKit has dimmed the
                // screen for it -- and the replacement dims the screen again in
                // the window above. Take UIKit's out; ours is the scrim the
                // theme describes, and it is the only one that should be there.
                [ours lmn_hideSystemScrim];

                if ([ours lmn_showInScene:hostWindow.windowScene
                               hostWindow:hostWindow]) {
                    if (completion != nil) {
                        completion();
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (![ours isViewLoaded] || ours.view.window == nil) {
                            NSString *detail = [NSString stringWithFormat:
                                @"requested=%@ ownWindow=1 parked=%d",
                                requestedClass,
                                sourceAlert.presentingViewController != nil];
                            [LMNModernAlertController
                                lmn_reportPresentationLost:detail
                                                  inWindow:hostWindow];
                        }
                    });
                    return;
                }

                // No scene to put a window of our own in. Unpark and leave the
                // host's own alert standing: functionality is exactly native
                // here, and only the glass is missing.
                [ours lmn_unparkSourceAlert];
                if (completion != nil) {
                    completion();
                }
                return;
            }

            // 1.2.22: no-scene path -- present the replacement the old way, from
            // somewhere that CAN present it.
            UIViewController *target =
                [LMNModernAlertController lmn_presenterFor:self];
            NSString *targetClass = NSStringFromClass([target class]);
            BOOL repairing = (target != self) && !lmnPresentationRepairInFlight;

            if (repairing) {
                lmnPresentationRepairInFlight = YES;
                [target presentViewController:replacement
                                     animated:flag
                                   completion:completion];
                lmnPresentationRepairInFlight = NO;
            } else {
                %orig(replacement, flag, completion);
            }

            // 1.2.21: prove it landed. If the replacement has no window a turn
            // later, the presentation was refused and the user is looking at
            // nothing -- so report it where it can be read, on the screen.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![replacement isViewLoaded]
                    || replacement.view.window == nil) {
                    NSString *detail = [NSString stringWithFormat:
                        @"requested=%@ target=%@ repaired=%d win=%d",
                        requestedClass, targetClass,
                        repairing ? 1 : 0, hostWindow != nil ? 1 : 0];
                    [LMNModernAlertController
                        lmn_reportPresentationLost:detail
                                          inWindow:hostWindow];
                }
            });
            return;
        }
    }
    %orig;
}

%end

/// `UIAlertAction` exposes no accessor for its handler block, and the block is
/// the host app's entire reason for showing the alert. There is exactly one
/// moment when the block is visible -- when the action is constructed -- so it
/// is captured there and replayed by the replacement when its button is
/// tapped. No private ivar is read and nothing is guessed.
%hook UIAlertAction

+ (instancetype)actionWithTitle:(NSString *)title
                          style:(UIAlertActionStyle)style
                        handler:(LMNActionHandler)handler {
    UIAlertAction *action = %orig;
    [LMNModernAlertController captureHandler:handler forAction:action];
    return action;
}

%end

/// iOS 16 routes every system alert — `UIAlertController` and, since it is
/// implemented on top of it, `UIActionSheet` — through this class, so a single
/// hook covers both presentation styles.
///
/// The hook deliberately never rebuilds the alert's own controls: it only
/// re-skins the card it already lives in and restyles the existing
/// `UIAlertAction` buttons. Rebuilding the panel from scratch would drop the
/// action handlers, the text field plumbing and every accessibility trait the
/// host app relies on.
%hook UIAlertController

/// 1.1.13: a dismiss aimed at the source alert has to reach what the user is
/// actually looking at. When the alert was replaced, the source was never
/// presented, so without this the host's
/// `[alert dismissViewControllerAnimated:completion:]` is a no-op and the
/// replacement stays on screen forever.
- (void)dismissViewControllerAnimated:(BOOL)flag
                           completion:(LMNPresentCompletion)completion {
    UIViewController *replacement =
        [LMNModernAlertController replacementForSourceAlert:self];
    if (replacement != nil) {
        [replacement dismissViewControllerAnimated:flag completion:completion];
        return;
    }
    %orig;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // 1.2.23: an alert with a replacement IS presented now, so these hooks fire
    // for it. It is invisible, and already drawn by us -- restyling it as well
    // would put the same glass in the tree twice.
    if ([LMNModernAlertController lmn_isReplacedAlert:self]) {
        return;
    }
    if ([self class] == [UIAlertController class]) {
        [LMNAlertRestyler restyleAlertController:self];
    } else {
        // System dialog (`_SBAlertController` and other private subclasses):
        // restyle in place, never tracked as a live alert. Single trigger.
        [LMNAlertRestyler restyleSystemAlertController:self];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([LMNModernAlertController lmn_isReplacedAlert:self]) {
        // 1.2.24: UIKit's own transition has just finished. That is the moment it
        // can have put the presented view back to alpha 1 -- parking is not a
        // state it knows about -- and the moment its scrim is certainly in the
        // tree. Re-park and take the scrim out again here, not only at the
        // presentation site.
        [LMNModernAlertController lmn_reassertParkedAlert:self];
        return;
    }
    if ([self class] == [UIAlertController class]) {
        [LMNAlertRestyler restyleAlertController:self];
    } else {
        [LMNAlertRestyler restyleSystemAlertController:self];
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if ([LMNModernAlertController lmn_isReplacedAlert:self]) {
        return;
    }
    if ([self class] == [UIAlertController class]) {
        [LMNAlertRestyler restyleAlertController:self];
    } else {
        [LMNAlertRestyler restyleSystemAlertController:self];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    // Light and dark glass are different layer stacks, not a recolour of one
    // stack, so an alert that is already on screen has to be rebuilt when the
    // system appearance flips. UIKit has already committed the new appearance
    // by the time this runs, which is exactly when the palette must change.
    if ([self.traitCollection
            hasDifferentColorAppearanceComparedToTraitCollection:
                previousTraitCollection]) {
        [LMNAlertRestyler alertsDidChangeAppearance];
    }
}

%end

%ctor {
    @autoreleasepool {
        [LMNAlertRestyler bootstrap];
    }
}
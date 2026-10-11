//
//  LMNModernAlertController.h
//  Lumen
//
//  1.1.13: the replacement renderer.
//
//  Everything before this version worked by *restyling* UIKit's own alert:
//  walk the private view tree, guess which view is the card, insert a glass
//  panel into it. Coverage therefore had an architectural ceiling -- whenever
//  the guess failed (`LMNAlertCards()` returned 0) the panel was never drawn,
//  while the capsules were, because `LMNStyleAllActionRows` runs
//  unconditionally. That is exactly the symptom reported: "buttons are ours,
//  the background is still the system's".
//
//  This controller takes the other road. It never touches UIKit's alert view
//  tree at all: a `UIAlertController` is intercepted at
//  `presentViewController:animated:completion:` and THIS controller is
//  presented instead, drawn entirely from the source alert's public properties
//  (title, message, actions, text fields, preferredStyle). There is nothing to
//  recognise and nothing to search, so there is no "not recognised" state --
//  coverage is complete by construction rather than by luck.
//
//  The one thing that is not public is the action's handler block.
//  `UIAlertAction` exposes no accessor for it, so it is captured at
//  construction time by hooking the public factory
//  `+actionWithTitle:style:handler:` -- see `captureHandler:forAction:`.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LMNModernAlertController : UIViewController

/// Always built from a source alert. The source is never presented: it is only
/// read from.
- (instancetype)initWithAlertController:(UIAlertController *)alert;

/// 1.2.22: put the replacement on screen in a window of its own, leaving the
/// host's presentation chain completely untouched -- no `presentedViewController`
/// is set on the host and nothing of ours enters its view tree. Returns NO when
/// there is no scene to put a window in, in which case the caller presents it as
/// every earlier version did.
- (BOOL)lmn_showInScene:(UIWindowScene *)scene hostWindow:(UIWindow *)hostWindow;

/// Take that window away and give `hostWindow` its key status back.
- (void)lmn_hideHostWindow;

/// 1.2.23: make the source alert invisible and touch-transparent, and mark it as
/// ours. Called BEFORE it is presented, so UIKit presents something already
/// invisible and there is no frame in which the real alert can be seen.
- (void)lmn_parkSourceAlertInvisibly;

/// Undo the parking: the alert is about to be dismissed for real, and a presented
/// alert left transparent and touch-refusing is the state this whole sequence
/// exists to avoid. Also clears the "has a replacement" marker.
- (void)lmn_unparkSourceAlert;

/// Whether `alert` has a replacement standing in for it. The in-place restyler
/// asks, because such an alert really is presented and its lifecycle hooks fire.
+ (BOOL)lmn_isReplacedAlert:(UIAlertController *)alert;

/// 1.2.24: take out the screen dimming UIKit installed for the alert it is now
/// really presenting, and re-assert that the alert is still parked invisible.
/// Safe to call repeatedly; does nothing once the alert is gone.
+ (void)lmn_reassertParkedAlert:(UIAlertController *)alert;

/// 1.2.24: as above, for this replacement's own source alert, repeated across the
/// half second in which UIKit's presentation transition may still be installing
/// things. Called from the presentation site.
- (void)lmn_hideSystemScrim;
/// 1.2.28. Record the scene's views before the source alert is presented, and
/// take out / put back whatever the presentation added. See 1.2.28 in the
/// implementation for why the difference is used instead of a description.
- (void)lmn_recordSceneInventory:(UIWindowScene *)scene;
- (void)lmn_restoreTakenScrims;

@property (nonatomic, strong, readonly) UIAlertController *sourceAlert;

/// Captures the host's handler block. Called from the
/// `+[UIAlertAction actionWithTitle:style:handler:]` hook, which is the only
/// place that block is ever visible.
+ (void)captureHandler:(void (^ _Nullable)(UIAlertAction *action))handler
             forAction:(UIAlertAction *)action;

/// Runs the captured block. Returns NO when the action was never given one, so
/// a caller can tell "no handler" from "handler ran".
+ (BOOL)fireHandlerForAction:(UIAlertAction *)action;

/// The substitute for `alert`, or nil when this alert must be left to UIKit.
///
/// nil is returned for an alert with nothing drawable, for a style whose switch
/// is off, and for any exception raised while building -- a failed replacement
/// must degrade to the system alert, never to a crash.
+ (UIViewController * _Nullable)replacementForAlertController:(UIAlertController *)alert;

/// The substitute currently standing in for `alert`, if any. How a dismiss
/// aimed at the never-presented source alert is forwarded to what the user is
/// actually looking at.
+ (UIViewController * _Nullable)replacementForSourceAlert:(UIAlertController *)alert;

/// Which controller a replacement should be presented from, given the one the
/// host asked for. Returns `requested` unchanged unless it is already presenting
/// something -- see the implementation for why the ordinary case is left alone
/// and what is used when it cannot be.
+ (UIViewController *)lmn_presenterFor:(UIViewController *)requested;

/// Remove any of our replacement root views still installed in `window`,
/// whatever made them -- including ones whose controller is already gone.
/// Called at presentation time, when none of ours is legitimately on screen.
+ (void)lmn_clearLingeringRootViewsIn:(UIWindow *)window;

/// Say on screen that a presentation of ours did not land, and what was in the
/// way. There is no log to read on the device; this is the channel.
+ (void)lmn_reportPresentationLost:(NSString *)detail
                          inWindow:(UIWindow *)hostWindow;

@end

NS_ASSUME_NONNULL_END

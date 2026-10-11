#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Turns any `UIAlertController` (and, on iOS 16, every `UIActionSheet`, which
/// is implemented as one) into the iOS 27 style liquid-glass panel.
@interface LMNAlertRestyler : NSObject

/// Registers the cross-process preference observer. Called from `%ctor`.
+ (void)bootstrap;

/// Idempotent. Safe to call from every layout pass.
+ (void)restyleAlertController:(nullable UIAlertController *)controller;

/// Restyles a system alert whose controller is NOT a `UIAlertController` --
/// SpringBoard's `_SBAlertController`, the class behind the notification /
/// ATT / location permission dialogs. Idempotent, in-place only (it never
/// replaces the presentation) and it does not track the dialog as a live
/// alert. Same visual treatment as `restyleAlertController:`.
+ (void)restyleSystemAlertController:(nullable UIViewController *)controller;

/// Re-applies the current parameters to alerts that are already on screen.
+ (void)refreshLiveAlerts;

/// Rebuilds on-screen alerts for a system appearance change. The light and
/// dark appearances are different layer stacks rather than a recolour, so the
/// existing panel has to be discarded and made again.
+ (void)alertsDidChangeAppearance;

@end

NS_ASSUME_NONNULL_END

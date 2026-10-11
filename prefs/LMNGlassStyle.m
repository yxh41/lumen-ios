#import "LMNGlassStyle.h"

// The whole file is two constants.
//
// The parameters themselves moved to LMNGlass.swift and the glass itself to
// LMNGlassPanelView.swift. Objective-C keeps only what it cannot live without:
// the identifier that names the preference store, and the notification that
// tells a running process the store changed. Swift reads both through the
// bridging header, so they have to be defined in Objective-C exactly once —
// and because the preference bundle is a separate binary, it compiles this
// file too.
NSString *const LMNPreferenceDomain = @"com.zlhkf.lumen";

CFStringRef const LMNGlassPreferencesChangedNotification =
    CFSTR("com.zlhkf.lumen.glass-preferences-changed");

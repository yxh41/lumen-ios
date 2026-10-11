//
//  Lumen-Bridging-Header.h
//
//  What the Swift half is allowed to see. Theos passes this to swiftc with
//  `-import-objc-header`, and it is picked up automatically because the
//  instance is named Lumen.
//
//  Only `LMNGlassStyle.h` is imported, and deliberately so:
//
//    * it carries the preference-domain constant, the change notification and
//      the slider bounds that both languages have to agree on;
//    * it declares `LMNGlassButtonRole`, which the Swift renderer switches on;
//    * it does NOT declare the renderer or the restyler, because importing an
//      Objective-C `@interface` for a class that Swift also defines under the
//      same `@objc` name is a duplicate-interface error. The Swift classes are
//      reached from Objective-C through the generated `Lumen-Swift.h` instead.
//

#import "LMNGlassStyle.h"

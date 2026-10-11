# Both slices are required: the package gate asserts arm64 *and* arm64e,
# because a roothide device loads arm64e while other jailbreak processes may
# still request the plain arm64 image.
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0

# Package scheme is switchable so one source tree produces both jailbreak
# flavours:
#
#   rootless -> installed under a literal /var/jb prefix
#   roothide -> installed into a randomised jbroot, no prefix in the deb
#
# roothide is not a repackaging of a rootless deb. Its package managers reject
# `Architecture: iphoneos-arm64` outright and expect `iphoneos-arm64e`, which
# has nothing to do with the arm64e CPU slice — it is a marker for "install me
# into jbroot". The deb layout is rootful-shaped, i.e. no /var/jb prefix.
#
# This tweak qualifies for the simple path documented by the roothide project:
# it never touches a jailbreak file at runtime (no diagnostic log, no
# /var/mobile path), so it needs neither the jbroot() API nor libroothide.
# Override with `make ... THEOS_PACKAGE_SCHEME=roothide`.
THEOS_PACKAGE_SCHEME ?= $(THEOS_SCHEME)
ifeq ($(strip $(THEOS_PACKAGE_SCHEME)),)
THEOS_PACKAGE_SCHEME := rootless
endif

# Keep Theos' jailbreak-native signer. Overriding this with Apple's
# `codesign -s -` produces a macOS ad-hoc CodeDirectory (CS_ADHOC) that can be
# accepted in SpringBoard while being rejected before our constructor runs in a
# sandboxed application process.

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Lumen

# Swift-first hybrid: the appearance half is Swift, the injection half is
# Objective-C. Theos accepts .swift in _FILES directly (rules.mk filters them
# into SWIFT_FILES), so no custom rule is needed — only the language version.
#
# The bridging header is Lumen-Bridging-Header.h, which Theos picks up by
# default from the instance name; the generated Lumen-Swift.h is what
# LMNAlertRestyler.m imports to see the Swift classes.
#
# Theos cannot hook Swift, which is why Tweak.xm and the restyler stay
# Objective-C: the whole Logos layer depends on it.
# Kept on one line: the local gate parses _FILES token by token, and a
# backslash continuation would be read as a source file named "\".
Lumen_FILES = Tweak.xm LMNGlassStyle.m LMNGlass.swift LMNGlassPanelView.swift LMNModernAlertController.m LMNAlertRestyler.m
Lumen_SWIFT_VERSION = 5
# Theos would infer this from the instance name; spelled out because the build
# breaks in a confusing way if it ever stops doing so.
Lumen_SWIFT_BRIDGING_HEADER = Lumen-Bridging-Header.h
Lumen_CFLAGS = -fobjc-arc -Wall -Wextra
Lumen_FRAMEWORKS = UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

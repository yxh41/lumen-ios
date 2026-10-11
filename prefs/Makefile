include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LumenPrefs

# The settings bundle is a separate binary, so it compiles its own copy of
# LMNGlassStyle.m — it needs the preference-domain constant and the change
# notification, and it cannot reach into the injected dylib for them.
#
# It deliberately does NOT compile the Swift half. The simplified page has no
# in-cell glass preview (the "预览弹窗" buttons present a real UIAlertController,
# which the tweak itself restyles — a truer preview that costs nothing), so the
# bundle never needs the renderer. Keeping Swift out of a preference bundle also
# keeps it off the risky path: a bundle is loaded by Preferences, not injected,
# and has no say in how the Swift runtime gets set up.
LumenPrefs_FILES = LMNRootListController.m LMNGlassStyle.m
LumenPrefs_FRAMEWORKS = UIKit QuartzCore CoreGraphics
LumenPrefs_INSTALL_PATH = /Library/PreferenceBundles
LumenPrefs_CFLAGS = -fobjc-arc -Wall -Wextra
LumenPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

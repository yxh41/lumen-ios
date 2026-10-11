#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The packaged control is rebuilt by Theos from the source `control`, so the
# version it carries must match the source. Derive the expected version from
# the source file instead of hardcoding it, or every release bumps both the
# control and this script (the 1.0.0 -> 1.0.1 bump already broke the gate once).
source_control="$(cd "$script_directory" && cd .. && pwd)/control"
if [[ ! -f "$source_control" ]]; then
    source_control="control"
fi
expected_version="$(awk -F': ' '/^[Vv]ersion:/ {print $2; exit}' "$source_control")"
if [[ -z "$expected_version" ]]; then
    echo "could not read Version from $source_control" >&2
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "usage: verify-package.sh PACKAGE.deb [SCHEME]" >&2
    echo "  SCHEME is 'rootless' (default) or 'roothide'." >&2
    echo "  It decides the expected Architecture value and whether the deb" >&2
    echo "  carries a /var/jb prefix, which is the whole difference between" >&2
    echo "  the two jailbreak flavours." >&2
    exit 2
fi

package="$1"
scheme="${2:-rootless}"

case "$scheme" in
    rootless)
        expected_architecture="iphoneos-arm64"
        expected_prefix="var/jb"
        ;;
    roothide)
        # Deliberately nothing to do with the arm64e CPU slice: roothide uses
        # this value as a marker meaning "install into the randomised jbroot".
        expected_architecture="iphoneos-arm64e"
        # A roothide deb is rootful-shaped — no prefix at all.
        expected_prefix=""
        ;;
    *)
        echo "unknown scheme '$scheme'; expected rootless or roothide" >&2
        exit 2
        ;;
esac

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

dpkg-deb --info "$package"
dpkg-deb --contents "$package"
dpkg-deb --extract "$package" "$workspace/root"
dpkg-deb --control "$package" "$workspace/control"

archive_directories="$(
    dpkg-deb --contents "$package" |
        awk '$1 ~ /^d/ { print $NF }' |
        sed -e 's#^\./##' -e 's#/$##'
)"

# Build the expected directory list from the prefix so one assertion block
# serves both flavours.
if [[ -n "$expected_prefix" ]]; then
    required_directories=(
        "var"
        "var/jb"
        "var/jb/Library"
        "var/jb/Library/MobileSubstrate"
        "var/jb/Library/MobileSubstrate/DynamicLibraries"
        "var/jb/Library/PreferenceBundles"
        "var/jb/Library/PreferenceBundles/LumenPrefs.bundle"
        "var/jb/Library/PreferenceLoader"
        "var/jb/Library/PreferenceLoader/Preferences"
    )
else
    required_directories=(
        "Library"
        "Library/MobileSubstrate"
        "Library/MobileSubstrate/DynamicLibraries"
        "Library/PreferenceBundles"
        "Library/PreferenceBundles/LumenPrefs.bundle"
        "Library/PreferenceLoader"
        "Library/PreferenceLoader/Preferences"
    )
fi

for directory in "${required_directories[@]}"; do
    if ! grep -Fxq "$directory" <<<"$archive_directories"; then
        echo "[$scheme] package archive is missing directory entry: $directory" >&2
        exit 1
    fi
done

# A rootless deb must not carry rootful paths, and a roothide deb must not
# carry the /var/jb prefix. Getting this backwards is the failure that makes a
# package install to the wrong place, so assert the absence explicitly.
if [[ "$scheme" == "roothide" ]] && grep -Fxq "var/jb" <<<"$archive_directories"; then
    echo "[$scheme] deb still contains a var/jb entry; roothide installs into" \
         "a randomised jbroot and the deb must be prefix-free" >&2
    exit 1
fi
if [[ "$scheme" == "rootless" ]] && ! grep -Fxq "var/jb" <<<"$archive_directories"; then
    echo "[$scheme] deb is missing the var/jb prefix" >&2
    exit 1
fi

# Every assertion below is named. A bare `test -f` or `grep -q` under `set -e`
# fails with no output at all, which costs a whole CI cycle to diagnose.
root="$workspace/root/$expected_prefix"
bundle="$root/Library/PreferenceBundles/LumenPrefs.bundle"
runtime="$root/Library/MobileSubstrate/DynamicLibraries/Lumen.dylib"
runtime_filter="$root/Library/MobileSubstrate/DynamicLibraries/Lumen.plist"
loader="$root/Library/PreferenceLoader/Preferences/com.zlhkf.lumen.plist"
preferences="$bundle/LumenPrefs"
preferences_root="$bundle/Root.plist"
preferences_info="$bundle/Info.plist"

for required_path in "$runtime" "$runtime_filter" "$loader" "$preferences" \
                     "$preferences_root" "$preferences_info"; do
    if [ ! -f "$required_path" ]; then
        echo "package is missing $(basename "$required_path") at $required_path" >&2
        exit 1
    fi
done

for icon in icon.png icon@2x.png icon@3x.png; do
    if [ ! -f "$bundle/$icon" ]; then
        echo "preference bundle is missing $icon" >&2
        exit 1
    fi
done

# The tweak is injected through UIKit so it can reach an arbitrary app; a
# per-app or executable-scoped filter would defeat the whole point.
for filter_key in Bundles com.apple.UIKit; do
    if ! grep -q "$filter_key" "$runtime_filter"; then
        echo "runtime filter is missing $filter_key" >&2
        exit 1
    fi
done
if grep -Eq "com.tencent|Executables|Classes" "$runtime_filter"; then
    echo "runtime filter must stay a generic UIKit injection" >&2
    exit 1
fi

# Theos writes Architecture into the packaged control from the active package
# scheme, so assert what the deb actually says rather than what the source
# control file says. For roothide this is the value that makes Sileo/Zebra
# accept the package at all.
for expected in "Package: com.zlhkf.lumen" "Name: Lumen" "Version: $expected_version" \
                 "Architecture: $expected_architecture"; do
    if ! grep -qx "$expected" "$workspace/control/control"; then
        echo "[$scheme] packaged control is missing line: $expected" >&2
        grep -E '^(Package|Name|Version|Architecture|Maintainer):' \
            "$workspace/control/control" >&2 || true
        exit 1
    fi
done

# The dylib must stay fat for both flavours. Note this is unrelated to the
# control Architecture value: roothide's `iphoneos-arm64e` is a packaging
# marker, not a statement that only the arm64e slice may load.
runtime_arches="$(xcrun lipo -archs "$runtime")"
preferences_arches="$(xcrun lipo -archs "$preferences")"
for pair in "Lumen:$runtime_arches" "LumenPrefs:$preferences_arches"; do
    name="${pair%%:*}"
    arches="${pair#*:}"
    if [[ "$arches" != *"arm64"* || "$arches" != *"arm64e"* ]]; then
        echo "$name has arches [$arches]; both arm64 and arm64e are required" >&2
        exit 1
    fi
done

# Apple's codesign verifier does not recognize ldid's jailbreak-native arm64e
# signature. Validate the embedded CodeDirectory directly instead.
python3 "$script_directory/verify-macho-signature.py" --require-flags 0 "$runtime"
python3 "$script_directory/verify-macho-signature.py" --require-flags 0 "$preferences"

# Lumen is a Swift-first hybrid: the dylib compiles Swift (the appearance), the
# preference bundle does not (it only writes the preference store). Assert both
# halves of that, because the failure is invisible in the deb listing and only
# shows up as an alert that never gets restyled.
#
# The Swift runtime is present on iOS 12.2+, so the dylib needs no embedded
# libswift* dylibs — what proves Swift was compiled in is the ObjC-visible class
# names in __objc_classname, plus the preference keys the Swift reader owns.
python3 - "$runtime" "$preferences" <<'PY'
import sys


def markers(path):
    return open(path, "rb").read()


def count(blob, needle):
    return blob.count(needle.encode("utf-8")) + blob.count(needle.encode("utf-16-le"))


runtime_blob = markers(sys.argv[1])
prefs_blob = markers(sys.argv[2])

# NOTE: "glassEnabled" is deliberately NOT asserted here. It is 12 bytes, and
# Swift stores a UTF-8 literal of 15 bytes or fewer *inline* in the String value
# (small-string encoding) — it never reaches __cstring, so a byte scan of the
# dylib cannot see it. Every key above 15 bytes does land there, which is why
# the five panel keys are findable and this one is not. The master switch is
# asserted at the source level by _gate.py instead, and at the binary level on
# the preference bundle, which is Objective-C and stores it as a real literal.
#
# ("com.zlhkf.lumen" is also 15 bytes, but it survives the same scan because it
# is defined in LMNGlassStyle.m — Objective-C, compiled into both binaries — so
# it reaches __cstring regardless of what Swift does with its own copy.)
runtime_required = [
    "com.zlhkf.lumen",
    "glassBlurIntensity",
    "glassRefractionWidth",
    "glassHighlightIntensity",
    "glassTintConcentration",
    "glassCornerRadius",
    "UIAlertController",
    # The Swift half, reachable from Objective-C under these exact names. If the
    # Swift files ever drop out of _FILES, all three disappear together.
    "LMNGlass",
    "LMNGlassParams",
    "LMNGlassPanelView",
    # 1.1.1 probe. Two symptoms measured on a real device — row titles keeping
    # the host tint, and the destructive row never turning red — are each
    # consistent with several causes needing different fixes. The probe is what
    # settles it in one device run instead of one CI cycle per guess, so its
    # absence from the binary is worth failing a build over.
    "lumen-probe",
]
prefs_required = [
    "com.zlhkf.lumen",
    "glassEnabled",
    "glassBlurIntensity",
    "glassRefractionWidth",
    "glassHighlightIntensity",
    "glassTintConcentration",
    "glassCornerRadius",
    "LMNGlassSliderCell",
    # The preview alert builds its own strings; the row labels live in
    # Root.plist instead, because a plist writer emits CJK as XML character
    # references and they were never greppable in a binary.
    "标题文字",
]

for blob, required, name in (
    (runtime_blob, runtime_required, "runtime dylib"),
    (prefs_blob, prefs_required, "preference bundle"),
):
    missing = [n for n in required if count(blob, n) < 1]
    if missing:
        sys.exit("%s is missing glass markers: %s" % (name, missing))
    print("%s carries all %d glass markers" % (name, len(required)))

# The iOS 26 era switch was removed in 1.1.0; a stale build that still reads
# those keys would silently pick the retired look.
for stale in ("glassIOS26StyleEnabled", "glassIOS27StyleEnabled"):
    for blob, name in ((runtime_blob, "runtime dylib"),
                       (prefs_blob, "preference bundle")):
        if count(blob, stale) >= 1:
            sys.exit("%s still carries the retired key %s" % (name, stale))
print("retired iOS 26 era keys are gone from both binaries")

# 1.1.1: capsule geometry stopped being preference-backed. Nothing ever wrote
# glassButtonHeight / glassButtonInset — not Root.plist, not LMNDefaultValues()
# — so a value left by an older build stayed in effect permanently and
# invisibly, which is how the pill ended up 8pt from the card edge instead of
# 16pt with no setting that could change it. Both are constants now.
#
# These two are 16 and 15 bytes. "glassButtonHeight" is exactly 16, so it does
# reach __cstring and the assertion below is meaningful; "glassButtonInset" is 15
# and would be inlined by Swift's small-string encoding, so only the longer one
# is asserted. Both are enforced at the source level by _gate.py regardless.
if count(runtime_blob, "glassButtonHeight") >= 1:
    sys.exit("runtime dylib still carries the preference key glassButtonHeight; "
             "capsule geometry is a constant in 1.1.1")
if b"glassButtonInset" in prefs_blob:
    sys.exit("preference bundle still carries the preference key "
             "glassButtonInset; it was never writable and is now a constant")
print("capsule geometry is constant (retired preference keys absent)")

# 1.1.3 capsule PLACEMENT. This is the check that matters most in the whole
# package, because getting it wrong is invisible: 1.1.2 shipped a build whose
# capsule was correctly shaped, correctly sized and completely invisible on a
# device, because it was inserted at the row's index 0 and the host painted over
# it. Nothing in a screenshot distinguishes "wrong shape" from "not drawn".
#
# The shape cannot be asserted from the binary at all — the corner curve is an
# extern constant that need not reach __cstring, and with a CAShapeLayer mask the
# layer's own curve is clipped away anyway. So what is asserted here is the
# probe string, which only exists if the new discovery-and-parenting code was
# actually compiled in:
#
#   clearedHighlights=  how many host highlight views were found and cleared
#   capsuleHost=        which private view the capsule was parented into
#
# Both are absent from a 1.1.2 dylib, and both are spelled distinctively on
# purpose: `host=` on its own would also match inside a longer word, and a
# marker that can match by accident is not a marker.
for probe in (b"clearedHighlights=", b"capsuleHost="):
    if probe not in runtime_blob:
        sys.exit("runtime dylib does not carry the 1.1.3 placement probe (%s); "
                 "the capsule may still be parented into the row instead of the "
                 "host's content view, which renders it invisible"
                 % probe.decode())
print("capsule placement probe present (parented into the host content view)")

# 1.2.0: the three themes (曜石玻璃 / 影院暗色 / 自动, renamed in 1.2.2 from
# the reference's 明昼 so that the third option follows the system instead of
# pinning a light card).
#
# Asserted on the SETTINGS side for the key, and on the RUNTIME side for the
# probe, because the two fail differently and neither is visible in a
# screenshot:
#
#   1. "glassTheme" must be in the preference bundle. It is an Objective-C
#      literal there, so it always reaches __cstring. It is NOT asserted in the
#      runtime dylib: "glassTheme" is 10 bytes, under the 15-byte threshold
#      noted above, so Swift stores it as a small string baked into the global's
#      initialiser and it never appears as a literal -- checking for it there
#      would fail a build that is correct.
#   2. The runtime must report the resolved theme. A build that reads the key
#      but never reaches the material assignments renders a picker that moves
#      and changes nothing, and that is indistinguishable from a mistyped key
#      without the probe.
if b"glassTheme" not in prefs_blob:
    sys.exit("preference bundle does not carry glassTheme; the theme picker "
             "would render three titles and write nothing")
if b"LMNGlassThemeCell" not in prefs_blob:
    sys.exit("preference bundle does not carry LMNGlassThemeCell; the theme row "
             "would fall back to the stock PSSegmentCell, which reads and "
             "writes through key+defaults -- neither of which this page "
             "declares, so the picker would persist nothing")
# 1.2.0: the SpringBoard refusal. Lumen's filter is a FRAMEWORK filter
# (com.apple.UIKit), so this dylib is also loaded into SpringBoard, and a
# replacement presented there is drawn onto a window that sits behind the
# foreground app -- invisible, untappable, never dismissed, and SpringBoard
# stays in the state where it suppresses the swipe up to the home screen. Both
# halves are asserted in the BINARY: the guard's host test and the refusal it
# logs. A build that dropped the guard would still carry every other marker.
if b"com.apple.springboard" not in runtime_blob:
    sys.exit("runtime dylib does not carry the SpringBoard host test; the "
             "replacement would run in SpringBoard and wedge the swipe up to "
             "the home screen")
if b"replacement declined host=SpringBoard" not in runtime_blob:
    sys.exit("runtime dylib does not carry the SpringBoard refusal probe, so a "
             "device run could not tell the refusal from a tweak that never "
             "loaded")
print("1.2.0 SpringBoard refusal present (host test + probe)")

# 1.2.1 deleted the tvOS material path (1.1.6). Asserted as an ABSENCE in both
# binaries, because this is the direction that fails silently: nothing in a
# normal build ever notices that a dead private-API touch point came back, and
# the switch it belonged to could not reach an alert in the first place -- a
# replaced alert never goes through UIKit's style factory, and the restyler
# nulls the effect view that style configures.
#
# The names are the ones that would be COMPILED IN, so their presence in
# __cstring means the code is back, not merely mentioned.
for gone in (b"UIInterfaceActionConcreteVisualStyle_AppleTV", b"set_blurRadius:",
             b"system=material", b"tvOSStyle"):
    if gone in runtime_blob:
        sys.exit("runtime dylib still carries %s; the tvOS material path was "
                 "deleted in 1.2.1 and cannot reach an alert from this renderer"
                 % gone.decode())
for gone in (b"tvOSStyleEnabled:", b"fullscreenBlurEnabled:", b"blurRadius"):
    if gone in prefs_blob:
        sys.exit("preference bundle still carries %s; the tvOS material "
                 "controls were deleted in 1.2.1" % gone.decode())
print("1.2.1 tvOS material path absent from both binaries")

# 1.2.2 deleted the two replacement switches and their keys. The master switch is
# the only switch now, so the shipped bundle must not carry the old keys: a
# settings page that still writes them is a page the runtime ignores, and worse,
# it is the combination that produced a half-covered alert.
for gone in (b"glassReplaceAlerts", b"glassReplaceSheets"):
    if gone in runtime_blob:
        sys.exit("runtime dylib still reads %s; the two replacement switches "
                 "were deleted in 1.2.2" % gone.decode())
for gone in (b"glassReplaceAlerts", b"glassReplaceSheets",
             b"replaceAlertsEnabled:", b"replaceSheetsEnabled:"):
    if gone in prefs_blob:
        sys.exit("preference bundle still carries %s; the master switch is "
                 "supposed to be the only switch" % gone.decode())
print("1.2.2 replacement switches absent from both binaries")

for probe in (b"theme=%ld", b"clearedHighlights="):
    if probe not in runtime_blob:
        sys.exit("runtime dylib does not carry the 1.2.0 theme probe (%s); a "
                 "build that reads the theme but never reports it cannot be "
                 "distinguished from one where it does nothing" % probe.decode())
print("1.2.0 theme picker present in both binaries, with its material probe")

# The preference bundle must not link Swift: it is loaded by Preferences, which
# gives it no say in how the Swift runtime is set up.
if b"libswift" in prefs_blob:
    sys.exit("preference bundle links the Swift runtime; it must stay "
             "Objective-C only")
print("preference bundle is Objective-C only (no libswift linkage)")
PY

# One settings page, described by one plist. A missing plist is what makes the
# Settings app abort the moment the entry is tapped.
for plist in Root.plist; do
    if [ ! -f "$bundle/$plist" ]; then
        echo "[$scheme] preference bundle is missing $plist" >&2
        exit 1
    fi
done

# The retired sub-pages must not ship: a plist in the bundle that no row links
# to is dead weight and a sign the page is not actually single.
for plist in TitleAlignment.plist PopupSettings.plist ButtonSettings.plist \
             AnimationSettings.plist InputSettings.plist; do
    if [ -f "$bundle/$plist" ]; then
        echo "[$scheme] preference bundle still ships the retired $plist" >&2
        exit 1
    fi
done

python3 - "$bundle/Root.plist" "$preferences" <<'PY'
import plistlib
import sys

root = plistlib.load(open(sys.argv[1], "rb"))
blob = open(sys.argv[2], "rb").read()

items = root.get("items")
if not isinstance(items, list) or not items:
    sys.exit("Root.plist has no items; the settings page would be empty")

# One page: master switch, the theme picker, the five sliders, the preview
# buttons, restore.
labels = {e.get("label") for e in items}
for required in ("启用lumen", "配色", "出现动画", "模糊强度", "边缘折射", "高光强度",
                 "底色浓度", "圆角半径", "预览弹窗", "预览操作菜单", "恢复默认设置"):
    if required not in labels:
        sys.exit("Root.plist is missing label %r" % required)

# 1.2.0: the theme picker, by title AND by the class that backs it. The three
# titles are the reference package's own, so a rename is a picker that no longer
# means what the reference means. And the row must name LMNGlassThemeCell:
# without it PSListController instantiates the stock PSSegmentCell, which
# persists through key+defaults -- neither declared here -- and the picker
# becomes three titles that move and write nothing.
segments = [e for e in items
            if e.get("cell") == "PSSegmentCell"
            and e.get("preferenceKey") == "glassTheme"]
if len(segments) != 1:
    sys.exit("Root.plist must carry exactly one theme picker, found %d"
             % len(segments))
segment = segments[0]
if segment.get("validTitles") != ["曜石玻璃", "影院暗色", "自动"]:
    sys.exit("the theme picker's titles are %r; they are the reference "
             "package's own and must not be renamed"
             % (segment.get("validTitles"),))
if segment.get("validValues") != ["0", "1", "2"]:
    sys.exit("the theme picker's values are %r; they must stay 0/1/2 so a "
             "preference written by the reference package means the same thing"
             % (segment.get("validValues"),))
if segment.get("cellClass") != "LMNGlassThemeCell":
    sys.exit("the theme picker is backed by %r; it must be LMNGlassThemeCell, "
             "or the stock cell persists through a defaults domain this page "
             "does not use" % (segment.get("cellClass"),))
if segment.get("preferenceKey") != "glassTheme":
    sys.exit("the theme picker writes %r, which no runtime reader looks for"
             % (segment.get("preferenceKey"),))

# 1.2.3: the entrance picker. Exactly one PSSegmentCell writes glassEntrance,
# with the three titles and the 0/1/2 values the renderer's switch handles. It
# is filtered by preferenceKey so the theme picker above stays the only one the
# theme check counts.
entrances = [e for e in items
             if e.get("cell") == "PSSegmentCell"
             and e.get("preferenceKey") == "glassEntrance"]
if len(entrances) != 1:
    sys.exit("Root.plist must carry exactly one entrance picker, found %d"
             % len(entrances))
entrance = entrances[0]
if entrance.get("validValues") != ["0", "1", "2"]:
    sys.exit("the entrance picker values are %r; they must stay 0/1/2 so the "
             "renderer switch has a case for every value"
             % (entrance.get("validValues"),))
if entrance.get("validTitles") != ["聚焦弹入", "上浮", "淡入"]:
    sys.exit("the entrance picker titles are %r; they are the three entrance "
             "animations" % (entrance.get("validTitles"),))
if entrance.get("defaultValue") != 0:
    sys.exit("the entrance picker default must be 0 (聚焦弹入), the prior "
             "hardcoded look")

for entry in items:
    if entry.get("cell") == "PSLinkCell":
        sys.exit("Root.plist still pushes a sub-page (%r); the page must stay "
                 "a single page" % entry.get("label"))

if "LMNGlassSliderCell" not in {e.get("cellClass") for e in items}:
    sys.exit("Root.plist is missing cellClass LMNGlassSliderCell")

keys = {e.get("preferenceKey") for e in items}
for required in ("glassBlurIntensity", "glassRefractionWidth",
                 "glassHighlightIntensity", "glassTintConcentration",
                 "glassCornerRadius", "glassTheme", "glassEntrance"):
    if required not in keys:
        sys.exit("Root.plist is missing preference key %s" % required)

# 1.2.1 lowered the corner-radius ceiling from 120 to 60, and the shipped plist
# is where that has to have landed: the engine clamps per card at
# (minDim - 1) / (2 * 1.528), which for a 200pt-tall alert is about 65, so a
# slider that still runs to 120 has a top third that changes nothing.
radius = [e for e in items if e.get("preferenceKey") == "glassCornerRadius"]
if len(radius) != 1:
    sys.exit("expected one glassCornerRadius row, found %d" % len(radius))
if radius[0].get("maximumValue") != 60.0:
    sys.exit("the shipped corner-radius slider runs to %r, not 60"
             % (radius[0].get("maximumValue"),))
if radius[0].get("minimumValue") != 12.0:
    sys.exit("the shipped corner-radius slider starts at %r, not 12"
             % (radius[0].get("minimumValue"),))
print("corner radius shipped as 12..60")

# Every action row must be a PSButtonCell: a PSLinkCell is for navigation and
# pushes its `detail` controller instead of performing the action. A `detail`
# row must also declare isController, or the class name is read as a bundle
# name. A switch driven by custom accessors must not also carry a `key`, or the
# getter and PSSpecifier fight over the same value.
for entry in items:
    if "action" in entry and entry.get("cell") != "PSButtonCell":
        sys.exit("Root.plist: action row %r uses %s; it must be a PSButtonCell"
                 % (entry.get("label"), entry.get("cell")))
    if "detail" in entry and not entry.get("isController"):
        sys.exit("Root.plist: detail row %r must declare isController"
                 % entry.get("label"))
    if entry.get("get") and "key" in entry:
        sys.exit("Root.plist: %r declares both a getter and a key"
                 % entry.get("label"))

# Identifiers have to be unique, and every slider row needs one: the plist's own
# grouping and -reloadSpecifierID: both key rows on it.
identifiers = [e["identifier"] for e in items if e.get("identifier")]
if len(identifiers) != len(set(identifiers)):
    sys.exit("Root.plist has duplicate identifiers: %s" % identifiers)
for entry in items:
    if entry.get("preferenceKey") and not entry.get("identifier"):
        sys.exit("slider row %r has no identifier" % entry.get("label"))

# The action selectors have to be linked into the binary; a plist naming a
# selector that was never compiled is what aborts on tap.
for symbol in ("masterEnabled:", "setMasterEnabled:specifier:",
               "themeChanged:", "previewAlert:", "previewActionSheet:",
               "restoreDefaults:"):
    if symbol.encode() not in blob:
        sys.exit("preference bundle binary is missing %r" % symbol)

print("settings plist verified: %d root items" % len(items))
PY

python3 - "$preferences_info" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)

expected = {
    "CFBundleIdentifier": "com.zlhkf.lumen.preferences",
    "NSPrincipalClass": "LMNRootListController",
    "CFBundleExecutable": "LumenPrefs",
}
for key, value in expected.items():
    if info.get(key) != value:
        sys.exit("preference Info.plist has %s=%r, expected %r"
                 % (key, info.get(key), value))
print("preference Info.plist identity verified")
PY

# Theos writes Architecture into the packaged control from the active package
# scheme, so assert what the deb actually says rather than what the source
# control file says. For roothide this is the value that makes Sileo/Zebra
# accept the package at all.
for expected in "Package: com.zlhkf.lumen" "Name: Lumen" "Version: $expected_version" \
                 "Architecture: $expected_architecture"; do
    if ! grep -qx "$expected" "$workspace/control/control"; then
        echo "[$scheme] packaged control is missing line: $expected" >&2
        grep -E '^(Package|Name|Version|Architecture|Maintainer):' \
            "$workspace/control/control" >&2 || true
        exit 1
    fi
done

if [ ! -x "$workspace/control/postinst" ]; then
    echo "package maintainer script is missing or not executable" >&2
    exit 1
fi

if grep -Riq "dpkg-divert" "$workspace/control"; then
    echo "package unexpectedly contains dpkg-divert maintainer logic" >&2
    exit 1
fi

# Nothing from the retired multitasking project may survive in this package.
if find "$workspace/root" -print | grep -Eiq "LumenCore|LumenKeyboard|LumenRadius|flyme"; then
    echo "package unexpectedly ships retired multitasking artefacts" >&2
    exit 1
fi

echo "[$scheme] package verification passed"

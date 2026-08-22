TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Clock26

# Font-only "stretch" plugin: swaps the lock-clock digits to the axs66 variable
# font and drives its HGHT (height) axis. No transform, no glass, no font engine
# beyond CoreText's variation API. The .otf ships via layout/.
Clock26_FILES = Tweak.xm
Clock26_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
Clock26_FRAMEWORKS = UIKit CoreGraphics QuartzCore CoreText

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

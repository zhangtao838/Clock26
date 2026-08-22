TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = Clock26Prefs

Clock26Prefs_FILES = C26RootListController.m
Clock26Prefs_CFLAGS = -fobjc-arc
Clock26Prefs_INSTALL_PATH = /Library/PreferenceBundles
Clock26Prefs_FRAMEWORKS = UIKit
Clock26Prefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

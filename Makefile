ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AODTweakPrefs
AODTweakPrefs_INSTALL_PATH = /Library/PreferenceBundles
AODTweakPrefs_FILES = AODTweakPrefsListController.m
AODTweakPrefs_FRAMEWORKS = UIKit CoreGraphics QuartzCore
AODTweakPrefs_PRIVATE_FRAMEWORKS = Preferences
AODTweakPrefs_RESOURCE_FILES = Resources/entry.plist Resources/Root.plist

include $(THEOS_MAKE_PATH)/bundle.mk

SUBPROJECT_AFTER_INSTALL = 1
after-install::
	install.exec "killall -9 Preferences || true"

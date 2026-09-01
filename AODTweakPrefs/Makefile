ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AODTweakPrefs
AODTweakPrefs_INSTALL_PATH = /Library/PreferenceBundles
AODTweakPrefs_FILES = AODTweakPrefsListController.m
AODTweakPrefs_FRAMEWORKS = UIKit CoreGraphics QuartzCore
AODTweakPrefs_PRIVATE_FRAMEWORKS = Preferences
AODTweakPrefs_RESOURCE_FILES = Resources/Root.plist

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	@cp -f Resources/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/AODTweakPrefs.plist

SUBPROJECT_AFTER_INSTALL = 1
after-install::
	install.exec "killall -9 Preferences || true"

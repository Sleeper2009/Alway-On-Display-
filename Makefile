ARCHS = arm64e
TARGET := iphone:clang:latest:15.0
THEOS_DEVICE_IP = 

export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AODTweak
AODTweak_FILES = Tweak.xm
AODTweak_CFLAGS = -fobjc-arc
AODTweak_FRAMEWORKS = UIKit IOKit
AODTweak_PRIVATE_FRAMEWORKS = SpringBoardServices SpringBoardFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AODTweakPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"

ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
THEOS_DEVICE_IP =

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AODTweak
AODTweak_FILES = tweak.x
AODTweak_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AODTweakPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

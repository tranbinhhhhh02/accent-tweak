TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AccentColorAll
AccentColorAll_FILES = Tweak.x
AccentColorAll_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AccentColorAll_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

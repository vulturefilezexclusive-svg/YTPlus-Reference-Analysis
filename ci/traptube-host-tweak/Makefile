ARCHS = arm64
TARGET = iphone:clang:16.5:13.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrapTubeBranding
TrapTubeBranding_FILES = TrapTubeBranding.x
TrapTubeBranding_CFLAGS = -fobjc-arc -I$(THEOS)/include/YouTubeHeader
TrapTubeBranding_FRAMEWORKS = UIKit Foundation QuartzCore
TrapTubeBranding_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

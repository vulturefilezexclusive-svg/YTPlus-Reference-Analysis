ARCHS = arm64
TARGET = iphone:clang:16.5:13.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrapTubeBranding
TrapTubeBranding_FILES = TrapTubeBranding.x
TrapTubeBranding_CFLAGS = -fobjc-arc -I$(THEOS)/include/YouTubeHeader
TrapTubeBranding_FRAMEWORKS = UIKit Foundation QuartzCore AVFoundation
TrapTubeBranding_LDFLAGS = -undefined dynamic_lookup

ifeq ($(TRAPTUBE_STEMKIT_KIND),framework)
TrapTubeBranding_FRAMEWORKS += TrapTubeStemKit
TrapTubeBranding_LDFLAGS += -F$(TRAPTUBE_STEMKIT_FRAMEWORKS)
else ifeq ($(TRAPTUBE_STEMKIT_KIND),dylib)
TrapTubeBranding_LDFLAGS += -L$(TRAPTUBE_STEMKIT_FRAMEWORKS) -lTrapTubeStemKit
else
$(error TRAPTUBE_STEMKIT_KIND must be set to framework or dylib)
endif

include $(THEOS_MAKE_PATH)/tweak.mk

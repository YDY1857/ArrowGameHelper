TARGET := iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = AlipayWallet
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ArrowGameHelper
ArrowGameHelper_FILES = Tweak.x Solver.m
ArrowGameHelper_CFLAGS = -fobjc-arc
ArrowGameHelper_PRIVATE_FRAMEWORKS = 
ArrowGameHelper_EXTRA_FRAMEWORKS = 

include $(THEOS_MAKE_PATH)/tweak.mk

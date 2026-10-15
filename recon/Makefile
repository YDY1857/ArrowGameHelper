TARGET := iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = AlipayWallet
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ArrowGameRecon
ArrowGameRecon_FILES = Tweak.x
ArrowGameRecon_CFLAGS = -fobjc-arc -Wno-error=deprecated-declarations
ArrowGameRecon_EXTRA_FRAMEWORKS = WebKit

include $(THEOS_MAKE_PATH)/tweak.mk

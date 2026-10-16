TARGET := iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = AlipayWallet
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ArrowGameRecon
ArrowGameRecon_FILES = Tweak.x
ArrowGameRecon_CFLAGS = -fobjc-arc -Wno-error=deprecated-declarations
ArrowGameRecon_EXTRA_FRAMEWORKS = WebKit
# Make the install name resolve next to the host executable, so injection tools
# that copy the dylib into the .app can load it via @executable_path.
ArrowGameRecon_LDFLAGS = -Wl,-install_name,@executable_path/ArrowGameRecon.dylib

include $(THEOS_MAKE_PATH)/tweak.mk

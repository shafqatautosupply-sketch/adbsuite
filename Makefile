# ADB Suite - Theos application for iPhone 4S / iOS 6 (armv7)
# Needs OpenSSL 1.1.1 built for iOS 6 (sh build-deps.sh) -> installed in $(OPENSSL)
ARCHS = armv7
TARGET = iphone:clang:latest:6.0
OPENSSL ?= $(HOME)/ios6-openssl

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ADBSuite

ADBSuite_FILES = $(wildcard Classes/*.m) core/adbapi.c core/conn.c core/keys.c core/pairing.c core/mdns.c core/spake2.c core/err.c
ADBSuite_OBJCFLAGS = -fobjc-arc
ADBSuite_CFLAGS = -Icore -I$(OPENSSL)/include -DHAVE_DNSSD -Wno-deprecated-declarations -O2
ADBSuite_LDFLAGS = $(OPENSSL)/lib/libssl.a $(OPENSSL)/lib/libcrypto.a
ADBSuite_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/application.mk

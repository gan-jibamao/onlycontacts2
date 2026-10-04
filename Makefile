TARGET := iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OnlyContacts
OnlyContacts_FILES = Tweak.xm
OnlyContacts_CFLAGS = -fobjc-arc
OnlyContacts_FRAMEWORKS = Foundation
OnlyContacts_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

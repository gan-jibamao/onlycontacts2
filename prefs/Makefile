export THEOS_BUILD_DIR = ..

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OnlyContactsPrefs
OnlyContactsPrefs_FILES = OCRootListController.m
OnlyContactsPrefs_CFLAGS = -fobjc-arc
OnlyContactsPrefs_FRAMEWORKS = Foundation UIKit
OnlyContactsPrefs_PRIVATE_FRAMEWORKS = Preferences
OnlyContactsPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	$(ECHO_NOTHING)cp Resources/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/OnlyContactsPrefs.bundle/Info.plist"$(ECHO_END)

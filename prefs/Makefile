export THEOS_BUILD_DIR = ..

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OnlyContactsPrefs
OnlyContactsPrefs_FILES = OCRootListController.m
OnlyContactsPrefs_CFLAGS = -fobjc-arc
OnlyContactsPrefs_FRAMEWORKS = Foundation UIKit
OnlyContactsPrefs_PRIVATE_FRAMEWORKS = Preferences
OnlyContactsPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

# theos 生成的 Info.plist 没有 NSPrincipalClass（面板会空白），
# stage 完用我们自己的覆盖回去
after-stage::
	$(ECHO_NOTHING)cp Resources/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/OnlyContactsPrefs.bundle/Info.plist"$(ECHO_END)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/* Preferences.framework 私有头（theos 不带，手写用到的部分） */
@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface OCRootListController : PSListController
@end

@implementation OCRootListController

/*
 * 显式从 Root.plist 加载：不依赖 PSListController 的默认路径。
 * 默认路径在 bundle 懒加载场景下可能拿不到 specifiers（表现为点进去空白），
 * 这里兜底：先走默认，空了就显式读 Root.plist。
 */
- (NSArray *)specifiers
{
    NSArray *s = [super specifiers];
    if (s.count) return s;
    return [self loadSpecifiersFromPlistName:@"Root" target:self];
}

@end
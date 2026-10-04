#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

/* Preferences.framework 私有接口 */
@interface PSListController : UIViewController
@end

@interface PSSpecifier : NSObject
+ (id)groupSpecifierWithName:(NSString *)name;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target
        set:(SEL)set get:(SEL)get detail:(id)detail cell:(id)cell edit:(id)edit;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

#define OC_DOMAIN @"com.rna.onlycontacts"

/* 配置（读/写 jbroot 里的偏好 plist） */
static BOOL  cfg_enabled   = YES;
static int   cfg_mode      = 0;
static BOOL  cfg_repeat    = NO;
static int   cfg_window    = 180;
static int   cfg_minmatch  = 7;
static BOOL  cfg_noid      = YES;
static BOOL  cfg_restrict  = YES;
static BOOL  cfg_log       = YES;
#define OC_DEBUG_FILE @"/var/mobile/Documents/oc-prefs-debug.txt"

#pragma mark - jbroot

static NSString *OCPJbRoot(void)
{
    static NSString *jb = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *p = _dyld_get_image_name(i);
            if (!p) continue;
            NSString *path = [NSString stringWithUTF8String:p];
            NSRange r = [path rangeOfString:@"/.jbroot-"];
            if (r.location == NSNotFound) continue;
            NSRange rest = NSMakeRange(r.location + 1, path.length - r.location - 1);
            NSRange slash = [path rangeOfString:@"/" options:0 range:rest];
            jb = (slash.location == NSNotFound) ? path
                  : [path substringToIndex:slash.location];
            break;
        }
    });
    return jb;
}

#pragma mark - 配置读写

static NSArray *OCCandidates(void)
{
    NSString *jb = OCPJbRoot();
    NSString *rel = @"/var/mobile/Library/Preferences/com.rna.onlycontacts.plist";
    NSMutableArray *a = [NSMutableArray array];
    if (jb.length) {
        [a addObject:[jb stringByAppendingString:@"/private/var/mobile/Library/Preferences/com.rna.onlycontacts.plist"]];
        [a addObject:[jb stringByAppendingString:@"/var/mobile/Library/Preferences/com.rna.onlycontacts.plist"]];
    }
    [a addObject:rel];
    return a;
}

static NSMutableDictionary *OCLoadDict(void)
{
    for (NSString *p in OCCandidates()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) return [d mutableCopy];
    }
    return [NSMutableDictionary new];
}

static void OCSaveDict(NSMutableDictionary *d)
{
    for (NSString *p in OCCandidates()) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if ([NSFileManager.defaultManager isWritableFileAtPath:[p stringByDeletingLastPathComponent]]) {
            [d writeToFile:p atomically:YES];
            chown(p.UTF8String, 501, 501);
            return;
        }
    }
}

#pragma mark - 面板控制器

@interface OCRootListController : PSListController
@end

@implementation OCRootListController

- (id)valueForSpecifier:(PSSpecifier *)spec
{
    NSString *key = [spec propertyForKey:@"key"];
    if ([key isEqualToString:@"enabled"])       return @(cfg_enabled = [OCCfg(@"enabled", @YES) boolValue]);
    if ([key isEqualToString:@"mode"])          return @(cfg_mode = [OCCfg(@"mode", @0) intValue]);
    if ([key isEqualToString:@"allow_repeat"])  return @(cfg_repeat = [OCCfg(@"allow_repeat", @NO) boolValue]);
    if ([key isEqualToString:@"repeat_window"]) return @(cfg_window = [OCCfg(@"repeat_window", @180) intValue]);
    if ([key isEqualToString:@"min_match"])     return @(cfg_minmatch = [OCCfg(@"min_match", @7) intValue]);
    if ([key isEqualToString:@"allow_unknown_id"]) return @(cfg_noid = [OCCfg(@"allow_unknown_id", @YES) boolValue]);
    if ([key isEqualToString:@"restrict_gate"]) return @(cfg_restrict = [OCCfg(@"restrict_gate", @YES) boolValue]);
    if ([key isEqualToString:@"log"])           return @(cfg_log = [OCCfg(@"log", @YES) boolValue]);
    return nil;
}

- (void)setValue:(id)value forSpecifier:(PSSpecifier *)spec
{
    NSString *key = [spec propertyForKey:@"key"];
    if ([key isEqualToString:@"enabled"])            cfg_enabled  = [value boolValue];
    else if ([key isEqualToString:@"mode"])          cfg_mode     = [value intValue];
    else if ([key isEqualToString:@"allow_repeat"])  cfg_repeat   = [value boolValue];
    else if ([key isEqualToString:@"repeat_window"]) cfg_window   = [value intValue];
    else if ([key isEqualToString:@"min_match"])     cfg_minmatch = [value intValue];
    else if ([key isEqualToString:@"allow_unknown_id"]) cfg_noid = [value boolValue];
    else if ([key isEqualToString:@"restrict_gate"]) cfg_restrict = [value boolValue];
    else if ([key isEqualToString:@"log"])           cfg_log      = [value boolValue];
    OCSet(key, value);
}

- (NSArray *)specifiers
{
    NSMutableArray *specs = [NSMutableArray array];
    Class PSSpec  = objc_getClass("PSSpecifier");
    Class PSGroup = objc_getClass("PSGroupCell");
    Class PSSw    = objc_getClass("PSSwitchCell");
    Class PSEd    = objc_getClass("PSEditTextCell");
    Class PSLL    = objc_getClass("PSLinkListCell");
    if (!PSSpec || !PSGroup || !PSSw) return specs;

    SEL named = NSSelectorFromString(@"preferenceSpecifierNamed:target:set:get:detail:cell:edit:");
    SEL grp   = NSSelectorFromString(@"groupSpecifierWithName:");
    SEL prop  = NSSelectorFromString(@"setProperty:forKey:");
    SEL set   = NSSelectorFromString(@"setValue:forSpecifier:");
    SEL get   = NSSelectorFromString(@"valueForSpecifier:");

    /* ===== 来电 ===== */
    [specs addObject:((id (*)(id, SEL, id))objc_msgSend)(PSSpec, grp, @"来电")];
    [specs addObject:((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"只允许通讯录来电", self, set, get, (id)nil, PSSw, (id)nil)];

    id mode = ((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"拦截方式", self, set, get, (id)nil, PSLL, (id)nil);
    ((void (*)(id, SEL, id, id))objc_msgSend)(mode, prop,
        [NSArray arrayWithObjects:@0, @1, nil], @"validValues");
    ((void (*)(id, SEL, id, id))objc_msgSend)(mode, prop,
        [NSArray arrayWithObjects:@"打不进（对方被拒接）", @"只过滤不响铃", nil], @"validTitles");
    [specs addObject:mode];

    /* ===== 例外的放行 ===== */
    [specs addObject:((id (*)(id, SEL, id))objc_msgSend)(PSSpec, grp, @"例外的放行")];

    [specs addObject:((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"连打两次放行", self, set, get, (id)nil, PSSw, (id)nil)];
    [specs addObject:((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"放行窗口（秒）", self, set, get, (id)nil, PSEd ?: PSSw, (id)nil)];
    [specs addObject:((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"尾号匹配位数", self, set, get, (id)nil, PSEd ?: PSSw, (id)nil)];
    [specs addObject:((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"隐号/无号码时放行", self, set, get, (id)nil, PSSw, (id)nil)];

    /* ===== 高级 ===== */
    [specs addObject:((id (*)(id, SEL, id))objc_msgSend)(PSSpec, grp, @"高级")];

    [specs addObject:((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"真的拒接（对方听忙音）", self, set, get, (id)nil, PSSw, (id)nil)];
    [specs addObject:((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"写决策日志", self, set, get, (id)nil, PSSw, (id)nil)];

    return specs;
}

@end
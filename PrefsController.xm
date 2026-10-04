#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

/* Preferences.framework 私有接口（手写用到的部分） */
@interface PSListController : UIViewController
@end

@interface PSSpecifier : NSObject
+ (id)groupSpecifierWithName:(NSString *)name;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target
        set:(SEL)set get:(SEL)get detail:(id)detail cell:(id)cell edit:(id)edit;
- (void)setProperty:(id)property forKey:(NSString *)key;
@end

#define OC_DOMAIN @"com.rna.onlycontacts"

#pragma mark - jbroot

static NSString *OCPJbRoot(void)
{
    static NSString *jb = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/usr/lib/system/libdyld.dylib", RTLD_NOW);
        if (!h) h = dlopen(NULL, RTLD_NOW);
        if (!h) return;
        unsigned (*cnt)(void) = (unsigned (*)(void))dlsym(h, "_dyld_image_count");
        const char *(*nm)(unsigned) = (const char *(*)(unsigned))dlsym(h, "_dyld_get_image_name");
        if (!cnt || !nm) return;
        uint32_t n = cnt();
        for (uint32_t i = 0; i < n; i++) {
            const char *p = nm(i);
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

#pragma mark - 配置读写（jbroot 感知，与插件共用同一份）

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

static NSString *OCSaveDict(NSMutableDictionary *d)
{
    for (NSString *p in OCCandidates()) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if ([NSFileManager.defaultManager isWritableFileAtPath:[p stringByDeletingLastPathComponent]]) {
            [d writeToFile:p atomically:YES];
            chown(p.UTF8String, 501, 501);
            return p;
        }
    }
    return nil;
}

static id OCCfg(NSString *key, id def)
{
    id v = OCLoadDict()[key];
    return v ?: def;
}

static void OCSet(NSString *key, id v)
{
    NSMutableDictionary *d = OCLoadDict();
    d[key] = v;
    OCSaveDict(d);
}

#pragma mark - 面板控制器

@interface OCRootListController : PSListController
@end

@implementation OCRootListController

/* 面板值直接读写配置文件（不走 defaults 域，保证和插件看到的是同一份） */

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
    else return;

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

    #define ADDSPEC(name_, cell_, key_) \
        id s_ = ((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)( \
            PSSpec, named, name_, self, \
            NSSelectorFromString(@"setValue:forSpecifier:"), \
            NSSelectorFromString(@"valueForSpecifier:"), \
            (id)nil, cell_, (id)nil); \
        ((void (*)(id, SEL, id, id))objc_msgSend)(s_, prop, key_, @"key"); \
        [specs addObject:s_];

    /* ===== 来电 ===== */
    [specs addObject:((id (*)(id, SEL, id))objc_msgSend)(PSSpec, grp, @"来电")];

    ADDSPEC(@"只允许通讯录来电", PSSw, @"enabled")

    id mode = ((id (*)(id, SEL, NSString *, id, SEL, SEL, id, id, id))objc_msgSend)(
        PSSpec, named, @"拦截方式", self,
        NSSelectorFromString(@"setValue:forSpecifier:"),
        NSSelectorFromString(@"valueForSpecifier:"), (id)nil, PSLL, (id)nil);
    ((void (*)(id, SEL, id, id))objc_msgSend)(mode, prop, @"mode", @"key");
    ((void (*)(id, SEL, id, id))objc_msgSend)(mode, prop,
        [NSArray arrayWithObjects:@0, @1, nil], @"validValues");
    ((void (*)(id, SEL, id, id))objc_msgSend)(mode, prop,
        [NSArray arrayWithObjects:@"打不进（对方被拒接）", @"只过滤不响铃", nil], @"validTitles");
    [specs addObject:mode];

    /* ===== 例外的放行 ===== */
    [specs addObject:((id (*)(id, SEL, id))objc_msgSend)(PSSpec, grp, @"例外的放行")];

    ADDSPEC(@"连打两次放行", PSSw, @"allow_repeat")
    ADDSPEC(@"放行窗口（秒）", PSEd ?: PSSw, @"repeat_window")
    ADDSPEC(@"尾号匹配位数", PSEd ?: PSSw, @"min_match")
    ADDSPEC(@"隐号/无号码时放行", PSSw, @"allow_unknown_id")

    /* ===== 高级 ===== */
    [specs addObject:((id (*)(id, SEL, id))objc_msgSend)(PSSpec, grp, @"高级")];

    ADDSPEC(@"真的拒接（对方听忙音）", PSSw, @"restrict_gate")
    ADDSPEC(@"写决策日志", PSSw, @"log")

    return specs;
}

@end
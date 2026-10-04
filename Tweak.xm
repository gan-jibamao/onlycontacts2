#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>

#define OC_DOMAIN @"com.rna.onlycontacts"

/* callservicesd 私有类（只声明我们用到的部分） */
@interface CSDCall : NSObject
@property (nonatomic, readonly, strong) id handle;
@end

@interface CSDCallFilterController : NSObject
@property (readonly, nonatomic) NSMutableArray *filters;
@end

#pragma mark - jbroot（roothide 的越狱根，从已加载映像的路径反推）

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

/* 同一个逻辑文件的几个候选落点（roothide 会把 /var/mobile 的偏好重定向进 jbroot） */
static NSArray *OCConfigCandidates(void)
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

#pragma mark - 配置

static BOOL  cfg_enabled   = YES;
static int   cfg_mode      = 0;      /* 0=block 1=silence */
static BOOL  cfg_repeat    = NO;
static int   cfg_window    = 180;
static int   cfg_minmatch  = 7;
static BOOL  cfg_noid      = YES;
static BOOL  cfg_restrict  = YES;
static BOOL  cfg_log       = YES;

static void OCReloadConfig(void)
{
    for (NSString *p in OCConfigCandidates()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d.count) continue;
        cfg_enabled  = d[@"enabled"]           ? [d[@"enabled"] boolValue]        : YES;
        cfg_mode     = d[@"mode"]              ? [d[@"mode"] intValue]            : 0;
        cfg_repeat   = d[@"allow_repeat"]      ? [d[@"allow_repeat"] boolValue]   : NO;
        cfg_window   = d[@"repeat_window"]     ? [d[@"repeat_window"] intValue]   : 180;
        cfg_minmatch = d[@"min_match"]         ? [d[@"min_match"] intValue]       : 7;
        cfg_noid     = d[@"allow_unknown_id"]  ? [d[@"allow_unknown_id"] boolValue] : YES;
        cfg_restrict = d[@"restrict_gate"]     ? [d[@"restrict_gate"] boolValue]  : YES;
        cfg_log      = d[@"log"]               ? [d[@"log"] boolValue]            : YES;
        if (cfg_minmatch < 4)  cfg_minmatch = 4;
        if (cfg_minmatch > 15) cfg_minmatch = 15;
        return;
    }
}

static void OCMaybeReloadConfig(void)
{
    static NSDate *last;
    if (!last || -[last timeIntervalSinceNow] >= 2.0) {
        OCReloadConfig();
        last = [NSDate date];
    }
}

#pragma mark - 号码

static NSString *OCDigits(NSString *in)
{
    if (!in) return @"";
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < in.length; i++) {
        unichar c = [in characterAtIndex:i];
        if (c >= '0' && c <= '9') [out appendFormat:@"%C", c];
    }
    if (out.length > 4 && [out hasPrefix:@"00"]) [out deleteCharactersInRange:NSMakeRange(0, 2)];
    return out;
}

static BOOL OCIsShortCode(NSString *d)
{
    return d.length <= 5;        /* 短号/急呼一律放行 */
}

/* 尾号匹配：两侧较短的一边 ≥ minMatch 位且尾部相同 */
static BOOL OCMatch(NSString *a, NSString *b, int minMatch)
{
    if (!a.length || !b.length) return NO;
    NSUInteger k = MIN(a.length, b.length);
    if ((int)k < minMatch) return NO;
    return [a compare:b options:NSBackwardsSearch range:NSMakeRange(a.length - k, k)] == NSOrderedSame;
}

#pragma mark - 白名单（直读通讯录库）

static NSArray *oc_wl;
static BOOL oc_wl_loaded = NO;

static void OCReloadWhitelist(void)
{
    NSMutableArray *out = [NSMutableArray array];
    NSString *jb = OCPJbRoot();
    NSMutableArray *dbs = [NSMutableArray arrayWithObject:
        @"/var/mobile/Library/AddressBook/AddressBook.sqlitedb"];
    if (jb.length) [dbs addObject:[jb stringByAppendingString:@"/var/mobile/Library/AddressBook/AddressBook.sqlitedb"]];
    for (NSString *db in dbs) {
        sqlite3 *h = NULL;
        if (sqlite3_open_v2(db.UTF8String, &h, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            if (h) sqlite3_close(h);
            continue;
        }
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(h, "SELECT value FROM ABMultiValue WHERE property=3", -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                const unsigned char *v = sqlite3_column_text(st, 0);
                NSString *d = OCDigits(v ? [NSString stringWithUTF8String:(const char *)v] : @"");
                if (d.length > 5) [out addObject:d];
            }
            sqlite3_finalize(st);
        }
        sqlite3_close(h);
        if (out.count) break;
    }
    oc_wl = out;
    oc_wl_loaded = YES;
}

static void OCMaybeReloadWhitelist(BOOL force)
{
    static NSDate *last;
    if (force || !last || -[last timeIntervalSinceNow] >= 300.0) {
        OCReloadWhitelist();
        last = [NSDate date];
    }
}

#pragma mark - 重复来电窗口

static NSMutableDictionary *oc_ring;

static BOOL OCSeenRecently(NSString *d)
{
    NSDate *t = oc_ring[d];
    return t && -[t timeIntervalSinceNow] <= cfg_window;
}

#pragma mark - 日志

static NSDateFormatter *OCDateFormatter(void)
{
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
    });
    return df;
}

static NSString *OCLogPath(void)
{
    NSString *jb = OCPJbRoot();
    NSString *rel = @"/var/mobile/Library/Logs/onlycontacts.log";
    if (jb.length) {
        NSString *p = [jb stringByAppendingString:rel];
        if ([[NSFileManager defaultManager] isWritableFileAtPath:[p stringByDeletingLastPathComponent]] ||
            [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:nil])
            return p;
    }
    return rel;
}

static void OCLog(NSString *fmt, ...)
{
    if (!cfg_log) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *path = OCLogPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (attr && [attr fileSize] > 512 * 1024) [NSFileManager.defaultManager removeItemAtPath:path error:nil];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (!fh) return;
    [fh seekToEndOfFile];
    [fh writeData:[[NSString stringWithFormat:@"%@|%@\n", [OCDateFormatter() stringFromDate:[NSDate date]], body]
                   dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#pragma mark - 判定

/* 系统自己的通讯录匹配：过滤器链里的 CSDContactsCallFilter -isUnknownCall: */
static BOOL OCSysUnknown(CSDCallFilterController *controller, id call)
{
    SEL sel = NSSelectorFromString(@"isUnknownCall:");
    for (id f in controller.filters)
        if ([f respondsToSelector:sel])
            return ((BOOL (*)(id, SEL, id))objc_msgSend)(f, sel, call);
    return NO;   /* 问不到就当已知，交给白名单兜底 */
}

#pragma mark - Hook

%hook CSDCallFilterController

- (BOOL)shouldFilterIncomingCall:(CSDCall *)call
{
    @try {
        OCMaybeReloadConfig();
        if (!cfg_enabled) return %orig;
        OCMaybeReloadWhitelist(NO);

        NSString *raw = nil;
        @try { raw = [[call handle] value]; } @catch (id e) { raw = nil; }
        NSString *d = OCDigits(raw);

        if (d.length <= 5) return %orig;                     /* 短号/急呼放行 */

        BOOL known = NO;
        if (oc_wl_loaded)
            for (NSString *c in oc_wl)
                if (OCMatch(c, d, cfg_minmatch)) { known = YES; break; }
        if (!known && !OCSysUnknown(self, call)) known = YES;  /* 系统说认识 */

        if (known) return %orig;
        if (cfg_repeat && OCSeenRecently(d)) {
            OCLog(@"REP|%@ 窗口内重复来电，放行", d);
            return %orig;
        }
        oc_ring[d] = [NSDate date];
        OCLog(@"BLK|%@ 不在通讯录 → 过滤（mode=%d）", d, cfg_mode);
        return YES;
    } @catch (NSException *e) {
        OCLog(@"ERR|%@", e);
        return %orig;
    }
}

%end

%ctor {
    oc_ring = [NSMutableDictionary new];
    OCReloadConfig();
    OCMaybeReloadWhitelist(YES);
    OCLog(@"BOOT|OnlyContacts 2.0 pid=%d proc=%s wl=%lu", getpid(), getprogname(),
          (unsigned long)(oc_wl ? oc_wl.count : 0));
    %init;
}

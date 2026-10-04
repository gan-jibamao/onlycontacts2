#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define OC_DOMAIN @"com.rna.onlycontacts"

@interface CSDCall : NSObject
@property (nonatomic, readonly, strong) id handle;
@end

@interface CSDCallFilterController : NSObject
@property (readonly, nonatomic) NSMutableArray *filters;
@end

#pragma mark - jbroot（从已加载映像的路径反推）

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

#pragma mark - 配置

static BOOL  cfg_enabled   = YES;
static int   cfg_mode      = 0;
static BOOL  cfg_repeat    = NO;
static int   cfg_window    = 180;
static int   cfg_minmatch  = 7;
static BOOL  cfg_noid      = YES;
static BOOL  cfg_restrict  = YES;
static BOOL  cfg_log       = YES;

static void OCApplyConfig(NSDictionary *d)
{
    if (!d.count) return;
    cfg_enabled  = d[@"enabled"]           ? [d[@"enabled"] boolValue]          : YES;
    cfg_mode     = d[@"mode"]              ? [d[@"mode"] intValue]              : 0;
    cfg_repeat   = d[@"allow_repeat"]      ? [d[@"allow_repeat"] boolValue]     : NO;
    cfg_window   = d[@"repeat_window"]     ? [d[@"repeat_window"] intValue]     : 180;
    cfg_minmatch = d[@"min_match"]         ? [d[@"min_match"] intValue]         : 7;
    cfg_noid     = d[@"allow_unknown_id"]  ? [d[@"allow_unknown_id"] boolValue] : YES;
    cfg_restrict = d[@"restrict_gate"]     ? [d[@"restrict_gate"] boolValue]    : YES;
    cfg_log      = d[@"log"]               ? [d[@"log"] boolValue]              : YES;
    if (cfg_minmatch < 4)  cfg_minmatch = 4;
    if (cfg_minmatch > 15) cfg_minmatch = 15;
}

static void OCReloadConfig(void)
{
    NSString *jb = OCPJbRoot();
    NSString *rel = @"/var/mobile/Library/Preferences/com.rna.onlycontacts.plist";
    NSMutableArray *c = [NSMutableArray array];
    if (jb.length) {
        [c addObject:[jb stringByAppendingString:@"/private/var/mobile/Library/Preferences/com.rna.onlycontacts.plist"]];
        [c addObject:[jb stringByAppendingString:@"/var/mobile/Library/Preferences/com.rna.onlycontacts.plist"]];
    }
    [c addObject:rel];
    for (NSString *p in c) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d.count) continue;
        OCApplyConfig(d);
        return;
    }
}

static void OCMaybeReloadConfig(void)
{
    static NSDate *last;
    static BOOL busy;
    if (last && -[last timeIntervalSinceNow] < 2.0) return;
    if (busy) return;
    last = [NSDate date];
    busy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OCReloadConfig();
        busy = NO;
    });
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

#pragma mark - 白名单

static NSArray *oc_wl;
static NSSet   *oc_wl_tail;
static NSSet   *oc_wl_full;
static int      oc_wl_built_with = -1;
static BOOL     oc_wl_loaded = NO;

static void OCReloadWhitelist(void)
{
    NSMutableArray *out = [NSMutableArray array];
    NSString *jb = OCPJbRoot();
    NSMutableArray *dbs = [NSMutableArray arrayWithObject:
        @"/var/mobile/Library/AddressBook/AddressBook.sqlitedb"];
    if (jb.length)
        [dbs addObject:[jb stringByAppendingString:@"/var/mobile/Library/AddressBook/AddressBook.sqlitedb"]];
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
    oc_wl_built_with = -1;
}

static BOOL OCInWhitelist(NSString *d)
{
    if (!oc_wl_loaded || !d.length) return NO;
    if ([oc_wl_full containsObject:d]) return YES;
    if ((int)d.length < cfg_minmatch) return NO;
    if (oc_wl_built_with != cfg_minmatch) {
        NSMutableSet *t = [NSMutableSet set];
        NSMutableSet *f = [NSMutableSet set];
        for (NSString *c in oc_wl) {
            [f addObject:c];
            if ((int)c.length >= cfg_minmatch)
                [t addObject:[c substringFromIndex:c.length - cfg_minmatch]];
        }
        oc_wl_tail = t;
        oc_wl_full = f;
        oc_wl_built_with = cfg_minmatch;
    }
    return [oc_wl_tail containsObject:[d substringFromIndex:d.length - cfg_minmatch]];
}

static void OCMaybeReloadWhitelist(BOOL force)
{
    static NSDate *last;
    static BOOL busy;
    if (!force && last && -[last timeIntervalSinceNow] < 300.0) return;
    if (busy) return;
    last = [NSDate date];
    busy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OCReloadWhitelist();
        busy = NO;
    });
}

#pragma mark - 重复来电窗口

static NSMutableDictionary *oc_ring;

static BOOL OCSeenRecently(NSString *d)
{
    NSDate *t = nil;
    @synchronized (oc_ring) { t = oc_ring[d]; }
    return t && -[t timeIntervalSinceNow] <= cfg_window;
}

static void OCMarkSeen(NSString *d)
{
    if (!d.length) return;
    @synchronized (oc_ring) {
        oc_ring[d] = [NSDate date];
        if (oc_ring.count > 128) {
            NSString *oldest = nil;
            NSDate *oldestT = nil;
            for (NSString *k in oc_ring) {
                NSDate *t = oc_ring[k];
                if (!oldestT || [t compare:oldestT] == NSOrderedAscending) { oldest = k; oldestT = t; }
            }
            if (oldest) [oc_ring removeObjectForKey:oldest];
        }
    }
}

#pragma mark - 日志（多落点 + 后台串行）

static dispatch_queue_t oc_logq;
static NSDateFormatter *oc_df;
static NSArray *oc_log_paths;

static void OCLogInitPaths(void)
{
    NSString *jb = OCPJbRoot();
    NSMutableArray *a = [NSMutableArray array];
    NSString *rel = @"/var/mobile/Library/Logs/onlycontacts.log";
    if (jb.length) {
        [a addObject:[jb stringByAppendingString:@"/private/var/mobile/Library/Logs/onlycontacts.log"]];
        [a addObject:[jb stringByAppendingString:@"/var/mobile/Library/Logs/onlycontacts.log"]];
    }
    [a addObject:rel];
    [a addObject:@"/var/mobile/Documents/onlycontacts.log"];
    oc_log_paths = a;
}

static void OCLog(NSString *fmt, ...)
{
    if (!oc_logq) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    dispatch_async(oc_logq, ^{
        for (NSString *p in oc_log_paths) {
            [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                [NSFileManager.defaultManager createFileAtPath:p contents:nil attributes:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:p];
            }
            if (!fh) continue;
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"%@|%@\n",
                            [oc_df stringFromDate:[NSDate date]], body] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    });
}

#pragma mark - 系统通讯录匹配

static id oc_cfilter;

static BOOL OCSysUnknown(CSDCallFilterController *controller, id call)
{
    SEL sel = NSSelectorFromString(@"isUnknownCall:");
    if (!oc_cfilter) {
        for (id f in controller.filters)
            if ([f respondsToSelector:sel]) { oc_cfilter = f; break; }
    }
    if (!oc_cfilter) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(oc_cfilter, sel, call);
}

#pragma mark - 主闸门（保留拦截逻辑）

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

        if (d.length <= 5) return %orig;

        BOOL known = OCInWhitelist(d);
        if (!known && !OCSysUnknown(self, call)) known = YES;

        if (known) return %orig;
        if (cfg_repeat && OCSeenRecently(d)) {
            OCLog(@"REP|%@ 窗口内重复来电，放行", d);
            return %orig;
        }
        OCMarkSeen(d);
        OCLog(@"BLK|%@ 主闸门拦截", d);
        return YES;
    } @catch (NSException *e) {
        OCLog(@"ERR|main %@", e);
        return %orig;
    }
}

/* restrict 闸门：10 秒护栏内真拒接 */
- (BOOL)shouldRestrictAddresses:(NSArray *)addresses
          forBundleIdentifier:(NSString *)bundle
       performSynchronously:(BOOL)sync
{
    @try {
        OCLog(@"DIAG|CTRL.shouldRestrict n=%lu bundle=%@", (unsigned long)addresses.count, bundle);
        if (!cfg_enabled || !cfg_restrict) return %orig;
        OCMaybeReloadWhitelist(NO);
        if (!oc_wl_loaded) return %orig;
        for (id a in addresses) {
            NSString *d = OCDigits([a respondsToSelector:@selector(value)] ? [a value] : a);
            if (!d.length || d.length <= 5) continue;
            if (OCInWhitelist(d)) continue;
            if (!OCSeenRecently(d)) continue;
            OCLog(@"RST|%@ 真被拒接", d);
            return YES;
        }
        return %orig;
    } @catch (NSException *e) {
        return %orig;
    }
}

/* 诊断：系统自己的判定 */
- (BOOL)isUnknownCall:(CSDCall *)call
{
    BOOL r = %orig;
    NSString *d = OCDigits([[call handle] value]);
    OCLog(@"DIAG|CTRL.isUnknown(%@)=%d mywl=%d", d, r, OCInWhitelist(d) ? 1 : 0);
    return r;
}

%end

/* ---------- 空段（诊断网已移除，主闸门在上面） ---------- */

%ctor {
    oc_ring = [NSMutableDictionary new];
    oc_df   = [NSDateFormatter new];
    oc_df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    oc_df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
    oc_logq = dispatch_queue_create("com.rna.onlycontacts.log", DISPATCH_QUEUE_SERIAL);
    OCLogInitPaths();
    OCReloadConfig();
    OCMaybeReloadWhitelist(YES);
    OCLog(@"BOOT|2.1-diag pid=%d proc=%s jbroot=%@ wl=%lu",
          getpid(), getprogname(), OCPJbRoot() ?: @"(none)",
          (unsigned long)(oc_wl ? oc_wl.count : 0));
    %init;
}
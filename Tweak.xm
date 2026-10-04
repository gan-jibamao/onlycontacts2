#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

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
    for (NSString *p in OCConfigCandidates()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d.count) continue;
        OCApplyConfig(d);
        return;
    }
}

/* 过期就丢后台重读，主路径永不阻塞 */
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

#pragma mark - 白名单（直读通讯录库 + 尾号索引 O(1)）

static NSArray *oc_wl;                  /* 原始号码（诊断用） */
static NSSet   *oc_wl_tail;             /* 末 minmatch 位索引 */
static NSSet   *oc_wl_full;             /* 全号精确匹配（兜住比 minmatch 还短的联系人号码） */
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
    oc_wl_built_with = -1;   /* 让索引按当前 minmatch 重建 */
}

/* O(1) 查询：尾号索引 + 全号精确匹配（兜住比 minmatch 还短的联系人号码） */
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

#pragma mark - 重复来电窗口（线程安全 + 有上限）

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
        if (oc_ring.count > 128) {                  /* 有上限，不泄漏 */
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

#pragma mark - 日志（后台串行写，不占来电路径）

static dispatch_queue_t oc_logq;
static NSDateFormatter *oc_df;
static NSString *oc_log_path;

static void OCLogInit(void)
{
    NSString *jb = OCPJbRoot();
    NSString *rel = @"/var/mobile/Library/Logs/onlycontacts.log";
    if (jb.length) {
        NSString *p = [jb stringByAppendingString:rel];
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if ([NSFileManager.defaultManager isWritableFileAtPath:[p stringByDeletingLastPathComponent]])
            oc_log_path = p;
    }
    if (!oc_log_path) oc_log_path = rel;
}

static void OCLog(NSString *fmt, ...)
{
    if (!cfg_log || !oc_logq) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    dispatch_async(oc_logq, ^{
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:oc_log_path];
        if (!fh) {
            [[NSFileManager defaultManager] createDirectoryAtPath:[oc_log_path stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            [NSFileManager.defaultManager createFileAtPath:oc_log_path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:oc_log_path];
        }
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:[[NSString stringWithFormat:@"%@|%@\n", [oc_df stringFromDate:[NSDate date]], body]
                       dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
        NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:oc_log_path error:nil];
        if (attr && [attr fileSize] > 512 * 1024) {
            [fh closeFile];
            [NSFileManager.defaultManager removeItemAtPath:oc_log_path error:nil];
        }
    });
}

#pragma mark - 系统通讯录匹配（缓存过滤器对象）

static id oc_cfilter;   /* CSDContactsCallFilter，找到一次就缓存 */

static BOOL OCSysUnknown(CSDCallFilterController *controller, id call)
{
    SEL sel = NSSelectorFromString(@"isUnknownCall:");
    if (!oc_cfilter) {
        for (id f in controller.filters)
            if ([f respondsToSelector:sel]) { oc_cfilter = f; break; }
    }
    if (!oc_cfilter) return NO;              /* 问不到 → 交给白名单兜底 */
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(oc_cfilter, sel, call);
}

#pragma mark - Hook

%hook CSDCallFilterController

/* 主闸门：陌生号码不响铃、不进通话 */
- (BOOL)shouldFilterIncomingCall:(CSDCall *)call
{
    @try {
        OCMaybeReloadConfig();
        if (!cfg_enabled) return %orig;
        OCMaybeReloadWhitelist(NO);

        NSString *raw = nil;
        @try { raw = [[call handle] value]; } @catch (id e) { raw = nil; }
        NSString *d = OCDigits(raw);

        if (d.length <= 5) return %orig;                 /* 短号/急呼一律放行 */

        BOOL known = OCInWhitelist(d);
        if (!known && !OCSysUnknown(self, call)) known = YES;   /* 系统说认识 */

        if (known) return %orig;
        if (cfg_repeat && OCSeenRecently(d)) {
            OCLog(@"REP|%@ 窗口内重复来电，放行", d);
            return %orig;
        }
        OCMarkSeen(d);
        OCLog(@"BLK|%@ 不在通讯录 → 过滤（mode=%d）", d, cfg_mode);
        return YES;
    } @catch (NSException *e) {
        OCLog(@"ERR|%@", e);
        return %orig;
    }
}

/*
 * restrict 闸门：让陌生号码**真的被拒接**（对方听忙音），不只是不响铃。
 * 安全护栏：只有 10 秒内真的打进来过的号码才允许被拒接——你回拨陌生号码不会被误伤。
 */
- (BOOL)shouldRestrictAddresses:(NSArray *)addresses
          forBundleIdentifier:(NSString *)bundle
       performSynchronously:(BOOL)sync
{
    @try {
        if (!cfg_enabled || !cfg_restrict) return %orig;
        OCMaybeReloadWhitelist(NO);
        if (!oc_wl_loaded) return %orig;

        for (id a in addresses) {
            NSString *d = OCDigits([a respondsToSelector:@selector(value)] ? [a value] : a);
            if (!d.length || d.length <= 5) continue;    /* 急呼不拦 */
            if (OCInWhitelist(d)) continue;
            if (!OCSeenRecently(d)) continue;            /* 不是刚打进来的，不拒 */
            OCLog(@"RST|%@ 真被拒接（对方听忙音）", d);
            return YES;
        }
        return %orig;
    } @catch (NSException *e) {
        return %orig;
    }
}

%end

%ctor {
    oc_ring = [NSMutableDictionary new];
    oc_df   = [NSDateFormatter new];
    oc_df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    oc_df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
    oc_logq = dispatch_queue_create("com.rna.onlycontacts.log", DISPATCH_QUEUE_SERIAL);
    OCLogInit();
    OCReloadConfig();
    OCMaybeReloadWhitelist(YES);
    OCLog(@"BOOT|OnlyContacts 2.0.1 pid=%d proc=%s wl=%lu", getpid(), getprogname(),
          (unsigned long)(oc_wl ? oc_wl.count : 0));
    %init;
}
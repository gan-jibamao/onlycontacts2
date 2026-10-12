//
//  OCPrefPath.h — OnlyContacts 共享偏好路径解析（注入 dylib 与设置面板共用同一份）
//
//  严格遵循 RootHide 偏好规范：
//   · 首选当前隐根：.../Shared/AppGroup/.jbroot-<UUID>/var/mobile/Library/Preferences/<id>.plist
//   · 动态扫描全部 .jbroot-*；优先"包含本插件 dylib"的根，其次越狱根特征，同分取 mtime 最新。
//     严禁硬编码 UUID。
//   · 进程内以已加载映像（路径含 /.jbroot-）兜底反推隐根。
//   · 无隐根时：rootless(/var/jb) 优先，最后落真实 /var/mobile 路径。
//   · 首次运行 / UUID 变化时迁移最新旧副本进当前隐根，并清理其余副本（保留在用副本）。
//
#ifndef OCPREF_PATH_H
#define OCPREF_PATH_H

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <unistd.h>

/* 运行时字符串构造：规避 RootHide 对静态 __cfstring 的重映射（SIGBUS 防护）。
   与 CPUthermal 面板（同设备已验证）同款防御：凡是路径/通知/域名串，
   一律 C 字符串 + runtime 构造，不落静态 __CFString。 */
#ifndef OC_S
#define OC_S(str) [NSString stringWithUTF8String:(str)]
#endif

#define OC_PREFS_FILENAME   OC_S("com.rna.onlycontacts.plist")
#define OC_DYLIB_REL_PATH   OC_S("Library/MobileSubstrate/DynamicLibraries/OnlyContacts.dylib")
#define OC_PREFS_REAL_PATH  OC_S("/var/mobile/Library/Preferences/com.rna.onlycontacts.plist")
#define OC_PREFS_JB_REL     OC_S("var/mobile/Library/Preferences/com.rna.onlycontacts.plist")

#pragma mark - 隐根发现

/* 进程内从已加载映像的路径反推隐根（含 "/.jbroot-" 的路径，截到 UUID 段） */
static inline NSString *OCPathFromDyld(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p) continue;
        NSString *path = [NSString stringWithUTF8String:p];
        NSRange r = [path rangeOfString:OC_S("/.jbroot-")];
        if (r.location == NSNotFound) continue;
        NSRange rest = NSMakeRange(r.location + 1, path.length - r.location - 1);
        NSRange slash = [path rangeOfString:OC_S("/") options:0 range:rest];
        return (slash.location == NSNotFound) ? path
                                              : [path substringToIndex:slash.location];
    }
    return nil;
}

/* 扫描 AppGroup 下全部 .jbroot-*，按（含dylib > 越狱特征 > mtime新）排序 */
static inline NSArray *OCScanJbrootDirs(void) {
    NSMutableArray *dirs = [NSMutableArray array];
    NSMutableDictionary *score = [NSMutableDictionary dictionary];
    NSMutableDictionary *mtime = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSArray *subs = [fm contentsOfDirectoryAtPath:OC_S("/var/mobile/Containers/Shared/AppGroup") error:nil];
    for (NSString *s in subs) {
        if (![s hasPrefix:OC_S(".jbroot-")]) continue;
        NSString *root = [OC_S("/var/mobile/Containers/Shared/AppGroup") stringByAppendingPathComponent:s];
        long sc = 0;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:OC_DYLIB_REL_PATH]]) sc += 100;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:OC_S("Library/MobileSubstrate")]]) sc += 10;
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:OC_S("usr/lib")]]) sc += 5;
        [dirs addObject:root];
        score[root] = @(sc);
        NSDictionary *attr = [fm attributesOfItemAtPath:root error:nil];
        mtime[root] = attr[NSFileModificationDate] ?: [NSDate distantPast];
    }
    NSString *fromDyld = OCPathFromDyld();
    if (fromDyld.length && [dirs indexOfObject:fromDyld] == NSNotFound) {
        [dirs addObject:fromDyld];
        score[fromDyld] = @1000;   /* 本进程实际加载的根，最可信，永远置顶 */
        mtime[fromDyld] = [NSDate distantPast];
    } else if (fromDyld.length) {
        score[fromDyld] = @1000;   /* 已在列表里也升到最高分 */
    }

    NSMutableArray *sorted = [NSMutableArray array];
    for (NSString *d in dirs) {
        NSUInteger ins = sorted.count;
        for (NSUInteger i = 0; i < sorted.count; i++) {
            NSString *cur = sorted[i];
            long s1 = [score[d] longValue], s2 = [score[cur] longValue];
            if (s1 > s2 ||
                (s1 == s2 && [(NSDate *)mtime[d] compare:(NSDate *)mtime[cur]] == NSOrderedDescending)) {
                ins = i; break;
            }
        }
        [sorted insertObject:d atIndex:ins];
    }
    return sorted;
}

/* 当前隐根（无则 nil） */
static inline NSString *OCJbrootDir(void) {
    NSArray *dirs = OCScanJbrootDirs();
    return dirs.count ? dirs[0] : nil;
}

#pragma mark - 路径候选

/* 读候选：全部隐根 var / private-var → /var/jb → 真实路径 */
static inline NSArray *OCPrefReadPaths(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *jb in OCScanJbrootDirs()) {
        [a addObject:[jb stringByAppendingPathComponent:OC_PREFS_JB_REL]];
        [a addObject:[jb stringByAppendingPathComponent:OC_S("private/var/mobile/Library/Preferences/com.rna.onlycontacts.plist")]];
    }
    [a addObject:[OC_S("/var/jb") stringByAppendingPathComponent:OC_PREFS_JB_REL]];
    [a addObject:OC_S("/var/jb/private/var/mobile/Library/Preferences/com.rna.onlycontacts.plist")];
    [a addObject:OC_PREFS_REAL_PATH];
    return a;
}

/* 写候选（按优先级）：当前隐根 → /var/jb（存在时） → 真实路径 */
static inline NSArray *OCWritePrefPaths(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *jb = OCJbrootDir();
    if (jb.length)
        [a addObject:[jb stringByAppendingPathComponent:OC_PREFS_JB_REL]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:OC_S("/var/jb")])
        [a addObject:[OC_S("/var/jb") stringByAppendingPathComponent:OC_PREFS_JB_REL]];
    [a addObject:OC_PREFS_REAL_PATH];
    return a;
}

/* 首选写目标 */
static inline NSString *OCWritePrefPath(void) {
    NSArray *a = OCWritePrefPaths();
    return a.count ? a[0] : OC_PREFS_REAL_PATH;
}

#pragma mark - 读写

/* 单次写盘（建目录 + 原子写 + 尽量修正属主） */
static inline BOOL OCWriteDictToPath(NSDictionary *d, NSString *path) {
    if (!d || !path.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil])
            return NO;
    }
    if (![d writeToFile:path atomically:YES]) return NO;
    chown(path.fileSystemRepresentation, 501, 501);   /* 失败无妨 */
    return YES;
}

/* 读：首个非空副本（正常即当前隐根那份） */
static inline NSMutableDictionary *OCLoadPrefsDict(void) {
    for (NSString *p in OCPrefReadPaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) return [d mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}

/* 写：按候选依次尝试。返回真正写入的路径（失败 nil） */
static inline NSString *OCSavePrefsDict(NSDictionary *d) {
    for (NSString *p in OCWritePrefPaths()) {
        if (OCWriteDictToPath(d, p)) return p;
    }
    return nil;
}

/* 清理副本：保留正在使用的那一份，删除其余同名配置 */
static inline void OCCleanupDupPrefs(NSString *keepPath) {
    if (!keepPath.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in OCPrefReadPaths()) {
        if ([p isEqualToString:keepPath]) continue;
        if ([fm fileExistsAtPath:p]) [fm removeItemAtPath:p error:nil];
    }
}

/* 迁移：把"最新"的旧副本原样搬进当前隐根（首次运行 / UUID 变化），随后清理其余副本 */
static inline void OCMigratePrefs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *writePath = OCWritePrefPath();

    NSString *newest = nil;
    NSDate *newestDate = nil;
    for (NSString *p in OCPrefReadPaths()) {
        NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
        if (!attr) continue;
        NSDate *m = attr[NSFileModificationDate] ?: [NSDate distantPast];
        if (!newest || [m compare:newestDate] == NSOrderedDescending) {
            newest = p; newestDate = m;
        }
    }
    if (!newest) return;             /* 全新用户：无历史副本 */

    NSDictionary *newestDict = [NSDictionary dictionaryWithContentsOfFile:newest];
    if (!newestDict.count) return;

    NSString *kept = writePath;
    NSDictionary *writeAttr = [fm attributesOfItemAtPath:writePath error:nil];
    BOOL need = YES;
    if (writeAttr) {
        NSDate *wm = writeAttr[NSFileModificationDate] ?: [NSDate distantPast];
        if ([wm compare:newestDate] != NSOrderedAscending) need = NO;   /* 目标已不落后 */
    }
    if (need) {
        NSString *written = OCSavePrefsDict(newestDict);
        if (!written.length) return;  /* 写失败：保留全部副本，绝不误删 */
        kept = written;
    }
    /* 仅 RootHide 模式（存在 .jbroot-*）清理其余副本；rootless 保持原逻辑不动 */
    if (OCJbrootDir().length) {
        OCCleanupDupPrefs(kept);
    }
}

#pragma mark - 通用路径解析（通讯录库、日志等）

/* 给定相对路径（如 var/mobile/Library/AddressBook/AddressBook.sqlitedb），生成读取候选：
   全部隐根（含 private/var 变体） → /var/jb（存在时） → 真实根 */
static inline NSArray *OCResolvePaths(NSString *rel) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *jb in OCScanJbrootDirs()) {
        [a addObject:[jb stringByAppendingPathComponent:rel]];
        [a addObject:[jb stringByAppendingPathComponent:[OC_S("private/") stringByAppendingString:rel]]];
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:OC_S("/var/jb")]) {
        [a addObject:[OC_S("/var/jb") stringByAppendingPathComponent:rel]];
        [a addObject:[OC_S("/var/jb") stringByAppendingPathComponent:[OC_S("private/") stringByAppendingString:rel]]];
    }
    [a addObject:[OC_S("/") stringByAppendingPathComponent:rel]];
    return a;
}

#endif /* OCPREF_PATH_H */

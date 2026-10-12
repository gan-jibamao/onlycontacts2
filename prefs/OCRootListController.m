//
//  OCRootListController.m — OnlyContacts 3.1.0 设置面板
//
//  重构要点（相对 3.0.0，对症「面板不显示/空白」）：
//   1. specifiers 官方缓存模式：`if (!_specifiers) { _specifiers = [self loadSpecifiersFromPlistName:S("Root") target:self]; }`
//      —— calltimer / AdSkipSelector 两个已验证活样本同款写法；GLOBAL.md 铁律。
//   2. 全字符串运行时构造：RootHide 重映射会破坏静态 __cfstring 指针（CPUthermal 金注释：SIGBUS）；
//      面板侧一切动态字符串改用 S("...") / [NSString stringWithFormat:]，仅保留 plist key 所需静态串。
//   3. 面板加载信标：init / viewDidLoad / specifiers 三处写日志到 onlycontacts.log，
//      下一轮万一还异常，日志可直接定位是「dlopen 失败 / specifiers 为空 / 视图未加载」。
//   4. 一键设置遇忙转移（3.0.0 功能全保留）：CoreTelephonyClient + CTCallForwardingValue(reason=1)
//      + saveCallForwardingValue:value:completion:（delegate event=3 成功回执，10s 超时兜底）。
//
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import "../OCPrefPath.h"

/* ---------- 字符串工具：运行时构造，规避 RootHide __cfstring 重映射 ----------
   RootHide 会重写二进制的静态字符串指针；面板若大量静态 __cfstring，
   有概率在 Settings 进程触发 SIGBUS/加载异常（CPUthermal 金注释实录）。
   这里统一用 C 字符串运行时构造，从根上规避。 */
#define SFS(fmt, ...) [NSString stringWithFormat:[NSString stringWithUTF8String:(fmt)], ##__VA_ARGS__]
#define S(str) [NSString stringWithUTF8String:(str)]

/* ---------- CoreTelephony 私有类（运行时动态取，缺了也不影响面板加载） ---------- */
@interface CoreTelephonyClient : NSObject
- (id)initWithQueue:(id)queue;
- (void)setDelegate:(id)delegate;
- (id)getUserDefaultVoiceSubscriptionContext:(id *)error;
- (void)saveCallForwardingValue:(id)context value:(id)value completion:(void (^)(NSError *error))completion;
@end

@interface OCRootListController : PSListController
@end

@implementation OCRootListController
{
    id        _ocCTClient;        /* 懒加载的 CoreTelephonyClient */
    NSTimer  *_ocTimeoutTimer;    /* 一键设置的兜底计时器 */
    BOOL      _ocAwaitingReply;   /* 已发出请求，等待回执 */
}

#pragma mark - 面板信标（诊断：面板进程是否加载、specifiers 是否生成）

/* 面板信标（诊断专用）：写独立文件 onlycontacts-panel.log，
   避开注入端（root）写的 onlycontacts.log 的属主冲突。
   逐候选尝试：隐根 → /var/jb → 真实路径 → Documents；写不进就换下一个。 */
static void OCPanelLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *a = [NSMutableArray array];
        [a addObjectsFromArray:OCResolvePaths(S("var/mobile/Library/Logs/onlycontacts-panel.log"))];
        [a addObjectsFromArray:OCResolvePaths(S("var/mobile/Documents/onlycontacts-panel.log"))];
        paths = a;
    });
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = S("yyyy-MM-dd HH:mm:ss");
    df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
    NSString *line = SFS("%@ [panel] %@\n", [df stringFromDate:[NSDate date]], body);
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *p in paths) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
        if (![fm fileExistsAtPath:p]) {
            if (![fm createFileAtPath:p contents:nil attributes:nil]) continue;
            chown(p.fileSystemRepresentation, 501, 501);
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) continue;
        BOOL ok = NO;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
            ok = YES;
        } @catch (NSException *e) {
            /* 落点不可写：换下一个候选 */
        }
        [fh closeFile];
        if (ok) return;   /* 写进去就收工 */
    }
}

/* bundle 被 dlopen 进 Settings 进程的第一现场（先于任何实例化） */
+ (void)load {
    @try {
        OCPanelLog(S("+load: bundle 已加载进 Settings 进程 pid=%d"), getpid());
    } @catch (NSException *e) {}
}

- (instancetype)init {
    self = [super init];
    if (self) {
        OCPanelLog(S("init(): OCRootListController 实例化 pid=%d"), getpid());
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    OCPanelLog(S("viewDidLoad(): 视图已加载"));
}

/* ---------- specifiers：官方缓存模式（活样本同款）+ 代码兜底 ---------- */

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        OCPanelLog(S("specifiers(): 首次生成，从 Root.plist 加载"));
        _specifiers = [self loadSpecifiersFromPlistName:S("Root") target:self];
        OCPanelLog(S("specifiers(): Root.plist -> %lu 项"),
                   (unsigned long)(_specifiers ? _specifiers.count : 0));
        if (!_specifiers || _specifiers.count == 0) {
            OCPanelLog(S("specifiers(): Root.plist 为空，启用代码兜底构建"));
            NSMutableArray *fb = [self ocFallbackSpecifiers];
            _specifiers = fb;
            OCPanelLog(S("specifiers(): 兜底 -> %lu 项"), (unsigned long)_specifiers.count);
        }
    }
    return _specifiers;
}

/* 兜底 specifiers：全部代码构建（不依赖 Root.plist），确保面板必有内容 */
- (NSMutableArray *)ocFallbackSpecifiers {
    NSMutableArray *arr = [NSMutableArray array];

    PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:S("OnlyContacts（兜底模式）")];
    [g1 setProperty:S("Root.plist 未加载成功，以下是核心设置（功能不受影响）。") forKey:S("footerText")];
    [arr addObject:g1];

    [arr addObject:[self ocSwitchSpecifier:S("只允许通讯录来电") key:S("enabled") def:YES]];
    [arr addObject:[self ocSwitchSpecifier:S("真的拒接（restrict 闸门）") key:S("restrict_gate") def:YES]];
    [arr addObject:[self ocSwitchSpecifier:S("写决策日志") key:S("log") def:YES]];

    PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:S("呼叫转移（自动化）")];
    [g2 setProperty:S("填「停机号」后点一键设置；失败可用拨号盘代码 **67*停机号#") forKey:S("footerText")];
    [arr addObject:g2];

    PSSpecifier *ed = [PSSpecifier preferenceSpecifierNamed:S("停机号（转移目标）")
                                                    target:self
                                                       set:@selector(setPreferenceValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:nil
                                                      cell:PSEditTextCell
                                                      edit:nil];
    [ed setProperty:S("com.rna.onlycontacts") forKey:S("defaults")];
    [ed setProperty:S("redirect_number") forKey:S("key")];
    [ed setProperty:S("") forKey:S("default")];
    [arr addObject:ed];

    PSSpecifier *b1 = [PSSpecifier preferenceSpecifierNamed:S("一键设置遇忙转移")
                                                    target:self set:NULL get:NULL detail:nil
                                                      cell:PSButtonCell edit:nil];
    [self ocSetSpecifierAction:b1 sel:@selector(ocApplyForwarding:)];
    [arr addObject:b1];

    PSSpecifier *b2 = [PSSpecifier preferenceSpecifierNamed:S("关闭遇忙转移")
                                                    target:self set:NULL get:NULL detail:nil
                                                      cell:PSButtonCell edit:nil];
    [self ocSetSpecifierAction:b2 sel:@selector(ocDisableForwarding:)];
    [arr addObject:b2];

    PSSpecifier *b3 = [PSSpecifier preferenceSpecifierNamed:S("拨码设置：**67*停机号# (遇忙)")
                                                    target:self set:NULL get:NULL detail:nil
                                                      cell:PSButtonCell edit:nil];
    [self ocSetSpecifierAction:b3 sel:@selector(ocDialForwardingCode:)];
    [arr addObject:b3];

    return arr;
}

- (PSSpecifier *)ocSwitchSpecifier:(NSString *)name key:(NSString *)key def:(BOOL)def {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                    target:self
                                                       set:@selector(setPreferenceValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:nil
                                                      cell:PSSwitchCell
                                                      edit:nil];
    [s setProperty:S("com.rna.onlycontacts") forKey:S("defaults")];
    [s setProperty:key forKey:S("key")];
    [s setProperty:@(def) forKey:S("default")];
    [s setProperty:S("com.rna.onlycontacts/prefsChanged") forKey:S("PostNotification")];
    return s;
}

/* 给 PSButtonCell 设置 action（兼容新旧 Preferences：property 与 ivar 双写） */
- (void)ocSetSpecifierAction:(PSSpecifier *)spec sel:(SEL)sel {
    if (!spec || !sel) return;
    Ivar iv = class_getInstanceVariable([PSSpecifier class], "action");
    if (iv) {
        ptrdiff_t off = ivar_getOffset(iv);
        *(SEL *)((uint8_t *)(__bridge void *)spec + off) = sel;
    }
    SEL setBA = NSSelectorFromString(S("setButtonAction:"));
    if ([spec respondsToSelector:setBA]) {
        ((void (*)(id, SEL, SEL))objc_msgSend)(spec, setBA, sel);
    }
}

#pragma mark - 偏好读写（与注入端共用 OCPrefPath.h 的路径解析）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSMutableDictionary *d = OCLoadPrefsDict();
    NSString *key = [specifier propertyForKey:S("key")];
    id v = key ? d[key] : nil;
    return v ?: [specifier propertyForKey:S("default")];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *d = OCLoadPrefsDict();
    NSString *key = [specifier propertyForKey:S("key")];
    if (!key) return;
    if (value == nil) {
        [d removeObjectForKey:key];
    } else {
        d[key] = value;
    }
    NSString *written = OCSavePrefsDict(d);
    OCPanelLog(S("setPreferenceValue(%@) -> %@"), key, written ?: S("FAILED"));
    if (written.length) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)S("com.rna.onlycontacts/prefsChanged"),
                                             NULL, NULL, YES);
    }
}

#pragma mark - 小工具

- (void)ocAlert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = self;
        while (top.presentedViewController) top = top.presentedViewController;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:S("好") style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

/* 读面板里已保存的停机号（先去空格/横线） */
- (NSString *)ocRedirectNumber {
    NSMutableDictionary *d = OCLoadPrefsDict();
    id raw = d[S("redirect_number")];
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < [(NSString *)raw length]; i++) {
        unichar c = [(NSString *)raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || c == '+') [digits appendFormat:S("%C"), c];
    }
    NSString *s = [digits stringByReplacingOccurrencesOfString:S("+") withString:S("")];
    return s.length ? s : nil;
}

- (id)ocCTClient {
    if (_ocCTClient) return _ocCTClient;
    Class cls = objc_getClass("CoreTelephonyClient");
    if (!cls) return nil;
    id client = ((id (*)(id, SEL, id))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc")),
        sel_registerName("initWithQueue:"),
        (id)dispatch_get_main_queue());
    _ocCTClient = client;
    (_ocCTClient) ? ((void (*)(id, SEL, id))objc_msgSend)(_ocCTClient,
                                                          sel_registerName("setDelegate:"), self) : (void)0;
    return _ocCTClient;
}

/* 造 CTCallForwardingValue：reason 1=遇忙；clss 1=语音；enabled/saveNumber 按需 */
- (id)ocForwardingValueForNumber:(NSString *)number enable:(BOOL)enable {
    Class valueCls = objc_getClass("CTCallForwardingValue");
    if (!valueCls) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)valueCls, sel_registerName("alloc")),
        sel_registerName("init"));
    if (!value) return nil;
    ((void (*)(id, SEL, int))objc_msgSend)(value, sel_registerName("setReason:"), 1);
    ((void (*)(id, SEL, int))objc_msgSend)(value, sel_registerName("setClss:"), 1);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(value, sel_registerName("setEnabled:"), enable);
    if (number.length)
        ((void (*)(id, SEL, id))objc_msgSend)(value, sel_registerName("setSaveNumber:"), number);
    return value;
}

- (void)ocCancelPending {
    _ocAwaitingReply = NO;
    [_ocTimeoutTimer invalidate];
    _ocTimeoutTimer = nil;
}

/* 发送设置请求（enable=YES 设置到号码；enable=NO 关闭） */
- (void)ocSendForwardingEnable:(BOOL)enable {
    [self.view endEditing:YES];

    __weak __typeof(self) weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSString *number = [self ocRedirectNumber];
        if (enable && !number.length) {
            [self ocAlert:S("先填停机号")
                   message:S("请先在「停机号（转移目标）」输入框里填好号码，点「完成」收起键盘后，再点一键设置。")];
            return;
        }
        if (enable && number.length < 5) {
            [self ocAlert:S("号码看着不对") message:S("停机号至少 5 位，请检查后重试。")];
            return;
        }

        id client = [self ocCTClient];
        if (!client) {
            [self ocAlert:S("本机不支持")
                   message:S("这个系统里没有 CoreTelephonyClient，无法自动设置。\n可以改用拨号盘手动设置（见本页底部的代码）。")];
            return;
        }

        NSError *ctxErr = nil;
        id ctx = ((id (*)(id, SEL, NSError **))objc_msgSend)(client,
                    sel_registerName("getUserDefaultVoiceSubscriptionContext:"), &ctxErr);
        if (!ctx) {
            NSString *msg = [NSString stringWithFormat:S("%@\n\n可改用拨号盘手动设置（见本页底部的代码）。"),
                             ctxErr.localizedDescription ?: S("未知错误")];
            [self ocAlert:S("拿不到 SIM 卡信息") message:msg];
            return;
        }

        id value = [self ocForwardingValueForNumber:number enable:enable];
        if (!value) {
            [self ocAlert:S("内部错误") message:S("CTCallForwardingValue 造不出来。")];
            return;
        }

        OCPanelLog(S("ocSendForwardingEnable(%d) number=%@"), enable, number ?: S("(nil)"));

        [self ocCancelPending];
        _ocAwaitingReply = YES;

        /* 10 秒兜底：无回执就提示自行验证 */
        _ocTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:NO
                                                            block:^(NSTimer *t) {
            __strong __typeof(weakSelf) self2 = weakSelf;
            if (!self2 || !self2->_ocAwaitingReply) return;
            [self2 ocCancelPending];
            NSString *msg = [NSString stringWithFormat:
                             S("运营商回执还没回来（可能被网络延迟吞了）。\n\n"
                               "请用另一部手机拨打本机验证：\n"
                               "· 通讯录里的号码 → 正常响铃\n"
                               "· 陌生号码 → 不响铃，主叫被转到 %@%@\n\n"
                               "若没生效，试试本页底部的拨号盘代码。"),
                             enable ? number : S("（本次是关闭操作）"),
                             enable ? S("") : S("。")];
            [self2 ocAlert:S("请求已发出") message:msg];
        }];

        void (^completion)(NSError *) = ^(NSError *error) {
            __strong __typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            if (error) {
                [self2 ocCancelPending];
                OCPanelLog(S("saveCallForwarding completion error: domain=%@ code=%ld desc=%@"),
                           error.domain, (long)error.code, error.localizedDescription ?: S("(nil)"));
                NSString *detail = [NSString stringWithFormat:S("[%@:%ld]"),
                                    error.domain ?: S("?"), (long)error.code];
                NSString *msg = [NSString stringWithFormat:
                                 S("%@\n%@\n\n"
                                   "这通常表示运营商侧没开通「呼叫转移」业务，或拒绝了这个请求。\n"
                                   "中国电信：请先拨 10000 开通（免费），或到「中国电信」App 办理；\n"
                                   "然后回到本页用上面的「拨码设置」按钮（拨号盘方式通常更稳）。"),
                                 error.localizedDescription ?: S("未知错误"), detail];
                [self2 ocAlert:S("设置失败") message:msg];
            }
            /* error == nil 时不动：等 delegate 事件 3 的成功回执 */
        };

        ((void (*)(id, SEL, id, id, id))objc_msgSend)(client,
            sel_registerName("saveCallForwardingValue:value:completion:"),
            ctx, value, completion);
    });
}

#pragma mark - 面板按钮

- (void)ocApplyForwarding:(PSSpecifier *)specifier {
    [self ocSendForwardingEnable:YES];
}

- (void)ocDisableForwarding:(PSSpecifier *)specifier {
    [self ocSendForwardingEnable:NO];
}

#pragma mark - 拨号盘拨码（绕过系统私有通道，直拨运营商 MMI 码）

/* 把拨码送进电话 App 拨号盘（tel URL，用户点一下拨出即执行）。
   MMI 码里的 # 必须 URL 编码为 %23。 */
- (void)ocDialCode:(NSString *)code requiresNumber:(BOOL)requiresNumber {
    [self.view endEditing:YES];
    NSString *number = [self ocRedirectNumber];
    if (requiresNumber && !number.length) {
        [self ocAlert:S("先填停机号")
               message:S("请先在「停机号（转移目标）」输入框里填好号码，再点这个拨码按钮。")];
        return;
    }
    NSString *full = code;
    if (requiresNumber) {
        full = [code stringByReplacingOccurrencesOfString:S("*N#") withString:
                [NSString stringWithFormat:S("*%@#"), number]];
    }
    NSString *encoded = [full stringByReplacingOccurrencesOfString:S("#") withString:S("%23")];
    NSString *urlStr = [NSString stringWithFormat:S("tel:%@"), encoded];
    NSURL *url = [NSURL URLWithString:urlStr];
    OCPanelLog(S("ocDialCode: %@"), full);
    if (!url) {
        [self ocAlert:S("拨码失败") message:full];
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self ocAlert:S("没能呼起电话 App") message:[NSString stringWithFormat:
                    S("请手动在拨号盘输入并拨出：\n\n%@"), full]];
            });
        }
    }];
}

/* 遇忙转移设置码：**67*停机号# */
- (void)ocDialForwardingCode:(PSSpecifier *)specifier {
    [self ocDialCode:S("**67*N#") requiresNumber:YES];
}

/* 无应答转移设置码：**61*停机号# */
- (void)ocDialNoReplyCode:(PSSpecifier *)specifier {
    [self ocDialCode:S("**61*N#") requiresNumber:YES];
}

/* 取消遇忙转移码：##67# */
- (void)ocDialDisableCode:(PSSpecifier *)specifier {
    [self ocDialCode:S("##67#") requiresNumber:NO];
}

/* 复制全部设置码到剪贴板（含当前停机号） */
- (void)ocCopyForwardingCode:(PSSpecifier *)specifier {
    [self.view endEditing:YES];
    NSString *number = [self ocRedirectNumber];
    NSString *n = number.length ? number : S("停机号");
    NSString *all = [NSString stringWithFormat:
        S("遇忙转移（设置）：**67*%@#\n"
          "遇忙转移（取消）：##67#\n"
          "无应答转移（设置）：**61*%@#\n"
          "无应答转移（取消）：##61#\n"
          "不可及转移（设置）：**62*%@#\n"
          "不可及转移（取消）：##62#\n"
          "无条件转移（设置）：**21*%@#\n"
          "无条件转移（取消）：##21#\n"
          "取消所有转移：##002#"),
        n, n, n, n];
    [UIPasteboard generalPasteboard].string = all;
    OCPanelLog(S("ocCopyForwardingCode: copied"));
    [self ocAlert:S("已复制")
           message:S("全部设置码已复制到剪贴板。\n\n到拨号盘粘贴、拨出即可（每条单独拨）。\n\n提示：电信未开通业务时，先打 10000 开通「呼叫转移」。")];
}

#pragma mark - CoreTelephony 回执（delegate 事件）

/*  event: 1=查询成功 2=查询出错 3=设置成功 4=设置出错；settingsType: 1=呼叫转移 */
- (void)suppServicesEvent:(id)event event:(int)evt settingsType:(int)type data:(id)data {
    if (type != 1) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (evt == 3) {
            if (!self->_ocAwaitingReply) return;
            [self ocCancelPending];
            NSString *number = [self ocRedirectNumber];
            NSString *msg = [NSString stringWithFormat:
                             S("「遇忙转移」已指到 %@。\n\n"
                               "现在：通讯录里的号码正常响铃；陌生号码不响铃，"
                               "主叫会被运营商转到这个号码。\n\n"
                               "（运营商的首次生效可能需要半分钟，稍等再试）"),
                             number.length ? number : S("（号码）")];
            [self ocAlert:S("已设置成功") message:msg];
        } else if (evt == 4) {
            if (!self->_ocAwaitingReply) return;
            [self ocCancelPending];
            OCPanelLog(S("suppServicesEvent evt=4 set-error data=%@"), [data description] ?: S("(nil)"));
            [self ocAlert:S("设置没有成功")
                   message:S("运营商侧拒绝了这次设置（可能没开通呼叫转移业务，或需要密码）。\n\n"
                             "中国电信：先拨 10000 免费开通「呼叫转移」，\n"
                             "然后回来点上面的「拨码设置」按钮（拨号盘方式通常更稳）。")];
        }
    });
}

@end

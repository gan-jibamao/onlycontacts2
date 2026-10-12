//
//  OCRootListController.m — OnlyContacts 3.0.0 设置面板
//
//  两个职责：
//   1. 常规偏好读写 —— 走共享的 OCPrefPath.h（与注入端完全同一份路径解析，
//      RootHide 隐根 / rootless /var/jb / 真实路径 三态自适应）。
//   2. 「一键设置遇忙转移」—— 调用系统同款通道：
//      CoreTelephonyClient getUserDefaultVoiceSubscriptionContext:
//      + CTCallForwardingValue(reason=1 MobileBusy, clss=1 Voice, enabled=YES, saveNumber=停机号)
//      + saveCallForwardingValue:value:completion:
//      成功回执走 delegate 的 suppServicesEvent:event:3；10 秒无回执则提示自行验证。
//
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import "../OCPrefPath.h"

static NSString *const kOCPrefsChangedNotification = @"com.rna.onlycontacts/prefsChanged";

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

#pragma mark - 偏好读写（与注入端共用 OCPrefPath.h 的路径解析）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSMutableDictionary *d = OCLoadPrefsDict();
    NSString *key = specifier.properties[@"key"];
    id v = key ? d[key] : nil;
    return v ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *d = OCLoadPrefsDict();
    NSString *key = specifier.properties[@"key"];
    if (!key) return;
    if (value == nil) {
        [d removeObjectForKey:key];
    } else {
        d[key] = value;
    }
    if (OCSavePrefsDict(d)) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)kOCPrefsChangedNotification,
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
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

/* 读面板里已保存的停机号（先去空格/横线） */
- (NSString *)ocRedirectNumber {
    NSMutableDictionary *d = OCLoadPrefsDict();
    id raw = d[@"redirect_number"];
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < [(NSString *)raw length]; i++) {
        unichar c = [(NSString *)raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || c == '+') [digits appendFormat:@"%C", c];
    }
    NSString *s = [digits stringByReplacingOccurrencesOfString:@"+" withString:@""];
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
    /* 先把键盘收起来，保证输入框内容已提交进偏好 */
    [self.view endEditing:YES];

    __weak __typeof(self) weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSString *number = [self ocRedirectNumber];
        if (enable && !number.length) {
            [self ocAlert:@"先填停机号"
                   message:@"请先在「停机号（转移目标）」输入框里填好号码，"
                            "点「完成」收起键盘后，再点一键设置。"];
            return;
        }
        if (enable && number.length < 5) {
            [self ocAlert:@"号码看着不对" message:@"停机号至少 5 位，请检查后重试。"];
            return;
        }

        id client = [self ocCTClient];
        if (!client) {
            [self ocAlert:@"本机不支持"
                   message:@"这个系统里没有 CoreTelephonyClient，无法自动设置。\n"
                            "可以改用拨号盘手动设置（见本页底部的代码）。"];
            return;
        }

        NSError *ctxErr = nil;
        id ctx = ((id (*)(id, SEL, NSError **))objc_msgSend)(client,
                    sel_registerName("getUserDefaultVoiceSubscriptionContext:"), &ctxErr);
        if (!ctx) {
            [self ocAlert:@"拿不到 SIM 卡信息"
                   message:[NSString stringWithFormat:@"%@\n\n可改用拨号盘手动设置（见本页底部的代码）。",
                            ctxErr.localizedDescription ?: @"未知错误"]];
            return;
        }

        id value = [self ocForwardingValueForNumber:number enable:enable];
        if (!value) {
            [self ocAlert:@"内部错误" message:@"CTCallForwardingValue 造不出来。"];
            return;
        }

        [self ocCancelPending];
        _ocAwaitingReply = YES;

        /* 10 秒兜底：无回执就提示自行验证 */
        _ocTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:NO
                                                            block:^(NSTimer *t) {
            __strong __typeof(weakSelf) self2 = weakSelf;
            if (!self2 || !self2->_ocAwaitingReply) return;
            [self2 ocCancelPending];
            [self2 ocAlert:@"请求已发出"
                    message:[NSString stringWithFormat:
                             @"运营商回执还没回来（可能被网络延迟吞了）。\n\n"
                             @"请用另一部手机拨打本机验证：\n"
                             @"· 通讯录里的号码 → 正常响铃\n"
                             @"· 陌生号码 → 不响铃，主叫被转到 %@%@\n\n"
                             @"若没生效，试试本页底部的拨号盘代码。",
                             enable ? number : @"（本次是关闭操作）",
                             enable ? @"" : @"。"]];
        }];

        void (^completion)(NSError *) = ^(NSError *error) {
            __strong __typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            if (error) {
                [self2 ocCancelPending];
                [self2 ocAlert:@"设置失败"
                        message:[NSString stringWithFormat:
                                 @"%@\n\n可以改用拨号盘手动设置（见本页底部代码）。",
                                 error.localizedDescription ?: @"未知错误"]];
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

#pragma mark - CoreTelephony 回执（delegate 事件）

/*  event: 1=查询成功 2=查询出错 3=设置成功 4=设置出错；settingsType: 1=呼叫转移 */
- (void)suppServicesEvent:(id)event event:(int)evt settingsType:(int)type data:(id)data {
    if (type != 1) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (evt == 3) {
            if (!self->_ocAwaitingReply) return;
            [self ocCancelPending];
            NSString *number = [self ocRedirectNumber];
            [self ocAlert:@"已设置成功"
                   message:[NSString stringWithFormat:
                            @"「遇忙转移」已指到 %@。\n\n"
                            @"现在：通讯录里的号码正常响铃；陌生号码不响铃，"
                            @"主叫会被运营商转到这个号码。\n\n"
                            @"（运营商的首次生效可能需要半分钟，稍等再试）",
                            number.length ? number : @"（号码）"]];
        } else if (evt == 4) {
            if (!self->_ocAwaitingReply) return;
            [self ocCancelPending];
            [self ocAlert:@"设置没有成功"
                   message:@"运营商侧拒绝了这次设置（可能没开通呼叫转移业务，或需要密码）。\n\n"
                            @"可以试试本页底部的拨号盘代码手动设置。"];
        }
    });
}

@end

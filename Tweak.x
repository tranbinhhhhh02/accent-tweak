// AccentColorAll v2 - đổi màu nhấn cho mọi app khi inject dylib.
// Mở bảng cài đặt: nhấn giữ 3 ngón tay ~1 giây.
// Gồm 3 lớp tác động:
//  1) tintColor của window/view (chế độ mạnh: ép mọi view dùng màu nhấn)
//  2) UIColor hệ thống (systemBlue, link)
//  3) Thay màu cứng: mọi UIColor tạo từ RGB trùng màu gốc (có sẵn vài màu phổ biến
//     + 1 ô "Màu gốc cần thay" tự nhập) sẽ đổi sang màu nhấn.
// Cài đặt lưu riêng từng app (sandbox iOS).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

static NSString *const kEnabledKey    = @"AccentColorAll_Enabled";
static NSString *const kHexKey        = @"AccentColorAll_Hex";
static NSString *const kSrcHexKey     = @"AccentColorAll_SrcHex";
static NSString *const kAggressiveKey = @"AccentColorAll_Aggressive";
static NSString *const kDefaultHex    = @"B8A8FF";
static const void *kGestureFlag       = &kGestureFlag;

typedef struct { CGFloat r, g, b; } RGB;

static RGB      gTargets[16];
static int      gTargetCount = 0;
static BOOL     gBypass = NO;
static BOOL     gAggressive = YES;
static UIColor *gAccent = nil;

#pragma mark - Màu

static UIColor *ColorFromHex(NSString *s) {
    s = [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6) return nil;
    unsigned v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if (![sc scanHexInt:&v] || !sc.isAtEnd) return nil;
    gBypass = YES;
    UIColor *c = [UIColor colorWithRed:((v >> 16) & 255) / 255.0
                                 green:((v >> 8) & 255) / 255.0
                                  blue:(v & 255) / 255.0
                                 alpha:1.0];
    gBypass = NO;
    return c;
}

static NSString *HexFromColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    #define CH(x) ((int)lround(fmax(0, fmin(1, x)) * 255))
    return [NSString stringWithFormat:@"%02X%02X%02X", CH(r), CH(g), CH(b)];
    #undef CH
}

// Màu quá tối sẽ chìm trên nền tối -> pha trắng (chỉ dùng ở dark mode).
static UIColor *DarkVariant(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    CGFloat lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    const CGFloat target = 0.6;
    if (lum >= target) return c;
    CGFloat f = (target - lum) / (1.0 - lum);
    return [UIColor colorWithRed:r + (1 - r) * f green:g + (1 - g) * f blue:b + (1 - b) * f alpha:1.0];
}

static void AddTarget(CGFloat r, CGFloat g, CGFloat b) {
    if (gTargetCount >= 16) return;
    gTargets[gTargetCount++] = (RGB){ r, g, b };
}

static inline BOOL Matches(CGFloat r, CGFloat g, CGFloat b) {
    if (gBypass || !gAccent || gTargetCount == 0) return NO;
    for (int i = 0; i < gTargetCount; i++) {
        if (fabs(r - gTargets[i].r) < 0.012 &&
            fabs(g - gTargets[i].g) < 0.012 &&
            fabs(b - gTargets[i].b) < 0.012) return YES;
    }
    return NO;
}

// Tính lại màu nhấn + danh sách màu cần thay. Gọi sau mỗi lần đổi cài đặt.
static void RefreshCache(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    gAggressive = [d boolForKey:kAggressiveKey];
    gTargetCount = 0;

    if (![d boolForKey:kEnabledKey]) { gAccent = nil; return; }

    NSString *hex = [d stringForKey:kHexKey] ?: kDefaultHex;
    UIColor *light = ColorFromHex(hex) ?: ColorFromHex(kDefaultHex);
    gBypass = YES;
    UIColor *dark = DarkVariant(light);
    gBypass = NO;
    gAccent = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];

    // Màu gốc do người dùng nhập
    UIColor *src = ColorFromHex([d stringForKey:kSrcHexKey]);
    if (src) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [src getRed:&r green:&g blue:&b alpha:&a];
        AddTarget(r, g, b);
    }
    // Màu cứng phổ biến (chỉ ở chế độ mạnh)
    if (gAggressive) {
        AddTarget(0.0 / 255, 122.0 / 255, 255.0 / 255);   // iOS blue sáng
        AddTarget(10.0 / 255, 132.0 / 255, 255.0 / 255);  // iOS blue tối
        AddTarget(29.0 / 255, 155.0 / 255, 240.0 / 255);  // X (Twitter) #1D9BF0
        AddTarget(0.0 / 255, 149.0 / 255, 246.0 / 255);   // Instagram/Threads #0095F6
        AddTarget(55.0 / 255, 151.0 / 255, 239.0 / 255);  // Instagram #3797EF
        AddTarget(254.0 / 255, 44.0 / 255, 85.0 / 255);   // TikTok #FE2C55
    }
}

static void RefreshViewTree(UIView *v, int depth) {
    if (depth > 40) return;
    [v tintColorDidChange];
    [v setNeedsDisplay];
    for (UIView *s in v.subviews) RefreshViewTree(s, depth + 1);
}

static void ApplyAll(void) {
    RefreshCache();
    if (gAccent) {
        [UISwitch appearance].onTintColor = gAccent;
        [UISlider appearance].minimumTrackTintColor = gAccent;
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            w.tintColor = gAccent; // nil = trả về mặc định
            RefreshViewTree(w, 0);
        }
    }
}

#pragma mark - Bảng cài đặt

static UIViewController *TopVC(UIWindow *w) {
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

@interface AACHelper : NSObject <UIGestureRecognizerDelegate, UIColorPickerViewControllerDelegate>
+ (instancetype)shared;
@end

@implementation AACHelper
+ (instancetype)shared {
    static AACHelper *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [AACHelper new]; });
    return h;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self showPanelFrom:(UIWindow *)g.view];
}

- (void)showPanelFrom:(UIWindow *)win {
    UIViewController *top = TopVC(win);
    if (!top || [top isKindOfClass:UIAlertController.class]) return;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL on = [d boolForKey:kEnabledKey];
    BOOL strong = [d boolForKey:kAggressiveKey];
    NSString *cur = [d stringForKey:kHexKey] ?: kDefaultHex;
    NSString *src = [d stringForKey:kSrcHexKey] ?: @"";

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Màu nhấn"
        message:[NSString stringWithFormat:@"%@ • #%@ • Chế độ mạnh: %@",
                 on ? @"Đang bật" : @"Đang tắt", cur, strong ? @"bật" : @"tắt"]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [@"#" stringByAppendingString:cur];
        tf.placeholder = @"Màu nhấn mới #RRGGBB";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = src.length ? [@"#" stringByAppendingString:src] : @"";
        tf.placeholder = @"Màu gốc cần thay (tuỳ chọn)";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    __weak UIAlertController *weakAc = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu & áp dụng" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *t1 = weakAc.textFields[0].text;
        NSString *t2 = weakAc.textFields[1].text;
        UIColor *c = ColorFromHex(t1);
        if (!c) return; // mã hex sai -> bỏ qua
        [d setObject:HexFromColor(c) forKey:kHexKey];
        UIColor *s = ColorFromHex(t2);
        if (s) [d setObject:HexFromColor(s) forKey:kSrcHexKey];
        else   [d removeObjectForKey:kSrcHexKey];
        [d setBool:YES forKey:kEnabledKey];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Chọn màu…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIColorPickerViewController *p = [UIColorPickerViewController new];
        p.delegate = self;
        p.supportsAlpha = NO;
        p.selectedColor = ColorFromHex(cur) ?: ColorFromHex(kDefaultHex);
        [TopVC(win) presentViewController:p animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:on ? @"Tắt màu nhấn" : @"Bật màu nhấn"
                                           style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [d setBool:!on forKey:kEnabledKey];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:strong ? @"Tắt chế độ mạnh" : @"Bật chế độ mạnh"
                                           style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [d setBool:!strong forKey:kAggressiveKey];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)saveColor:(UIColor *)c {
    [NSUserDefaults.standardUserDefaults setObject:HexFromColor(c) forKey:kHexKey];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kEnabledKey];
    ApplyAll();
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)vc { [self saveColor:vc.selectedColor]; }
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc { [self saveColor:vc.selectedColor]; }
@end

#pragma mark - Hook

static void Setup(UIWindow *w) {
    if (!objc_getAssociatedObject(w, kGestureFlag)) {
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[AACHelper shared] action:@selector(onLongPress:)];
        g.numberOfTouchesRequired = 3;
        g.minimumPressDuration = 1.0;
        g.cancelsTouchesInView = NO;
        g.delegate = [AACHelper shared];
        [w addGestureRecognizer:g];
        objc_setAssociatedObject(w, kGestureFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    w.tintColor = gAccent;
}

%hook UIWindow
- (void)makeKeyAndVisible { %orig; Setup(self); }
- (void)becomeKeyWindow { %orig; Setup(self); }
- (void)setRootViewController:(UIViewController *)vc { %orig; Setup(self); }
%end

// Chế độ mạnh: ép mọi view trả về màu nhấn, kể cả khi app tự đặt tintColor.
%hook UIView
- (UIColor *)tintColor {
    if (gAccent && gAggressive) return gAccent;
    return %orig;
}
%end

%hook UIColor
// Màu hệ thống hay dùng làm accent
+ (UIColor *)systemBlueColor {
    if (gAccent && gAggressive) return gAccent;
    return %orig;
}
+ (UIColor *)linkColor {
    if (gAccent && gAggressive) return gAccent;
    return %orig;
}
// Thay màu cứng theo RGB
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (Matches(r, g, b)) return a >= 0.999 ? gAccent : [gAccent colorWithAlphaComponent:a];
    return %orig;
}
- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (Matches(r, g, b)) return a >= 0.999 ? gAccent : [gAccent colorWithAlphaComponent:a];
    return %orig;
}
%end

%ctor {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kEnabledKey: @YES, kHexKey: kDefaultHex, kAggressiveKey: @YES }];
    RefreshCache();
}

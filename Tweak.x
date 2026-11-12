// AccentColorAll - đổi màu nhấn (tintColor) cho mọi app khi inject dylib.
// Mở bảng cài đặt: nhấn giữ 3 ngón tay ~1 giây trên màn hình bất kỳ.
// Cài đặt lưu theo từng app (sandbox iOS không cho chia sẻ giữa các app đã sideload).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

static NSString *const kEnabledKey  = @"AccentColorAll_Enabled";
static NSString *const kHexKey      = @"AccentColorAll_Hex";
static NSString *const kDefaultHex  = @"B8A8FF"; // đổi mã mặc định tại đây
static const void *kGestureFlag     = &kGestureFlag;

#pragma mark - Màu

static UIColor *ColorFromHex(NSString *s) {
    s = [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6) return nil;
    unsigned v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if (![sc scanHexInt:&v] || !sc.isAtEnd) return nil;
    return [UIColor colorWithRed:((v >> 16) & 255) / 255.0
                           green:((v >> 8) & 255) / 255.0
                            blue:(v & 255) / 255.0
                           alpha:1.0];
}

static NSString *HexFromColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    #define CH(x) ((int)lround(fmax(0, fmin(1, x)) * 255))
    return [NSString stringWithFormat:@"%02X%02X%02X", CH(r), CH(g), CH(b)];
    #undef CH
}

// Màu quá tối sẽ chìm trên nền tối -> pha trắng cho đến khi đủ sáng (chỉ dùng ở dark mode).
static UIColor *DarkVariant(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    CGFloat lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    const CGFloat target = 0.6;
    if (lum >= target) return c;
    CGFloat f = (target - lum) / (1.0 - lum);
    return [UIColor colorWithRed:r + (1 - r) * f green:g + (1 - g) * f blue:b + (1 - b) * f alpha:1.0];
}

static BOOL IsEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kEnabledKey];
}

static UIColor *Accent(void) {
    if (!IsEnabled()) return nil;
    NSString *hex = [NSUserDefaults.standardUserDefaults stringForKey:kHexKey] ?: kDefaultHex;
    UIColor *light = ColorFromHex(hex) ?: ColorFromHex(kDefaultHex);
    UIColor *dark = DarkVariant(light);
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}

static void ApplyAll(void) {
    UIColor *c = Accent();
    if (c) {
        [UISwitch appearance].onTintColor = c;
        [UISlider appearance].minimumTrackTintColor = c;
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) w.tintColor = c; // nil = trả về mặc định
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

    NSString *cur = [NSUserDefaults.standardUserDefaults stringForKey:kHexKey] ?: kDefaultHex;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Màu nhấn"
        message:[NSString stringWithFormat:@"Đang %@ • #%@", IsEnabled() ? @"bật" : @"tắt", cur]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [@"#" stringByAppendingString:cur];
        tf.placeholder = @"#RRGGBB";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    __weak UIAlertController *weakAc = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu & áp dụng" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *t = weakAc.textFields.firstObject.text;
        UIColor *c = ColorFromHex(t);
        if (!c) return; // mã hex sai -> bỏ qua
        [NSUserDefaults.standardUserDefaults setObject:HexFromColor(c) forKey:kHexKey];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kEnabledKey];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Chọn màu…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIColorPickerViewController *p = [UIColorPickerViewController new];
        p.delegate = self;
        p.supportsAlpha = NO;
        p.selectedColor = ColorFromHex(cur) ?: ColorFromHex(kDefaultHex);
        [TopVC(win) presentViewController:p animated:YES completion:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:IsEnabled() ? @"Tắt màu nhấn" : @"Bật màu nhấn"
                                           style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [NSUserDefaults.standardUserDefaults setBool:!IsEnabled() forKey:kEnabledKey];
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
    w.tintColor = Accent();
}

%hook UIWindow
- (void)makeKeyAndVisible { %orig; Setup(self); }
- (void)becomeKeyWindow { %orig; Setup(self); }
- (void)setRootViewController:(UIViewController *)vc { %orig; Setup(self); }
%end

%ctor {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{ kEnabledKey: @YES, kHexKey: kDefaultHex }];
}

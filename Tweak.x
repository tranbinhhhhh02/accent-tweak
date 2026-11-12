// AccentColorAll v3 - đổi màu nhấn cho mọi app khi inject dylib.
// Mở bảng cài đặt: nhấn giữ 3 ngón tay ~1 giây.
// 3 nhóm độc lập, mỗi nhóm có công tắc bật/tắt và màu riêng:
//   - Nút & nền : nền nút, nền chip/pill, viền, switch, slider
//   - Chữ       : chữ link, tiêu đề nút
//   - Icon      : icon (tint), nét vẽ vector
// Cài đặt lưu riêng từng app (sandbox iOS).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

typedef NS_ENUM(int, AACCat) { AACFill = 0, AACText = 1, AACIcon = 2, AACCount = 3 };

static NSString *const kMasterKey  = @"AccentColorAll_Enabled";
static NSString *const kDefaultHex = @"B8A8FF";
static const void *kFill           = &kFill;
static const void *kGestureFlag    = &kGestureFlag;

static NSString *CatOnKey(int c)  { return [NSString stringWithFormat:@"AccentColorAll_On_%d", c]; }
static NSString *CatHexKey(int c) { return [NSString stringWithFormat:@"AccentColorAll_Hex_%d", c]; }
static NSString *CatName(int c)   { return c == AACFill ? @"Nút & nền" : (c == AACText ? @"Chữ" : @"Icon"); }

// Cache (ghi ở main thread, đọc ở mọi thread). Không bao giờ giải phóng giá trị cũ để tránh use-after-free.
static BOOL        gMaster = YES;
static BOOL        gOn[AACCount];
static UIColor    *gColor[AACCount];
static CGColorRef  gCGLight[AACCount], gCGDark[AACCount], gCGSoftLight[AACCount], gCGSoftDark[AACCount];
static BOOL        gDark = NO;
static int         gFillCount = 0;
static NSMutableArray *gKeep;
static __weak UIWindow *gLastWin;
static CGPoint     gLastPt;

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

static NSString *HexFromRGB(CGFloat r, CGFloat g, CGFloat b) {
    #define CH(x) ((int)lround(fmax(0, fmin(1, x)) * 255))
    return [NSString stringWithFormat:@"%02X%02X%02X", CH(r), CH(g), CH(b)];
    #undef CH
}

static NSString *HexFromColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    return HexFromRGB(r, g, b);
}

static NSString *HexFromCG(CGColorRef c) {
    if (!c) return @"-";
    const CGFloat *k = CGColorGetComponents(c);
    if (!k) return @"?";
    size_t n = CGColorGetNumberOfComponents(c);
    return n >= 3 ? HexFromRGB(k[0], k[1], k[2]) : HexFromRGB(k[0], k[0], k[0]);
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

// Phân loại xanh dương theo hue: 1 = xanh đậm (link, nút, viền), 2 = nền xanh nhạt, 0 = không phải.
static inline int BlueClass(CGFloat r, CGFloat g, CGFloat b) {
    CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
    if (b < mx || mx - mn < 0.001) return 0;
    CGFloat h = 60.0 * (4.0 + (r - g) / (mx - mn));
    if (h < 195.0 || h > 230.0) return 0;
    CGFloat sat = (mx - mn) / mx;
    if (mx >= 0.75 && sat >= 0.55) return 1;
    if (mx >= 0.90 && sat >= 0.05 && sat <= 0.30) return 2;
    return 0;
}

static inline CGColorRef CGFor(int cat, BOOL soft) {
    if (gDark) return soft ? gCGSoftDark[cat] : gCGDark[cat];
    return soft ? gCGSoftLight[cat] : gCGLight[cat];
}

static void RefreshCache(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (!gKeep) gKeep = [NSMutableArray new];
    gMaster = [d boolForKey:kMasterKey];
    for (int c = 0; c < AACCount; c++) {
        NSString *hex = [d stringForKey:CatHexKey(c)] ?: kDefaultHex;
        UIColor *light = ColorFromHex(hex) ?: ColorFromHex(kDefaultHex);
        UIColor *dark = DarkVariant(light);
        UIColor *dyn = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        }];
        [gKeep addObject:dyn];
        gColor[c] = dyn;
        gCGLight[c] = CGColorCreateCopy(light.CGColor);
        gCGDark[c] = CGColorCreateCopy(dark.CGColor);
        gCGSoftLight[c] = CGColorCreateCopyWithAlpha(light.CGColor, 0.2);
        gCGSoftDark[c] = CGColorCreateCopyWithAlpha(dark.CGColor, 0.2);
        gOn[c] = gMaster && [d boolForKey:CatOnKey(c)];
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
    if (gOn[AACFill]) {
        [UISwitch appearance].onTintColor = gColor[AACFill];
        [UISlider appearance].minimumTrackTintColor = gColor[AACFill];
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            gDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
            w.tintColor = gOn[AACIcon] ? gColor[AACIcon] : nil;
            RefreshViewTree(w, 0);
        }
    }
}

#pragma mark - Dò phần tử (để báo lỗi chính xác)

static NSString *Describe(UIWindow *w, CGPoint p) {
    UIView *v = [w hitTest:p withEvent:nil];
    if (!v) return @"Không tìm thấy view tại vị trí này.";
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 8 && v; i++, v = v.superview) {
        CALayer *l = v.layer;
        [s appendFormat:@"%d) %@ bg:%@ r:%.0f %.0fx%.0f", i, NSStringFromClass(v.class),
            HexFromCG(l.backgroundColor), l.cornerRadius, l.bounds.size.width, l.bounds.size.height];
        int shown = 0;
        for (CALayer *sub in l.sublayers) {
            if (shown >= 2) break;
            if ([sub isKindOfClass:CAShapeLayer.class]) {
                CAShapeLayer *sh = (CAShapeLayer *)sub;
                [s appendFormat:@" [shape fill:%@ stroke:%@]", HexFromCG(sh.fillColor), HexFromCG(sh.strokeColor)];
                shown++;
            }
        }
        [s appendString:@"\n"];
    }
    return s;
}

#pragma mark - Bảng cài đặt

static UIViewController *TopVC(UIWindow *w) {
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

@interface AACHelper : NSObject <UIGestureRecognizerDelegate, UIColorPickerViewControllerDelegate>
@property (nonatomic) int pickCat; // -1 = cả 3 nhóm
@property (nonatomic, weak) UIWindow *panelWin;
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
    UIWindow *win = (UIWindow *)g.view;
    gLastWin = win;
    gLastPt = [g locationInView:win];
    [self showMainFrom:win];
}

- (void)later:(void (^)(void))blk {
    dispatch_async(dispatch_get_main_queue(), blk);
}

- (void)present:(UIAlertController *)ac from:(UIWindow *)win {
    UIViewController *top = TopVC(win);
    if (top) [top presentViewController:ac animated:YES completion:nil];
}

- (void)showMainFrom:(UIWindow *)win {
    UIViewController *top = TopVC(win);
    if (!top || [top isKindOfClass:UIAlertController.class]) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL master = [d boolForKey:kMasterKey];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Màu nhấn"
        message:master ? @"Chọn nhóm để chỉnh" : @"Đang tắt toàn bộ"
        preferredStyle:UIAlertControllerStyleAlert];

    for (int c = 0; c < AACCount; c++) {
        BOOL on = [d boolForKey:CatOnKey(c)];
        NSString *hex = [d stringForKey:CatHexKey(c)] ?: kDefaultHex;
        NSString *t = [NSString stringWithFormat:@"%@: %@ • #%@", CatName(c), on ? @"bật" : @"tắt", hex];
        [ac addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self later:^{ [self showCat:c from:win]; }];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cùng một màu cho cả 3 nhóm…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self later:^{ [self showAllFrom:win]; }];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:master ? @"Tắt toàn bộ" : @"Bật toàn bộ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [d setBool:!master forKey:kMasterKey];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Dò phần tử tại chỗ vừa giữ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self later:^{
            UIWindow *w = gLastWin ?: win;
            UIAlertController *info = [UIAlertController alertControllerWithTitle:@"Thông tin view"
                message:Describe(w, gLastPt) preferredStyle:UIAlertControllerStyleAlert];
            [info addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
            [self present:info from:w];
        }];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)showCat:(int)c from:(UIWindow *)win {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL on = [d boolForKey:CatOnKey(c)];
    NSString *cur = [d stringForKey:CatHexKey(c)] ?: kDefaultHex;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:CatName(c)
        message:on ? @"Đang bật" : @"Đang tắt" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [@"#" stringByAppendingString:cur];
        tf.placeholder = @"#RRGGBB";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAc = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu màu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIColor *col = ColorFromHex(weakAc.textFields.firstObject.text);
        if (!col) return;
        [d setObject:HexFromColor(col) forKey:CatHexKey(c)];
        [d setBool:YES forKey:CatOnKey(c)];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Chọn màu…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.pickCat = c;
        [self later:^{
            UIColorPickerViewController *p = [UIColorPickerViewController new];
            p.delegate = self;
            p.supportsAlpha = NO;
            p.selectedColor = ColorFromHex(cur) ?: ColorFromHex(kDefaultHex);
            [TopVC(win) presentViewController:p animated:YES completion:nil];
        }];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:on ? @"Tắt nhóm này" : @"Bật nhóm này" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [d setBool:!on forKey:CatOnKey(c)];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Quay lại" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [self later:^{ [self showMainFrom:win]; }];
    }]];
    [self present:ac from:win];
}

- (void)showAllFrom:(UIWindow *)win {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *cur = [d stringForKey:CatHexKey(AACFill)] ?: kDefaultHex;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Cùng một màu"
        message:@"Áp dụng và bật cả 3 nhóm" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [@"#" stringByAppendingString:cur];
        tf.placeholder = @"#RRGGBB";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAc = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIColor *col = ColorFromHex(weakAc.textFields.firstObject.text);
        if (!col) return;
        for (int c = 0; c < AACCount; c++) {
            [d setObject:HexFromColor(col) forKey:CatHexKey(c)];
            [d setBool:YES forKey:CatOnKey(c)];
        }
        [d setBool:YES forKey:kMasterKey];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Chọn màu…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.pickCat = -1;
        [self later:^{
            UIColorPickerViewController *p = [UIColorPickerViewController new];
            p.delegate = self;
            p.supportsAlpha = NO;
            p.selectedColor = ColorFromHex(cur) ?: ColorFromHex(kDefaultHex);
            [TopVC(win) presentViewController:p animated:YES completion:nil];
        }];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Quay lại" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [self later:^{ [self showMainFrom:win]; }];
    }]];
    [self present:ac from:win];
}

- (void)saveColor:(UIColor *)col {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *hex = HexFromColor(col);
    for (int c = 0; c < AACCount; c++) {
        if (self.pickCat == -1 || self.pickCat == c) {
            [d setObject:hex forKey:CatHexKey(c)];
            [d setBool:YES forKey:CatOnKey(c)];
        }
    }
    [d setBool:YES forKey:kMasterKey];
    ApplyAll();
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)vc { [self saveColor:vc.selectedColor]; }
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc { [self saveColor:vc.selectedColor]; }
@end

#pragma mark - Hỗ trợ hook

static void MarkFill(CALayer *l) {
    if (l.bounds.size.height > 120) return; // chỉ nút/chip, không phải nền lớn
    if (!objc_getAssociatedObject(l, kFill)) {
        objc_setAssociatedObject(l, kFill, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gFillCount++;
    }
}

static BOOL UnderFill(UIView *v) {
    for (int i = 0; i < 4 && v; i++) {
        if (objc_getAssociatedObject(v.layer, kFill)) return YES;
        v = v.superview;
    }
    return NO;
}

// CGColor xanh dương -> CGColor của nhóm cat (đã lưu sẵn, không giải phóng). NULL nếu không áp dụng.
static CGColorRef LayerRemap(CGColorRef c, int cat, int *clsOut) {
    if (!c || !gOn[cat]) return NULL;
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (!cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) return NULL;
    if (CGColorGetNumberOfComponents(c) < 4) return NULL;
    const CGFloat *k = CGColorGetComponents(c);
    if (!k) return NULL;
    int cls = BlueClass(k[0], k[1], k[2]);
    if (cls == 0) return NULL;
    if (clsOut) *clsOut = cls;
    return CGFor(cat, cls == 2);
}

// UIColor xanh dương -> màu của nhóm cat. nil nếu không áp dụng.
static UIColor *ColorRemap(UIColor *c, int cat, int *clsOut) {
    if (!c || !gOn[cat]) return nil;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return nil;
    int cls = BlueClass(r, g, b);
    if (cls == 0) return nil;
    if (clsOut) *clsOut = cls;
    return cls == 2 ? [gColor[cat] colorWithAlphaComponent:0.2] : gColor[cat];
}

// Nền đen bo tròn cỡ nút/chip (vd "Theo dõi", nút ✓, thumb segmented, dấu + avatar) -> màu "Nút & nền".
static void TryBlack(CALayer *l) {
    if (!gOn[AACFill]) return;
    CGColorRef bg = l.backgroundColor;
    if (!bg || CGColorGetAlpha(bg) < 0.99) return;
    const CGFloat *c = CGColorGetComponents(bg);
    if (!c) return;
    size_t n = CGColorGetNumberOfComponents(bg);
    BOOL black = (n == 2) ? (c[0] < 0.03) : (n >= 4 && c[0] < 0.03 && c[1] < 0.03 && c[2] < 0.03);
    if (!black) return;
    CGSize sz = l.bounds.size;
    if (sz.height < 14 || sz.height > 64 || sz.width < 14 || l.cornerRadius < 6) return;
    if (![NSThread isMainThread]) return;
    l.backgroundColor = CGFor(AACFill, NO);
    MarkFill(l);
}

static BOOL IsBlackColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return a >= 0.99 && r < 0.03 && g < 0.03 && b < 0.03;
}

static int TintCat(UIView *v) {
    if ([v isKindOfClass:UIImageView.class]) return AACIcon;
    if ([v isKindOfClass:UILabel.class] || [v isKindOfClass:UIButton.class] ||
        [v isKindOfClass:UITextField.class] || [v isKindOfClass:UITextView.class]) return AACText;
    if ([v isKindOfClass:UISwitch.class] || [v isKindOfClass:UISlider.class] ||
        [v isKindOfClass:UIProgressView.class] || [v isKindOfClass:UIActivityIndicatorView.class] ||
        [v isKindOfClass:UIStepper.class] || [v isKindOfClass:UISegmentedControl.class] ||
        [v isKindOfClass:UIPageControl.class]) return AACFill;
    return AACIcon;
}

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
    gDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    w.tintColor = gOn[AACIcon] ? gColor[AACIcon] : nil;
}

#pragma mark - Hook

%hook UIWindow
- (void)makeKeyAndVisible { %orig; Setup(self); }
- (void)becomeKeyWindow { %orig; Setup(self); }
- (void)setRootViewController:(UIViewController *)vc { %orig; Setup(self); }
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    %orig;
    gDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
}
%end

%hook UIView
- (UIColor *)tintColor {
    if (!gMaster) return %orig;
    if (gFillCount > 0 && gOn[AACFill] && [NSThread isMainThread] && UnderFill(self)) return UIColor.whiteColor;
    int cat = TintCat(self);
    if (gOn[cat]) return gColor[cat];
    return %orig;
}
- (void)setBackgroundColor:(UIColor *)c {
    int cls = 0;
    UIColor *n = gMaster ? ColorRemap(c, AACFill, &cls) : nil;
    %orig(n ?: c);
    if (!gMaster) return;
    if (n && cls == 1) MarkFill(self.layer);
    else if (!n && gOn[AACFill] && IsBlackColor(c)) TryBlack(self.layer);
}
%end

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)c {
    int cls = 0;
    CGColorRef n = gMaster ? LayerRemap(c, AACFill, &cls) : NULL;
    if (n) { %orig(n); if (cls == 1) MarkFill(self); return; }
    %orig;
    if (gMaster) TryBlack(self);
}
- (void)setBounds:(CGRect)b {
    %orig;
    if (gMaster && gOn[AACFill]) TryBlack(self);
}
- (void)setCornerRadius:(CGFloat)r {
    %orig;
    if (gMaster && gOn[AACFill]) TryBlack(self);
}
- (void)setBorderColor:(CGColorRef)c {
    CGColorRef n = gMaster ? LayerRemap(c, AACFill, NULL) : NULL;
    if (n) { %orig(n); return; }
    %orig;
}
%end

%hook CAShapeLayer
- (void)setFillColor:(CGColorRef)c {
    CGColorRef n = gMaster ? LayerRemap(c, AACIcon, NULL) : NULL;
    if (n) { %orig(n); return; }
    %orig;
}
- (void)setStrokeColor:(CGColorRef)c {
    CGColorRef n = gMaster ? LayerRemap(c, AACIcon, NULL) : NULL;
    if (n) { %orig(n); return; }
    %orig;
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)c {
    UIColor *n = gMaster ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c);
}
%end

%hook UIButton
- (void)setTitleColor:(UIColor *)c forState:(UIControlState)st {
    UIColor *n = gMaster ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c, st);
}
%end

%hook UIColor
+ (UIColor *)systemBlueColor {
    if (gMaster && gOn[AACIcon]) return gColor[AACIcon];
    return %orig;
}
+ (UIColor *)linkColor {
    if (gMaster && gOn[AACText]) return gColor[AACText];
    return %orig;
}
%end

%ctor {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kMasterKey: @YES,
        @"AccentColorAll_On_0": @YES, @"AccentColorAll_On_1": @YES, @"AccentColorAll_On_2": @YES,
        @"AccentColorAll_Hex_0": kDefaultHex, @"AccentColorAll_Hex_1": kDefaultHex, @"AccentColorAll_Hex_2": kDefaultHex }];
    RefreshCache();
}

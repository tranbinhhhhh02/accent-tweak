#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#if __has_feature(objc_arc)
#define AAC_BRIDGE(T) (__bridge T)
#else
#define AAC_BRIDGE(T) (T)
#endif

#define kEnabledKey  @"AccentColorAll_Enabled"
#define kHexKey      @"AccentColorAll_Hex"
#define kDefaultHex  @"B8A8FF"

static UIColor *gAccent = nil;
static BOOL gEnabled = YES;
static __thread BOOL gGuard = NO;

static char kSendKey;     // view đã được nhận diện là nút gửi
static char kFillKey;     // view đang giữ nền đen của nút gửi
static char kOutKey;      // CGImage đã recolor của layer
static char kGestureKey;  // đã gắn gesture cho window

#pragma mark - Color utils

static UIColor *AACColorFromHex(NSString *hex) {
    hex = [[hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 6) return nil;
    unsigned v = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&v]) return nil;
    return [UIColor colorWithRed:((v >> 16) & 255) / 255.0
                           green:((v >> 8) & 255) / 255.0
                            blue:(v & 255) / 255.0
                           alpha:1.0];
}

static void AACReloadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gEnabled = [d objectForKey:kEnabledKey] ? [d boolForKey:kEnabledKey] : YES;
    UIColor *c = AACColorFromHex([d stringForKey:kHexKey] ?: kDefaultHex);
    gAccent = [(c ?: AACColorFromHex(kDefaultHex)) copy];
}

static UIColor *AACAccent(void) {
    if (!gAccent) AACReloadPrefs();
    return gAccent;
}

// Màu tối trung tính (đen / xám đen)
static BOOL AACIsDark(UIColor *c, UITraitCollection *tc) {
    if (!c) return NO;
    if (tc) c = [c resolvedColorWithTraitCollection:tc];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if ([c getWhite:&w alpha:&a]) { r = g = b = w; } else return NO;
    }
    if (a < 0.5) return NO;
    CGFloat lum = 0.299 * r + 0.587 * g + 0.114 * b;
    CGFloat spread = fmax(fmax(r, g), b) - fmin(fmin(r, g), b);
    return lum < 0.25 && spread < 0.12;
}

static BOOL AACIsBlueish(UIColor *c) {
    if (!c) return NO;
    CGFloat h = 0, s = 0, b = 0, a = 0;
    if (![c getHue:&h saturation:&s brightness:&b alpha:&a]) return NO;
    return a > 0.3 && s > 0.45 && b > 0.4 && h > 0.52 && h < 0.70;
}

static BOOL AACSkipClassName(NSString *n) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = @[@"Shim", @"Glass", @"Backdrop", @"Material", @"VisualEffect"]; });
    for (NSString *k in keys) if ([n containsString:k]) return YES;
    return NO;
}

static BOOL AACNameIsKeyboard(NSString *n) {
    return [n containsString:@"Keyboard"] || [n containsString:@"UIKB"] || [n containsString:@"TextEffects"];
}

static BOOL AACViewInKeyboard(UIView *v) {
    int d = 0;
    for (UIView *p = v; p && d < 12; p = p.superview, d++) {
        if (AACNameIsKeyboard(NSStringFromClass([p class]))) return YES;
    }
    return NO;
}

static UIView *AACOwnerView(CALayer *l) {
    int d = 0;
    for (CALayer *p = l; p && d < 12; p = p.superlayer, d++) {
        id del = p.delegate;
        if ([del isKindOfClass:[UIView class]]) return del;
    }
    return nil;
}

static BOOL AACLayerInKeyboard(CALayer *l) {
    int d = 0;
    for (CALayer *p = l; p && d < 12; p = p.superlayer, d++) {
        id del = p.delegate;
        NSString *n = NSStringFromClass(del ? [del class] : [p class]);
        if (AACNameIsKeyboard(n)) return YES;
    }
    return NO;
}

#pragma mark - CGImage utils

// Tô màu lại glyph (giữ alpha, đổi RGB)
static CGImageRef AACCreateTinted(CGImageRef src, UIColor *color) {
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (!w || !h) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGRect r = CGRectMake(0, 0, w, h);
    CGContextDrawImage(ctx, r, src);
    CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CGContextFillRect(ctx, r);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

// Glyph có màu trung bình tối (đen) hay không
static BOOL AACImageIsDarkGlyph(CGImageRef img) {
    uint8_t px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 1, 1, 8, 4, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!c) return NO;
    CGContextSetInterpolationQuality(c, kCGInterpolationMedium);
    CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), img);
    CGContextRelease(c);
    if (px[3] < 8) return NO;
    CGFloat a = px[3] / 255.0;
    CGFloat lum = (0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]) / 255.0 / a;
    return lum < 0.30;
}

#pragma mark - Send button (nút gửi)

static BOOL AACIsMarkedSend(UIView *v) {
    return objc_getAssociatedObject(v, &kSendKey) != nil;
}

// v hoặc 1 trong 4 view cha là nút gửi
static BOOL AACViewInSendCircle(UIView *v) {
    int d = 0;
    for (UIView *p = v; p && d < 4; p = p.superview, d++) {
        if (AACIsMarkedSend(p)) return YES;
    }
    return NO;
}

// View nào đang giữ màu nền đen của nút
static UIView *AACDarkFillView(UIView *v) {
    UITraitCollection *tc = v.traitCollection;
    if (AACIsDark(v.backgroundColor, tc)) return v;
    if (v.layer.backgroundColor &&
        AACIsDark([UIColor colorWithCGColor:v.layer.backgroundColor], tc)) return v;

if (@available(iOS 15.0, *)) {
    if ([v isKindOfClass:[UIButton class]]) {
        UIButtonConfiguration *cf = ((UIButton *)v).configuration;
        if (cf && (AACIsDark(cf.baseBackgroundColor, tc) || AACIsDark(cf.background.backgroundColor, tc)))
            return v;
    }
}
    CGSize s = v.bounds.size;
    for (UIView *sub in v.subviews) {
        if (AACSkipClassName(NSStringFromClass([sub class]))) continue;
        if (sub.bounds.size.width >= s.width * 0.9 && sub.bounds.size.height >= s.height * 0.9) {
            if (AACIsDark(sub.backgroundColor, tc)) return sub;
            if (sub.layer.backgroundColor &&
                AACIsDark([UIColor colorWithCGColor:sub.layer.backgroundColor], tc)) return sub;
        }
    }
    return nil;
}

static BOOL AACIsRound(UIView *v) {
    CGFloat w = v.bounds.size.width;
    if (v.layer.cornerRadius >= w / 2 - 1.5) return YES;
    for (UIView *s in v.subviews) {
        if (s.bounds.size.width >= w * 0.9 && s.layer.cornerRadius >= w / 2 - 1.5) return YES;
    }
if (@available(iOS 15.0, *)) {
    if ([v isKindOfClass:[UIButton class]]) {
        UIButtonConfiguration *cf = ((UIButton *)v).configuration;
        if (cf && cf.background.cornerRadius >= w / 2 - 1.5) return YES;
        if (cf && cf.cornerStyle == UIButtonConfigurationCornerStyleCapsule) return YES;
    }
}
    return NO;
}

static BOOL AACHasIcon(UIView *v, int depth) {
    if (depth > 3) return NO;
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:[UIImageView class]] && ((UIImageView *)s).image) return YES;
        if (AACHasIcon(s, depth + 1)) return YES;
    }
    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:[CAShapeLayer class]] || l.contents) return YES;
    }
    return NO;
}

static BOOL AACDetectSend(UIView *v) {
    if (AACIsMarkedSend(v)) return YES;
    CGSize s = v.bounds.size;
    if (s.width < 24 || s.width > 64 || fabs(s.width - s.height) > 1.5) return NO;
    if (!AACDarkFillView(v)) return NO;
    if (!AACIsRound(v)) return NO;
    if (!AACHasIcon(v, 0)) return NO;
    return YES;
}

// Mũi tên -> trắng
static void AACWhitenImageView(UIImageView *iv) {
    UIImage *img = iv.image;
    if (img && img.renderingMode != UIImageRenderingModeAlwaysTemplate) {
        BOOL old = gGuard; gGuard = YES;
        iv.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        gGuard = old;
    }
    iv.tintColor = [UIColor whiteColor];
}

static void AACWhitenLayers(CALayer *l, int depth) {
    if (depth > 4) return;
    if ([l isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *sh = (CAShapeLayer *)l;
        CGColorRef white = [UIColor whiteColor].CGColor;
        if (sh.fillColor) sh.fillColor = white;
        if (sh.strokeColor) sh.strokeColor = white;
    }
    for (CALayer *s in l.sublayers) AACWhitenLayers(s, depth + 1);
}

static void AACWhiten(UIView *v, int depth) {
    if (depth > 4) return;
    if ([v isKindOfClass:[UIImageView class]]) AACWhitenImageView((UIImageView *)v);
    else if ([v isKindOfClass:[UILabel class]]) ((UILabel *)v).textColor = [UIColor whiteColor];
    AACWhitenLayers(v.layer, 0);
    for (UIView *s in v.subviews) AACWhiten(s, depth + 1);
}

static void AACApplySend(UIView *v) {
    UIColor *acc = AACAccent();
    UIView *fill = objc_getAssociatedObject(v, &kFillKey);
    if (!fill) {
        fill = AACDarkFillView(v);
        if (fill) objc_setAssociatedObject(v, &kFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(v, &kSendKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 1) Nền tròn -> accent
    if (fill) {
        fill.backgroundColor = acc;
        fill.layer.backgroundColor = acc.CGColor;
    }
if (@available(iOS 15.0, *)) {
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        UIButtonConfiguration *cf = b.configuration;
        if (cf && !([cf.baseBackgroundColor isEqual:acc] && [cf.baseForegroundColor isEqual:[UIColor whiteColor]])) {
            cf = [cf copy];
            cf.baseBackgroundColor = acc;
            cf.baseForegroundColor = [UIColor whiteColor];
            if (cf.background.backgroundColor) cf.background.backgroundColor = acc;
            b.configuration = cf;
        }
    }
}
    // 2) Mũi tên -> trắng (màu gốc)
    for (UIView *s in v.subviews) {
        if (s == fill && s != v) { if (!AACHasIcon(s, 0)) continue; }
        AACWhiten(s, 0);
    }
    AACWhitenLayers(v.layer, 0);
}

static void AACMaybeSend(UIView *v) {
    if (!gEnabled) return;
    CGFloat w = v.bounds.size.width;
    if (w < 24 || w > 64) return;
    if (AACDetectSend(v)) AACApplySend(v);
}

#pragma mark - Keyboard glyph (icon return/back màu đen -> accent)

static void AACProcessImageView(UIImageView *iv) {
    if (!gEnabled || gGuard || !iv.image) return;

    if (AACViewInSendCircle(iv)) { AACWhitenImageView(iv); return; }

    if (AACViewInKeyboard(iv)) {
        UIImage *img = iv.image;
        if (img.renderingMode == UIImageRenderingModeAlwaysTemplate) return;
        CGImageRef cg = img.CGImage;
        if (cg && MAX(CGImageGetWidth(cg), CGImageGetHeight(cg)) <= 240 && AACImageIsDarkGlyph(cg)) {
            BOOL old = gGuard; gGuard = YES;
            iv.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            gGuard = old;
            iv.tintColor = AACAccent();
        }
    }
}

static void AACProcessLayerContents(CALayer *l) {
    if (!gEnabled || gGuard) return;
    id c = l.contents;
    if (!c || CFGetTypeID(AAC_BRIDGE(CFTypeRef)c) != CGImageGetTypeID()) return;
    if (objc_getAssociatedObject(l, &kOutKey) == c) return;

    CGImageRef src = AAC_BRIDGE(CGImageRef)c;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (!w || !h || w > 240 || h > 240) return;

    UIColor *target = nil;
    UIView *owner = AACOwnerView(l);
    if (owner && !AACIsMarkedSend(owner) && AACViewInSendCircle(owner)) {
        target = [UIColor whiteColor];                 // mũi tên nút gửi
    } else if (AACLayerInKeyboard(l) && AACImageIsDarkGlyph(src)) {
        target = AACAccent();                          // icon return/back
    }
    if (!target) return;

    CGImageRef out = AACCreateTinted(src, target);
    if (!out) return;
    gGuard = YES;
    l.contents = AAC_BRIDGE(id)out;
    gGuard = NO;
    objc_setAssociatedObject(l, &kOutKey, AAC_BRIDGE(id)out, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGImageRelease(out);
}

static CGColorRef AACShapeColor(CAShapeLayer *l, CGColorRef c) {
    if (!gEnabled || !c) return c;
    UIView *o = AACOwnerView(l);
    if (o && AACViewInSendCircle(o)) return [UIColor whiteColor].CGColor;
    UIColor *uc = [UIColor colorWithCGColor:c];
    if (AACLayerInKeyboard(l) && AACIsDark(uc, nil)) return AACAccent().CGColor;
    if (AACIsBlueish(uc)) return AACAccent().CGColor;
    return c;
}

#pragma mark - Picker / menu

static void AACRefreshView(UIView *v, int depth) {
    if (depth > 40) return;
    [v tintColorDidChange];
    [v setNeedsLayout];
    [v setNeedsDisplay];
    if (AACIsMarkedSend(v)) AACApplySend(v);
    for (UIView *s in v.subviews) AACRefreshView(s, depth + 1);
}

static void AACRefreshAll(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            w.tintColor = AACAccent();
            AACRefreshView(w, 0);
        }
    }
}

static void AACSaveHex(NSString *hex) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:hex forKey:kHexKey];
    AACReloadPrefs();
    AACRefreshAll();
}

@interface AACHelper : NSObject <UIColorPickerViewControllerDelegate, UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation AACHelper

+ (instancetype)shared {
    static AACHelper *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [AACHelper new]; });
    return h;
}

- (UIViewController *)topVC {
    UIWindow *key = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) { key = w; break; } }
        if (key) break;
    }
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSString *hex = [[NSUserDefaults standardUserDefaults] stringForKey:kHexKey] ?: kDefaultHex;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"AccentColor"
                                                               message:[NSString stringWithFormat:@"#%@  •  %@", hex, gEnabled ? @"Bật" : @"Tắt"]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Chọn màu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self pickColor]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Nhập mã HEX" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self editHex]; }]];
    [a addAction:[UIAlertAction actionWithTitle:gEnabled ? @"Tắt tweak" : @"Bật tweak" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setBool:!gEnabled forKey:kEnabledKey];
        AACReloadPrefs();
        AACRefreshAll();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [[self topVC] presentViewController:a animated:YES completion:nil];
}

- (void)pickColor {
    UIColorPickerViewController *p = [UIColorPickerViewController new];
    p.selectedColor = AACAccent();
    p.supportsAlpha = NO;
    p.delegate = self;
    [[self topVC] presentViewController:p animated:YES completion:nil];
}

- (void)saveColor:(UIColor *)c {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if ([c getWhite:&w alpha:&a]) { r = g = b = w; } else return;
    }
    AACSaveHex([NSString stringWithFormat:@"%02X%02X%02X",
                (int)lround(r * 255), (int)lround(g * 255), (int)lround(b * 255)]);
}

- (void)colorPickerViewController:(UIColorPickerViewController *)vc didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    if (!continuously) [self saveColor:color];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc {
    [self saveColor:vc.selectedColor];
}

- (void)editHex {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Mã HEX" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"#RRGGBB";
        tf.text = [[NSUserDefaults standardUserDefaults] stringForKey:kHexKey] ?: kDefaultHex;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *t = a.textFields.firstObject.text;
        if (AACColorFromHex(t)) {
            t = [[t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
            if ([t hasPrefix:@"#"]) t = [t substringFromIndex:1];
            AACSaveHex(t);
        }
    }]];
    [[self topVC] presentViewController:a animated:YES completion:nil];
}

@end

static BOOL AACIsAppex(void) {
    return [[[NSBundle mainBundle].bundlePath pathExtension] isEqualToString:@"appex"];
}

#pragma mark - Hooks

%hook UIColor
+ (UIColor *)systemBlueColor { return gEnabled ? AACAccent() : %orig; }
+ (UIColor *)linkColor       { return gEnabled ? AACAccent() : %orig; }
%end

%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    if (!gEnabled) return;
    self.tintColor = AACAccent();
    if (AACIsAppex()) return;
    if (!objc_getAssociatedObject(self, &kGestureKey)) {
        UILongPressGestureRecognizer *g =
            [[UILongPressGestureRecognizer alloc] initWithTarget:[AACHelper shared] action:@selector(onLongPress:)];
        g.minimumPressDuration = 1.0;
        g.numberOfTouchesRequired = 3;
        g.cancelsTouchesInView = NO;
        g.delegate = [AACHelper shared];
        [self addGestureRecognizer:g];
        objc_setAssociatedObject(self, &kGestureKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
%end

%hook UIView
- (UIColor *)tintColor {
    if (!gEnabled) return %orig;
    if (AACViewInSendCircle(self)) return [UIColor whiteColor];   // mũi tên nút gửi giữ màu trắng
    return AACAccent();
}

- (void)setBackgroundColor:(UIColor *)c {
    if (gEnabled && c) {
        if (AACIsMarkedSend(self) && AACIsDark(c, self.traitCollection)) { %orig(AACAccent()); return; }
        if (AACIsBlueish(c) && !AACSkipClassName(NSStringFromClass([self class]))) { %orig(AACAccent()); return; }
    }
    %orig;
    if (gEnabled && c && !AACIsMarkedSend(self) && AACIsDark(c, nil)) AACMaybeSend(self);
}

- (void)layoutSubviews {
    %orig;
    AACMaybeSend(self);
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) AACMaybeSend(self);
}
%end

%hook UIImageView
- (void)setImage:(UIImage *)image {
    %orig;
    if (!gGuard) AACProcessImageView(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) AACProcessImageView(self);
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)c {
    if (gEnabled && c) {
        if (AACViewInSendCircle(self)) { %orig([UIColor whiteColor]); return; }
        if (AACIsBlueish(c) || (AACIsDark(c, self.traitCollection) && AACViewInKeyboard(self))) {
            %orig(AACAccent()); return;
        }
    }
    %orig;
}
- (void)didMoveToWindow {
    %orig;
    if (gEnabled && self.window && AACViewInKeyboard(self) && AACIsDark(self.textColor, self.traitCollection))
        self.textColor = AACAccent();
}
%end

%hook CALayer
- (void)setContents:(id)contents {
    %orig;
    AACProcessLayerContents(self);
}
- (void)layoutSublayers {
    %orig;
    AACProcessLayerContents(self);
}
- (void)setBackgroundColor:(CGColorRef)c {
    if (gEnabled && c && AACIsBlueish([UIColor colorWithCGColor:c])) { %orig(AACAccent().CGColor); return; }
    %orig;
}
%end

%hook CAShapeLayer
- (void)setFillColor:(CGColorRef)c   { %orig(AACShapeColor(self, c)); }
- (void)setStrokeColor:(CGColorRef)c { %orig(AACShapeColor(self, c)); }
%end

%hook UISwitch
- (void)setOnTintColor:(UIColor *)c { %orig(gEnabled ? AACAccent() : c); }
%end

%hook UISegmentedControl
- (void)setSelectedSegmentTintColor:(UIColor *)c { %orig(gEnabled ? AACAccent() : c); }
%end

%hook UIBarButtonItem
- (void)setTintColor:(UIColor *)c { %orig(gEnabled ? AACAccent() : c); }
%end

%ctor {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{ kEnabledKey: @YES, kHexKey: kDefaultHex }];
        AACReloadPrefs();
        %init;
    }
}

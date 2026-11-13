#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

typedef NS_ENUM(int, AACCat) { AACFill = 0, AACText = 0, AACIcon = 0, AACCount = 1 };

static NSString *const kMasterKey  = @"AccentColorAll_Enabled";
static NSString *const kHexKey     = @"AccentColorAll_Hex";
static NSString *const kDefaultHex = @"B8A8FF";

static const void *kFill        = &kFill;
static const void *kGestureFlag = &kGestureFlag;
static const void *kTintVer     = &kTintVer;
static const void *kIconShape   = &kIconShape;
static const void *kMonoBlack   = &kMonoBlack;
static const void *kAccentSrc   = &kAccentSrc;
static const void *kAccentStamp = &kAccentStamp;
static const void *kBlueState   = &kBlueState;
static const void *kBlueOut     = &kBlueOut;
static const void *kBlueStamp   = &kBlueStamp;
static const void *kBlueSrc     = &kBlueSrc;

static BOOL        gMaster = YES;
static BOOL        gOn[AACCount];
static UIColor    *gColor[AACCount];
static CGColorRef  gCGLight[AACCount], gCGDark[AACCount], gCGSoftLight[AACCount], gCGSoftDark[AACCount];
static BOOL        gDark = NO;
static int         gFillCount = 0;
static int         gVersion = 0;
static NSMutableArray *gKeep;
static __thread BOOL gRaw;
static BOOL        gInTry;
static BOOL        gInTabFix;
static volatile int32_t gPending;

@interface CALayer (AACPrivate)
- (void)setContentsMultiplyColor:(CGColorRef)c;
@end

static inline BOOL OnMain(void) { return [NSThread isMainThread]; }

static void TabBarFix(UITabBar *bar);

#pragma mark - Màu

static UIColor *ColorFromHex(NSString *s) {
    s = [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6) return nil;
    unsigned v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if (![sc scanHexInt:&v] || !sc.isAtEnd) return nil;
    gRaw = YES;
    UIColor *c = [UIColor colorWithRed:((v >> 16) & 255) / 255.0
                                 green:((v >> 8) & 255) / 255.0
                                  blue:(v & 255) / 255.0
                                 alpha:1.0];
    gRaw = NO;
    return c;
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

static UIColor *DarkVariant(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    CGFloat lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    const CGFloat target = 0.6;
    if (lum >= target) return c;
    CGFloat f = (target - lum) / (1.0 - lum);
    gRaw = YES;
    UIColor *o = [UIColor colorWithRed:r + (1 - r) * f green:g + (1 - g) * f blue:b + (1 - b) * f alpha:1.0];
    gRaw = NO;
    return o;
}

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

static inline BOOL IsOurs(CGColorRef c) {
    return c == gCGLight[0] || c == gCGDark[0] || c == gCGSoftLight[0] || c == gCGSoftDark[0];
}

static inline CGColorRef CGFor(int cat, BOOL soft) {
    if (gDark) return soft ? gCGSoftDark[cat] : gCGDark[cat];
    return soft ? gCGSoftLight[cat] : gCGLight[cat];
}

static NSString *CurHex(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d stringForKey:kHexKey] ?: [d stringForKey:@"AccentColorAll_Hex_0"] ?: kDefaultHex;
}

static void RefreshCache(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (!gKeep) gKeep = [NSMutableArray new];
    gMaster = [d boolForKey:kMasterKey];
    UIColor *light = ColorFromHex(CurHex()) ?: ColorFromHex(kDefaultHex);
    UIColor *dark = DarkVariant(light);
    UIColor *dyn = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
    [gKeep addObject:dyn];
    gCGLight[0] = CGColorCreateCopy(light.CGColor);
    gCGDark[0] = CGColorCreateCopy(dark.CGColor);
    gCGSoftLight[0] = CGColorCreateCopyWithAlpha(light.CGColor, 0.2);
    gCGSoftDark[0] = CGColorCreateCopyWithAlpha(dark.CGColor, 0.2);
    gColor[0] = dyn;
    gOn[0] = gMaster;
    gVersion++;
}

static void RefreshLayerTree(CALayer *l, int depth) {
    if (depth > 40) return;
    if ([l isKindOfClass:CAShapeLayer.class] && gOn[AACIcon]) {
        NSNumber *m = objc_getAssociatedObject(l, kIconShape);
        if (m) {
            CAShapeLayer *sh = (CAShapeLayer *)l;
            if (m.intValue & 1) sh.fillColor   = CGFor(AACIcon, NO);
            if (m.intValue & 2) sh.strokeColor = CGFor(AACIcon, NO);
        }
    }
    for (CALayer *sub in [l.sublayers copy]) RefreshLayerTree(sub, depth + 1);
}

static void RefreshViewTree(UIView *v, int depth) {
    if (depth > 40) return;
    if (gOn[AACFill]) {
        if ([v isKindOfClass:UISwitch.class]) ((UISwitch *)v).onTintColor = gColor[AACFill];
        else if ([v isKindOfClass:UISlider.class]) ((UISlider *)v).minimumTrackTintColor = gColor[AACFill];
    }
    if ([v isKindOfClass:UITabBar.class]) TabBarFix((UITabBar *)v);
    [v tintColorDidChange];
    [v setNeedsDisplay];
    for (UIView *s in [v.subviews copy]) RefreshViewTree(s, depth + 1);
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
            objc_setAssociatedObject(w, kTintVer, @(gVersion), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            RefreshViewTree(w, 0);
            RefreshLayerTree(w.layer, 0);
        }
    }
}

#pragma mark - Hỗ trợ hook

static void MarkFill(CALayer *l) {
    if (!OnMain()) return;
    if (l.bounds.size.height > 120) return;
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

static BOOL IsBlackColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return a >= 0.99 && r < 0.03 && g < 0.03 && b < 0.03;
}

static BOOL IsBlackCG(CGColorRef c) {
    if (!c || CGColorGetAlpha(c) < 0.99) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *k = CGColorGetComponents(c);
    if (!k) return NO;
    if (n == 2) return k[0] < 0.03;
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (n < 4 || !cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) return NO;
    return k[0] < 0.03 && k[1] < 0.03 && k[2] < 0.03;
}

// ---- Nền trắng (nút "Theo dõi" ở dark mode) ----

static BOOL IsWhiteColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return a >= 0.99 && r > 0.97 && g > 0.97 && b > 0.97;
}

static BOOL IsWhiteCG(CGColorRef c) {
    if (!c || CGColorGetAlpha(c) < 0.99) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *k = CGColorGetComponents(c);
    if (!k) return NO;
    if (n == 2) return k[0] > 0.97;
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (n < 4 || !cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) return NO;
    return k[0] > 0.97 && k[1] > 0.97 && k[2] > 0.97;
}

// Nền cần đổi sang accent: đen, hoặc trắng khi đang ở dark mode
static BOOL IsFillCandidateCG(CGColorRef c) {
    return IsBlackCG(c) || (gDark && IsWhiteCG(c));
}

static BOOL IsFillCandidateColor(UIColor *c) {
    return IsBlackColor(c) || (gDark && IsWhiteColor(c));
}

// Tránh đổi nhầm núm trắng của UISwitch / UISlider
static BOOL InControlKnob(CALayer *l) {
    id d = l.delegate;
    if (![d isKindOfClass:UIView.class]) return NO;
    UIView *v = (UIView *)d;
    for (int i = 0; i < 6 && v; i++, v = v.superview)
        if ([v isKindOfClass:UISwitch.class] || [v isKindOfClass:UISlider.class]) return YES;
    return NO;
}

static CGColorRef LayerRemap(CGColorRef c, int cat, int *clsOut) {
    if (!c || !gOn[cat] || IsOurs(c)) return NULL;
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

static UIColor *ColorRemap(UIColor *c, int cat, int *clsOut) {
    if (!c || !gOn[cat] || gRaw) return nil;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return nil;
    int cls = BlueClass(r, g, b);
    if (cls == 0) return nil;
    if (clsOut) *clsOut = cls;
    return cls == 2 ? [gColor[cat] colorWithAlphaComponent:0.2] : gColor[cat];
}

static UIColor *RemapRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    if (gRaw || !gMaster || !gOn[AACFill] || !gColor[AACFill]) return nil;
    int cls = BlueClass(r, g, b);
    if (!cls) return nil;
    CGFloat al = (cls == 2 ? 0.2 : 1.0) * a;
    if (al >= 0.99) return gColor[AACFill];
    gRaw = YES;
    UIColor *res = [gColor[AACFill] colorWithAlphaComponent:al];
    gRaw = NO;
    return res;
}

static BOOL IsAccentCG(CGColorRef c) {
    if (!c || !gColor[0]) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *k = CGColorGetComponents(c);
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (!k || n < 4 || !cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB || CGColorGetAlpha(c) < 0.99) return NO;
    for (int d = 0; d < 2; d++) {
        CGColorRef a = d ? gCGDark[0] : gCGLight[0];
        const CGFloat *q = CGColorGetComponents(a);
        if (q && fabs(k[0] - q[0]) < 0.02 && fabs(k[1] - q[1]) < 0.02 && fabs(k[2] - q[2]) < 0.02) return YES;
    }
    return NO;
}

static BOOL LayerUnderFill(CALayer *l) {
    for (int i = 0; i < 4 && l; i++, l = l.superlayer)
        if (objc_getAssociatedObject(l, kFill) || IsAccentCG(l.backgroundColor)) return YES;
    return NO;
}

// Avatar: view bo tròn + cắt theo bounds -> không đụng vào ảnh bên trong
static BOOL LooksLikeAvatarView(UIView *v) {
    if (!v) return NO;
    CALayer *l = v.layer;
    if (!l.masksToBounds || l.cornerRadius <= 0) return NO;
    CGSize s = v.bounds.size;
    if (s.width <= 0 || s.height <= 0) return YES;
    return l.cornerRadius >= fmin(s.width, s.height) * 0.25;
}

static void TryBlack(CALayer *l) {
    if (!gOn[AACFill] || !OnMain()) return;
    CGSize sz = l.bounds.size;
    // Không đổi nền của UIImageView / layer đang hiển thị ảnh / hình tròn (avatar)
    id dv = l.delegate;
    if ([dv isKindOfClass:UIImageView.class] || l.contents) return;
    if (sz.width > 0 && fabs(sz.width - sz.height) < 2 && l.cornerRadius >= sz.width * 0.45) return;
    BOOL nested = LayerUnderFill(l.superlayer);
    CGColorRef bg = l.backgroundColor;
    BOOL cand = IsFillCandidateCG(bg) && !(IsWhiteCG(bg) && InControlKnob(l));
    if (cand && sz.height >= 14 && sz.height <= 64 && sz.width >= 14 && (l.cornerRadius >= 6 || nested)) {
        l.backgroundColor = CGFor(AACFill, NO);
        MarkFill(l);
    }
    if (l.borderWidth > 0 && IsBlackCG(l.borderColor) && (nested || LayerUnderFill(l))) {
        l.borderColor = CGFor(AACFill, NO);
    }
}

// Label nằm trong nút đã đổi accent mà vẫn giữ nền đen/trắng -> làm trong suốt
static void FixLabelBG(UILabel *lb) {
    if (!gMaster || !gOn[AACFill] || !OnMain()) return;
    UIColor *bg = lb.backgroundColor;
    if (!bg || !IsFillCandidateColor(bg)) return;
    if (lb.bounds.size.height > 64) return;
    if (UnderFill(lb.superview) || LayerUnderFill(lb.layer.superlayer)) {
        lb.backgroundColor = UIColor.clearColor;
    }
}

static void TryBlackShape(CAShapeLayer *sh) {
    if (!gOn[AACFill] || !OnMain()) return;
    if (!IsBlackCG(sh.fillColor)) return;
    CGPathRef path = sh.path;
    if (!path || CGPathIsEmpty(path)) return;
    CGRect b = CGPathGetBoundingBox(path);
    if (CGRectIsNull(b) || CGRectIsInfinite(b) || isnan(b.size.width) || isnan(b.size.height)) return;
    if (b.size.height < 20 || b.size.height > 64 || b.size.width < b.size.height * 1.6) return;
    sh.fillColor = CGFor(AACFill, NO);
}

static void TryBlackIconShape(CAShapeLayer *sh) {
    if (!gOn[AACIcon] || gInTry || !OnMain()) return;
    BOOL fill = IsBlackCG(sh.fillColor), stroke = IsBlackCG(sh.strokeColor);
    if (!fill && !stroke) return;
    CGPathRef path = sh.path;
    if (!path || CGPathIsEmpty(path)) return;
    CGRect b = CGPathGetBoundingBox(path);
    if (CGRectIsNull(b) || CGRectIsInfinite(b) || isnan(b.size.width) || isnan(b.size.height)) return;
    CGFloat mx = fmax(b.size.width, b.size.height);
    if (mx < 6 || mx > 48) return;
    gInTry = YES;
    int bits = 0;
    if (fill)   { sh.fillColor   = CGFor(AACIcon, NO); bits |= 1; }
    if (stroke) { sh.strokeColor = CGFor(AACIcon, NO); bits |= 2; }
    gInTry = NO;
    NSNumber *old = objc_getAssociatedObject(sh, kIconShape);
    objc_setAssociatedObject(sh, kIconShape, @(bits | old.intValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSHashTable *gPend;
static volatile int32_t gHasPend;
static const void *kAttempts  = &kAttempts;
static const void *kPendShape = &kPendShape;
#define PEND_LOCK @"AACPend"

static void RunCheck(CALayer *l, BOOL shape) {
    if (shape && [l isKindOfClass:CAShapeLayer.class]) {
        TryBlackShape((CAShapeLayer *)l);
        TryBlackIconShape((CAShapeLayer *)l);
    } else {
        TryBlack(l);
    }
}

static BOOL CheckDone(CALayer *l, BOOL shape) {
    if (shape && [l isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *sh = (CAShapeLayer *)l;
        return !IsBlackCG(sh.fillColor) && !IsBlackCG(sh.strokeColor);
    }
    return !IsFillCandidateCG(l.backgroundColor) && !(l.borderWidth > 0 && IsBlackCG(l.borderColor));
}

static void AddPending(CALayer *l, BOOL shape) {
    @synchronized (PEND_LOCK) {
        if (!gPend) gPend = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
        if (gPend.count > 400) return;
        [gPend addObject:l];
        gHasPend = 1;
    }
    objc_setAssociatedObject(l, kPendShape, @(shape), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void PendingRun(CALayer *l) {
    BOOL has;
    @synchronized (PEND_LOCK) { has = [gPend containsObject:l]; }
    if (!has) return;
    BOOL shape = [objc_getAssociatedObject(l, kPendShape) boolValue];
    RunCheck(l, shape);
    int n = [objc_getAssociatedObject(l, kAttempts) intValue] + 1;
    objc_setAssociatedObject(l, kAttempts, @(n), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (n >= 8 || CheckDone(l, shape)) {
        @synchronized (PEND_LOCK) {
            [gPend removeObject:l];
            if (!gPend.count) gHasPend = 0;
        }
    }
}

static void ScheduleCheck(CALayer *l, BOOL shape) {
    if (!l) return;
    if (OnMain()) {
        RunCheck(l, shape);
        if (CheckDone(l, shape)) return;
    }
    AddPending(l, shape);
    if (gPending > 96) return;
    __sync_fetch_and_add(&gPending, 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        RunCheck(l, shape);
        __sync_fetch_and_sub(&gPending, 1);
    });
}

static BOOL ImageIsBlackMono(UIImage *img) {
    NSNumber *cached = objc_getAssociatedObject(img, kMonoBlack);
    if (cached) return cached.boolValue;
    static CFAbsoluteTime winStart; static int winCount;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - winStart > 1.0) { winStart = now; winCount = 0; }
    if (++winCount > 120) return NO;
    BOOL res = NO;
    CGImageRef cg = img.CGImage;
    if (cg && img.images.count <= 1) {
        enum { N = 24 };
        uint8_t buf[N * N * 4];
        memset(buf, 0, sizeof buf);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(buf, N, N, 8, N * 4, cs,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, N, N), cg);
            CGContextRelease(ctx);
            int solid = 0, clear = 0, bad = 0;
            for (int i = 0; i < N * N; i++) {
                const uint8_t *px = buf + i * 4;
                if (px[3] < 40) { clear++; continue; }
                solid++;
                int mxc = MAX(px[0], MAX(px[1], px[2]));
                if (mxc * 255 > 40 * px[3]) { bad++; break; }
            }
            // Icon đen thường là nét mảnh (<= ~62% diện tích). Ảnh đen đặc/avatar thì bỏ qua.
            res = (solid >= 6 && clear >= 1 && bad == 0 && solid * 100 <= N * N * 62);
        }
    }
    objc_setAssociatedObject(img, kMonoBlack, @(res), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return res;
}

static UIImage *IconRemapImage(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.isSymbolImage) return img;
    CGSize sz = img.size;
    if (sz.width < 8 || sz.height < 8 || sz.width > 64 || sz.height > 64) return img;
    if (!ImageIsBlackMono(img)) return img;
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// Ảnh/symbol đã được tô sẵn màu xanh (palette/hierarchical hoặc PNG) -> tô lại theo accent
static UIImage *BlueImageRemap(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
    if (objc_getAssociatedObject(img, kBlueSrc) || objc_getAssociatedObject(img, kAccentSrc)) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate) return img;
    CGSize sz = img.size;
    if (sz.width < 8 || sz.height < 8 || sz.width > 64 || sz.height > 64 || img.images.count > 1) return img;

    NSNumber *state = objc_getAssociatedObject(img, kBlueState);
    if (state && !state.boolValue) return img;
    int want = gVersion * 2 + (gDark ? 1 : 0);
    if (state) {
        UIImage *cached = objc_getAssociatedObject(img, kBlueOut);
        if (cached && [objc_getAssociatedObject(img, kBlueStamp) intValue] == want) return cached;
    } else {
        static CFAbsoluteTime winStart; static int winCount;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - winStart > 1.0) { winStart = now; winCount = 0; }
        if (++winCount > 60) return img;
    }

    CGFloat scale = img.scale > 0 ? img.scale : 1;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIImage *flat = [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt]
        imageWithActions:^(UIGraphicsImageRendererContext *rc) {
            [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
        }];
    CGImageRef cg = flat.CGImage;
    size_t w = cg ? CGImageGetWidth(cg) : 0, h = cg ? CGImageGetHeight(cg) : 0;
    if (!cg || w == 0 || h == 0 || w > 256 || h > 256) {
        objc_setAssociatedObject(img, kBlueState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }

    uint8_t *buf = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        free(buf);
        return img;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);

    int solid = 0, blue = 0, other = 0;
    for (size_t i = 0; i < w * h; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        solid++;
        CGFloat a = px[3];
        if (BlueClass(fmin(1, px[0] / a), fmin(1, px[1] / a), fmin(1, px[2] / a))) blue++;
        else other++;
    }
    BOOL ok = solid >= 6 && blue > 0 && other * 40 <= solid;
    if (!ok) {
        CGContextRelease(ctx);
        free(buf);
        objc_setAssociatedObject(img, kBlueState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }

    const CGFloat *k = CGColorGetComponents(CGFor(AACIcon, NO));
    CGFloat ar = k[0], ag = k[1], ab = k[2];
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        CGFloat a = px[3];
        int cls = BlueClass(fmin(1, px[0] / a), fmin(1, px[1] / a), fmin(1, px[2] / a));
        if (!cls) continue;
        CGFloat al = (a / 255.0) * (cls == 2 ? 0.2 : 1.0);
        px[0] = (uint8_t)lround(fmax(0, fmin(1, ar)) * al * 255);
        px[1] = (uint8_t)lround(fmax(0, fmin(1, ag)) * al * 255);
        px[2] = (uint8_t)lround(fmax(0, fmin(1, ab)) * al * 255);
        px[3] = (uint8_t)lround(al * 255);
    }
    CGImageRef outCG = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    if (!outCG) return img;
    UIImage *out = [UIImage imageWithCGImage:outCG scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(outCG);

    objc_setAssociatedObject(out, kBlueSrc, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kBlueState, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kBlueOut, out, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kBlueStamp, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

static UIColor *IconTintFix(UIColor *c) {
    if (gMaster && gOn[AACIcon] && c && OnMain()) {
        if (IsBlackColor(c)) return gColor[AACIcon];
        UIColor *n = ColorRemap(c, AACIcon, NULL);
        if (n) return n;
    }
    return c;
}

#pragma mark - Tab bar

static BOOL InTabBar(UIView *v) {
    for (int i = 0; i < 10 && v; i++, v = v.superview)
        if ([v isKindOfClass:UITabBar.class]) return YES;
    return NO;
}

static UIImage *TabColorize(UIImage *im) {
    if (!im || !gMaster || !gOn[AACIcon] || !OnMain()) return im;
    int want = gVersion * 2 + (gDark ? 1 : 0);
    UIImage *src = objc_getAssociatedObject(im, kAccentSrc);
    NSNumber *stamp = objc_getAssociatedObject(im, kAccentStamp);
    if (src && stamp.intValue == want) return im;
    UIImage *base = src ?: im;
    CGSize sz = base.size;
    if (sz.width > 80 || sz.height > 80) return im;
    BOOL ok = base.renderingMode == UIImageRenderingModeAlwaysTemplate || base.isSymbolImage || ImageIsBlackMono(base);
    if (!ok) return im;
    UIColor *c = [UIColor colorWithCGColor:CGFor(AACIcon, NO)];
    UIImage *out = [base imageWithTintColor:c renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!out) return im;
    objc_setAssociatedObject(out, kAccentSrc, base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(out, kAccentStamp, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

static void TabFixView(UIView *v, int depth) {
    if (depth > 10) return;
    if ([v isKindOfClass:UIImageView.class]) {
        UIImageView *iv = (UIImageView *)v;
        UIImage *im = iv.image;
        if (im && !LooksLikeAvatarView(iv)) {
            UIImage *n = TabColorize(IconRemapImage(im));
            if (n != im) iv.image = n;
        }
    }
    for (UIView *s in [v.subviews copy]) TabFixView(s, depth + 1);
}

static void TabBarFix(UITabBar *bar) {
    if (!bar || !gMaster || !gOn[AACIcon] || gInTabFix || !OnMain()) return;
    gInTabFix = YES;
    TabFixView(bar, 0);
    gInTabFix = NO;
}

static void TabBarFixLater(UITabBar *bar) {
    dispatch_async(dispatch_get_main_queue(), ^{ TabBarFix(bar); });
}

// Chữ dưới tab bar (tab chưa chọn đang màu đen) -> màu accent
static void TabLabelFix(UILabel *lb) {
    if (!gMaster || !gOn[AACIcon] || !gColor[AACIcon] || !OnMain()) return;
    if (lb.textColor == gColor[AACIcon]) return;
    if (!InTabBar(lb)) return;
    lb.textColor = gColor[AACIcon];
}

#pragma mark - Bảng cài đặt

static UIViewController *TopVC(UIWindow *w) {
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

static NSString *HexCG(CGColorRef c) {
    if (!c) return @"nil";
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *k = CGColorGetComponents(c);
    if (!k) return @"?";
    CGFloat al = CGColorGetAlpha(c);
    NSString *h = n >= 3 ? HexFromRGB(k[0], k[1], k[2]) : HexFromRGB(k[0], k[0], k[0]);
    return al < 0.99 ? [NSString stringWithFormat:@"%@@%.2f", h, al] : h;
}

static void DumpLayer(CALayer *l, int depth, NSMutableString *out) {
    if (depth > 30 || out.length > 60000) return;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@%@", pad, NSStringFromClass(l.class)];
    id d = l.delegate;
    if ([d isKindOfClass:UIView.class]) [line appendFormat:@" view=%@", NSStringFromClass([d class])];
    CGRect f = l.frame;
    [line appendFormat:@" [%.0f,%.0f %.0fx%.0f]", f.origin.x, f.origin.y, f.size.width, f.size.height];
    if (l.backgroundColor) [line appendFormat:@" bg=%@", HexCG(l.backgroundColor)];
    if ([l isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *sh = (CAShapeLayer *)l;
        if (sh.fillColor) [line appendFormat:@" fill=%@", HexCG(sh.fillColor)];
        if (sh.strokeColor) [line appendFormat:@" stroke=%@", HexCG(sh.strokeColor)];
    }
    if (l.contents) [line appendFormat:@" contents=%@", NSStringFromClass([(id)l.contents class])];
    @try {
        id mc = [l valueForKey:@"contentsMultiplyColor"];
        if (mc) [line appendFormat:@" multiply=%@", HexCG((__bridge CGColorRef)mc)];
    } @catch (__unused id e) {}
    [out appendFormat:@"%@\n", line];
    for (CALayer *s in [l.sublayers copy]) DumpLayer(s, depth + 1, out);
}

@interface AACSettingsVC : UITableViewController <UIColorPickerViewControllerDelegate>
@end

@implementation AACSettingsVC

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Màu nhấn";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 4; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return @"Màu nhấn"; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.row == 0) {
        cell.textLabel.text = @"Bật màu nhấn";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new];
        sw.on = [d boolForKey:kMasterKey];
        [sw addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (ip.row == 1) {
        cell.textLabel.text = @"Mã màu";
        cell.detailTextLabel.text = [@"#" stringByAppendingString:CurHex()];
        UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
        sw.layer.cornerRadius = 12;
        sw.backgroundColor = ColorFromHex(CurHex()) ?: ColorFromHex(kDefaultHex);
        sw.layer.borderWidth = 1;
        sw.layer.borderColor = UIColor.separatorColor.CGColor;
        cell.accessoryView = sw;
    } else if (ip.row == 2) {
        cell.textLabel.text = @"Chọn màu…";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = @"Sao chép thông tin debug";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 1) [self editHex];
    else if (ip.row == 2) [self pickColor];
    else if (ip.row == 3) [self dumpDebug];
}

- (void)dumpDebug {
    UIViewController *root = self.view.window.rootViewController;
    NSMutableString *out = [NSMutableString stringWithFormat:@"gDark=%d fillCount=%d hex=%@\n", gDark, gFillCount, CurHex()];
    if (root.view) DumpLayer(root.view.layer, 0, out);
    UIPasteboard.generalPasteboard.string = out;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Đã sao chép"
        message:@"Dán nội dung vào cuộc trò chuyện để gửi lại." preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)masterChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.isOn forKey:kMasterKey];
    ApplyAll();
}

- (void)editHex {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Mã màu" message:@"Nhập #RRGGBB"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [@"#" stringByAppendingString:CurHex()];
        tf.placeholder = @"#RRGGBB";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *wac = ac;
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIColor *col = ColorFromHex(wac.textFields.firstObject.text);
        if (col) [ws saveColor:col];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)pickColor {
    UIColorPickerViewController *p = [UIColorPickerViewController new];
    p.delegate = self;
    p.supportsAlpha = NO;
    p.selectedColor = ColorFromHex(CurHex()) ?: ColorFromHex(kDefaultHex);
    [self presentViewController:p animated:YES completion:nil];
}

- (void)saveColor:(UIColor *)col {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:HexFromColor(col) forKey:kHexKey];
    [d setBool:YES forKey:kMasterKey];
    ApplyAll();
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)vc { [self saveColor:vc.selectedColor]; }
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc { [self saveColor:vc.selectedColor]; }
@end

@interface AACHelper : NSObject <UIGestureRecognizerDelegate>
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
    UIViewController *top = TopVC(win);
    if (!top) return;
    if ([top isKindOfClass:UINavigationController.class] &&
        [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:AACSettingsVC.class]) return;
    if ([top isKindOfClass:UIAlertController.class] || [top isKindOfClass:UIColorPickerViewController.class]) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[AACSettingsVC new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}
@end

static void Setup(UIWindow *w) {
    if (!OnMain()) return;
    if (!objc_getAssociatedObject(w, kGestureFlag)) {
        NSString *cn = NSStringFromClass(w.class);
        BOOL skip = w.windowLevel > UIWindowLevelNormal ||
            [cn containsString:@"Keyboard"] || [cn containsString:@"TextEffects"] || [cn containsString:@"Shim"];
        objc_setAssociatedObject(w, kGestureFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!skip) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc]
                    initWithTarget:[AACHelper shared] action:@selector(onLongPress:)];
                g.numberOfTouchesRequired = 3;
                g.minimumPressDuration = 1.0;
                g.cancelsTouchesInView = NO;
                g.delegate = [AACHelper shared];
                [w addGestureRecognizer:g];
            });
        }
    }
    gDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NSNumber *tv = objc_getAssociatedObject(w, kTintVer);
    if (!tv || tv.intValue != gVersion) {
        objc_setAssociatedObject(w, kTintVer, @(gVersion), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        w.tintColor = gOn[AACIcon] ? gColor[AACIcon] : nil;
    }
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
    if (!gMaster || !gOn[AACIcon] || !gColor[AACIcon]) return %orig;
    if (gFillCount > 0 && gOn[AACFill] && OnMain() && UnderFill(self)) return UIColor.whiteColor;
    return gColor[AACIcon];
}
- (void)setTintColor:(UIColor *)c {
    if (gMaster && gOn[AACIcon] && c && OnMain() && IsBlackColor(c)) { %orig(gColor[AACIcon]); return; }
    %orig;
}
- (void)setBackgroundColor:(UIColor *)c {
    if (!gMaster || !c) { %orig; return; }
    if (!OnMain()) { UIColor *m = ColorRemap(c, AACFill, NULL); %orig(m ?: c); return; }
    int cls = 0;
    UIColor *n = ColorRemap(c, AACFill, &cls);
    %orig(n ?: c);
    if (n && cls == 1) MarkFill(self.layer);
    else if (!n && gOn[AACFill] && IsFillCandidateColor(c)) ScheduleCheck(self.layer, NO);
}
%end

%hook CALayer
- (void)layoutSublayers {
    %orig;
    if (gHasPend && OnMain()) PendingRun(self);
}
- (void)setBackgroundColor:(CGColorRef)c {
    if (!gMaster || !c) { %orig; return; }
    int cls = 0;
    CGColorRef n = LayerRemap(c, AACFill, &cls);
    if (n) { %orig(n); if (cls == 1 && OnMain()) MarkFill(self); return; }
    %orig;
    if (gOn[AACFill] && IsFillCandidateCG(c)) ScheduleCheck(self, NO);
}
- (void)setBorderColor:(CGColorRef)c {
    CGColorRef n = gMaster ? LayerRemap(c, AACFill, NULL) : NULL;
    if (n) { %orig(n); return; }
    %orig;
    if (gMaster && gOn[AACFill] && IsBlackCG(c)) ScheduleCheck(self, NO);
}
// SwiftUI tô symbol/template image bằng contentsMultiplyColor
- (void)setContentsMultiplyColor:(CGColorRef)c {
    CGColorRef n = (gMaster && c) ? LayerRemap(c, AACIcon, NULL) : NULL;
    %orig(n ?: c);
}
%end

%hook CATextLayer
- (void)setForegroundColor:(CGColorRef)c {
    CGColorRef n = (gMaster && c) ? LayerRemap(c, AACIcon, NULL) : NULL;
    %orig(n ?: c);
}
%end


%hook CAShapeLayer
- (void)setFillColor:(CGColorRef)c {
    if (!gMaster || !c) { %orig; return; }
    CGColorRef n = LayerRemap(c, AACIcon, NULL);
    if (n) { %orig(n); return; }
    %orig;
    if (!gInTry && (gOn[AACFill] || gOn[AACIcon]) && IsBlackCG(c)) ScheduleCheck(self, YES);
}
- (void)setStrokeColor:(CGColorRef)c {
    if (!gMaster || !c) { %orig; return; }
    CGColorRef n = LayerRemap(c, AACIcon, NULL);
    if (n) { %orig(n); return; }
    %orig;
    if (!gInTry && gOn[AACIcon] && IsBlackCG(c)) ScheduleCheck(self, YES);
}
%end

%hook UISegmentedControl
- (void)setSelectedSegmentTintColor:(UIColor *)c {
    UIColor *n = (gMaster && gOn[AACFill] && c && OnMain() && IsBlackColor(c)) ? gColor[AACFill] : nil;
    %orig(n ?: c);
}
- (void)didMoveToWindow {
    %orig;
    if (gMaster && gOn[AACFill] && OnMain()) {
        UIColor *cur = self.selectedSegmentTintColor;
        if (cur && IsBlackColor(cur)) self.selectedSegmentTintColor = gColor[AACFill];
    }
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)c {
    UIColor *n = gMaster ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) { FixLabelBG(self); TabLabelFix(self); }
}
- (void)layoutSubviews {
    %orig;
    FixLabelBG(self);
    TabLabelFix(self);
}
%end

%hook UIButton
- (void)setTitleColor:(UIColor *)c forState:(UIControlState)st {
    UIColor *n = gMaster ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c, st);
}
- (void)setImage:(UIImage *)img forState:(UIControlState)st {
    %orig(BlueImageRemap(IconRemapImage(img)), st);
}
%end

%hook UIImageView
- (void)setImage:(UIImage *)img {
    if (OnMain() && LooksLikeAvatarView(self)) { %orig(img); return; }
    UIImage *n = BlueImageRemap(IconRemapImage(img));
    if (n && gMaster && gOn[AACIcon] && OnMain()) {
        CGSize s = n.size;
        if (s.width <= 80 && s.height <= 80 && InTabBar(self)) n = TabColorize(n);
    }
    %orig(n);
}
%end

%hook UIImage
- (UIImage *)imageWithTintColor:(UIColor *)c renderingMode:(UIImageRenderingMode)m {
    return %orig(IconTintFix(c), m);
}
- (UIImage *)imageWithTintColor:(UIColor *)c {
    return %orig(IconTintFix(c));
}
%end

%hook UITabBar
- (void)layoutSubviews { %orig; TabBarFix(self); }
- (void)didMoveToWindow { %orig; if (self.window) TabBarFixLater(self); }
- (void)setSelectedItem:(UITabBarItem *)item { %orig; TabBarFixLater(self); }
- (void)traitCollectionDidChange:(UITraitCollection *)prev { %orig; TabBarFixLater(self); }
- (void)setUnselectedItemTintColor:(UIColor *)c {
    %orig((gMaster && gOn[AACIcon] && c && OnMain() && IsBlackColor(c)) ? gColor[AACIcon] : c);
}
%end

%hook UITabBarItemStateAppearance
- (void)setIconColor:(UIColor *)c {
    %orig((gMaster && gOn[AACIcon] && c && OnMain() && IsBlackColor(c)) ? gColor[AACIcon] : c);
}
- (void)setTitleTextAttributes:(NSDictionary<NSAttributedStringKey, id> *)attrs {
    if (gMaster && gOn[AACIcon] && gColor[AACIcon] && OnMain()) {
        NSMutableDictionary *m = attrs ? [attrs mutableCopy] : [NSMutableDictionary new];
        m[NSForegroundColorAttributeName] = gColor[AACIcon];
        attrs = m;
    }
    %orig(attrs);
}
%end

%hook UIImageSymbolConfiguration
+ (UIImageSymbolConfiguration *)configurationWithHierarchicalColor:(UIColor *)c {
    return %orig(IconTintFix(c));
}
+ (UIImageSymbolConfiguration *)configurationWithPaletteColors:(NSArray<UIColor *> *)colors {
    NSMutableArray *m = [NSMutableArray arrayWithCapacity:colors.count];
    for (UIColor *c in colors) [m addObject:IconTintFix(c)];
    return %orig(m);
}
%end

%hook UISwitch
- (void)setOnTintColor:(UIColor *)c {
    %orig((gMaster && gOn[AACFill]) ? gColor[AACFill] : c);
}
- (UIColor *)onTintColor {
    if (gMaster && gOn[AACFill]) return gColor[AACFill];
    return %orig;
}
- (void)didMoveToWindow {
    %orig;
    if (gMaster && gOn[AACFill] && OnMain()) self.onTintColor = gColor[AACFill];
}
%end

%hook UIColor
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return RemapRGBA(r, g, b, a) ?: %orig;
}
+ (UIColor *)colorWithDisplayP3Red:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return RemapRGBA(r, g, b, a) ?: %orig;
}
- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    UIColor *n = RemapRGBA(r, g, b, a);
    return n ?: %orig;
}
+ (UIColor *)systemBlueColor {
    if (gMaster && gOn[AACIcon] && gColor[AACIcon]) return gColor[AACIcon];
    return %orig;
}
+ (UIColor *)linkColor {
    if (gMaster && gOn[AACText] && gColor[AACText]) return gColor[AACText];
    return %orig;
}
%end

%ctor {
    @autoreleasepool {
        NSString *bp = NSBundle.mainBundle.bundlePath;
        if (!bp || [bp.pathExtension isEqualToString:@"appex"]) return;
        [NSUserDefaults.standardUserDefaults registerDefaults:@{ kMasterKey: @YES }];
        RefreshCache();
        %init;
    }
}

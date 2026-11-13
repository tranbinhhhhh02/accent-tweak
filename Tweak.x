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
static const void *kCtxOut      = &kCtxOut;
static const void *kCtxSrc      = &kCtxSrc;
static const void *kCtxStamp    = &kCtxStamp;
static const void *kCtxSkip     = &kCtxSkip;
static const void *kWhitenN     = &kWhitenN;

static BOOL        gMaster = YES;
static BOOL        gOn[AACCount];
static UIColor    *gColor[AACCount];
static CGColorRef  gCGLight[AACCount], gCGDark[AACCount], gCGSoftLight[AACCount], gCGSoftDark[AACCount];
static CGColorRef  gCGWhite;
static BOOL        gDark = NO;
static int         gFillCount = 0;
static int         gVersion = 0;
static NSMutableArray *gKeep;
static __thread BOOL gRaw;
static BOOL        gInTry;
static BOOL        gInTabFix;
static BOOL        gInContents;
static BOOL        gApplying;
static volatile int32_t gPending;

@interface CALayer (AACPrivate)
- (void)setContentsMultiplyColor:(CGColorRef)c;
- (CGColorRef)contentsMultiplyColor;
@end

static inline BOOL OnMain(void) { return [NSThread isMainThread]; }

static void TabBarFix(UITabBar *bar);
static void WhitenOnFill(CALayer *fill);
static void ContentsCheck(CALayer *l);

#pragma mark - Màu

static UIColor *ColorFromHex(NSString *s) {
    s = [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6) return nil;
    unsigned v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if (![sc scanHexInt:&v] || !sc.isAtEnd) return nil;
    BOOL old = gRaw;
    gRaw = YES;
    UIColor *c = [UIColor colorWithRed:((v >> 16) & 255) / 255.0
                                 green:((v >> 8) & 255) / 255.0
                                  blue:(v & 255) / 255.0
                                 alpha:1.0];
    gRaw = old;
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
    BOOL old = gRaw;
    gRaw = YES;
    UIColor *o = [UIColor colorWithRed:r + (1 - r) * f green:g + (1 - g) * f blue:b + (1 - b) * f alpha:1.0];
    gRaw = old;
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
    return c && (c == gCGLight[0] || c == gCGDark[0] || c == gCGSoftLight[0] || c == gCGSoftDark[0] || c == gCGWhite);
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
    // Các CGColor cũ cố ý không release: layer có thể còn đang giữ con trỏ này
    gCGLight[0] = CGColorCreateCopy(light.CGColor);
    gCGDark[0] = CGColorCreateCopy(dark.CGColor);
    gCGSoftLight[0] = CGColorCreateCopyWithAlpha(light.CGColor, 0.2);
    gCGSoftDark[0] = CGColorCreateCopyWithAlpha(dark.CGColor, 0.2);
    if (!gCGWhite) {
        BOOL old = gRaw;
        gRaw = YES;
        gCGWhite = CGColorCreateCopy([UIColor colorWithRed:1 green:1 blue:1 alpha:1].CGColor);
        gRaw = old;
    }
    gColor[0] = dyn;
    gOn[0] = gMaster;
    gVersion++;
}

#pragma mark - Phân loại màu

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

// Độ sáng của màu trung tính (xám/đen/trắng). -1 nếu không phải màu trung tính đục
static CGFloat NeutralLumCG(CGColorRef c) {
    if (!c || CGColorGetAlpha(c) < 0.99) return -1;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *k = CGColorGetComponents(c);
    if (!k) return -1;
    if (n == 2) return k[0];
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (n < 4 || !cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) return -1;
    CGFloat mx = fmax(k[0], fmax(k[1], k[2])), mn = fmin(k[0], fmin(k[1], k[2]));
    if (mx - mn > 0.08) return -1;
    return (k[0] + k[1] + k[2]) / 3.0;
}

// Màu "chữ/icon" thông thường: đen/xám đậm ở light mode, trắng/xám nhạt ở dark mode
static BOOL IsFgLum(CGFloat l) {
    if (l < 0) return NO;
    if (l < 0.12) return YES;
    return gDark ? (l > 0.55) : (l < 0.5);
}

static BOOL IsIconFgCG(CGColorRef c) {
    return IsFgLum(NeutralLumCG(c));
}

static BOOL IsAccentCG(CGColorRef c) {
    if (!c || !gColor[0] || !gCGLight[0] || !gCGDark[0]) return NO;
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

static BOOL IsAccentColor(UIColor *c) {
    if (!c) return NO;
    if (c == gColor[0]) return YES;
    return IsAccentCG(c.CGColor);
}

static BOOL IsAccentOrBlackCG(CGColorRef c) {
    return c && (IsOurs(c) || IsAccentCG(c) || IsBlackCG(c));
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
    if (cls == 2) {
        BOOL old = gRaw;
        gRaw = YES;
        UIColor *s = [gColor[cat] colorWithAlphaComponent:0.2];
        gRaw = old;
        return s;
    }
    return gColor[cat];
}

static UIColor *RemapRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    if (gRaw || !gMaster || !gOn[AACFill] || !gColor[AACFill]) return nil;
    int cls = BlueClass(r, g, b);
    if (!cls) return nil;
    CGFloat al = (cls == 2 ? 0.2 : 1.0) * a;
    if (al >= 0.99) return gColor[AACFill];
    BOOL old = gRaw;
    gRaw = YES;
    UIColor *res = [gColor[AACFill] colorWithAlphaComponent:al];
    gRaw = old;
    return res;
}

#pragma mark - Nền accent (fill)

static void MarkFill(CALayer *l) {
    if (!OnMain()) return;
    if (l.bounds.size.height > 120) return;
    if (!objc_getAssociatedObject(l, kFill)) {
        objc_setAssociatedObject(l, kFill, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gFillCount++;
        __weak CALayer *w = l;
        dispatch_async(dispatch_get_main_queue(), ^{
            CALayer *s = w;
            if (s) WhitenOnFill(s);
        });
    }
}

static BOOL IsFillLayer(CALayer *l) {
    return l && (objc_getAssociatedObject(l, kFill) || IsAccentCG(l.backgroundColor));
}

// Layer nằm trên một nền accent: là con cháu của nền, hoặc là "anh em" nằm đè lên nền đó
static BOOL LayerUnderFill(CALayer *l) {
    CALayer *child = nil;
    for (int i = 0; i < 6 && l; i++) {
        if (i > 0 && l.bounds.size.height > 120) return NO;
        if (IsFillLayer(l)) return YES;
        if (child) {
            CGRect cf = child.frame;
            CGPoint cp = CGPointMake(CGRectGetMidX(cf), CGRectGetMidY(cf));
            int n = 0;
            for (CALayer *s in [l.sublayers copy]) {
                if (s == child) continue;
                if (++n > 12) break;
                if (IsFillLayer(s) && CGRectContainsPoint(s.frame, cp)) return YES;
            }
        }
        child = l;
        l = l.superlayer;
    }
    return NO;
}

static BOOL UnderFill(UIView *v) {
    UIView *child = nil;
    for (int i = 0; i < 6 && v; i++) {
        if (i > 0 && v.bounds.size.height > 120) return NO;
        if (IsFillLayer(v.layer)) return YES;
        if (child) {
            CGRect cf = child.frame;
            CGPoint cp = CGPointMake(CGRectGetMidX(cf), CGRectGetMidY(cf));
            int n = 0;
            for (UIView *s in v.subviews) {
                if (s == child) continue;
                if (++n > 12) break;
                if (IsFillLayer(s.layer) && CGRectContainsPoint(s.frame, cp)) return YES;
            }
        }
        child = v;
        v = v.superview;
    }
    return NO;
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

// Avatar: view bo tròn + cắt theo bounds -> không đụng vào ảnh bên trong
static BOOL LooksLikeAvatarView(UIView *v) {
    if (!v) return NO;
    CALayer *l = v.layer;
    if (!l.masksToBounds || l.cornerRadius <= 0) return NO;
    CGSize s = v.bounds.size;
    if (s.width <= 0 || s.height <= 0) return YES;
    return l.cornerRadius >= fmin(s.width, s.height) * 0.25;
}

#pragma mark - Ảnh / icon

// Phân tích ảnh nhỏ: trả về độ sáng trung bình nếu là icon 1 màu trung tính (đen/xám/trắng) có nền trong suốt.
// -1: không phải icon 1 màu, -2: bị giới hạn tốc độ (chưa phân tích)
static CGFloat CGIconLum(CGImageRef cg) {
    static CFAbsoluteTime winStart; static int winCount;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - winStart > 1.0) { winStart = now; winCount = 0; }
    if (++winCount > 150) return -2;
    if (!cg) return -1;
    enum { N = 24 };
    uint8_t buf[N * N * 4];
    memset(buf, 0, sizeof buf);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, N, N, 8, N * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return -1;
    CGContextDrawImage(ctx, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(ctx);
    int solid = 0, clear = 0;
    double sum = 0, lo = 2, hi = -1;
    for (int i = 0; i < N * N; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 40) { clear++; continue; }
        solid++;
        double a = px[3];
        double r = fmin(1, px[0] / a), g = fmin(1, px[1] / a), b = fmin(1, px[2] / a);
        double mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.16) return -1;
        double lum = (r + g + b) / 3.0;
        sum += lum;
        if (px[3] >= 200) { lo = fmin(lo, lum); hi = fmax(hi, lum); }
    }
    if (solid < 6 || clear * 100 < N * N * 8 || solid * 100 > N * N * 82) return -1;
    if (hi >= 0 && hi - lo > 0.3) return -1;
    return (CGFloat)(sum / solid);
}

static CGFloat ImageIconLum(UIImage *img) {
    NSNumber *cached = objc_getAssociatedObject(img, kMonoBlack);
    if (cached) return cached.doubleValue;
    CGFloat r = -1;
    CGImageRef cg = img.CGImage;
    if (cg && img.images.count <= 1) {
        r = CGIconLum(cg);
        if (r == -2) return -1;
    }
    objc_setAssociatedObject(img, kMonoBlack, @(r), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r;
}

static BOOL ImageIsMonoIcon(UIImage *img) {
    return IsFgLum(ImageIconLum(img));
}

static UIImage *IconRemapImage(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.isSymbolImage) return img;
    if (objc_getAssociatedObject(img, kAccentSrc) || objc_getAssociatedObject(img, kBlueSrc)) return img;
    CGSize sz = img.size;
    if (sz.width < 8 || sz.height < 8 || sz.width > 64 || sz.height > 64) return img;
    if (!ImageIsMonoIcon(img)) return img;
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
    if (!buf) return img;
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
    if (!k) {
        CGContextRelease(ctx);
        free(buf);
        return img;
    }
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

#pragma mark - Icon vẽ thẳng vào layer.contents (Texture / AsyncDisplayKit - icon Messenger của Facebook)

static CGImageRef CreateTintedCG(CGImageRef src, CGColorRef color) {
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (!w || !h || w > 384 || h > 384 || !color) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGRect r = CGRectMake(0, 0, w, h);
    CGContextDrawImage(ctx, r, src);
    CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
    CGContextSetFillColorWithColor(ctx, color);
    CGContextFillRect(ctx, r);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

static void ContentsCheck(CALayer *l) {
    if (gInContents || !gMaster || !gOn[AACIcon] || !gCGWhite || !OnMain()) return;
    id c = l.contents;
    if (!c) return;
    if (CFGetTypeID((__bridge CFTypeRef)c) != CGImageGetTypeID()) return;
    CGSize sz = l.bounds.size;
    if (sz.width < 10 || sz.height < 10 || sz.width > 48 || sz.height > 48) return;
    if ([l.delegate isKindOfClass:UIImageView.class]) return;
    if (l.cornerRadius > 0 && l.masksToBounds) return;

    CGImageRef cg = (__bridge CGImageRef)c;
    unsigned long p = (unsigned long)(uintptr_t)cg;
    NSNumber *outP = objc_getAssociatedObject(l, kCtxOut);
    id src = objc_getAssociatedObject(l, kCtxSrc);
    BOOL ours = outP && outP.unsignedLongValue == p && src;
    BOOL onFill = (gFillCount > 0 && gOn[AACFill]) ? LayerUnderFill(l) : NO;
    int want = gVersion * 4 + (gDark ? 2 : 0) + (onFill ? 1 : 0);

    if (ours) {
        if ([objc_getAssociatedObject(l, kCtxStamp) intValue] == want) return;
    } else {
        NSArray *sk = objc_getAssociatedObject(l, kCtxSkip);
        if (sk.count == 2 && [sk[0] unsignedLongValue] == p && [sk[1] intValue] == want) return;
    }

    CGImageRef base = ours ? (__bridge CGImageRef)src : cg;
    CGFloat lum = CGIconLum(base);
    if (lum == -2) return;
    CGColorRef col = onFill ? gCGWhite : CGFor(AACIcon, NO);
    CGImageRef out = IsFgLum(lum) ? CreateTintedCG(base, col) : NULL;
    if (!out) {
        if (ours) {
            gInContents = YES;
            l.contents = src;
            gInContents = NO;
            objc_setAssociatedObject(l, kCtxOut, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(l, kCtxSrc, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            unsigned long sp = (unsigned long)(uintptr_t)(__bridge CGImageRef)src;
            objc_setAssociatedObject(l, kCtxSkip, @[@(sp), @(want)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            objc_setAssociatedObject(l, kCtxSkip, @[@(p), @(want)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    id keep = (__bridge id)base;
    gInContents = YES;
    l.contents = (__bridge id)out;
    gInContents = NO;
    objc_setAssociatedObject(l, kCtxSrc, keep, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, kCtxOut, @((unsigned long)(uintptr_t)out), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, kCtxStamp, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGImageRelease(out);
}

#pragma mark - Nội dung nằm trên nền accent -> màu trắng

// Label nằm trong nút đã đổi accent: nền đen/trắng -> trong suốt, chữ accent/đen -> trắng
static void FixLabelOnFill(UILabel *lb) {
    if (!gMaster || !gOn[AACFill] || gFillCount <= 0 || !OnMain()) return;
    if (lb.bounds.size.height > 64) return;
    UIColor *bg = lb.backgroundColor;
    UIColor *tc = lb.textColor;
    BOOL bgBad = bg && IsFillCandidateColor(bg);
    BOOL txtBad = tc && (IsBlackColor(tc) || IsAccentColor(tc));
    if (!bgBad && !txtBad) return;
    if (!UnderFill(lb) || IsFillLayer(lb.layer)) {
        if (!(IsFillLayer(lb.layer) && txtBad)) return;
    }
    if (bgBad) lb.backgroundColor = UIColor.clearColor;
    if (txtBad) lb.textColor = UIColor.whiteColor;
}

static BOOL WhitenLayer(CALayer *l) {
    if (!gCGWhite || !gOn[AACFill] || !OnMain()) return NO;
    if (objc_getAssociatedObject(l, kFill)) return NO;
    BOOL ch = NO;
    gInTry = YES;
    if ([l isKindOfClass:CATextLayer.class]) {
        CATextLayer *t = (CATextLayer *)l;
        if (IsAccentOrBlackCG(t.foregroundColor)) { t.foregroundColor = gCGWhite; ch = YES; }
    }
    if ([l isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *sh = (CAShapeLayer *)l;
        if (IsAccentOrBlackCG(sh.fillColor))   { sh.fillColor = gCGWhite; ch = YES; }
        if (IsAccentOrBlackCG(sh.strokeColor)) { sh.strokeColor = gCGWhite; ch = YES; }
        if (ch) objc_setAssociatedObject(sh, kIconShape, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([l respondsToSelector:@selector(contentsMultiplyColor)]) {
        CGColorRef m = [l contentsMultiplyColor];
        if (m && IsAccentOrBlackCG(m)) { [l setContentsMultiplyColor:gCGWhite]; ch = YES; }
    }
    gInTry = NO;
    ContentsCheck(l);
    id d = l.delegate;
    if ([d isKindOfClass:UILabel.class]) FixLabelOnFill((UILabel *)d);
    else if ([d isKindOfClass:UIImageView.class] || [d isKindOfClass:UIButton.class]) [(UIView *)d tintColorDidChange];
    return ch;
}

static void WhitenTree(CALayer *n, CALayer *fill, int depth) {
    if (depth > 8) return;
    for (CALayer *s in [n.sublayers copy]) {
        if (s != fill && !objc_getAssociatedObject(s, kFill)) {
            CGRect r = [s convertRect:s.bounds toLayer:fill];
            if (!CGRectIsEmpty(r) && CGRectIntersectsRect(r, fill.bounds)) WhitenLayer(s);
        }
        WhitenTree(s, fill, depth + 1);
    }
}

static void WhitenOnFill(CALayer *fill) {
    if (!OnMain() || !gOn[AACFill] || !gMaster) return;
    CALayer *host = fill.superlayer;
    if (!host || host.bounds.size.height > 120) host = fill;
    WhitenTree(host, fill, 0);
}

static void WhitenIfOnFill(CALayer *l) {
    if (!l || objc_getAssociatedObject(l, kFill)) return;
    if (LayerUnderFill(l)) WhitenLayer(l);
}

static void WhitenLater(CALayer *l) {
    if (!OnMain() || gFillCount <= 0 || !gOn[AACFill] || !gMaster) return;
    WhitenIfOnFill(l);
    __weak CALayer *w = l;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CALayer *s = w;
        if (s) WhitenIfOnFill(s);
    });
}

static void FillLayoutWhiten(CALayer *l) {
    int n = [objc_getAssociatedObject(l, kWhitenN) intValue];
    if (n >= 6) return;
    objc_setAssociatedObject(l, kWhitenN, @(n + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WhitenOnFill(l);
}

#pragma mark - Đổi nền đen/trắng sang accent

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
    BOOL shapeOK = l.cornerRadius >= 6 || nested || (l.mask && sz.width >= sz.height * 1.5);
    if (cand && sz.height >= 14 && sz.height <= 64 && sz.width >= 14 && shapeOK) {
        l.backgroundColor = CGFor(AACFill, NO);
        MarkFill(l);
    }
    if (l.borderWidth > 0 && IsBlackCG(l.borderColor) && (nested || LayerUnderFill(l))) {
        l.borderColor = CGFor(AACFill, NO);
    }
}

static void TryBlackShape(CAShapeLayer *sh) {
    if (!gOn[AACFill] || !OnMain()) return;
    if (!IsFillCandidateCG(sh.fillColor)) return;
    if (LayerUnderFill(sh)) return;
    CGPathRef path = sh.path;
    if (!path || CGPathIsEmpty(path)) return;
    CGRect b = CGPathGetBoundingBox(path);
    if (CGRectIsNull(b) || CGRectIsInfinite(b) || isnan(b.size.width) || isnan(b.size.height)) return;
    if (b.size.height < 20 || b.size.height > 64 || b.size.width < b.size.height * 1.6) return;
    gInTry = YES;
    sh.fillColor = CGFor(AACFill, NO);
    gInTry = NO;
    MarkFill(sh);
}

// SwiftUI vẽ nền đặc bằng layer + contentsMultiplyColor đen
static void TryMultiplyFill(CALayer *l) {
    if (!gOn[AACFill] || !OnMain()) return;
    if (![l respondsToSelector:@selector(contentsMultiplyColor)]) return;
    CGColorRef m = [l contentsMultiplyColor];
    if (!IsBlackCG(m)) return;
    CGSize sz = l.bounds.size;
    if (sz.height < 20 || sz.height > 64 || sz.width < sz.height * 1.5) return;
    if (InControlKnob(l) || LayerUnderFill(l)) return;
    gInTry = YES;
    [l setContentsMultiplyColor:CGFor(AACFill, NO)];
    gInTry = NO;
    MarkFill(l);
}

static void TryBlackIconShape(CAShapeLayer *sh) {
    if (!gOn[AACIcon] || gInTry || !OnMain()) return;
    BOOL fill = IsIconFgCG(sh.fillColor), stroke = IsIconFgCG(sh.strokeColor);
    if (!fill && !stroke) return;
    if (LayerUnderFill(sh)) return;
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

#pragma mark - Hàng đợi kiểm tra trễ

static NSHashTable *gPend;
static volatile int32_t gHasPend;
static const void *kAttempts  = &kAttempts;
static const void *kPendKind  = &kPendKind;
#define PEND_LOCK @"AACPend"

// kind: 0 = nền layer, 1 = shape, 2 = contentsMultiplyColor
static void RunCheck(CALayer *l, int kind) {
    if (kind == 1) {
        if ([l isKindOfClass:CAShapeLayer.class]) {
            TryBlackShape((CAShapeLayer *)l);
            TryBlackIconShape((CAShapeLayer *)l);
        }
    } else if (kind == 2) {
        TryMultiplyFill(l);
    } else {
        TryBlack(l);
    }
}

static BOOL CheckDone(CALayer *l, int kind) {
    if (kind == 1) {
        if (![l isKindOfClass:CAShapeLayer.class]) return YES;
        CAShapeLayer *sh = (CAShapeLayer *)l;
        return !IsIconFgCG(sh.fillColor) && !IsIconFgCG(sh.strokeColor) && !IsFillCandidateCG(sh.fillColor);
    }
    if (kind == 2) {
        if (![l respondsToSelector:@selector(contentsMultiplyColor)]) return YES;
        return !IsBlackCG([l contentsMultiplyColor]);
    }
    return !IsFillCandidateCG(l.backgroundColor) && !(l.borderWidth > 0 && IsBlackCG(l.borderColor));
}

static void AddPending(CALayer *l, int kind) {
    @synchronized (PEND_LOCK) {
        if (!gPend) gPend = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
        if (gPend.count > 400) return;
        [gPend addObject:l];
        gHasPend = 1;
    }
    objc_setAssociatedObject(l, kPendKind, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void PendingRun(CALayer *l) {
    BOOL has;
    @synchronized (PEND_LOCK) { has = [gPend containsObject:l]; }
    if (!has) return;
    int kind = [objc_getAssociatedObject(l, kPendKind) intValue];
    RunCheck(l, kind);
    int n = [objc_getAssociatedObject(l, kAttempts) intValue] + 1;
    objc_setAssociatedObject(l, kAttempts, @(n), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (n >= 8 || CheckDone(l, kind)) {
        @synchronized (PEND_LOCK) {
            [gPend removeObject:l];
            if (!gPend.count) gHasPend = 0;
        }
    }
}

static void ScheduleCheck(CALayer *l, int kind) {
    if (!l) return;
    if (OnMain()) {
        RunCheck(l, kind);
        if (CheckDone(l, kind)) return;
    }
    AddPending(l, kind);
    if (gPending > 96) return;
    __sync_fetch_and_add(&gPending, 1);
    __weak CALayer *wl = l;
    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *s = wl;
        if (s) RunCheck(s, kind);
        __sync_fetch_and_sub(&gPending, 1);
    });
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
    BOOL ok = base.renderingMode == UIImageRenderingModeAlwaysTemplate || base.isSymbolImage || ImageIsMonoIcon(base);
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
    __weak UITabBar *wb = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITabBar *b = wb;
        if (b) TabBarFix(b);
    });
}

// Chữ dưới tab bar (tab chưa chọn đang màu đen) -> màu accent
static void TabLabelFix(UILabel *lb) {
    if (!gMaster || !gOn[AACIcon] || !gColor[AACIcon] || !OnMain()) return;
    if (lb.textColor == gColor[AACIcon]) return;
    if (!InTabBar(lb)) return;
    lb.textColor = gColor[AACIcon];
}

#pragma mark - Làm mới toàn bộ

static void RefreshLayerTree(CALayer *l, int depth) {
    if (depth > 40) return;
    if ([l isKindOfClass:CAShapeLayer.class] && gOn[AACIcon]) {
        NSNumber *m = objc_getAssociatedObject(l, kIconShape);
        if (m) {
            CAShapeLayer *sh = (CAShapeLayer *)l;
            gInTry = YES;
            if (m.intValue & 1) sh.fillColor   = CGFor(AACIcon, NO);
            if (m.intValue & 2) sh.strokeColor = CGFor(AACIcon, NO);
            gInTry = NO;
        }
    }
    if (l.contents && gOn[AACIcon]) ContentsCheck(l);
    for (CALayer *sub in [l.sublayers copy]) RefreshLayerTree(sub, depth + 1);
}

static void RefreshViewTree(UIView *v, int depth) {
    if (depth > 40) return;
    if (gOn[AACFill]) {
        if ([v isKindOfClass:UISwitch.class]) ((UISwitch *)v).onTintColor = gColor[AACFill];
        else if ([v isKindOfClass:UISlider.class]) ((UISlider *)v).minimumTrackTintColor = gColor[AACFill];
    }
    if ([v isKindOfClass:UITabBar.class]) TabBarFix((UITabBar *)v);
    for (UIView *s in [v.subviews copy]) RefreshViewTree(s, depth + 1);
}

static void ApplyAll(void) {
    if (gApplying || !OnMain()) return;
    gApplying = YES;
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
    gApplying = NO;
}

#pragma mark - Bảng cài đặt

static UIViewController *TopVC(UIWindow *w) {
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
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
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 3; }
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
    } else {
        cell.textLabel.text = @"Chọn màu…";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 1) [self editHex];
    else if (ip.row == 2) [self pickColor];
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
            __weak UIWindow *ww = w;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *sw = ww;
                if (!sw) return;
                UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc]
                    initWithTarget:[AACHelper shared] action:@selector(onLongPress:)];
                g.numberOfTouchesRequired = 3;
                g.minimumPressDuration = 1.0;
                g.cancelsTouchesInView = NO;
                g.delegate = [AACHelper shared];
                [sw addGestureRecognizer:g];
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
    BOOL nowDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    if (nowDark != gDark) {
        gDark = nowDark;
        if (gMaster) dispatch_async(dispatch_get_main_queue(), ^{ ApplyAll(); });
    }
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
    else if (!n && gOn[AACFill] && IsFillCandidateColor(c)) ScheduleCheck(self.layer, 0);
}
%end

%hook CALayer
- (void)layoutSublayers {
    %orig;
    if (!OnMain()) return;
    if (gHasPend) PendingRun(self);
    if (gFillCount > 0 && gOn[AACFill] && objc_getAssociatedObject(self, kFill)) FillLayoutWhiten(self);
    if (gMaster && gOn[AACIcon] && self.contents) ContentsCheck(self);
}
- (void)setContents:(id)c {
    %orig;
    if (c && gMaster && gOn[AACIcon] && !gInContents && OnMain()) ContentsCheck(self);
}
- (void)setBackgroundColor:(CGColorRef)c {
    if (!gMaster || !c) { %orig; return; }
    int cls = 0;
    CGColorRef n = LayerRemap(c, AACFill, &cls);
    if (n) { %orig(n); if (cls == 1 && OnMain()) MarkFill(self); return; }
    %orig;
    if (gOn[AACFill] && IsFillCandidateCG(c)) ScheduleCheck(self, 0);
}
- (void)setBorderColor:(CGColorRef)c {
    CGColorRef n = gMaster ? LayerRemap(c, AACFill, NULL) : NULL;
    if (n) { %orig(n); return; }
    %orig;
    if (gMaster && gOn[AACFill] && IsBlackCG(c)) ScheduleCheck(self, 0);
}
// SwiftUI tô symbol/template image và nền đặc bằng contentsMultiplyColor
- (void)setContentsMultiplyColor:(CGColorRef)c {
    CGColorRef n = (gMaster && c) ? LayerRemap(c, AACIcon, NULL) : NULL;
    %orig(n ?: c);
    if (!gMaster || !c || gInTry || !OnMain()) return;
    if (n) { WhitenLater(self); return; }
    if (IsBlackCG(c)) {
        if (gOn[AACFill]) ScheduleCheck(self, 2);
        WhitenLater(self);
    }
}
%end

%hook CATextLayer
- (void)setForegroundColor:(CGColorRef)c {
    CGColorRef n = (gMaster && c) ? LayerRemap(c, AACIcon, NULL) : NULL;
    %orig(n ?: c);
    if (!gMaster || !c || gInTry || !OnMain()) return;
    if (n || IsBlackCG(c)) WhitenLater(self);
}
%end

%hook CAShapeLayer
- (void)setFillColor:(CGColorRef)c {
    if (!gMaster || !c) { %orig; return; }
    CGColorRef n = LayerRemap(c, AACIcon, NULL);
    if (n) { %orig(n); if (!gInTry && OnMain()) WhitenLater(self); return; }
    %orig;
    if (!gInTry && (gOn[AACFill] || gOn[AACIcon]) && IsIconFgCG(c)) {
        ScheduleCheck(self, 1);
        if (IsBlackCG(c)) WhitenLater(self);
    }
}
- (void)setStrokeColor:(CGColorRef)c {
    if (!gMaster || !c) { %orig; return; }
    CGColorRef n = LayerRemap(c, AACIcon, NULL);
    if (n) { %orig(n); if (!gInTry && OnMain()) WhitenLater(self); return; }
    %orig;
    if (!gInTry && gOn[AACIcon] && IsIconFgCG(c)) {
        ScheduleCheck(self, 1);
        if (IsBlackCG(c)) WhitenLater(self);
    }
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
    if (self.window) { FixLabelOnFill(self); TabLabelFix(self); }
}
- (void)layoutSubviews {
    %orig;
    FixLabelOnFill(self);
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

%hook UIBarButtonItem
- (void)setImage:(UIImage *)img {
    %orig(BlueImageRemap(IconRemapImage(img)));
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
    for (UIColor *c in colors) [m addObject:IconTintFix(c) ?: c];
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

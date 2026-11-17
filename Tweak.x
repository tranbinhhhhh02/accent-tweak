#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#include <execinfo.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#define AAC_CONTENTS_HOOK 1

#define AAC_PANEL_OWN_WINDOW 0

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
static const void *kContentsSrc = &kContentsSrc;
static const void *kCtl         = &kCtl;
static const void *kImgView     = &kImgView;
static const void *kOwner       = &kOwner;
static const void *kKbSrc       = &kKbSrc;     // [MOI] contents ban phim da doi mau
static const void *kNoShadow    = &kNoShadow;  // layer bi go bong do
static const void *kStripSrc    = &kStripSrc;  // anh da go vien/bong den
static const void *kStripState  = &kStripState;
static const void *kStripOut    = &kStripOut;
static const void *kKbImg       = &kKbImg;     // anh ban phim da doi mau

@interface AACWeak : NSObject
@property (nonatomic, weak) id obj;
@end
@implementation AACWeak
@end

static BOOL        gMaster = YES;
static BOOL        gOn[AACCount];
static UIColor    *gColor[AACCount];
static CGColorRef  gCGLight[AACCount], gCGDark[AACCount], gCGSoftLight[AACCount], gCGSoftDark[AACCount];
static CGColorRef  gCGWhite;
static CGFloat     gRGBL[3], gRGBD[3];
static BOOL        gDark = NO;
static int         gFillCount = 0;
static int         gVersion = 0;
static NSMutableArray *gKeep;
static __thread BOOL gRaw;

#define AAC_MAXDEPTH 12
static __thread int gDepth;
static inline int  AACDepthEnter(void)      { gDepth++; return 0; }
static inline void AACDepthLeave(int *p)    { gDepth--; }
#define AAC_DEPTH_SCOPE int _aacScope __attribute__((cleanup(AACDepthLeave))) = AACDepthEnter()
static BOOL        gInTry;
static BOOL        gInTabFix;
static BOOL        gInContents;
static volatile int32_t gPending;
static BOOL        gSafe;

@interface CALayer (AACPrivate)
- (void)setContentsMultiplyColor:(CGColorRef)c;
@end

static inline BOOL OnMain(void) { return [NSThread isMainThread]; }

static char gSigPath[1024];
static char gCrumb[160];
static void Crumb(const char *s) { if (s) strlcpy(gCrumb, s, sizeof gCrumb); }

static void AACSignalHandler(int sig) {
    if (gSigPath[0]) {
        int fd = open(gSigPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            char head[320];
            int n = snprintf(head, sizeof head, "signal %d\nbuoc cuoi: %s\n", sig, gCrumb);
            if (n > 0) write(fd, head, (size_t)n);
            void *bt[40];
            int c = backtrace(bt, 40);
            backtrace_symbols_fd(bt, c, fd);
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void InstallSignals(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    const char *path = [dir stringByAppendingPathComponent:@"aac_signal.txt"].fileSystemRepresentation;
    if (path) strlcpy(gSigPath, path, sizeof gSigPath);
    static stack_t ss;
    ss.ss_size = 64 * 1024;
    ss.ss_sp = malloc(ss.ss_size);
    ss.ss_flags = 0;
    if (ss.ss_sp) sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = AACSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_ONSTACK;
    int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], &sa, NULL);
}

static void TabBarFix(UITabBar *bar);

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

static BOOL CGRGBA(CGColorRef c, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (!c) return NO;
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (!cs) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *k = CGColorGetComponents(c);
    if (!k) return NO;
    CGColorSpaceModel m = CGColorSpaceGetModel(cs);
    if (m == kCGColorSpaceModelMonochrome && n >= 2) {
        *r = *g = *b = k[0]; *a = k[1];
        return YES;
    }
    if (m == kCGColorSpaceModelRGB && n >= 4) {
        *r = k[0]; *g = k[1]; *b = k[2]; *a = k[3];
        return YES;
    }
    return NO;
}

static inline BOOL IsOurs(CGColorRef c) {
    return c == gCGLight[0] || c == gCGDark[0] || c == gCGSoftLight[0] || c == gCGSoftDark[0] || c == gCGWhite;
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
    if (!gCGWhite) gCGWhite = CGColorCreateGenericRGB(1, 1, 1, 1);
    CGFloat a = 1;
    [light getRed:&gRGBL[0] green:&gRGBL[1] blue:&gRGBL[2] alpha:&a];
    [dark getRed:&gRGBD[0] green:&gRGBD[1] blue:&gRGBD[2] alpha:&a];
    gCGLight[0] = CGColorCreateCopy(light.CGColor);
    gCGDark[0] = CGColorCreateCopy(dark.CGColor);
    gCGSoftLight[0] = CGColorCreateCopyWithAlpha(light.CGColor, 0.2);
    gCGSoftDark[0] = CGColorCreateCopyWithAlpha(dark.CGColor, 0.2);
    gColor[0] = dyn;
    gOn[0] = gMaster;
    gVersion++;
}

static BOOL IsDarkRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a, CGFloat thr) {
    return a >= 0.99 && r < thr && g < thr && b < thr;
}

static BOOL IsBlackColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return IsDarkRGBA(r, g, b, a, 0.03);
}
static BOOL IsInkColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return IsDarkRGBA(r, g, b, a, 0.16);
}

static BOOL IsBlackCG(CGColorRef c) {
    CGFloat r, g, b, a;
    return CGRGBA(c, &r, &g, &b, &a) && IsDarkRGBA(r, g, b, a, 0.03);
}
static BOOL IsInkCG(CGColorRef c) {
    CGFloat r, g, b, a;
    return CGRGBA(c, &r, &g, &b, &a) && IsDarkRGBA(r, g, b, a, 0.16);
}

static BOOL IsWhiteColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return a >= 0.99 && r > 0.97 && g > 0.97 && b > 0.97;
}

static BOOL IsWhiteCG(CGColorRef c) {
    CGFloat r, g, b, a;
    return CGRGBA(c, &r, &g, &b, &a) && a >= 0.99 && r > 0.97 && g > 0.97 && b > 0.97;
}

static BOOL IsFillCandidateCG(CGColorRef c) {
    return IsBlackCG(c) || (gDark && IsWhiteCG(c));
}

static BOOL IsFillCandidateColor(UIColor *c) {
    return IsBlackColor(c) || (gDark && IsWhiteColor(c));
}

static BOOL IsAccentCG(CGColorRef c) {
    if (!c || !gColor[0]) return NO;
    CGFloat r, g, b, a;
    if (!CGRGBA(c, &r, &g, &b, &a) || a < 0.99) return NO;
    for (int d = 0; d < 2; d++) {
        const CGFloat *q = d ? gRGBD : gRGBL;
        if (fabs(r - q[0]) < 0.02 && fabs(g - q[1]) < 0.02 && fabs(b - q[2]) < 0.02) return YES;
    }
    return NO;
}

static BOOL LayerUnderFill(CALayer *l) {
    for (int i = 0; i < 4 && l; i++, l = l.superlayer)
        if (objc_getAssociatedObject(l, kFill) || IsAccentCG(l.backgroundColor)) return YES;
    return NO;
}

static CGColorRef IconShapeColor(CALayer *l) {
    if (gCGWhite && LayerUnderFill(l.superlayer)) return gCGWhite;
    return CGFor(AACIcon, NO);
}

static CGColorRef LayerRemap(CGColorRef c, int cat, int *clsOut) {
    if (!c || !gOn[cat] || IsOurs(c)) return NULL;
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (!cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) return NULL;
    CGFloat r, g, b, a;
    if (!CGRGBA(c, &r, &g, &b, &a)) return NULL;
    int cls = BlueClass(r, g, b);
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

static BOOL RemapComps(CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (gRaw || !gMaster || !gOn[AACFill]) return NO;
    int cls = BlueClass(*r, *g, *b);
    if (!cls) return NO;
    const CGFloat *q = gDark ? gRGBD : gRGBL;
    *a = *a * (cls == 2 ? 0.2 : 1.0);
    *r = q[0]; *g = q[1]; *b = q[2];
    return YES;
}

static int CGImageIsBlackMono(CGImageRef cg) {
    if (!cg) return 0;
    static CFAbsoluteTime winStart; static int winCount;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - winStart > 1.0) { winStart = now; winCount = 0; }
    if (++winCount > 120) return -1;
    int res = 0;
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
            if (mxc * 100 > 30 * px[3]) { bad++; break; }
        }
        res = (solid >= 6 && clear >= 1 && bad == 0 && solid * 100 <= N * N * 62) ? 1 : 0;
    }
    return res;
}

static BOOL ImageIsBlackMono(UIImage *img) {
    NSNumber *cached = objc_getAssociatedObject(img, kMonoBlack);
    if (cached) return cached.boolValue;
    if (!img.CGImage || img.images.count > 1) return NO;
    int r = CGImageIsBlackMono(img.CGImage);
    if (r < 0) return NO;
    objc_setAssociatedObject(img, kMonoBlack, @(r == 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r == 1;
}

static CGImageRef CopyTintedCG(CGImageRef src, CGColorRef color) {
    if (!src || !color) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w == 0 || h == 0 || w > 512 || h > 512) return NULL;
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

// ---- Ban phim: nut xanh -> accent, bieu tuong den (Enter/back) -> accent ----
static BOOL KbName(NSString *cn) {
    return [cn hasPrefix:@"UIKB"] || [cn containsString:@"Keyboard"] || [cn containsString:@"UIInputWindow"];
}

static BOOL ViewInKeyboard(UIView *v) {
    if (!v) return NO;
    UIWindow *w = v.window;
    if (w && KbName(NSStringFromClass(w.class))) return YES;
    for (int i = 0; i < 10 && v; i++, v = v.superview)
        if (KbName(NSStringFromClass(v.class))) return YES;
    return NO;
}

static BOOL IsKeyboardLayer(CALayer *l) {
    BOOL checked = NO;
    for (int i = 0; i < 10 && l; i++, l = l.superlayer) {
        if (KbName(NSStringFromClass(l.class))) return YES;
        id d = l.delegate;
        if (d) {
            if (KbName(NSStringFromClass([d class]))) return YES;
            if (!checked && [d isKindOfClass:UIView.class]) {
                checked = YES;
                if (ViewInKeyboard((UIView *)d)) return YES;
            }
        }
    }
    return NO;
}

static CGImageRef KbRecolor(CGImageRef src) {
    if (!src || !gMaster || !gOn[AACIcon]) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w < 8 || h < 8 || w > 400 || h > 400) return NULL;
    static CFAbsoluteTime winStart; static int winCount;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - winStart > 1.0) { winStart = now; winCount = 0; }
    if (++winCount > 80) return NULL;

    uint8_t *buf = calloc(w * h, 4);
    if (!buf) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NULL; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);

    size_t total = w * h;
    int solid = 0, blue = 0, gray = 0, blk = 0, lt = 0, clear = 0;
    for (size_t i = 0; i < total; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) { clear++; continue; }
        solid++;
        CGFloat a = px[3];
        CGFloat r = fmin(1, px[0] / a), g = fmin(1, px[1] / a), b = fmin(1, px[2] / a);
        if (BlueClass(r, g, b) == 1) { blue++; continue; }
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.12) continue;
        gray++;
        CGFloat lum = (r + g + b) / 3.0;
        if (lum < 0.3) blk++;
        else if (lum > 0.75) lt++;
    }

    int mode = 0;
    if (solid >= 30 && blue * 100 >= 35 * solid) mode = 1;
    else if (solid >= 20 && gray * 100 >= 85 * solid && blk >= 6 &&
             (blk * 100 <= 45 * solid || (size_t)clear * 100 >= 40 * total) &&
             (lt * 100 >= 20 * solid || (size_t)clear * 100 >= 30 * total)) mode = 2;
    if (!mode) { CGContextRelease(ctx); free(buf); return NULL; }

    CGFloat ar = gDark ? gRGBD[0] : gRGBL[0];
    CGFloat ag = gDark ? gRGBD[1] : gRGBL[1];
    CGFloat ab = gDark ? gRGBD[2] : gRGBL[2];
    for (size_t i = 0; i < total; i++) {
        uint8_t *px = buf + i * 4;
        if (px[3] == 0) continue;
        CGFloat a = px[3];
        CGFloat r = fmin(1, px[0] / a), g = fmin(1, px[1] / a), b = fmin(1, px[2] / a);
        if (mode == 1) {
            if (BlueClass(r, g, b) != 1) continue;
            CGFloat al = a / 255.0;
            px[0] = (uint8_t)lround(fmax(0, fmin(1, ar)) * al * 255);
            px[1] = (uint8_t)lround(fmax(0, fmin(1, ag)) * al * 255);
            px[2] = (uint8_t)lround(fmax(0, fmin(1, ab)) * al * 255);
        } else {
            CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
            if (mx - mn > 0.12) continue;
            CGFloat t = fmax(0, fmin(1, (r + g + b) / 3.0));
            px[0] = (uint8_t)lround((ar * (1 - t) + t) * a);
            px[1] = (uint8_t)lround((ag * (1 - t) + t) * a);
            px[2] = (uint8_t)lround((ab * (1 - t) + t) * a);
        }
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    return out;
}

// ---- Go bong do (shadow) tren nut/icon accent ----
static BOOL NearControl(CALayer *l) {
    for (int i = 0; i < 4 && l; i++, l = l.superlayer) {
        NSString *cn = NSStringFromClass(l.class);
        if ([cn containsString:@"UISwitch"] || [cn containsString:@"Slider"]) return YES;
    }
    return NO;
}

static BOOL HasAccentMark(CALayer *l) {
    return objc_getAssociatedObject(l, kFill) || objc_getAssociatedObject(l, kIconShape) ||
           objc_getAssociatedObject(l, kContentsSrc) || objc_getAssociatedObject(l, kKbSrc) ||
           IsAccentCG(l.backgroundColor);
}

static void KillShadowUp(CALayer *l, int levels) {
    if (!l || !OnMain()) return;
    for (int i = 0; i < levels && l; i++, l = l.superlayer) {
        CGSize s = l.bounds.size;
        if (s.height > 120) break;
        if (i > 0 && s.width > 120) break;
        if (NearControl(l)) break;
        objc_setAssociatedObject(l, kNoShadow, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (l.shadowOpacity > 0) l.shadowOpacity = 0;
    }
}

static BOOL ShadowEligible(CALayer *l) {
    if (!gMaster || !OnMain()) return NO;
    if (objc_getAssociatedObject(l, kNoShadow)) return YES;
    CGSize s = l.bounds.size;
    if (s.height > 120 || s.width > 200) return NO;
    if (NearControl(l)) return NO;
    if (HasAccentMark(l)) return YES;
    CGColorRef sc = l.shadowColor;
    if (sc && (IsAccentCG(sc) || IsOurs(sc))) return YES;
    int n = 0;
    for (CALayer *sub in l.sublayers) {
        if (++n > 6) break;
        if (HasAccentMark(sub)) return YES;
    }
    return NO;
}

static BOOL gInKbFix;

static void KbLabelFix(UILabel *lb) {
    if (!gMaster || !gOn[AACIcon] || !gColor[AACIcon] || !OnMain()) return;
    NSString *t = lb.text ?: lb.attributedText.string;
    if (t.length > 3) return;
    if (!ViewInKeyboard(lb)) return;
    if (IsInkColor(lb.textColor)) lb.textColor = gColor[AACIcon];
    NSAttributedString *as = lb.attributedText;
    if (as.length) {
        UIColor *c = [as attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        if (c && IsInkColor(c)) {
            NSMutableAttributedString *m = [as mutableCopy];
            [m addAttribute:NSForegroundColorAttributeName value:gColor[AACIcon] range:NSMakeRange(0, m.length)];
            lb.attributedText = m;
        }
    }
}

static void KbImageFix(UIImageView *iv) {
    if (gInKbFix || !gMaster || !gOn[AACIcon] || !OnMain()) return;
    UIImage *im = iv.image;
    if (!im || !im.CGImage || objc_getAssociatedObject(im, kKbImg)) return;
    if (im.isSymbolImage || im.renderingMode == UIImageRenderingModeAlwaysTemplate || im.images.count > 1) return;
    if (im.size.width > 96 || im.size.height > 96) return;
    if (!ViewInKeyboard(iv)) return;
    CGImageRef k = KbRecolor(im.CGImage);
    if (!k) return;
    UIImage *out = [UIImage imageWithCGImage:k scale:im.scale orientation:im.imageOrientation];
    CGImageRelease(k);
    if (!out) return;
    objc_setAssociatedObject(out, kKbImg, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gInKbFix = YES;
    iv.image = out;
    gInKbFix = NO;
}

static void ReapplyContents(CALayer *l) {
    if (!OnMain()) return;
    id src = objc_getAssociatedObject(l, kContentsSrc);
    if (src) {
        CGImageRef t = CopyTintedCG((__bridge CGImageRef)src, IconShapeColor(l));
        if (t) {
            gInContents = YES;
            l.contents = (__bridge id)t;
            gInContents = NO;
            CGImageRelease(t);
        }
        return;
    }
    id ks = objc_getAssociatedObject(l, kKbSrc);
    if (ks) {
        CGImageRef t = KbRecolor((__bridge CGImageRef)ks);
        if (t) {
            gInContents = YES;
            l.contents = (__bridge id)t;
            gInContents = NO;
            CGImageRelease(t);
        }
    }
}

static void RefreshLayerTree(CALayer *l, int depth) {
    if (depth > 40) return;
    if ([l isKindOfClass:CAShapeLayer.class] && gOn[AACIcon]) {
        NSNumber *m = objc_getAssociatedObject(l, kIconShape);
        if (m) {
            CAShapeLayer *sh = (CAShapeLayer *)l;
            CGColorRef c = IconShapeColor(l);
            gInTry = YES;
            if (m.intValue & 1) sh.fillColor   = c;
            if (m.intValue & 2) sh.strokeColor = c;
            gInTry = NO;
        }
    }
    ReapplyContents(l);
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
        for (UIWindow *w in [((UIWindowScene *)s).windows copy]) {
            gDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
            w.tintColor = gOn[AACIcon] ? gColor[AACIcon] : nil;
            objc_setAssociatedObject(w, kTintVer, @(gVersion), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            RefreshViewTree(w, 0);
            RefreshLayerTree(w.layer, 0);
        }
    }
}

static void FixUnderFill(CALayer *l, int depth) {
    if (!l || depth > 6) return;
    for (CALayer *s in [l.sublayers copy]) {
        if ([s isKindOfClass:CAShapeLayer.class]) {
            NSNumber *m = objc_getAssociatedObject(s, kIconShape);
            if (m) {
                CAShapeLayer *sh = (CAShapeLayer *)s;
                CGColorRef c = IconShapeColor(s);
                gInTry = YES;
                if (m.intValue & 1) sh.fillColor   = c;
                if (m.intValue & 2) sh.strokeColor = c;
                gInTry = NO;
            }
        }
        ReapplyContents(s);
        FixUnderFill(s, depth + 1);
    }
}

static void FixUnderFillView(UIView *v, int depth) {
    if (!v || depth > 6) return;
    for (UIView *sv in [v.subviews copy]) {
        [sv tintColorDidChange];
        [sv setNeedsDisplay];
        FixUnderFillView(sv, depth + 1);
    }
}

static void MarkFill(CALayer *l, UIView *v) {
    if (!OnMain()) return;
    if (l.bounds.size.height > 120) return;
    if (!objc_getAssociatedObject(l, kFill)) {
        objc_setAssociatedObject(l, kFill, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gFillCount++;
        KillShadowUp(l, 2);
        if (gSafe) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FixUnderFill(l, 0);
            });
            return;
        }
        if (!v) v = ((AACWeak *)objc_getAssociatedObject(l, kOwner)).obj;
        __weak UIView *wv = v;
        dispatch_async(dispatch_get_main_queue(), ^{
            FixUnderFill(l, 0);
            UIView *sv = wv;
            if (sv) FixUnderFillView(sv, 0);
        });
    }
}

static BOOL UnderFill(UIView *v) {
    for (int i = 0; i < 4 && v; i++) {
        if (objc_getAssociatedObject(v.layer, kFill)) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL InControlKnob(CALayer *l) {
    for (int i = 0; i < 8 && l; i++, l = l.superlayer)
        if (objc_getAssociatedObject(l, kCtl)) return YES;
    return NO;
}

static BOOL GlassName(NSString *cn) {
    return [cn containsString:@"Glass"] || [cn containsString:@"Backdrop"] ||
           [cn containsString:@"Material"] || [cn containsString:@"VisualEffect"] ||
           [cn containsString:@"UISwitch"];
}

static BOOL InGlassLayer(CALayer *l) {
    for (int i = 0; i < 8 && l; i++, l = l.superlayer) {
        if (objc_getAssociatedObject(l, kCtl)) return YES;
        if (GlassName(NSStringFromClass(l.class))) return YES;
    }
    return NO;
}

static BOOL InBackdropLayer(CALayer *l) {
    for (int i = 0; i < 3 && l; i++, l = l.superlayer) {
        NSString *cn = NSStringFromClass(l.class);
        if ([cn containsString:@"Backdrop"] || [cn containsString:@"UISwitch"]) return YES;
    }
    return NO;
}

static BOOL InControlView(UIView *v) {
    for (int i = 0; i < 6 && v; i++, v = v.superview) {
        if ([v isKindOfClass:UISwitch.class] || [v isKindOfClass:UISlider.class] ||
            [v isKindOfClass:UIVisualEffectView.class]) return YES;
        if (GlassName(NSStringFromClass(v.class))) return YES;
    }
    return NO;
}

static void TagControl(UIView *v) {
    if (v && !objc_getAssociatedObject(v.layer, kCtl))
        objc_setAssociatedObject(v.layer, kCtl, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SetOwner(UIView *v) {
    if (gSafe) return;
    CALayer *l = v.layer;
    if (objc_getAssociatedObject(l, kOwner)) return;
    AACWeak *w = [AACWeak new];
    w.obj = v;
    objc_setAssociatedObject(l, kOwner, w, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL LooksLikeAvatarView(UIView *v) {
    if (!v) return NO;
    CALayer *l = v.layer;
    if (!l.masksToBounds || l.cornerRadius <= 0) return NO;
    CGSize s = v.bounds.size;
    if (s.width <= 0 || s.height <= 0) return YES;
    return l.cornerRadius >= fmin(s.width, s.height) * 0.25;
}

// ---- Nut tron den co mui ten (nut gui + nut "Hien thi cau tra loi") ----
static const void *kArrowDone = &kArrowDone;

static void ArrowFixView(UIView *v, int depth) {
    if (!v || depth > 3) return;
    for (UIView *sv in [v.subviews copy]) {
        if ([sv isKindOfClass:UIImageView.class]) {
            UIImageView *iv = (UIImageView *)sv;
            UIImage *im = iv.image;
            if (im && im.renderingMode != UIImageRenderingModeAlwaysTemplate &&
                !objc_getAssociatedObject(im, kArrowDone)) {
                UIImage *t = [im imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
                if (t) {
                    objc_setAssociatedObject(t, kArrowDone, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    iv.image = t;
                }
            }
            iv.tintColor = UIColor.whiteColor;
        }
        [sv tintColorDidChange];
        ArrowFixView(sv, depth + 1);
    }
}

static void ArrowFix(CALayer *l) {
    if (!OnMain() || !l) return;
    __weak CALayer *wl = l;
    void (^work)(void) = ^{
        CALayer *ly = wl;
        if (!ly) return;
        FixUnderFill(ly, 0);
        id d = ly.delegate;
        if ([d isKindOfClass:UIView.class]) ArrowFixView((UIView *)d, 0);
    };
    dispatch_async(dispatch_get_main_queue(), work);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), work);
}

static void TryBlack(CALayer *l) {
    if (!gOn[AACFill] || !OnMain()) return;
    if (InGlassLayer(l)) return;
    CGSize sz = l.bounds.size;
    if (l.contents || objc_getAssociatedObject(l, kImgView)) return;
    BOOL round = sz.width > 0 && fabs(sz.width - sz.height) < 2 && l.cornerRadius >= sz.width * 0.45;
    BOOL arrowBtn = round && sz.width >= 10 && sz.width <= 56 && l.sublayers.count > 0 && IsBlackCG(l.backgroundColor);
    if (round && sz.width >= 40 && !arrowBtn) return;
    BOOL nested = LayerUnderFill(l.superlayer);
    CGColorRef bg = l.backgroundColor;
    BOOL cand = IsFillCandidateCG(bg) && !(IsWhiteCG(bg) && InControlKnob(l));
    if (cand && ((sz.height >= 14 && sz.height <= 64 && sz.width >= 14 && (l.cornerRadius >= 6 || nested)) || arrowBtn)) {
        l.backgroundColor = CGFor(AACFill, NO);
        MarkFill(l, nil);
        if (arrowBtn) ArrowFix(l);
    }
    if (l.borderWidth > 0 && IsBlackCG(l.borderColor) && (nested || LayerUnderFill(l))) {
        l.borderColor = CGFor(AACFill, NO);
    }
}

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

// Icon trang co vien/bong den (vd icon like, comment tren video): bo vien thay vi doi sang accent
static void StripWhiteShapeOutline(CAShapeLayer *sh) {
    if (gInTry || !gMaster || !OnMain()) return;
    CGColorRef st = sh.strokeColor;
    if (!st || sh.lineWidth > 3) return;
    CGFloat r, g, b, a;
    if (!CGRGBA(sh.fillColor, &r, &g, &b, &a) || a < 0.99 || r <= 0.97 || g <= 0.97 || b <= 0.97) return;
    NSNumber *m = objc_getAssociatedObject(sh, kIconShape);
    BOOL ours = (m.intValue & 2) != 0;
    BOOL dark = CGRGBA(st, &r, &g, &b, &a) && r < 0.3 && g < 0.3 && b < 0.3;
    if (!dark && !ours) return;
    CGPathRef path = sh.path;
    if (path && !CGPathIsEmpty(path)) {
        CGRect bb = CGPathGetBoundingBox(path);
        if (!CGRectIsNull(bb) && !CGRectIsInfinite(bb) && fmax(bb.size.width, bb.size.height) > 64) return;
    }
    gInTry = YES;
    sh.strokeColor = NULL;
    gInTry = NO;
    if (m) objc_setAssociatedObject(sh, kIconShape, @(m.intValue & ~2), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void TryBlackIconShape(CAShapeLayer *sh) {
    if (!gOn[AACIcon] || gInTry || !OnMain()) return;
    if (InGlassLayer(sh)) return;
    StripWhiteShapeOutline(sh);
    BOOL fill = IsInkCG(sh.fillColor), stroke = IsInkCG(sh.strokeColor);
    if (!fill && !stroke) return;
    CGPathRef path = sh.path;
    if (!path || CGPathIsEmpty(path)) return;
    CGRect b = CGPathGetBoundingBox(path);
    if (CGRectIsNull(b) || CGRectIsInfinite(b) || isnan(b.size.width) || isnan(b.size.height)) return;
    CGFloat mx = fmax(b.size.width, b.size.height);
    if (mx < 6 || mx > 48) return;
    gInTry = YES;
    int bits = 0;
    CGColorRef c = IconShapeColor(sh);
    if (fill)   { sh.fillColor   = c; bits |= 1; }
    if (stroke) { sh.strokeColor = c; bits |= 2; }
    gInTry = NO;
    NSNumber *old = objc_getAssociatedObject(sh, kIconShape);
    objc_setAssociatedObject(sh, kIconShape, @(bits | old.intValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    KillShadowUp(sh, 2);
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
        return !IsInkCG(sh.fillColor) && !IsInkCG(sh.strokeColor);
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
    if (gSafe) return;
    AddPending(l, shape);
    if (gPending > 96) return;
    __sync_fetch_and_add(&gPending, 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        RunCheck(l, shape);
        __sync_fetch_and_sub(&gPending, 1);
    });
}

// Icon trang co vien/bong den "nuong" trong anh -> xoa phan toi, giu phan trang
static UIImage *ShadowStripImage(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
    if (objc_getAssociatedObject(img, kStripSrc)) return img;
    if (img.isSymbolImage || img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.images.count > 1) return img;
    CGSize sz = img.size;
    if (sz.width < 14 || sz.height < 14 || sz.width > 64 || sz.height > 64) return img;
    NSNumber *state = objc_getAssociatedObject(img, kStripState);
    if (state) return state.boolValue ? (objc_getAssociatedObject(img, kStripOut) ?: img) : img;
    static CFAbsoluteTime winStart; static int winCount;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - winStart > 1.0) { winStart = now; winCount = 0; }
    if (++winCount > 50) return img;

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
        objc_setAssociatedObject(img, kStripState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }
    uint8_t *buf = calloc(w * h, 4);
    if (!buf) return img;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return img; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);

    int solid = 0, light = 0, dark = 0, darkOpq = 0, colored = 0;
    for (size_t i = 0; i < w * h; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        solid++;
        CGFloat a = px[3];
        CGFloat r = fmin(1, px[0] / a), g = fmin(1, px[1] / a), b = fmin(1, px[2] / a);
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.15) { colored++; continue; }
        CGFloat lum = (r + g + b) / 3.0;
        if (lum < 0.35) { dark++; if (px[3] >= 200) darkOpq++; }
        else if (lum > 0.8 && px[3] >= 200) light++;
    }
    BOOL ok = solid >= 20 && colored * 10 <= solid && light * 100 >= 20 * solid &&
              dark * 100 >= 5 * solid && darkOpq <= light;
    if (!ok) {
        CGContextRelease(ctx);
        free(buf);
        objc_setAssociatedObject(img, kStripState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *px = buf + i * 4;
        if (px[3] == 0) continue;
        CGFloat a = px[3];
        CGFloat r = fmin(1, px[0] / a), g = fmin(1, px[1] / a), b = fmin(1, px[2] / a);
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.15) continue;
        if ((r + g + b) / 3.0 < 0.4) { px[0] = px[1] = px[2] = px[3] = 0; }
    }
    CGImageRef outCG = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    if (!outCG) return img;
    UIImage *out = [UIImage imageWithCGImage:outCG scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(outCG);
    objc_setAssociatedObject(out, kStripSrc, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kStripState, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kStripOut, out, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

static UIImage *IconRemapImage(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.isSymbolImage) return img;
    CGSize sz = img.size;
    if (sz.width < 8 || sz.height < 8 || sz.width > 64 || sz.height > 64) return img;
    if (!ImageIsBlackMono(img)) return img;
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *BlueImageRemap(UIImage *img) {
    if (!img || gSafe || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
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

    CGFloat ar = gDark ? gRGBD[0] : gRGBL[0];
    CGFloat ag = gDark ? gRGBD[1] : gRGBL[1];
    CGFloat ab = gDark ? gRGBD[2] : gRGBL[2];
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


// ---- Icon den (kem chi tiet trang, vd icon Messenger tren Facebook) -> doi den thanh accent, giu trang ----
static const void *kDualSrc   = &kDualSrc;
static const void *kDualState = &kDualState;
static const void *kDualOut   = &kDualOut;
static const void *kDualStamp = &kDualStamp;

static UIImage *DualImageRemap(UIImage *img) {
    if (!img || !gSafe || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
    if (objc_getAssociatedObject(img, kDualSrc) || objc_getAssociatedObject(img, kBlueSrc) || objc_getAssociatedObject(img, kAccentSrc)) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.isSymbolImage) return img;
    CGSize sz = img.size;
    if (sz.width < 18 || sz.height < 18 || sz.width > 44 || sz.height > 44 || img.images.count > 1) return img;

    NSNumber *state = objc_getAssociatedObject(img, kDualState);
    if (state && !state.boolValue) return img;
    int want = gVersion * 2 + (gDark ? 1 : 0);
    if (state) {
        UIImage *cached = objc_getAssociatedObject(img, kDualOut);
        if (cached && [objc_getAssociatedObject(img, kDualStamp) intValue] == want) return cached;
    } else {
        static CFAbsoluteTime winStart; static int winCount;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - winStart > 1.0) { winStart = now; winCount = 0; }
        if (++winCount > 40) return img;
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
        objc_setAssociatedObject(img, kDualState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }
    uint8_t *buf = calloc(w * h, 4);
    if (!buf) return img;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return img; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);

    int solid = 0, blk = 0, mid = 0, other = 0, opq = 0, opqBlk = 0;
    for (size_t i = 0; i < w * h; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        solid++;
        CGFloat a = px[3];
        CGFloat r = fmin(1, px[0] / a), g = fmin(1, px[1] / a), b = fmin(1, px[2] / a);
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.12) { other++; continue; }
        CGFloat lum = (r + g + b) / 3.0;
        if (px[3] >= 200) { opq++; if (lum < 0.16) opqBlk++; }
        if (lum < 0.16) blk++;
        else if (lum > 0.25 && lum < 0.75) mid++;
    }
    BOOL ok = solid >= 30 && other * 30 <= solid && blk * 100 >= 30 * solid && mid * 100 <= 18 * solid &&
              opq > 0 && opqBlk * 100 >= 40 * opq;
    if (!ok) {
        CGContextRelease(ctx);
        free(buf);
        objc_setAssociatedObject(img, kDualState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }

    CGFloat ar = gDark ? gRGBD[0] : gRGBL[0];
    CGFloat ag = gDark ? gRGBD[1] : gRGBL[1];
    CGFloat ab = gDark ? gRGBD[2] : gRGBL[2];
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *px = buf + i * 4;
        if (px[3] == 0) continue;
        CGFloat a = px[3];
        CGFloat r = fmin(1, px[0] / a), g = fmin(1, px[1] / a), b = fmin(1, px[2] / a);
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.12) continue;
        CGFloat t = fmax(0, fmin(1, (r + g + b) / 3.0));
        CGFloat nr = ar * (1 - t) + t, ng = ag * (1 - t) + t, nb = ab * (1 - t) + t;
        px[0] = (uint8_t)lround(nr * a);
        px[1] = (uint8_t)lround(ng * a);
        px[2] = (uint8_t)lround(nb * a);
    }
    CGImageRef outCG = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    if (!outCG) return img;
    UIImage *out = [UIImage imageWithCGImage:outCG scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(outCG);

    objc_setAssociatedObject(out, kDualSrc, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kDualState, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kDualOut, out, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kDualStamp, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

static UIColor *IconTintFix(UIColor *c) {
    if (gMaster && gOn[AACIcon] && c && OnMain()) {
        if (IsInkColor(c)) return gColor[AACIcon];
        UIColor *n = ColorRemap(c, AACIcon, NULL);
        if (n) return n;
    }
    return c;
}

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

static void TabLabelFix(UILabel *lb) {
    if (!gMaster || !gOn[AACIcon] || !gColor[AACIcon] || !OnMain()) return;
    if (lb.textColor == gColor[AACIcon]) return;
    if (!InTabBar(lb)) return;
    lb.textColor = gColor[AACIcon];
}

static UIWindow *gPanelWin;
static BOOL      gPanelShown;
static BOOL      gPanelPending;

static void ClosePanelWindow(void) {
    gPanelShown = NO;
    gPanelPending = NO;
    UIWindow *w = gPanelWin;
    gPanelWin = nil;
    if (w) {
        w.hidden = YES;
        w.rootViewController = nil;
    }
}

static BOOL VCBusy(UIViewController *vc) {
    if (!vc) return YES;
    if (!vc.viewIfLoaded.window) return YES;
    if (vc.isBeingPresented || vc.isBeingDismissed || vc.isMovingToParentViewController || vc.isMovingFromParentViewController) return YES;
    if (vc.transitionCoordinator != nil) return YES;
    if ([vc isKindOfClass:UIAlertController.class]) return YES;
    return NO;
}

static UIViewController *TopVC(void) {
    UIWindow *best = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        if (sc.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in [((UIWindowScene *)sc).windows copy]) {
            if (w == gPanelWin || w.hidden || w.windowLevel != UIWindowLevelNormal || !w.rootViewController) continue;
            if (w.isKeyWindow) { best = w; break; }
            if (!best) best = w;
        }
        if (best && best.isKeyWindow) break;
    }
    UIViewController *vc = best.rootViewController;
    for (int i = 0; i < 20 && vc; i++) {
        UIViewController *next = nil;
        UIViewController *pr = vc.presentedViewController;
        if (pr && !pr.isBeingDismissed) next = pr;
        else if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *vis = ((UINavigationController *)vc).visibleViewController;
            if (vis && vis != vc) next = vis;
        } else if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
            if (sel && sel != vc) next = sel;
        }
        if (!next) break;
        vc = next;
    }
    return vc;
}

#if AAC_PANEL_OWN_WINDOW
static UIWindowScene *ActiveScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        if (sc.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)sc;
        if (!fallback && sc.activationState == UISceneActivationStateForegroundInactive) fallback = (UIWindowScene *)sc;
    }
    return fallback;
}
#endif

static NSString *PeekCrash(void);
static void ClearCrash(void);

@interface AACSettingsVC : UITableViewController <UIColorPickerViewControllerDelegate>
@end

@implementation AACSettingsVC

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    Crumb("settingsVC:viewDidLoad");
    self.title = @"Màu nhấn";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:^{ ClosePanelWindow(); }]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return PeekCrash().length ? 4 : 3; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return @"Thay màu nhấn"; }
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
        cell.textLabel.text = @"Lỗi crash lần trước";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 1) [self editHex];
    else if (ip.row == 2) [self pickColor];
    else if (ip.row == 3) [self showCrash];
}

- (void)showCrash {
    NSString *t = PeekCrash();
    if (!t.length) return;
    NSString *shown = t.length > 1800 ? [t substringToIndex:1800] : t;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Lỗi crash lần trước"
        message:shown preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Sao chép" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = t;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        ClearCrash();
        [ws.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
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

@interface AACHelper : NSObject <UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate>
+ (instancetype)shared;
@end

#if AAC_PANEL_OWN_WINDOW
static void ShowPanelOwnWindow(UIWindowScene *scene) {
    gPanelPending = NO;
    if (gPanelWin || !scene) return;
    @try {
        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.windowLevel = UIWindowLevelAlert + 1;
        w.backgroundColor = UIColor.clearColor;
        UIViewController *host = [UIViewController new];
        host.view.backgroundColor = UIColor.clearColor;
        w.rootViewController = host;
        gPanelWin = w;
        gPanelShown = YES;
        if (gSafe) w.hidden = NO; else [w makeKeyAndVisible];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[AACSettingsVC new]];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        nav.presentationController.delegate = [AACHelper shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gPanelWin != w) return;
            @try { [host presentViewController:nav animated:YES completion:nil]; }
            @catch (NSException *e) { ClosePanelWindow(); }
        });
    } @catch (NSException *e) {
        ClosePanelWindow();
    }
}
#else
static void ShowPanel(int attempt) {
    if (gPanelShown) { gPanelPending = NO; return; }
    Crumb("ShowPanel:begin");
    UIViewController *top = TopVC();
    if (VCBusy(top)) {
        if (attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ShowPanel(attempt + 1);
            });
        } else {
            gPanelPending = NO;
        }
        return;
    }
    @try {
        Crumb("ShowPanel:create");
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[AACSettingsVC new]];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        nav.presentationController.delegate = [AACHelper shared];
        gPanelShown = YES;
        gPanelPending = NO;
        Crumb("ShowPanel:present");
        [top presentViewController:nav animated:YES completion:^{ Crumb("ShowPanel:presented"); }];
    } @catch (NSException *e) {
        ClosePanelWindow();
    }
}
#endif

@implementation AACHelper
+ (instancetype)shared {
    static AACHelper *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [AACHelper new]; });
    return h;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)pc {
    ClosePanelWindow();
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (gPanelShown || gPanelWin || gPanelPending) return;
    Crumb("onLongPress");
    gPanelPending = YES;
#if AAC_PANEL_OWN_WINDOW
    UIWindowScene *scene = nil;
    UIView *gv = g.view;
    if ([gv isKindOfClass:UIWindow.class]) scene = ((UIWindow *)gv).windowScene;
    if (!scene) scene = ActiveScene();
    if (!scene) { gPanelPending = NO; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ShowPanelOwnWindow(scene);
    });
#else
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ShowPanel(0);
    });
#endif
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
                g.delaysTouchesBegan = NO;
                g.delaysTouchesEnded = NO;
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

%hook UIWindow
- (void)makeKeyAndVisible { %orig; Setup(self); }
- (void)becomeKeyWindow { %orig; Setup(self); }
- (void)setRootViewController:(UIViewController *)vc { %orig; Setup(self); }
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    gDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
}
%end

%hook UIView
- (UIColor *)tintColor {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    if (!gMaster || !gOn[AACIcon] || !gColor[AACIcon]) return %orig;
    if (gFillCount > 0 && gOn[AACFill] && OnMain() && UnderFill(self) && !InControlView(self)) return UIColor.whiteColor;
    return gColor[AACIcon];
}
- (void)setTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (gMaster && gOn[AACIcon] && c && OnMain() && IsInkColor(c)) { %orig(gColor[AACIcon]); return; }
    %orig;
}
- (void)setBackgroundColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (!gMaster || !c) { %orig; return; }
    if (!OnMain()) { UIColor *m = ColorRemap(c, AACFill, NULL); %orig(m ?: c); return; }
    int cls = 0;
    UIColor *n = ColorRemap(c, AACFill, &cls);
    if (n && cls == 2 && InGlassLayer(self.layer)) n = nil;
    %orig(n ?: c);
    if (n && cls == 1) MarkFill(self.layer, self);
    else if (!n && gOn[AACFill] && IsFillCandidateColor(c)) { SetOwner(self); ScheduleCheck(self.layer, NO); }
}
%end

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (!gMaster || !c) { %orig; return; }
    int cls = 0;
    CGColorRef n = LayerRemap(c, AACFill, &cls);
    if (n && cls == 2 && OnMain() && InGlassLayer(self)) n = NULL;
    if (n) { %orig(n); if (cls == 1 && OnMain()) MarkFill(self, nil); return; }
    %orig;
    if (gOn[AACFill] && IsFillCandidateCG(c)) ScheduleCheck(self, NO);
}
- (void)setBorderColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    CGColorRef n = gMaster ? LayerRemap(c, AACFill, NULL) : NULL;
    if (n) { %orig(n); return; }
    %orig;
    if (gMaster && gOn[AACFill] && IsBlackCG(c)) ScheduleCheck(self, NO);
}
- (void)setContentsMultiplyColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    CGColorRef n = NULL;
    if (gMaster && c) {
        int mcls = 0;
        n = LayerRemap(c, AACIcon, &mcls);
        if (n && mcls == 2 && OnMain() && InGlassLayer(self)) n = NULL;
        if (!n && gOn[AACIcon] && OnMain() && IsInkCG(c) && !InGlassLayer(self)) {
            CGSize s = self.bounds.size;
            if (s.width <= 64 && s.height <= 64) n = IconShapeColor(self);
        }
    }
    %orig(n ?: c);
}
// [MOI] Go bong do tren nut/icon da doi sang accent
- (void)setShadowOpacity:(float)v {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (v > 0 && ShadowEligible(self)) { %orig(0); return; }
    %orig;
}
- (void)setShadowColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (self.shadowOpacity > 0 && ShadowEligible(self)) self.shadowOpacity = 0;
}
%end

%hook CATextLayer
- (void)setForegroundColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    CGColorRef n = (gMaster && c) ? LayerRemap(c, AACIcon, NULL) : NULL;
    if (!n && gMaster && gOn[AACIcon] && c && OnMain() && IsInkCG(c) && IsKeyboardLayer(self)) n = CGFor(AACIcon, NO);
    %orig(n ?: c);
}
%end

%hook CAShapeLayer
- (void)setFillColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (!gMaster || !c) { %orig; return; }
    CGColorRef n = LayerRemap(c, AACIcon, NULL);
    if (n) { %orig(n); return; }
    %orig;
    StripWhiteShapeOutline(self);
    if (!gInTry && (gOn[AACFill] || gOn[AACIcon]) && (IsBlackCG(c) || (gOn[AACIcon] && IsInkCG(c)))) ScheduleCheck(self, YES);
}
- (void)setStrokeColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (!gMaster || !c) { %orig; return; }
    CGColorRef n = LayerRemap(c, AACIcon, NULL);
    if (n) { %orig(n); return; }
    %orig;
    StripWhiteShapeOutline(self);
    if (!gInTry && gOn[AACIcon] && IsInkCG(c)) ScheduleCheck(self, YES);
}
%end

%hook UISegmentedControl
- (void)setSelectedSegmentTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    UIColor *n = (gMaster && gOn[AACFill] && c && OnMain() && IsBlackColor(c)) ? gColor[AACFill] : nil;
    %orig(n ?: c);
}
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (gMaster && gOn[AACFill] && OnMain()) {
        UIColor *cur = self.selectedSegmentTintColor;
        if (cur && IsBlackColor(cur)) self.selectedSegmentTintColor = gColor[AACFill];
    }
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    UIColor *n = gMaster ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c);
}
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (self.window) { FixLabelBG(self); TabLabelFix(self); KbLabelFix(self); }
}
- (void)layoutSubviews {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    FixLabelBG(self);
    TabLabelFix(self);
}
%end

%hook UIButton
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (self.window && gMaster && gOn[AACIcon] && OnMain() && ViewInKeyboard(self)) {
        UIColor *tc = [self titleColorForState:UIControlStateNormal];
        if (tc && IsInkColor(tc)) [self setTitleColor:gColor[AACIcon] forState:UIControlStateNormal];
    }
}
- (void)setTitleColor:(UIColor *)c forState:(UIControlState)st {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    UIColor *n = gMaster ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c, st);
}
- (void)setImage:(UIImage *)img forState:(UIControlState)st {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig(DualImageRemap(BlueImageRemap(IconRemapImage(ShadowStripImage(img)))), st);
}
%end

%hook UIBarButtonItem
- (void)setImage:(UIImage *)img {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig(DualImageRemap(BlueImageRemap(IconRemapImage(ShadowStripImage(img)))));
}
%end

%hook UIImageView
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (self.window) KbImageFix(self);
}
- (void)setImage:(UIImage *)img {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (OnMain() && !objc_getAssociatedObject(self.layer, kImgView))
        objc_setAssociatedObject(self.layer, kImgView, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (OnMain() && LooksLikeAvatarView(self)) { %orig(img); return; }
    UIImage *n = DualImageRemap(BlueImageRemap(IconRemapImage(ShadowStripImage(img))));
    if (n && gMaster && gOn[AACIcon] && OnMain()) {
        CGSize s = n.size;
        if (s.width <= 80 && s.height <= 80 && InTabBar(self)) n = TabColorize(n);
    }
    %orig(n);
    // [MOI] icon da doi sang accent -> bo bong do
    if (n && n != img && gMaster && gOn[AACIcon] && OnMain()) KillShadowUp(self.layer, 2);
    if (self.window) KbImageFix(self);
}
%end

%hook UIImage
- (UIImage *)imageWithTintColor:(UIColor *)c renderingMode:(UIImageRenderingMode)m {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    return %orig(IconTintFix(c), m);
}
- (UIImage *)imageWithTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    return %orig(IconTintFix(c));
}
%end

%hook UITabBar
- (void)layoutSubviews { %orig; TabBarFix(self); }
- (void)didMoveToWindow { %orig; if (self.window) TabBarFixLater(self); }
- (void)setSelectedItem:(UITabBarItem *)item { %orig; TabBarFixLater(self); }
- (void)traitCollectionDidChange:(UITraitCollection *)prev { %orig; TabBarFixLater(self); }
- (void)setUnselectedItemTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig((gMaster && gOn[AACIcon] && c && OnMain() && IsInkColor(c)) ? gColor[AACIcon] : c);
}
%end

%hook UITabBarItemStateAppearance
- (void)setIconColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig((gMaster && gOn[AACIcon] && c && OnMain() && IsInkColor(c)) ? gColor[AACIcon] : c);
}
- (void)setTitleTextAttributes:(NSDictionary<NSAttributedStringKey, id> *)attrs {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
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
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    return %orig(IconTintFix(c));
}
+ (UIImageSymbolConfiguration *)configurationWithPaletteColors:(NSArray<UIColor *> *)colors {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    NSMutableArray *m = [NSMutableArray arrayWithCapacity:colors.count];
    for (UIColor *c in colors) [m addObject:(c ? IconTintFix(c) : c) ?: (id)NSNull.null];
    if ([m containsObject:NSNull.null]) return %orig(colors);
    return %orig(m);
}
%end

%hook UISlider
- (void)didMoveToWindow { %orig; TagControl(self); }
%end

%hook UIVisualEffectView
- (void)didMoveToWindow { %orig; TagControl(self); }
%end

%hook UISwitch
- (void)layoutSubviews { %orig; TagControl(self); }
- (void)setOnTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig((gMaster && gOn[AACFill]) ? gColor[AACFill] : c);
}
- (UIColor *)onTintColor {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    if (gMaster && gOn[AACFill]) return gColor[AACFill];
    return %orig;
}
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    TagControl(self);
    if (gMaster && gOn[AACFill] && OnMain()) self.onTintColor = gColor[AACFill];
}
%end

%hook UIColor
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    return RemapRGBA(r, g, b, a) ?: %orig;
}
+ (UIColor *)colorWithDisplayP3Red:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    return RemapRGBA(r, g, b, a) ?: %orig;
}
- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    CGFloat nr = r, ng = g, nb = b, na = a;
    if (RemapComps(&nr, &ng, &nb, &na)) return %orig(nr, ng, nb, na);
    return %orig;
}
+ (UIColor *)systemBlueColor {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    if (gMaster && gOn[AACIcon] && gColor[AACIcon]) return gColor[AACIcon];
    return %orig;
}
+ (UIColor *)linkColor {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    if (gMaster && gOn[AACText] && gColor[AACText]) return gColor[AACText];
    return %orig;
}
%end

%group AACContents
%hook CALayer
- (void)setContents:(id)contents {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (gInContents) { %orig; return; }
    if (objc_getAssociatedObject(self, kContentsSrc))
        objc_setAssociatedObject(self, kContentsSrc, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(self, kKbSrc))
        objc_setAssociatedObject(self, kKbSrc, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!contents || !gMaster || !gOn[AACIcon] || !OnMain() ||
        CFGetTypeID((__bridge CFTypeRef)contents) != CGImageGetTypeID()) { %orig; return; }

    CGImageRef cg = (__bridge CGImageRef)contents;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    CGSize s = self.bounds.size;
    BOOL skip = objc_getAssociatedObject(self, kImgView) || [self isKindOfClass:CAShapeLayer.class] ||
                (self.masksToBounds && self.cornerRadius > 0) ||
                w < 8 || h < 8 || w > 192 || h > 192 ||
                s.width > 48 || s.height > 48 ||
                (double)MIN(w, h) / (double)MAX(w, h) < 0.6;
    BOOL monoOK = !skip && !InBackdropLayer(self) && CGImageIsBlackMono(cg) == 1;
    if (!monoOK) {
        // [MOI] Phim ban phim: nut xanh -> accent, bieu tuong den (Enter) -> accent
        if (w >= 8 && h >= 8 && w <= 400 && h <= 400 && s.width <= 220 && s.height <= 160 &&
            !objc_getAssociatedObject(self, kImgView) && ![self isKindOfClass:CAShapeLayer.class] &&
            IsKeyboardLayer(self)) {
            CGImageRef k = KbRecolor(cg);
            if (k) {
                objc_setAssociatedObject(self, kKbSrc, contents, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                %orig((__bridge id)k);
                CGImageRelease(k);
                return;
            }
        }
        %orig;
        return;
    }

    CGImageRef t = CopyTintedCG(cg, IconShapeColor(self));
    if (!t) { %orig; return; }
    objc_setAssociatedObject(self, kContentsSrc, contents, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig((__bridge id)t);
    CGImageRelease(t);
    KillShadowUp(self, 2);
}
%end
%end

%group AACPending
%hook CALayer
- (void)layoutSublayers {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (gHasPend && OnMain()) PendingRun(self);
}
%end
%end

static BOOL IsFacebookFamily(void) {
    NSBundle *b = NSBundle.mainBundle;
    NSString *bid = [b.bundleIdentifier lowercaseString] ?: @"";
    NSString *exe = [[b objectForInfoDictionaryKey:@"CFBundleExecutable"] lowercaseString] ?: @"";
    return [bid containsString:@"facebook"] || [bid containsString:@"messenger"] ||
           [exe isEqualToString:@"facebook"] || [exe isEqualToString:@"messenger"];
}

static NSString *const kCrashKey = @"AccentColorAll_LastCrash";
static NSUncaughtExceptionHandler *gPrevEH;

static void AACExceptionHandler(NSException *e) {
    @try {
        NSMutableString *t = [NSMutableString stringWithFormat:@"%@: %@\n", e.name, e.reason];
        for (NSString *l in e.callStackSymbols) {
            [t appendFormat:@"%@\n", l];
            if (t.length > 6000) break;
        }
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setObject:t forKey:kCrashKey];
        [d synchronize];
    } @catch (__unused id x) {}
    if (gPrevEH) gPrevEH(e);
}

static void InstallEH(int n) {
    NSUncaughtExceptionHandler *cur = NSGetUncaughtExceptionHandler();
    if (cur != AACExceptionHandler) {
        gPrevEH = cur;
        NSSetUncaughtExceptionHandler(AACExceptionHandler);
    }
    if (n < 4) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ InstallEH(n + 1); });
}

static NSString *SigPathStr(void) { return gSigPath[0] ? [NSString stringWithUTF8String:gSigPath] : nil; }

static NSString *PeekCrash(void) {
    NSString *t = [NSUserDefaults.standardUserDefaults stringForKey:kCrashKey];
    NSString *sp = SigPathStr();
    NSString *sg = sp ? [NSString stringWithContentsOfFile:sp encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!t.length && !sg.length) return nil;
    NSMutableString *m = [NSMutableString new];
    if (t.length) [m appendFormat:@"[NSException]\n%@\n", t];
    if (sg.length) [m appendFormat:@"[Signal]\n%@\n", sg];
    return m;
}

static void ClearCrash(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kCrashKey];
    NSString *sp = SigPathStr();
    if (sp) [NSFileManager.defaultManager removeItemAtPath:sp error:nil];
}

%ctor {
    @autoreleasepool {
        NSString *bp = NSBundle.mainBundle.bundlePath;
        if (!bp || [bp.pathExtension isEqualToString:@"appex"]) return;
        [NSUserDefaults.standardUserDefaults registerDefaults:@{ kMasterKey: @YES }];
        InstallSignals();
        InstallEH(0);
        gSafe = IsFacebookFamily();
        RefreshCache();
        %init;
        if (!gSafe) { %init(AACPending); }
        if (AAC_CONTENTS_HOOK) { %init(AACContents); }
    }
}

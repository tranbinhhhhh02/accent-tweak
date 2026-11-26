#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#include <execinfo.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#import <objc/message.h>
#if __has_include(<substrate.h>)
#import <substrate.h>
#endif

typedef NS_ENUM(int, AACCat) { AACFill = 0, AACText = 0, AACIcon = 0, AACCount = 1 };

static NSString *const kMasterKey  = @"AccentColorAll_Enabled";
static NSString *const kHexKey     = @"AccentColorAll_Hex";
static NSString *const kDefaultHex = @"B8A8FF";
static NSString *const kCrashKey   = @"AccentColorAll_LastCrash";
static NSString *const kKbBarKey   = @"AccentColorAll_KbShortcuts";
static NSString *const kKbTopKey   = @"AccentColorAll_KbTopMode";
static NSString *const kKeepAliveKey = @"AccentColorAll_KeepAlive";

#define KEY(n) static const void *n = &n;
KEY(kFill) KEY(kGestureFlag) KEY(kTintVer) KEY(kIconShape) KEY(kMonoBlack)
KEY(kAccentSrc) KEY(kAccentStamp) KEY(kBlueState) KEY(kBlueOut) KEY(kBlueStamp) KEY(kBlueSrc)
KEY(kDualSrc) KEY(kDualState) KEY(kDualOut) KEY(kDualStamp)
KEY(kContentsSrc) KEY(kCtl) KEY(kImgView) KEY(kOwner) KEY(kNoShadow)
KEY(kStripSrc) KEY(kStripState) KEY(kStripOut)
KEY(kKbSrc) KEY(kKbImg) KEY(kKbBlue) KEY(kKbTried) KEY(kKbTries)
KEY(kInkTint) KEY(kInkImg) KEY(kArrowDone) KEY(kAttempts) KEY(kPendShape)
KEY(kTintWhite)
KEY(kOrigTint) KEY(kInkOrig) KEY(kInkBase) KEY(kInkMode)

// Gioi han so lan xu ly nang trong 1 giay (moi vi tri goi co bo dem rieng)
#define RATE_LIMIT(max) ({ static CFAbsoluteTime _ws; static int _wc; \
    CFAbsoluteTime _n = CFAbsoluteTimeGetCurrent(); \
    if (_n - _ws > 1.0) { _ws = _n; _wc = 0; } \
    ++_wc <= (max); })

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
static NSCache    *gKbCache;
static __thread BOOL gRaw;

#define AAC_MAXDEPTH 12
static __thread int gDepth;
static inline int  AACDepthEnter(void)      { gDepth++; return 0; }
static inline void AACDepthLeave(int *p)    { gDepth--; }
#define AAC_DEPTH_SCOPE int _aacScope __attribute__((cleanup(AACDepthLeave))) = AACDepthEnter()
static BOOL        gInTry;
static BOOL        gInTabFix;
static BOOL        gInContents;
static BOOL        gInKbFix;
static volatile int32_t gPending;
static BOOL        gSafe;
static BOOL        gKbBarOn;
static BOOL        gKbTopOn;
static BOOL        gKeepAliveOn;
static __thread BOOL gTintBypass;

@interface CALayer (AACPrivate)
- (void)setContentsMultiplyColor:(CGColorRef)c;
@end

static inline BOOL OnMain(void) { return [NSThread isMainThread]; }
static inline const CGFloat *AccRGB(void) { return gDark ? gRGBD : gRGBL; }

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

// Facebook/Messenger cai handler tin hieu rieng de de len handler cua minh -> cai lai dinh ky de van ghi duoc log crash
static void ReinstallSignals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = AACSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_ONSTACK;
    int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) {
        struct sigaction cur;
        if (sigaction(sigs[i], NULL, &cur) == 0 && cur.sa_handler != AACSignalHandler) sigaction(sigs[i], &sa, NULL);
    }
}

static void TabBarFix(UITabBar *bar);

// ---- Mau ----
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
    gKbBarOn = [d boolForKey:kKbBarKey];
    gKbTopOn = [d boolForKey:kKbTopKey];
    gKeepAliveOn = [d boolForKey:kKeepAliveKey];
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
    return [c getRed:&r green:&g blue:&b alpha:&a] && IsDarkRGBA(r, g, b, a, 0.03);
}
static BOOL IsInkColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    return [c getRed:&r green:&g blue:&b alpha:&a] && IsDarkRGBA(r, g, b, a, 0.16);
}
static BOOL IsWhiteColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    return [c getRed:&r green:&g blue:&b alpha:&a] && a >= 0.99 && r > 0.97 && g > 0.97 && b > 0.97;
}

static BOOL IsBlackCG(CGColorRef c) {
    CGFloat r, g, b, a;
    return CGRGBA(c, &r, &g, &b, &a) && IsDarkRGBA(r, g, b, a, 0.03);
}
static BOOL IsInkCG(CGColorRef c) {
    CGFloat r, g, b, a;
    return CGRGBA(c, &r, &g, &b, &a) && IsDarkRGBA(r, g, b, a, 0.16);
}
static BOOL IsWhiteCG(CGColorRef c) {
    CGFloat r, g, b, a;
    return CGRGBA(c, &r, &g, &b, &a) && a >= 0.99 && r > 0.97 && g > 0.97 && b > 0.97;
}

static BOOL IsFillCandidateCG(CGColorRef c)    { return IsBlackCG(c) || (gDark && IsWhiteCG(c)); }
static BOOL IsFillCandidateColor(UIColor *c)   { return IsBlackColor(c) || (gDark && IsWhiteColor(c)); }

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

// Lop "nen accent" hop le: mau nen hien tai that su la accent (khong tin vao co danh dau cu,
// vi lop co the bi tai su dung / doi mau sau khi da danh dau -> icon bi tra thanh trang).
// Them: nen phai THAT SU HIEN THI (khong an, khong trong suot, khong rong) -> neu khong icon se bi to trang tren nen sang/trang
static BOOL FillValid(CALayer *a) {
    if (!a || !IsAccentCG(a.backgroundColor)) return NO;
    CGSize sz = a.bounds.size;
    if (sz.width < 1 || sz.height < 1) return NO;
    CALayer *p = a;
    for (int i = 0; i < 6 && p; i++, p = p.superlayer) {
        if (p.hidden || p.opacity < 0.5f) return NO;
    }
    return YES;
}

static BOOL LayerUnderFill(CALayer *l) {
    for (int i = 0; i < 4 && l; i++, l = l.superlayer)
        if (FillValid(l)) return YES;
    return NO;
}

// Icon nam BEN TRONG mot nen accent (chu khong chi cung cay lop) -> moi ve trang
static BOOL LayerInsideFill(CALayer *l) {
    CALayer *p = l.superlayer;
    for (int i = 0; i < 4 && p; i++, p = p.superlayer) {
        if (!FillValid(p)) continue;
        CGRect r = [l convertRect:l.bounds toLayer:p];
        if (CGRectContainsRect(CGRectInset(p.bounds, -6, -6), r)) return YES;
    }
    return NO;
}

static CGColorRef IconShapeColor(CALayer *l) {
    if (gCGWhite && LayerInsideFill(l)) return gCGWhite;
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
    const CGFloat *q = AccRGB();
    *a = *a * (cls == 2 ? 0.2 : 1.0);
    *r = q[0]; *g = q[1]; *b = q[2];
    return YES;
}

// ---- Xu ly pixel dung chung ----
static inline void Unpre(const uint8_t *px, CGFloat *r, CGFloat *g, CGFloat *b) {
    CGFloat a = px[3];
    *r = fmin(1, px[0] / a); *g = fmin(1, px[1] / a); *b = fmin(1, px[2] / a);
}

// Ve anh ra bo dem RGBA premultiplied. Tra ve buffer (caller free) va context (caller release)
static uint8_t *FlatBuf(UIImage *img, size_t *pw, size_t *ph, CGContextRef *pctx) {
    CGSize sz = img.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = img.scale > 0 ? img.scale : 1;
    fmt.opaque = NO;
    UIImage *flat = [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt]
        imageWithActions:^(UIGraphicsImageRendererContext *rc) {
            [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
        }];
    CGImageRef cg = flat.CGImage;
    size_t w = cg ? CGImageGetWidth(cg) : 0, h = cg ? CGImageGetHeight(cg) : 0;
    if (!cg || w == 0 || h == 0 || w > 256 || h > 256) return NULL;
    uint8_t *buf = calloc(w * h, 4);
    if (!buf) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NULL; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    *pw = w; *ph = h; *pctx = ctx;
    return buf;
}

static UIImage *FlatFinish(CGContextRef ctx, uint8_t *buf, CGFloat scale) {
    CGImageRef o = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    if (!o) return nil;
    UIImage *out = [UIImage imageWithCGImage:o scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(o);
    return out;
}

static int CGImageIsBlackMono(CGImageRef cg) {
    if (!cg) return 0;
    if (!RATE_LIMIT(120)) return -1;
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

// ---- Ban phim ----
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

// Phim nen xanh (da doi accent) nam duoi bieu tuong -> khong to accent bieu tuong trang (tranh mat chu)
static BOOL OnAccentKey(CALayer *l) {
    CGSize s = l.bounds.size;
    CALayer *p = l.superlayer;
    for (int i = 0; i < 2 && p; i++, p = p.superlayer) {
        CGPoint c = [l convertPoint:CGPointMake(s.width / 2, s.height / 2) toLayer:p];
        int n = 0;
        for (CALayer *o in p.sublayers) {
            if (++n > 24) break;
            if (o != l && objc_getAssociatedObject(o, kKbBlue) && CGRectContainsPoint(o.frame, c)) return YES;
        }
    }
    return NO;
}

// ---- Nhan dien chu tren phim Space (ten ban phim, vd. "Tieng Viet Telex") ----
// Dua vao VI TRI: nam giua man hinh theo chieu ngang, o phan duoi cua man hinh (hang phim cuoi)
// -> khong phu thuoc cau truc view cua ban phim.
static BOOL KbBadName(NSString *cn) {
    return [cn containsString:@"Candidate"] || [cn containsString:@"Prediction"] ||
           [cn containsString:@"Suggestion"] || [cn containsString:@"Autocorrect"] ||
           [cn containsString:@"QuickType"];
}

static BOOL SpaceGeom(CGPoint c, CGFloat lw) {
    CGSize ss = UIScreen.mainScreen.bounds.size;
    if (ss.width <= 0 || lw < 24 || lw > ss.width * 0.8) return NO;
    return fabs(c.x - ss.width / 2) <= ss.width * 0.22 && c.y >= ss.height * 0.6;
}

static BOOL SpaceKeyLabel(UIView *lb) {
    UIWindow *w = lb.window;
    if (!w) return NO;
    UIView *p = lb;
    for (int i = 0; i < 8 && p; i++, p = p.superview)
        if (KbBadName(NSStringFromClass(p.class))) return NO;
    CGSize b = lb.bounds.size;
    CGPoint c = [lb convertPoint:CGPointMake(b.width / 2, b.height / 2) toView:nil];
    c = [w convertPoint:c toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    return SpaceGeom(c, b.width);
}

static BOOL SpaceKeyLayer(CALayer *l) {
    CGSize b = l.bounds.size;
    CGPoint pt = CGPointMake(b.width / 2, b.height / 2);
    CALayer *p = l;
    for (int i = 0; i < 30 && p; i++) {
        if (KbBadName(NSStringFromClass(p.class))) return NO;
        id d = p.delegate;
        if (d && KbBadName(NSStringFromClass([d class]))) return NO;
        CALayer *sup = p.superlayer;
        if (!sup) break;
        pt = [p convertPoint:pt toLayer:sup];
        p = sup;
    }
    return SpaceGeom(pt, b.width);
}

// Phan tich anh ban phim. mode: 1 = nut xanh -> accent, 2 = bieu tuong den -> accent,
// 3 = bieu tuong trang (dia cau, phim chu o Dark Mode...) -> accent,
// 4 = (chi phim Space) chu trang tren nen toi/xam o Dark Mode -> chi doi phan chu sang accent, giu nguyen nen.
// Tra ve anh moi hoac NULL.
static CGImageRef KbRender(CGImageRef src, size_t w, size_t h, BOOL spaceOK, int *pmode) {
    uint8_t *buf = calloc(w * h, 4);
    if (!buf) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NULL; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);

    size_t total = w * h;
    int solid = 0, blue = 0, gray = 0, blk = 0, lt = 0, clear = 0, lo = 0, hi = 0;
    for (size_t i = 0; i < total; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) { clear++; continue; }
        solid++;
        CGFloat r, g, b;
        Unpre(px, &r, &g, &b);
        if (BlueClass(r, g, b) == 1) { blue++; continue; }
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.12) continue;
        gray++;
        CGFloat lum = (r + g + b) / 3.0;
        if (lum < 0.3) blk++;
        else if (lum > 0.75) lt++;
        if (lum < 0.6) lo++;
        if (lum > 0.8) hi++;
    }

    BOOL glyph = (size_t)clear * 100 >= 30 * total;
    int mode = 0;
    if (solid >= 30 && blue * 100 >= 35 * solid) mode = 1;
    else if (solid >= 20 && gray * 100 >= 85 * solid && glyph && lt * 100 >= 55 * solid && blk * 100 <= 20 * solid) mode = 3;
    else if (solid >= 20 && gray * 100 >= 85 * solid && blk >= 6 &&
             (blk * 100 <= 45 * solid || (size_t)clear * 100 >= 40 * total) &&
             (lt * 100 >= 20 * solid || (size_t)clear * 100 >= 30 * total)) mode = 2;
    else if (spaceOK && solid >= 200 && gray * 100 >= 85 * solid && hi >= 8 && hi * 100 <= 30 * solid &&
             lo * 100 >= 60 * solid) mode = 4;
    *pmode = mode;
    if (!mode) { CGContextRelease(ctx); free(buf); return NULL; }

    const CGFloat *q = AccRGB();
    for (size_t i = 0; i < total; i++) {
        uint8_t *px = buf + i * 4;
        if (px[3] == 0) continue;
        CGFloat a = px[3], r, g, b, n[3];
        Unpre(px, &r, &g, &b);
        if (mode == 1) {
            if (BlueClass(r, g, b) != 1) continue;
            n[0] = q[0]; n[1] = q[1]; n[2] = q[2];
        } else if (mode == 4) {
            CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
            if (mx - mn > 0.12) continue;
            CGFloat lum = (r + g + b) / 3.0;
            if (lum < 0.55) continue;
            CGFloat t = fmin(1, (lum - 0.55) / 0.3);
            CGFloat o[3] = { r, g, b };
            for (int k = 0; k < 3; k++) n[k] = o[k] * (1 - t) + q[k] * t;
        } else {
            CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
            if (mx - mn > 0.12) continue;
            CGFloat t = fmax(0, fmin(1, (r + g + b) / 3.0));
            for (int k = 0; k < 3; k++) n[k] = mode == 2 ? q[k] * (1 - t) + t : q[k] * t;
        }
        for (int k = 0; k < 3; k++) px[k] = (uint8_t)lround(fmax(0, fmin(1, n[k])) * a);
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    return out;
}

// Co cache theo (anh goc, phien ban accent, dark/light, co phai phim space) -> doi ngon ngu khong phai tinh lai, khong nhap nhay
// Anh rong (> 400px, vd. chu tren phim space): chi nhan dien che do 2 (chu den); rieng phim Space (theo vi tri) con nhan 3 va 4 (chu trang)
static CGImageRef KbRecolor(CGImageRef src, CALayer *l) {
    if (!src || !gMaster || !gOn[AACIcon]) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w < 8 || h < 8 || w > 1600 || h > 500) return NULL;
    BOOL big = w > 400;
    BOOL spaceOK = big && l && SpaceKeyLayer(l);
    if (!gKbCache) { gKbCache = [NSCache new]; gKbCache.countLimit = 400; }
    NSString *key = [NSString stringWithFormat:@"%p:%d:%d", src, gVersion * 2 + (gDark ? 1 : 0), spaceOK ? 1 : 0];
    NSArray *e = [gKbCache objectForKey:key];
    if (!e) {
        if (big) { if (!RATE_LIMIT(30)) return NULL; }
        else     { if (!RATE_LIMIT(400)) return NULL; }
        int mode = 0;
        CGImageRef o = KbRender(src, w, h, spaceOK, &mode);
        e = @[(__bridge id)src, o ? (__bridge id)o : (id)NSNull.null, @(mode)];   // giu src de dia chi khong bi tai su dung
        if (o) CGImageRelease(o);
        [gKbCache setObject:e forKey:key];
    }
    int mode = [e[2] intValue];
    if (!mode) return NULL;
    if (big && !(mode == 2 || (spaceOK && (mode == 3 || mode == 4)))) return NULL;
    if (mode == 3 && l && OnAccentKey(l)) return NULL;
    if (mode == 1 && l) objc_setAssociatedObject(l, kKbBlue, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return CGImageRetain((__bridge CGImageRef)e[1]);
}

// Chu/so ban phim bi dam hon accent (to 2 lan) hoac bi den (nhan voi mau den): anh da duoc to accent
// nen contentsMultiplyColor phai la trang. Chi goi cho layer da duoc tweak to accent (kKbSrc / kContentsSrc).
static void FixDoubleTint(CALayer *l) {
    if (!l || !gCGWhite) return;
    @try {
        id m = [l valueForKey:@"contentsMultiplyColor"];
        if (m && CFGetTypeID((__bridge CFTypeRef)m) == CGColorGetTypeID() &&
            !IsWhiteCG((__bridge CGColorRef)m)) {
            [l setContentsMultiplyColor:gCGWhite];
        }
    } @catch (NSException *e) {}
}

static void SetKbContents(CALayer *l, CGImageRef k) {
    gInContents = YES;
    l.contents = (__bridge id)k;
    gInContents = NO;
    FixDoubleTint(l);
}

// Thu lai doi mau cho layer ban phim khi layer da gan vao cay (goi tu layoutSublayers -> truoc khi hien len man hinh)
static void KbLate(CALayer *l) {
    if (!l || !gMaster || !gOn[AACIcon] || !OnMain() || !l.superlayer) return;
    if (objc_getAssociatedObject(l, kKbSrc) || objc_getAssociatedObject(l, kContentsSrc) || objc_getAssociatedObject(l, kImgView)) return;
    id c = l.contents;
    if (!c || CFGetTypeID((__bridge CFTypeRef)c) != CGImageGetTypeID() || [l isKindOfClass:CAShapeLayer.class]) return;
    CGSize s = l.bounds.size;
    if (s.width > 800 || s.height > 240) return;
    NSNumber *n = objc_getAssociatedObject(l, kKbTries);
    if (objc_getAssociatedObject(l, kKbTried) != c) {
        objc_setAssociatedObject(l, kKbTried, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        n = nil;
    }
    if (n.intValue >= 4) return;
    objc_setAssociatedObject(l, kKbTries, @(n.intValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!IsKeyboardLayer(l)) return;
    CGImageRef k = KbRecolor((__bridge CGImageRef)c, l);
    if (!k) return;
    objc_setAssociatedObject(l, kKbSrc, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SetKbContents(l, k);
    CGImageRelease(k);
}

// Chu tren ban phim (label / CATextLayer): chu den -> accent; Dark Mode: chu trang 1 ky tu -> accent
static NSString *TextOf(id s) {
    if ([s isKindOfClass:NSAttributedString.class]) return [(NSAttributedString *)s string];
    return [s isKindOfClass:NSString.class] ? s : nil;
}

static BOOL KbCol(UIColor *c, BOOL one) { return c && (IsInkColor(c) || (one && IsWhiteColor(c))); }

// Mau chu tren phim Space: xam/den (hoac trang o Dark Mode), CHO PHEP trong suot mot phan (alpha >= 0.3)
static BOOL KbGrayLum(CGFloat r, CGFloat g, CGFloat b, CGFloat a, BOOL allowLight) {
    if (a < 0.3) return NO;
    CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
    if (mx - mn > 0.12) return NO;
    CGFloat lum = (r + g + b) / 3.0;
    return lum < 0.4 || (allowLight && lum > 0.7);
}

static BOOL KbColSpace(UIColor *c, UITraitCollection *tc, BOOL allowLight) {
    if (!c) return NO;
    UIColor *rc = tc ? [c resolvedColorWithTraitCollection:tc] : c;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![rc getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return KbGrayLum(r, g, b, a, allowLight);
}

static BOOL KbCGSpaceCol(CGColorRef c, BOOL allowLight) {
    if (!c || IsOurs(c)) return NO;
    CGFloat r, g, b, a;
    if (!CGRGBA(c, &r, &g, &b, &a)) return NO;
    return KbGrayLum(r, g, b, a, allowLight);
}

static BOOL KbColAny(UIColor *c, BOOL space, BOOL one, UITraitCollection *tc) {
    if (!c || c == gColor[AACIcon]) return NO;
    if (space) return KbColSpace(c, tc, one);
    return KbCol(c, one);
}

// Doi mau chu trong NSAttributedString (toan bo cac doan) -> tra ve ban sao da sua hoac nil neu khong can doi
static NSMutableAttributedString *KbAttrFix(NSAttributedString *as, BOOL space, BOOL one, UITraitCollection *tc) {
    if (!as || as.length == 0 || !gColor[AACIcon]) return nil;
    __block NSMutableAttributedString *m = nil;
    [as enumerateAttribute:NSForegroundColorAttributeName
                   inRange:NSMakeRange(0, as.length)
                   options:0
                usingBlock:^(id v, NSRange r, BOOL *stop) {
        if ([v isKindOfClass:UIColor.class] && KbColAny((UIColor *)v, space, one, tc)) {
            if (!m) m = [as mutableCopy];
            [m addAttribute:NSForegroundColorAttributeName value:gColor[AACIcon] range:r];
        }
    }];
    return m;
}

static CGColorRef KbTextColor(CGColorRef c, id str, CALayer *l) {
    NSString *t = TextOf(str);
    if (!c || t.length == 0 || t.length > 40) return NULL;
    BOOL space = NO;
    if (t.length > 3) {
        // Chu dai: chi doi khi la chu tren phim Space
        if (!l || !(IsInkCG(c) || (gDark && IsWhiteCG(c)) || KbCGSpaceCol(c, gDark)) || !SpaceKeyLayer(l)) return NULL;
        space = YES;
    }
    if (IsInkCG(c) || (gDark && (t.length == 1 || space) && IsWhiteCG(c)) || (space && KbCGSpaceCol(c, gDark)))
        return CGFor(AACIcon, NO);
    return NULL;
}

static void KbTextFix(CALayer *l) {
    if (!gOn[AACIcon] || ![l isKindOfClass:CATextLayer.class]) return;
    CATextLayer *t = (CATextLayer *)l;
    id str = t.string;
    NSString *s = TextOf(str);
    if (s.length == 0 || s.length > 40) return;
    CGColorRef fg = t.foregroundColor;
    BOOL isAttr = [str isKindOfClass:NSAttributedString.class];
    BOOL longTxt = s.length > 3;
    BOOL fgHit = fg && (IsInkCG(fg) || (gDark && IsWhiteCG(fg)) || (longTxt && KbCGSpaceCol(fg, gDark)));
    if (!fgHit && !isAttr) return;
    if (!IsKeyboardLayer(l)) return;
    BOOL space = NO;
    if (longTxt) {
        if (!SpaceKeyLayer(l)) return;
        space = YES;
    }
    BOOL one = gDark && (s.length == 1 || space);
    if (fg && (IsInkCG(fg) || (one && IsWhiteCG(fg)) || (space && KbCGSpaceCol(fg, gDark)))) t.foregroundColor = CGFor(AACIcon, NO);
    if (isAttr && gColor[AACIcon]) {
        NSMutableAttributedString *m = KbAttrFix((NSAttributedString *)str, space, one, nil);
        if (m) t.string = m;
    }
}

static void KbLabelFix(UILabel *lb) {
    if (!gMaster || !gOn[AACIcon] || !gColor[AACIcon] || !OnMain()) return;
    NSString *t = lb.text ?: lb.attributedText.string;
    if (t.length == 0 || t.length > 40 || !ViewInKeyboard(lb)) return;
    BOOL space = NO;
    if (t.length > 3) {
        // Chu dai: chi doi khi la chu tren phim Space
        if (!SpaceKeyLabel(lb)) return;
        space = YES;
    }
    UITraitCollection *tc = lb.traitCollection;
    BOOL dk = gDark || tc.userInterfaceStyle == UIUserInterfaceStyleDark;
    BOOL one = dk && (t.length == 1 || space);
    if (KbColAny(lb.textColor, space, one, tc)) lb.textColor = gColor[AACIcon];
    NSMutableAttributedString *m = KbAttrFix(lb.attributedText, space, one, tc);
    if (m) lb.attributedText = m;
}

static void KbImageFix(UIImageView *iv) {
    if (gInKbFix || !gMaster || !gOn[AACIcon] || !OnMain()) return;
    UIImage *im = iv.image;
    if (!im || !im.CGImage || objc_getAssociatedObject(im, kKbImg)) return;
    if (im.isSymbolImage || im.renderingMode == UIImageRenderingModeAlwaysTemplate || im.images.count > 1) return;
    if (im.size.width > 96 || im.size.height > 96) {
        // Anh rong: chi xu ly neu la chu tren phim Space
        if (im.size.width > 600 || im.size.height > 120 || !SpaceKeyLayer(iv.layer)) return;
    }
    if (!ViewInKeyboard(iv)) return;
    CGImageRef k = KbRecolor(im.CGImage, iv.layer);
    if (!k) return;
    UIImage *out = [UIImage imageWithCGImage:k scale:im.scale orientation:im.imageOrientation];
    CGImageRelease(k);
    if (!out) return;
    objc_setAssociatedObject(out, kKbImg, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gInKbFix = YES;
    iv.image = out;
    gInKbFix = NO;
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

static void KillShadowDown(CALayer *l, int depth) {
    if (!l || depth > 4 || !OnMain() || IsKeyboardLayer(l)) return;
    for (CALayer *s in [l.sublayers copy]) {
        CGSize z = s.bounds.size;
        if (z.height > 120 || z.width > 200 || NearControl(s)) continue;
        objc_setAssociatedObject(s, kNoShadow, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (s.shadowOpacity > 0) s.shadowOpacity = 0;
        KillShadowDown(s, depth + 1);
    }
}

static void KillShadowUp(CALayer *l, int levels) {
    if (!l || !OnMain()) return;
    for (int i = 0; i < levels && l; i++, l = l.superlayer) {
        if (IsKeyboardLayer(l)) break;
        CGSize s = l.bounds.size;
        if (s.height > 120) break;
        if (i > 0 && s.width > 120) break;
        if (NearControl(l)) break;
        objc_setAssociatedObject(l, kNoShadow, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (l.shadowOpacity > 0) l.shadowOpacity = 0;
    }
}

static BOOL SubtreeAccent(CALayer *l, int depth, int *budget) {
    if (!l || depth > 5 || *budget <= 0) return NO;
    for (CALayer *sub in l.sublayers) {
        if ((*budget)-- <= 0) break;
        if (HasAccentMark(sub)) return YES;
        if (SubtreeAccent(sub, depth + 1, budget)) return YES;
    }
    return NO;
}

static BOOL ShadowNamed(CALayer *l) {
    if ([NSStringFromClass(l.class) containsString:@"Shadow"]) return YES;
    id d = l.delegate;
    return d && [NSStringFromClass([d class]) containsString:@"Shadow"];
}

static BOOL ShadowEligible(CALayer *l) {
    if (!gMaster || !OnMain()) return NO;
    if (IsKeyboardLayer(l)) return NO;
    if (objc_getAssociatedObject(l, kNoShadow)) return YES;
    if (ShadowNamed(l)) {
        CGSize z = l.bounds.size;
        if (z.height <= 160 && z.width <= 800) return YES;
    }
    CGSize s = l.bounds.size;
    if (s.height > 120 || s.width > 200) return NO;
    if (NearControl(l)) return NO;
    if (HasAccentMark(l)) return YES;
    CGColorRef sc = l.shadowColor;
    if (sc && (IsAccentCG(sc) || IsOurs(sc))) return YES;
    CALayer *p = l.superlayer;
    for (int i = 0; i < 6 && p; i++, p = p.superlayer) {
        CGSize ps = p.bounds.size;
        if (ps.height > 120 || ps.width > 200) break;
        if (HasAccentMark(p)) return YES;
    }
    int budget = 60;
    return SubtreeAccent(l, 0, &budget);
}

// Glow/vien: lop "den" nam canh lop icon trang cung kich thuoc -> an di thay vi nhuom accent
static BOOL HasTwinSibling(CALayer *l) {
    CALayer *p = l.superlayer;
    if (!p) return NO;
    CGSize s = l.bounds.size;
    if (s.width < 6 || s.height < 6 || s.width > 64 || s.height > 64) return NO;
    int n = 0;
    for (CALayer *o in p.sublayers) {
        if (++n > 12) break;
        if (o == l || o.hidden || objc_getAssociatedObject(o, kInkTint)) continue;
        CGSize t = o.bounds.size;
        if (fabs(t.width - s.width) > 10 || fabs(t.height - s.height) > 10) continue;
        if (o.contents || [o isKindOfClass:CAShapeLayer.class] || o.sublayers.count > 0) return YES;
    }
    return NO;
}

static void GlowCheck(CALayer *l) {
    if (!l || !gMaster || !OnMain() || l.hidden) return;
    if (!objc_getAssociatedObject(l, kInkTint) || IsKeyboardLayer(l)) return;
    if (HasTwinSibling(l)) l.hidden = YES;
}

static void MarkInk(CALayer *l) {
    if (!l || !OnMain()) return;
    objc_setAssociatedObject(l, kInkTint, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak CALayer *wl = l;
    double delays[3] = { 0.0, 0.3, 1.0 };
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GlowCheck(wl);
        });
    }
}

// Ghi nho layer nay dang duoc to trang hay to accent (de kiem tra lai khi nen thay doi)
static void NoteTint(CALayer *l, CGColorRef c) {
    objc_setAssociatedObject(l, kTintWhite, @(c == gCGWhite), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ReapplyContents(CALayer *l) {
    if (!OnMain()) return;
    id src = objc_getAssociatedObject(l, kContentsSrc);
    if (src) {
        CGColorRef ic = IconShapeColor(l);
        CGImageRef t = CopyTintedCG((__bridge CGImageRef)src, ic);
        if (t) { NoteTint(l, ic); SetKbContents(l, t); CGImageRelease(t); }
        return;
    }
    id ks = objc_getAssociatedObject(l, kKbSrc);
    if (ks) {
        CGImageRef t = KbRecolor((__bridge CGImageRef)ks, l);
        if (t) { SetKbContents(l, t); CGImageRelease(t); }
    }
}

// Icon dang bi to trang nhung nen accent da mat (hoac nguoc lai) -> to lai cho dung
static void RecheckContents(CALayer *l) {
    NSNumber *w = objc_getAssociatedObject(l, kTintWhite);
    if (!w || !objc_getAssociatedObject(l, kContentsSrc)) return;
    BOOL want = (IconShapeColor(l) == gCGWhite);
    if (want != w.boolValue) ReapplyContents(l);
}

static void ApplyShapeColor(CALayer *l) {
    NSNumber *m = objc_getAssociatedObject(l, kIconShape);
    if (!m || ![l isKindOfClass:CAShapeLayer.class]) return;
    CAShapeLayer *sh = (CAShapeLayer *)l;
    CGColorRef c = IconShapeColor(l);
    gInTry = YES;
    if (m.intValue & 1) sh.fillColor   = c;
    if (m.intValue & 2) sh.strokeColor = c;
    gInTry = NO;
}

static void RefreshLayerTree(CALayer *l, int depth) {
    if (depth > 40) return;
    if (gOn[AACIcon]) ApplyShapeColor(l);
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
        ApplyShapeColor(s);
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
    if (!OnMain() || l.bounds.size.height > 120) return;
    if (objc_getAssociatedObject(l, kFill)) return;
    objc_setAssociatedObject(l, kFill, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gFillCount++;
    KillShadowUp(l, 5);
    KillShadowDown(l, 0);
    if (gSafe) {
        dispatch_async(dispatch_get_main_queue(), ^{ FixUnderFill(l, 0); });
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

// Co danh dau VA nen hien tai that su la accent (tranh co danh dau cu khi lop bi tai su dung)
static BOOL UnderFill(UIView *v) {
    for (int i = 0; i < 4 && v; i++) {
        CALayer *l = v.layer;
        if (objc_getAssociatedObject(l, kFill) && FillValid(l)) return YES;
        v = v.superview;
    }
    return NO;
}

// Dung cho getter tintColor: view phai nam BEN TRONG nen accent (dang hien thi) thi moi tra ve trang
static BOOL TintOnFill(UIView *v) {
    UIView *p = v;
    for (int i = 0; i < 4 && p; i++, p = p.superview) {
        CALayer *pl = p.layer;
        if (!objc_getAssociatedObject(pl, kFill) || !FillValid(pl)) continue;
        if (p == v) return YES;
        CGRect r = [v convertRect:v.bounds toView:p];
        if (CGRectContainsRect(CGRectInset(p.bounds, -6, -6), r)) return YES;
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

// ---- Nut tron den co mui ten (nut gui, nut "Hien thi cau tra loi"); KHONG ap dung tren ban phim ----
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
    // Uu tien icon dia cau: bo xu ly nut "back/mui ten" tron tren ban phim
    BOOL arrowBtn = round && sz.width >= 10 && sz.width <= 56 && l.sublayers.count > 0 &&
                    IsBlackCG(l.backgroundColor) && !IsKeyboardLayer(l);
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
    if (!bg || !IsFillCandidateColor(bg) || lb.bounds.size.height > 64) return;
    if (UnderFill(lb.superview) || LayerUnderFill(lb.layer.superlayer)) lb.backgroundColor = UIColor.clearColor;
}

static void TryBlackShape(CAShapeLayer *sh) {
    if (!gOn[AACFill] || !OnMain() || !IsBlackCG(sh.fillColor)) return;
    CGPathRef path = sh.path;
    if (!path || CGPathIsEmpty(path)) return;
    CGRect b = CGPathGetBoundingBox(path);
    if (CGRectIsNull(b) || CGRectIsInfinite(b) || isnan(b.size.width) || isnan(b.size.height)) return;
    if (b.size.height < 20 || b.size.height > 64 || b.size.width < b.size.height * 1.6) return;
    sh.fillColor = CGFor(AACFill, NO);
}

// Icon trang co vien/bong den: bo vien thay vi doi sang accent
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
    if (!gOn[AACIcon] || gInTry || !OnMain() || InGlassLayer(sh)) return;
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
    MarkInk(sh);
}

// ---- Hang doi kiem tra lai layer ----
static NSHashTable *gPend;
static volatile int32_t gHasPend;
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

// ---- Bien doi anh icon (chay tren moi ung dung) ----
// Icon trang co vien/bong den "nuong" trong anh -> xoa phan toi, giu phan trang
static UIImage *ShadowStripImage(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
    if (objc_getAssociatedObject(img, kStripSrc)) return img;
    if (img.isSymbolImage || img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.images.count > 1) return img;
    if (!UIEdgeInsetsEqualToEdgeInsets(img.capInsets, UIEdgeInsetsZero)) return img;
    CGSize sz = img.size;
    if (sz.width < 14 || sz.height < 14 || sz.width > 64 || sz.height > 64) return img;
    NSNumber *state = objc_getAssociatedObject(img, kStripState);
    if (state) return state.boolValue ? (objc_getAssociatedObject(img, kStripOut) ?: img) : img;
    if (!RATE_LIMIT(50)) return img;

    size_t w = 0, h = 0; CGContextRef ctx = NULL;
    uint8_t *buf = FlatBuf(img, &w, &h, &ctx);
    if (!buf) {
        objc_setAssociatedObject(img, kStripState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }
    int solid = 0, light = 0, dark = 0, darkOpq = 0, colored = 0, clear = 0;
    for (size_t i = 0; i < w * h; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) { clear++; continue; }
        solid++;
        CGFloat r, g, b;
        Unpre(px, &r, &g, &b);
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.15) { colored++; continue; }
        CGFloat lum = (r + g + b) / 3.0;
        if (lum < 0.35) { dark++; if (px[3] >= 200) darkOpq++; }
        else if (lum > 0.8 && px[3] >= 200) light++;
    }
    BOOL ok = solid >= 20 && colored * 10 <= solid && light * 100 >= 20 * solid &&
              dark * 100 >= 5 * solid && darkOpq <= light &&
              (size_t)clear * 100 >= 25 * w * h;
    if (!ok) {
        CGContextRelease(ctx);
        free(buf);
        objc_setAssociatedObject(img, kStripState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *px = buf + i * 4;
        if (px[3] == 0) continue;
        CGFloat r, g, b;
        Unpre(px, &r, &g, &b);
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.15) continue;
        if ((r + g + b) / 3.0 < 0.4) px[0] = px[1] = px[2] = px[3] = 0;
    }
    UIImage *out = FlatFinish(ctx, buf, img.scale > 0 ? img.scale : 1);
    if (!out) return img;
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
    } else if (!RATE_LIMIT(60)) {
        return img;
    }

    size_t w = 0, h = 0; CGContextRef ctx = NULL;
    uint8_t *buf = FlatBuf(img, &w, &h, &ctx);
    if (!buf) {
        objc_setAssociatedObject(img, kBlueState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }
    int solid = 0, blue = 0, other = 0;
    for (size_t i = 0; i < w * h; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        solid++;
        CGFloat r, g, b;
        Unpre(px, &r, &g, &b);
        if (BlueClass(r, g, b)) blue++; else other++;
    }
    if (!(solid >= 6 && blue > 0 && other * 40 <= solid)) {
        CGContextRelease(ctx);
        free(buf);
        objc_setAssociatedObject(img, kBlueState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }
    const CGFloat *q = AccRGB();
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        CGFloat r, g, b;
        Unpre(px, &r, &g, &b);
        int cls = BlueClass(r, g, b);
        if (!cls) continue;
        CGFloat al = (px[3] / 255.0) * (cls == 2 ? 0.2 : 1.0);
        for (int k = 0; k < 3; k++) px[k] = (uint8_t)lround(fmax(0, fmin(1, q[k])) * al * 255);
        px[3] = (uint8_t)lround(al * 255);
    }
    UIImage *out = FlatFinish(ctx, buf, img.scale > 0 ? img.scale : 1);
    if (!out) return img;
    objc_setAssociatedObject(out, kBlueSrc, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kBlueState, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kBlueOut, out, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kBlueStamp, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

// Icon den kem chi tiet trang (vd icon Messenger) -> doi den thanh accent, giu trang
static UIImage *DualImageRemap(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
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
    } else if (!RATE_LIMIT(40)) {
        return img;
    }

    size_t w = 0, h = 0; CGContextRef ctx = NULL;
    uint8_t *buf = FlatBuf(img, &w, &h, &ctx);
    if (!buf) {
        objc_setAssociatedObject(img, kDualState, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return img;
    }
    int solid = 0, blk = 0, mid = 0, other = 0, opq = 0, opqBlk = 0;
    for (size_t i = 0; i < w * h; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        solid++;
        CGFloat r, g, b;
        Unpre(px, &r, &g, &b);
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
    const CGFloat *q = AccRGB();
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *px = buf + i * 4;
        if (px[3] == 0) continue;
        CGFloat a = px[3], r, g, b;
        Unpre(px, &r, &g, &b);
        CGFloat mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
        if (mx - mn > 0.12) continue;
        CGFloat t = fmax(0, fmin(1, (r + g + b) / 3.0));
        for (int k = 0; k < 3; k++) px[k] = (uint8_t)lround((q[k] * (1 - t) + t) * a);
    }
    UIImage *out = FlatFinish(ctx, buf, img.scale > 0 ? img.scale : 1);
    if (!out) return img;
    objc_setAssociatedObject(out, kDualSrc, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kDualState, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kDualOut, out, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(img, kDualStamp, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return out;
}

static UIImage *IconFix(UIImage *img) {
    return DualImageRemap(BlueImageRemap(IconRemapImage(ShadowStripImage(img))));
}

static UIColor *IconTintFix(UIColor *c) {
    if (gTintBypass) return c;
    if (gMaster && gOn[AACIcon] && c && OnMain()) {
        if (IsInkColor(c)) return gColor[AACIcon];
        UIColor *n = ColorRemap(c, AACIcon, NULL);
        if (n) return n;
    }
    return c;
}

// ---- Dark Mode: vung accent che noi dung (anh lon bi to mau accent, vd. lop mo vien bai Threads trong Facebook) ----
// Anh/icon nho van doi accent nhu cu; chi anh LON (> 120pt moi chieu) o Dark Mode giu nguyen mau goc.
static BOOL BigImageView(UIView *v) {
    if (![v isKindOfClass:UIImageView.class]) return NO;
    CGSize b = v.bounds.size;
    if (b.width > 0 && b.height > 0) return b.width > 120 && b.height > 120;
    UIImage *im = ((UIImageView *)v).image;
    return im && im.size.width > 120 && im.size.height > 120;
}

static void KeepInkOrig(UIImage *out, UIImage *base, UIColor *c, NSInteger mode) {
    if (!out || !base || !c || !IsInkColor(c)) return;
    objc_setAssociatedObject(out, kInkOrig, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(out, kInkBase, base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(out, kInkMode, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ImageView lon dang hien anh da bi to accent thay cho mau den goc -> to lai bang mau goc
static void BigInkFix(UIImageView *iv) {
    if (!gDark || !gMaster || !OnMain()) return;
    CGSize b = iv.bounds.size;
    if (b.width <= 120 || b.height <= 120) return;
    UIImage *im = iv.image;
    if (!im) return;
    UIImage *base = objc_getAssociatedObject(im, kInkBase);
    UIColor *orig = objc_getAssociatedObject(im, kInkOrig);
    if (!base || !orig) return;
    NSInteger mode = [objc_getAssociatedObject(im, kInkMode) integerValue];
    gTintBypass = YES;
    UIImage *r = [base imageWithTintColor:orig renderingMode:(UIImageRenderingMode)mode];
    gTintBypass = NO;
    if (r) iv.image = r;
}

// Du phong (chi Facebook + Dark Mode): lop lon co gradient accent / multiply accent / nen accent co mask -> bo mau accent
static BOOL gInLargeFix;
static void LargeAccentFix(CALayer *l) {
    if (!gSafe || !gDark || !gMaster || !OnMain() || gInLargeFix || !l) return;
    CGSize s = l.bounds.size;
    if (s.width < 200 || s.height < 200) return;
    gInLargeFix = YES;
    @try {
        if ([l isKindOfClass:CAGradientLayer.class]) {
            CAGradientLayer *g = (CAGradientLayer *)l;
            NSArray *cols = g.colors;
            if (cols.count) {
                BOOL hit = NO;
                NSMutableArray *m = [NSMutableArray arrayWithCapacity:cols.count];
                for (id c in cols) {
                    if (c && CFGetTypeID((__bridge CFTypeRef)c) == CGColorGetTypeID() && IsAccentCG((__bridge CGColorRef)c)) {
                        CGColorRef clr = CGColorCreateCopyWithAlpha((__bridge CGColorRef)c, 0);
                        if (clr) { [m addObject:(__bridge_transfer id)clr]; hit = YES; continue; }
                    }
                    [m addObject:c];
                }
                if (hit) g.colors = m;
            }
        }
        if (l.contents && gCGWhite) {
            id mc = [l valueForKey:@"contentsMultiplyColor"];
            if (mc && CFGetTypeID((__bridge CFTypeRef)mc) == CGColorGetTypeID() && IsAccentCG((__bridge CGColorRef)mc))
                [l setContentsMultiplyColor:gCGWhite];
        }
        if (l.mask && l.backgroundColor && IsAccentCG(l.backgroundColor)) l.backgroundColor = NULL;
    } @catch (NSException *e) {}
    gInLargeFix = NO;
}

// ---- Tab bar ----
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
    if (lb.textColor == gColor[AACIcon] || !InTabBar(lb)) return;
    lb.textColor = gColor[AACIcon];
}

// ---- Bang cai dat ----
static BOOL gPanelShown;
static BOOL gPanelPending;

static void ClosePanelWindow(void) {
    gPanelShown = NO;
    gPanelPending = NO;
}

static BOOL VCBusy(UIViewController *vc) {
    if (!vc || !vc.viewIfLoaded.window) return YES;
    if (vc.isBeingPresented || vc.isBeingDismissed || vc.isMovingToParentViewController || vc.isMovingFromParentViewController) return YES;
    if (vc.transitionCoordinator != nil) return YES;
    return [vc isKindOfClass:UIAlertController.class];
}

static UIViewController *TopVC(void) {
    UIWindow *best = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        if (sc.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in [((UIWindowScene *)sc).windows copy]) {
            if (w.hidden || w.windowLevel != UIWindowLevelNormal || !w.rootViewController) continue;
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

static NSString *PeekCrash(void);
static void ClearCrash(void);
static void KbBarRefreshAll(void);
static void KeepAliveRefresh(void);

// App chu co khai bao UIBackgroundModes = audio trong Info.plist khong
static BOOL HostDeclaresAudio(void) {
    id m = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
    return [m isKindOfClass:NSArray.class] && [(NSArray *)m containsObject:@"audio"];
}

@interface AACSettingsVC : UITableViewController <UIColorPickerViewControllerDelegate>
@end

@implementation AACSettingsVC

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    Crumb("settingsVC:viewDidLoad");
    self.title = @"Action Tool";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    [self buildAuthorFooter];
}

- (void)buildAuthorFooter {
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 64)];
    UILabel *a = [UILabel new];
    a.text = @"Created by ";
    a.font = [UIFont systemFontOfSize:13];
    a.textColor = UIColor.secondaryLabelColor;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"Tran Binh" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [b addTarget:self action:@selector(openAuthor) forControlEvents:UIControlEventTouchUpInside];
    UILabel *c = [UILabel new];
    c.text = @" \u2661";
    c.font = [UIFont systemFontOfSize:13];
    c.textColor = UIColor.secondaryLabelColor;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[a, b, c]];
    st.axis = UILayoutConstraintAxisHorizontal;
    st.alignment = UIStackViewAlignmentCenter;
    st.spacing = 0;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [st.centerYAnchor constraintEqualToAnchor:box.centerYAnchor]
    ]];
    self.tableView.tableFooterView = box;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *f = self.tableView.tableFooterView;
    CGFloat w = self.tableView.bounds.size.width;
    if (f && w > 0 && fabs(f.frame.size.width - w) > 0.5) {
        f.frame = CGRectMake(0, 0, w, 64);
        self.tableView.tableFooterView = f;
    }
}

- (void)openAuthor {
    NSURL *u = [NSURL URLWithString:@"https://www.facebook.com/profile.php?id=100091902503211"];
    if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:^{ ClosePanelWindow(); }]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 1) return 2;
    if (s == 2) return 1;
    return PeekCrash().length ? 4 : 3;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 2 ? @"Hành vi" : (s == 1 ? @"Bàn phím" : @"Màu nhấn"); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 2) {
        return HostDeclaresAudio()
            ? @"Giữ phiên âm thanh hoạt động khi app xuống nền hoặc khoá màn hình. App này đã khai báo chế độ nền audio."
            : @"App này chưa khai báo chế độ nền \"audio\" (UIBackgroundModes) trong Info.plist nên iOS vẫn có thể tạm dừng app sau ít giây. Hãy thêm UIBackgroundModes = audio khi ký/cài IPA (Sideloadly, ESign...).";
    }
    return s == 1 ? @"Thanh phím tắt: hàng nút cạnh phím địa cầu. \"Dạng TrollPad\" chuyển Hoàn tác, Làm lại, Dán sang trái và In đậm/nghiêng/gạch chân sang phải hàng gợi ý từ phía trên bàn phím (cần có hàng gợi ý, nếu không sẽ về dạng thường)." : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.section == 2) {
        UITableViewCell *kc = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        kc.selectionStyle = UITableViewCellSelectionStyleNone;
        kc.textLabel.text = @"Chạy nền (Keep-Alive)";
        kc.detailTextLabel.text = @"Giữ phiên âm thanh hoạt động khi app xuống nền; hiệu quả phụ thuộc vào việc app có hỗ trợ audio nền.";
        kc.detailTextLabel.numberOfLines = 0;
        kc.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        UISwitch *ksw = [UISwitch new];
        ksw.on = [d boolForKey:kKeepAliveKey];
        [ksw addTarget:self action:@selector(keepAliveChanged:) forControlEvents:UIControlEventValueChanged];
        kc.accessoryView = ksw;
        return kc;
    }
    if (ip.section == 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *ks = [UISwitch new];
        if (ip.row == 0) {
            cell.textLabel.text = @"Thanh phím tắt";
            ks.on = [d boolForKey:kKbBarKey];
            [ks addTarget:self action:@selector(kbBarChanged:) forControlEvents:UIControlEventValueChanged];
        } else if (ip.row == 1) {
            cell.textLabel.text = @"Dạng TrollPad";
            ks.on = [d boolForKey:kKbTopKey];
            [ks addTarget:self action:@selector(kbTopChanged:) forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = ks;
        return cell;
    }
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
    if (ip.section != 0) return;
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

- (void)keepAliveChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.isOn forKey:kKeepAliveKey];
    gKeepAliveOn = sw.isOn;
    KeepAliveRefresh();
}

- (void)kbTopChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.isOn forKey:kKbTopKey];
    gKbTopOn = sw.isOn;
    KbBarRefreshAll();
}

- (void)kbBarChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.isOn forKey:kKbBarKey];
    gKbBarOn = sw.isOn;
    KbBarRefreshAll();
    // Ap dung ngay: yeu cau ban phim dang mo nap lai thanh phim tat (khong can mo lai ban phim)
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [UIApplication.sharedApplication sendAction:@selector(reloadInputViews) to:nil from:nil forEvent:nil];
        } @catch (__unused id x) {}
    });
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

// ---- Cong cu chan doan: giu 4 ngon 1 giay -> sao chep cay layer vao clipboard ----
static NSString *HexCG(CGColorRef c) {
    CGFloat r, g, b, a;
    if (!CGRGBA(c, &r, &g, &b, &a)) return c ? @"?" : @"nil";
    return [NSString stringWithFormat:@"%@@%.2f", HexFromRGB(r, g, b), a];
}

static void DumpLayer(CALayer *l, int depth, BOOL kb, NSMutableString *out, NSUInteger limit) {
    if (!l || depth > 16 || out.length > limit) return;
    CGSize s = l.bounds.size;
    BOOL shp = [l isKindOfClass:CAShapeLayer.class];
    BOOL txt = [l isKindOfClass:CATextLayer.class];
    BOOL small = s.width <= 64 && s.height <= 64;
    BOOL big = s.width >= 120 && s.height >= 120;
    BOOL grad = [l isKindOfClass:CAGradientLayer.class];
    BOOL show = kb ? (l.contents != nil || shp || txt)
                   : (l.shadowOpacity > 0 || shp || (l.contents && small) || grad ||
                      (big && (l.mask || l.contents || (l.backgroundColor && IsAccentCG(l.backgroundColor)))));
    if (show) {
        [out appendFormat:@"%d %@ %.0fx%.0f", depth, NSStringFromClass(l.class), s.width, s.height];
        id d = l.delegate;
        if (d) [out appendFormat:@" del=%@", NSStringFromClass([d class])];
        if ([d isKindOfClass:UIImageView.class]) {
            UIImage *dim = ((UIImageView *)d).image;
            if (dim) [out appendFormat:@" img=%.0fx%.0f rm=%ld", dim.size.width, dim.size.height, (long)dim.renderingMode];
        }
        if (l.mask) [out appendString:@" MASK"];
        if (grad) {
            for (id gc in ((CAGradientLayer *)l).colors) {
                if (gc && CFGetTypeID((__bridge CFTypeRef)gc) == CGColorGetTypeID())
                    [out appendFormat:@" g=%@", HexCG((__bridge CGColorRef)gc)];
            }
        }
        if (l.contents) [out appendString:@" contents"];
        if (l.hidden) [out appendString:@" HIDDEN"];
        if (l.opacity < 0.99) [out appendFormat:@" op=%.2f", l.opacity];
        if (l.shadowOpacity > 0)
            [out appendFormat:@" shadow(op=%.2f r=%.1f col=%@)", l.shadowOpacity, l.shadowRadius, HexCG(l.shadowColor)];
        if (l.backgroundColor) [out appendFormat:@" bg=%@", HexCG(l.backgroundColor)];
        if (shp) {
            CAShapeLayer *sh = (CAShapeLayer *)l;
            [out appendFormat:@" fill=%@ stroke=%@ lw=%.1f", HexCG(sh.fillColor), HexCG(sh.strokeColor), sh.lineWidth];
        }
        @try {
            id m = [l valueForKey:@"contentsMultiplyColor"];
            if (m) [out appendFormat:@" mult=%@", HexCG((__bridge CGColorRef)m)];
        } @catch (NSException *e) {}
        [out appendString:@"\n"];
    }
    for (CALayer *sub in [l.sublayers copy]) DumpLayer(sub, depth + 1, kb, out, limit);
}

static NSString *DumpAll(void) {
    NSMutableString *out = [NSMutableString new];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [((UIWindowScene *)sc).windows copy]) {
            NSString *cn = NSStringFromClass(w.class);
            BOOL kb = KbName(cn) || [cn containsString:@"TextEffects"];
            [out appendFormat:@"== %@ level=%.0f kb=%d\n", cn, w.windowLevel, kb];
            DumpLayer(w.layer, 0, kb, out, out.length + 7000);
        }
    }
    return out;
}

@interface AACHelper : NSObject <UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate>
+ (instancetype)shared;
@end

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

@implementation AACHelper
+ (instancetype)shared {
    static AACHelper *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [AACHelper new]; });
    return h;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (void)onDump:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIPasteboard.generalPasteboard.string = DumpAll();
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)pc {
    ClosePanelWindow();
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (gPanelShown || gPanelPending) return;
    Crumb("onLongPress");
    gPanelPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ShowPanel(0);
    });
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
                UILongPressGestureRecognizer *g2 = [[UILongPressGestureRecognizer alloc]
                    initWithTarget:[AACHelper shared] action:@selector(onDump:)];
                g2.numberOfTouchesRequired = 4;
                g2.minimumPressDuration = 1.0;
                g2.cancelsTouchesInView = NO;
                g2.delegate = [AACHelper shared];
                [w addGestureRecognizer:g2];
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

// ================= HOOKS =================
%hook UIWindow
- (void)makeKeyAndVisible { %orig; Setup(self); }
- (void)becomeKeyWindow { %orig; Setup(self); }
- (void)setRootViewController:(UIViewController *)vc { %orig; Setup(self); }
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    BOOL d = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    if (d == gDark) return;
    gDark = d;
    // Doi Light/Dark: ve lai ban phim & icon ngay voi mau tuong ung
    static BOOL pending;
    if (pending) return;
    pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ pending = NO; ApplyAll(); });
}
%end

%hook UIView
- (UIColor *)tintColor {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    if (!gMaster || !gOn[AACIcon] || !gColor[AACIcon]) return %orig;
    if (gDark && BigImageView(self)) {
        UIColor *keep = objc_getAssociatedObject(self, kOrigTint);
        if (keep) return keep;
        return %orig;
    }
    if (gFillCount > 0 && gOn[AACFill] && OnMain() && TintOnFill(self) && !InControlView(self)) return UIColor.whiteColor;
    return gColor[AACIcon];
}
- (void)setTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    if (gMaster && gOn[AACIcon] && c && OnMain() && IsInkColor(c)) {
        objc_setAssociatedObject(self, kOrigTint, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(gColor[AACIcon]);
        if ([self isKindOfClass:UIImageView.class]) MarkInk(self.layer);
        return;
    }
    if (objc_getAssociatedObject(self, kOrigTint)) objc_setAssociatedObject(self, kOrigTint, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    BOOL inkSwap = NO;
    if (gMaster && c) {
        int mcls = 0;
        n = LayerRemap(c, AACIcon, &mcls);
        if (n && mcls == 2 && OnMain() && InGlassLayer(self)) n = NULL;
        if (!n && gOn[AACIcon] && OnMain() && IsInkCG(c) && !InGlassLayer(self)) {
            CGSize s = self.bounds.size;
            if (s.width <= 64 && s.height <= 64) { n = IconShapeColor(self); inkSwap = YES; }
        }
        // Anh cua layer nay da duoc to accent san -> multiply luon la trang (khong to 2 lan, moi phim cung 1 mau)
        if (gCGWhite && !IsWhiteCG(c) &&
            (objc_getAssociatedObject(self, kKbSrc) || objc_getAssociatedObject(self, kContentsSrc))) {
            n = gCGWhite;
        }
    }
    %orig(n ?: c);
    if (inkSwap) MarkInk(self);
}
// Go bong do tren nut/icon da doi sang accent
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
- (void)setShadowRadius:(CGFloat)r {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (self.shadowOpacity > 0 && ShadowEligible(self)) self.shadowOpacity = 0;
}
- (void)setShadowOffset:(CGSize)o {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (self.shadowOpacity > 0 && ShadowEligible(self)) self.shadowOpacity = 0;
}
// Mot hook layout duy nhat: hang doi kiem tra, go bong, doi mau ban phim (chay truoc khi len man hinh -> khong nhap nhay)
- (void)layoutSublayers {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (!gMaster || !OnMain()) return;
    LargeAccentFix(self);
    if (gHasPend) PendingRun(self);
    if (self.shadowOpacity > 0 && ShadowEligible(self)) self.shadowOpacity = 0;
    if (objc_getAssociatedObject(self, kContentsSrc)) RecheckContents(self);
    if (self.contents) KbLate(self);
    KbTextFix(self);
}
%end

%hook CAGradientLayer
- (void)setColors:(NSArray *)colors {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    LargeAccentFix(self);
}
%end

%hook CATextLayer
- (void)setForegroundColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    CGColorRef n = (gMaster && c) ? LayerRemap(c, AACIcon, NULL) : NULL;
    if (!n && gMaster && gOn[AACIcon] && c && OnMain() && IsKeyboardLayer(self)) n = KbTextColor(c, self.string, self);
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
    if (self.window) KbLabelFix(self);     // nhan phim (vd. nhan phim Space) doi mau ngay, khong cho layout
}
- (void)setText:(NSString *)t {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (self.window) KbLabelFix(self);
}
- (void)setAttributedText:(NSAttributedString *)t {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    if (self.window) KbLabelFix(self);
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
    KbLabelFix(self);
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
    %orig(IconFix(img), st);
}
%end

%hook UIBarButtonItem
- (void)setImage:(UIImage *)img {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig(IconFix(img));
}
%end

%hook UIImageView
- (void)layoutSubviews {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; }
    AAC_DEPTH_SCOPE;
    %orig;
    BigInkFix(self);
}
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
    UIImage *n = IconFix(img);
    if (n && gMaster && gOn[AACIcon] && OnMain()) {
        CGSize s = n.size;
        if (s.width <= 80 && s.height <= 80 && InTabBar(self)) n = TabColorize(n);
    }
    %orig(n);
    if (n && n != img && gMaster && gOn[AACIcon] && OnMain()) KillShadowUp(self.layer, 2);
    if (self.window) KbImageFix(self);
    if (n && objc_getAssociatedObject(n, kInkImg) && gMaster && OnMain()) MarkInk(self.layer);
}
%end

%hook UIImage
- (UIImage *)imageWithTintColor:(UIColor *)c renderingMode:(UIImageRenderingMode)m {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    UIColor *n = IconTintFix(c);
    UIImage *o = %orig(n, m);
    if (o && c && n != c && OnMain()) {
        objc_setAssociatedObject(o, kInkImg, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        KeepInkOrig(o, self, c, (NSInteger)m);
    }
    return o;
}
- (UIImage *)imageWithTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) return %orig;
    AAC_DEPTH_SCOPE;
    UIColor *n = IconTintFix(c);
    UIImage *o = %orig(n);
    if (o && c && n != c && OnMain()) {
        objc_setAssociatedObject(o, kInkImg, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        KeepInkOrig(o, self, c, (NSInteger)UIImageRenderingModeAlwaysOriginal);
    }
    return o;
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
    if (objc_getAssociatedObject(self, kContentsSrc)) objc_setAssociatedObject(self, kContentsSrc, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(self, kKbSrc))       objc_setAssociatedObject(self, kKbSrc, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(self, kKbBlue))      objc_setAssociatedObject(self, kKbBlue, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!contents || !gMaster || !gOn[AACIcon] || !OnMain() ||
        CFGetTypeID((__bridge CFTypeRef)contents) != CGImageGetTypeID()) { %orig; return; }

    CGImageRef cg = (__bridge CGImageRef)contents;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    CGSize s = self.bounds.size;
    BOOL notShape = ![self isKindOfClass:CAShapeLayer.class];
    BOOL skip = objc_getAssociatedObject(self, kImgView) || !notShape ||
                (self.masksToBounds && self.cornerRadius > 0) ||
                w < 8 || h < 8 || w > 192 || h > 192 ||
                s.width > 48 || s.height > 48 ||
                (double)MIN(w, h) / (double)MAX(w, h) < 0.6;
    BOOL monoOK = !skip && !InBackdropLayer(self) && CGImageIsBlackMono(cg) == 1;
    if (!monoOK) {
        // Ban phim: nut xanh / icon den / icon trang (dia cau, phim chu Dark Mode) -> accent, xu ly dong bo
        BOOL kbSize = notShape && w >= 8 && h >= 8 && w <= 1600 && h <= 500 && s.width <= 800 && s.height <= 240;
        if (kbSize && !objc_getAssociatedObject(self, kImgView) && IsKeyboardLayer(self)) {
            CGImageRef k = KbRecolor(cg, self);
            if (k) {
                objc_setAssociatedObject(self, kKbSrc, contents, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                %orig((__bridge id)k);
                FixDoubleTint(self);
                CGImageRelease(k);
                return;
            }
        }
        %orig;
        if (kbSize) {
            __weak CALayer *wl = self;
            dispatch_async(dispatch_get_main_queue(), ^{ KbLate(wl); });
        }
        return;
    }

    CGColorRef ic = IconShapeColor(self);
    CGImageRef t = CopyTintedCG(cg, ic);
    if (!t) { %orig; return; }
    objc_setAssociatedObject(self, kContentsSrc, contents, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NoteTint(self, ic);
    %orig((__bridge id)t);
    FixDoubleTint(self);
    CGImageRelease(t);
    KillShadowUp(self, 2);
}
%end
%end

// ---- Thanh nut Hoan tac / Lam lai / Sao chep / Cat / Dan canh phim dia cau (nguyen ly ActionBar) ----
// Khong phu thuoc UIKeyboardGetSafeDeviceIdiom: tu them UIStackView vao UIKeyboardDockView va gui
// copy:/cut:/paste: toi first responder qua -[UIApplication sendAction:to:nil], nen khong dung API rieng tu cua iOS.
KEY(kKbBarView)
static NSHashTable *gDocks;
static __weak UIResponder *gGrabbed;

@interface UIResponder (AACGrab)
- (void)aac_grab:(id)sender;
@end
@implementation UIResponder (AACGrab)
- (void)aac_grab:(id)sender { gGrabbed = self; }
@end

static UIResponder *KbFirstResponder(void) {
    gGrabbed = nil;
    [UIApplication.sharedApplication sendAction:@selector(aac_grab:) to:nil from:nil forEvent:nil];
    return gGrabbed;
}

@interface AACKbActions : NSObject
+ (instancetype)shared;
- (void)tap:(UIButton *)b;
@end

static id KbObjSend(id t, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (t && [t respondsToSelector:s]) return ((id (*)(id, SEL))objc_msgSend)(t, s);
    return nil;
}

// Gom moi NSUndoManager co the chua lich su go phim: first responder, delegate cua ban phim, chuoi responder
static NSArray<NSUndoManager *> *KbUndoManagers(void) {
    NSMutableArray *out = [NSMutableArray new];
    void (^add)(id) = ^(id o) {
        NSUndoManager *um = nil;
        if ([o isKindOfClass:UIResponder.class]) um = ((UIResponder *)o).undoManager;
        else um = KbObjSend(o, @"undoManager");
        if ([um isKindOfClass:NSUndoManager.class] && ![out containsObject:um]) [out addObject:um];
    };
    UIResponder *fr = KbFirstResponder();
    add(fr);
    id impl = KbObjSend((id)NSClassFromString(@"UIKeyboardImpl"), @"activeInstance");
    add(KbObjSend(impl, @"privateInputDelegate"));
    add(KbObjSend(impl, @"inputDelegate"));
    add(KbObjSend(fr, @"_responderWindow"));
    if ([fr isKindOfClass:UIView.class]) add(((UIView *)fr).window);
    return out;
}

static void KbMoveCursor(int off) {
    UIResponder *fr = KbFirstResponder();
    if (![fr conformsToProtocol:@protocol(UITextInput)]) return;
    id<UITextInput> ti = (id<UITextInput>)fr;
    UITextRange *r = ti.selectedTextRange;
    if (!r) return;
    UITextPosition *t = r.isEmpty ? [ti positionFromPosition:r.start offset:off] : (off < 0 ? r.start : r.end);
    if (!t) return;
    ti.selectedTextRange = [ti textRangeFromPosition:t toPosition:t];
}

static void KbHideKeyboard(void) {
    UIResponder *fr = KbFirstResponder();
    if ([fr isKindOfClass:UIView.class]) [((UIView *)fr).window endEditing:YES];
    [fr resignFirstResponder];
}

// Sao chep: co chon -> chep phan chon; khong chon -> chep TOAN BO noi dung o nhap (Copy All)
static NSString *KbTextToCopy(UIResponder *fr, BOOL *hadSel) {
    *hadSel = NO;
    if (![fr conformsToProtocol:@protocol(UITextInput)]) return nil;
    id<UITextInput> ti = (id<UITextInput>)fr;
    NSString *str = nil;
    UITextRange *sel = ti.selectedTextRange;
    if (sel && !sel.isEmpty) {
        *hadSel = YES;
        str = [ti textInRange:sel];
    }
    if (!str.length) {
        UITextPosition *b = ti.beginningOfDocument, *e = ti.endOfDocument;
        if (b && e) {
            UITextRange *all = [ti textRangeFromPosition:b toPosition:e];
            if (all && !all.isEmpty) str = [ti textInRange:all];
        }
    }
    return str;
}

static void KbCopyAll(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIResponder *fr = KbFirstResponder();
    BOOL hadSel = NO;
    NSString *str = KbTextToCopy(fr, &hadSel);
    if (hadSel) {   // co vung chon: dung copy: he thong de giu dinh dang, that bai thi chep chu thuong
        NSInteger cc = UIPasteboard.generalPasteboard.changeCount;
        BOOL ok = [app sendAction:@selector(copy:) to:nil from:nil forEvent:nil];
        if (ok && UIPasteboard.generalPasteboard.changeCount != cc) return;
    }
    if (str.length) {
        UIPasteboard.generalPasteboard.string = str;
        return;
    }
    // Du phong: o nhap khong theo UITextInput -> chon het roi copy:
    if (![app sendAction:@selector(copy:) to:nil from:nil forEvent:nil]) {
        [app sendAction:@selector(selectAll:) to:nil from:nil forEvent:nil];
        [app sendAction:@selector(copy:) to:nil from:nil forEvent:nil];
    }
}

static void KbUndoRedo(BOOL redo) {
    for (NSUndoManager *um in KbUndoManagers()) {
        if (redo ? um.canRedo : um.canUndo) {
            if (um.groupingLevel > 0) [um endUndoGrouping];
            if (redo) [um redo]; else [um undo];
            return;
        }
    }
}

@implementation AACKbActions
+ (instancetype)shared {
    static AACKbActions *a; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [AACKbActions new]; });
    return a;
}
- (void)tap:(UIButton *)b {
    @try {
        UIApplication *app = UIApplication.sharedApplication;
        switch (b.tag) {
            case 0: KbUndoRedo(NO); break;
            case 1: KbUndoRedo(YES); break;
            case 2: [app sendAction:@selector(selectAll:) to:nil from:nil forEvent:nil]; break;
            case 3: KbCopyAll(); break;
            case 4: [app sendAction:@selector(cut:)   to:nil from:nil forEvent:nil]; break;
            case 5: {
                BOOL ok = [app sendAction:@selector(paste:) to:nil from:nil forEvent:nil];
                if (!ok) {   // du phong: o nhap khong nhan paste: -> tu chen noi dung clipboard
                    NSString *str = UIPasteboard.generalPasteboard.string;
                    UIResponder *fr = KbFirstResponder();
                    if (str.length && [fr conformsToProtocol:@protocol(UIKeyInput)]) [(id<UIKeyInput>)fr insertText:str];
                }
                break;
            }
            case 6: KbMoveCursor(-1); break;
            case 7: KbMoveCursor(1); break;
            case 8: KbHideKeyboard(); break;
            case 9:  [app sendAction:NSSelectorFromString(@"toggleBoldface:")  to:nil from:nil forEvent:nil]; break;
            case 10: [app sendAction:NSSelectorFromString(@"toggleItalics:")   to:nil from:nil forEvent:nil]; break;
            case 11: [app sendAction:NSSelectorFromString(@"toggleUnderline:") to:nil from:nil forEvent:nil]; break;
        }
        [[UIImpactFeedbackGenerator new] impactOccurred];
    } @catch (__unused id x) {}
}
@end

static UIButton *KbMakeButton(NSInteger tag, NSString *title, NSString *symbol) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    if (symbol) {
        UIImage *im = [UIImage systemImageNamed:symbol];
        if (im) [b setImage:im forState:UIControlStateNormal];
        else [b setTitle:title forState:UIControlStateNormal];
    } else {
        [b setTitle:title forState:UIControlStateNormal];
    }
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    b.tintColor = UIColor.labelColor;
    [b setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    b.backgroundColor = UIColor.clearColor;
    [b addTarget:[AACKbActions shared] action:@selector(tap:) forControlEvents:UIControlEventTouchDown];
    return b;
}

static UIStackView *KbMakeBar(void) {
    NSArray *items = @[ KbMakeButton(0, @"Hoàn tác",  @"arrow.uturn.backward"),
                        KbMakeButton(1, @"Làm lại",   @"arrow.uturn.forward"),
                        KbMakeButton(3, @"Sao chép",  @"doc.on.doc"),
                        KbMakeButton(4, @"Cắt",       @"scissors"),
                        KbMakeButton(5, @"Dán",       @"doc.on.clipboard"),
                        KbMakeButton(8, @"Ẩn phím",   @"keyboard.chevron.compact.down") ];
    UIStackView *sv = [[UIStackView alloc] initWithArrangedSubviews:items];
    sv.axis = UILayoutConstraintAxisHorizontal;
    sv.distribution = UIStackViewDistributionFillEqually;
    sv.alignment = UIStackViewAlignmentFill;
    sv.spacing = 0;
    return sv;
}

// Thu thap cac view nho (icon qua dia cau, nut ben phai) trong dock theo toa do cua dock
static void KbCollectItems(UIView *root, UIView *dock, UIView *skip, int depth, NSMutableArray *out) {
    if (depth > 6) return;
    for (UIView *v in root.subviews) {
        if (v == skip || v.hidden || v.alpha < 0.05) continue;
        CGRect f = [dock convertRect:v.bounds fromView:v];
        BOOL small = f.size.width >= 14 && f.size.width <= 110 && f.size.height >= 14 && f.size.height <= 110;
        NSString *cn = NSStringFromClass(v.class);
        BOOL img = [v isKindOfClass:UIImageView.class];
        BOOL kind = img || [v isKindOfClass:UIControl.class] ||
                    [cn containsString:@"Button"] || [cn containsString:@"DockItem"] || [cn containsString:@"Globe"];
        if (small && kind) [out addObject:@{ @"r": [NSValue valueWithCGRect:f], @"img": @(img) }];
        KbCollectItems(v, dock, skip, depth + 1, out);
    }
}

static void KbBarPlace(UIView *dock) {
    UIStackView *bar = objc_getAssociatedObject(dock, kKbBarView);
    if (!gKbBarOn) {
        if (bar) { [bar removeFromSuperview]; objc_setAssociatedObject(dock, kKbBarView, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return;
    }
    if (!bar) {
        bar = KbMakeBar();
        objc_setAssociatedObject(dock, kKbBarView, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (bar.superview != dock) [dock addSubview:bar];
    CGRect b = dock.bounds;
    if (b.size.height < 20.0) { bar.hidden = YES; return; }

    NSMutableArray *items = [NSMutableArray new];
    KbCollectItems(dock, dock, bar, 0, items);
    CGFloat cy = b.size.height / 2.0, left = 64.0, right = b.size.width - 12.0;
    // Qua dia cau = view ben trai ngoai cung; neu nhieu view cung vi tri (nut + icon) thi lay icon (UIImageView) nho nhat
    CGFloat bestX = CGFLOAT_MAX, bestArea = CGFLOAT_MAX, rmin = CGFLOAT_MAX;
    BOOL bestImg = NO;
    for (NSDictionary *it in items) {
        CGRect f = [it[@"r"] CGRectValue];
        BOOL img = [it[@"img"] boolValue];
        CGFloat mx = CGRectGetMidX(f), area = f.size.width * f.size.height;
        if (mx >= b.size.width / 2.0) { rmin = MIN(rmin, CGRectGetMinX(f)); continue; }
        BOOL farther = mx > bestX + 6.0;
        BOOL nearer  = mx < bestX - 6.0;
        BOOL better  = nearer || (!farther && ((img && !bestImg) || (img == bestImg && area < bestArea)));
        if (bestX == CGFLOAT_MAX || better) {
            bestX = mx; bestArea = area; bestImg = img;
            cy = CGRectGetMidY(f);
            left = CGRectGetMaxX(f) + 8.0;
        }
    }
    if (rmin < CGFLOAT_MAX) right = rmin - 8.0;
    CGFloat w = MIN(right - left, 340.0);
    if (w < 150.0) { bar.hidden = YES; return; }
    bar.hidden = NO;
    CGFloat h = 34.0;
    CGFloat cx = (left + right) / 2.0;
    bar.frame = CGRectMake(cx - w / 2.0, cy - h / 2.0, w, h);
    [dock bringSubviewToFront:bar];
}

// ---- Dang TrollPad: Hoan tac/Lam lai/Dan ben trai, B/I/U ben phai hang goi y tu (nhu anh mau) ----
KEY(kKbTopL) KEY(kKbTopR) KEY(kKbTopOrig) KEY(kKbTopTry)
static NSHashTable *gTops;
static BOOL gTopHooked;
static void (*orig_topLayout)(id, SEL);

// Ve lai SF Symbol vao khung vuong co dinh, can theo tam hien thi thuc te cua net ve (bo qua khoang trong/baseline
// cua tung symbol), de B/I/U/hoan tac/dan nam cung mot truc ngang.
static UIImage *KbCenteredSymbol(NSString *name, CGFloat pt) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightRegular];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!img || !img.CGImage) return img;
    CGFloat scale = UIScreen.mainScreen.scale;
    size_t w = (size_t)ceil(img.size.width * scale), h = (size_t)ceil(img.size.height * scale);
    if (w == 0 || h == 0) return img;
    uint8_t *buf = calloc(w * h, 1);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (!ctx) { free(buf); return img; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img.CGImage);
    size_t minX = w, maxX = 0, minY = h, maxY = 0;
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++)
            if (buf[y * w + x] > 20) {
                if (x < minX) minX = x; if (x > maxX) maxX = x;
                if (y < minY) minY = y; if (y > maxY) maxY = y;
            }
    CGContextRelease(ctx); free(buf);
    if (maxX < minX || maxY < minY) return img;
    CGFloat cx = ((CGFloat)(minX + maxX + 1) / 2.0) / scale;
    CGFloat cy = ((CGFloat)(minY + maxY + 1) / 2.0) / scale;   // du lieu bitmap di tu tren xuong, khop he toa do UIKit
    CGFloat S = ceil(pt * 1.8);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale; fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(S, S) format:fmt];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] drawAtPoint:CGPointMake(S / 2.0 - cx, S / 2.0 - cy)];
    }];
    return [out imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIStackView *KbMakeGroup(NSArray<NSNumber *> *tags) {
    NSMutableArray *bs = [NSMutableArray new];
    for (NSNumber *n in tags) {
        switch (n.integerValue) {
            case 0:  [bs addObject:KbMakeButton(0,  @"Hoàn tác", @"arrow.uturn.backward")]; break;
            case 1:  [bs addObject:KbMakeButton(1,  @"Làm lại",  @"arrow.uturn.forward")]; break;
            case 5:  [bs addObject:KbMakeButton(5,  @"Dán",      @"doc.on.clipboard")]; break;
            case 9:  [bs addObject:KbMakeButton(9,  @"B",        @"bold")]; break;
            case 10: [bs addObject:KbMakeButton(10, @"I",        @"italic")]; break;
            case 11: [bs addObject:KbMakeButton(11, @"U",        @"underline")]; break;
        }
    }
    NSDictionary *syms = @{ @0: @"arrow.uturn.backward", @1: @"arrow.uturn.forward", @5: @"doc.on.clipboard",
                            @9: @"bold", @10: @"italic", @11: @"underline" };
    for (UIButton *b in bs) {
        UIImage *ci = KbCenteredSymbol(syms[@(b.tag)], 20);
        if (ci) { [b setImage:ci forState:UIControlStateNormal]; b.imageView.contentMode = UIViewContentModeCenter; }
    }
    UIStackView *sv = [[UIStackView alloc] initWithArrangedSubviews:bs];
    sv.axis = UILayoutConstraintAxisHorizontal;
    sv.distribution = UIStackViewDistributionFillEqually;
    sv.alignment = UIStackViewAlignmentFill;
    sv.spacing = 0;
    return sv;
}

// Tam doc trung binh cua cac chu goi y (UILabel) trong hang goi y, theo toa do cua P
static void KbLabelMids(UIView *root, UIView *P, UIView *skipA, UIView *skipB, int depth, CGFloat *sum, int *cnt) {
    if (depth > 7) return;
    for (UIView *v in root.subviews) {
        if (v == skipA || v == skipB || v.hidden || v.alpha < 0.05) continue;
        if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) {
            CGRect f = [P convertRect:v.bounds fromView:v];
            *sum += CGRectGetMidY(f); (*cnt)++;
        }
        KbLabelMids(v, P, skipA, skipB, depth + 1, sum, cnt);
    }
}

// Du phong: chu goi y ve bang CATextLayer
static void KbTextLayerMids(CALayer *root, CALayer *P, CALayer *skipA, CALayer *skipB, int depth, CGFloat *sum, int *cnt) {
    if (depth > 8) return;
    for (CALayer *l in root.sublayers) {
        if (l == skipA || l == skipB || l.hidden || l.opacity < 0.05) continue;
        if ([l isKindOfClass:CATextLayer.class] && ((CATextLayer *)l).string) {
            CGRect f = [P convertRect:l.bounds fromLayer:l];
            *sum += CGRectGetMidY(f); (*cnt)++;
        }
        KbTextLayerMids(l, P, skipA, skipB, depth + 1, sum, cnt);
    }
}

// Tam doc cua cac vach ngan cach giua cac goi y (view rong <= 2.5pt): trung voi tam chu goi y
static void KbSeparatorMids(UIView *root, UIView *P, UIView *skipA, UIView *skipB, int depth, CGFloat *sum, int *cnt) {
    if (depth > 7) return;
    for (UIView *v in root.subviews) {
        if (v == skipA || v == skipB || v.hidden || v.alpha < 0.05) continue;
        CGRect f = [P convertRect:v.bounds fromView:v];
        if (f.size.width > 0 && f.size.width <= 2.5 && f.size.height >= 12 && f.size.height <= 45) {
            *sum += CGRectGetMidY(f); (*cnt)++;
            continue;
        }
        KbSeparatorMids(v, P, skipA, skipB, depth + 1, sum, cnt);
    }
}

static void KbSeparatorLayerMids(CALayer *root, CALayer *P, CALayer *skipA, CALayer *skipB, int depth, CGFloat *sum, int *cnt) {
    if (depth > 8) return;
    for (CALayer *l in root.sublayers) {
        if (l == skipA || l == skipB || l.hidden || l.opacity < 0.05) continue;
        CGRect f = [P convertRect:l.bounds fromLayer:l];
        if (f.size.width > 0 && f.size.width <= 2.5 && f.size.height >= 12 && f.size.height <= 45) {
            *sum += CGRectGetMidY(f); (*cnt)++;
            continue;
        }
        KbSeparatorLayerMids(l, P, skipA, skipB, depth + 1, sum, cnt);
    }
}

static void KbTopPlace(UIView *P) {
    UIStackView *L = objc_getAssociatedObject(P, kKbTopL);
    UIStackView *R = objc_getAssociatedObject(P, kKbTopR);
    BOOL on = gKbBarOn && gKbTopOn;
    if (!on) {
        if (L || R) {
            [L removeFromSuperview]; [R removeFromSuperview];
            objc_setAssociatedObject(P, kKbTopL, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(P, kKbTopR, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (UIView *sv in P.subviews) {
                NSValue *o = objc_getAssociatedObject(sv, kKbTopOrig);
                if (o) { sv.frame = o.CGRectValue; objc_setAssociatedObject(sv, kKbTopOrig, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            }
            [P setNeedsLayout];
        }
        return;
    }
    if (!L) { L = KbMakeGroup(@[@0, @1, @5]);    objc_setAssociatedObject(P, kKbTopL, L, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    if (!R) { R = KbMakeGroup(@[@9, @10, @11]);  objc_setAssociatedObject(P, kKbTopR, R, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    if (L.superview != P) [P addSubview:L];
    if (R.superview != P) [P addSubview:R];
    CGRect pb = P.bounds;
    CGFloat bw = 36.0, gw = bw * 3.0, h = MIN(pb.size.height, 36.0);
    CGFloat sum = 0; int cnt = 0;
    KbSeparatorMids(P, P, L, R, 0, &sum, &cnt);            // 1) vach ngan cach giua cac goi y
    if (!cnt) KbSeparatorLayerMids(P.layer, P.layer, L.layer, R.layer, 0, &sum, &cnt);   // vach la CALayer
    if (!cnt) KbLabelMids(P, P, L, R, 0, &sum, &cnt);      // 2) UILabel cua chu goi y
    if (!cnt) KbTextLayerMids(P.layer, P.layer, L.layer, R.layer, 0, &sum, &cnt);
    CGFloat cy = pb.size.height / 2.0;
    if (cnt) cy = sum / cnt;                               // cung hang voi chu goi y
    else {                                                 // du phong: tam doc cua khung chua cac o goi y
        for (UIView *sv in P.subviews) {
            if (sv == L || sv == R || sv.hidden) continue;
            NSValue *o = objc_getAssociatedObject(sv, kKbTopOrig);
            CGRect f = o ? o.CGRectValue : sv.frame;
            if (f.size.width >= pb.size.width * 0.8 && f.size.height >= 20) { cy = CGRectGetMidY(f) + 3.0; break; }   // chu goi y nam thap hon tam khung ~3pt
        }
    }
    static const CGFloat kTopNudge = 0.0;   // nang icon len (pt); doi so nay neu can lech them
    CGFloat cc = cy - kTopNudge;                  // tam icon sau khi nang
    h = MAX(24.0, MIN(h, 2.0 * cc));              // giu khung nut trong P de van nhan duoc cham
    CGFloat y = cc - h / 2.0;
    L.frame = CGRectMake(6.0, y, gw, h);
    R.frame = CGRectMake(pb.size.width - gw - 6.0, y, gw, h);
    // Thu hep phan goi y vao giua de khong bi de len
    CGFloat inset = gw + 10.0;
    for (UIView *sv in P.subviews) {
        if (sv == L || sv == R || sv.hidden) continue;
        if (sv.frame.size.width >= pb.size.width * 0.8) {
            if (!objc_getAssociatedObject(sv, kKbTopOrig))
                objc_setAssociatedObject(sv, kKbTopOrig, [NSValue valueWithCGRect:sv.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            sv.frame = CGRectMake(inset, sv.frame.origin.y, pb.size.width - 2 * inset, sv.frame.size.height);
        }
    }
    [P bringSubviewToFront:L]; [P bringSubviewToFront:R];
    // Dam bao cham duoc vao nut: hang goi y va cac view cha khong duoc tat tuong tac
    L.userInteractionEnabled = YES; R.userInteractionEnabled = YES;
    int up = 0;
    for (UIView *a = P; a && up < 8; a = a.superview, up++) a.userInteractionEnabled = YES;
}

static UIView *(*orig_topHit)(id, SEL, CGPoint, UIEvent *);
static UIView *new_topHit(id self, SEL _cmd, CGPoint pt, UIEvent *ev) {
    @try {
        UIView *P = (UIView *)self;
        const void *keys[2] = { kKbTopL, kKbTopR };
        for (int i = 0; i < 2; i++) {
            UIStackView *g = objc_getAssociatedObject(P, keys[i]);
            if (g && g.superview == P && !g.hidden && CGRectContainsPoint(g.frame, pt)) {
                UIView *h = [g hitTest:[g convertPoint:pt fromView:P] withEvent:ev];
                if (h) return h;
            }
        }
    } @catch (__unused id x) {}
    return orig_topHit ? orig_topHit(self, _cmd, pt, ev) : nil;
}

static void new_topLayout(id self, SEL _cmd) {
    if (orig_topLayout) orig_topLayout(self, _cmd);
    @try { KbTopPlace((UIView *)self); } @catch (__unused id x) {}
}

// Tim view hang goi y tu (QuickType) nam cung ban phim voi dock
static UIView *KbFindPrediction(UIView *v, UIView *dock, int depth) {
    if (depth > 8) return nil;
    for (UIView *c in v.subviews) {
        NSString *cn = NSStringFromClass(c.class);
        if ([cn containsString:@"Prediction"] && ![cn containsString:@"Controller"] &&
            c.bounds.size.width >= dock.bounds.size.width * 0.6 && c.bounds.size.height >= 20 && c.bounds.size.height <= 90) return c;
        UIView *r = KbFindPrediction(c, dock, depth + 1);
        if (r) return r;
    }
    return nil;
}

static UIView *KbFindTop(UIView *dock) {
    UIView *a = dock.superview;
    for (int i = 0; a && i < 8; i++, a = a.superview) {
        UIView *p = KbFindPrediction(a, dock, 0);
        if (p) return p;
    }
    return nil;
}

static void KbBarRefreshAll(void) {
    for (UIView *d in [gDocks allObjects]) [d setNeedsLayout];
    for (UIView *t in [gTops allObjects]) { KbTopPlace(t); [t setNeedsLayout]; }
}

static void (*orig_dockLayout)(id, SEL);
static void new_dockLayout(id self, SEL _cmd) {
    if (orig_dockLayout) orig_dockLayout(self, _cmd);
    @try {
        UIView *dock = (UIView *)self;
        if (!gDocks) gDocks = [NSHashTable weakObjectsHashTable];
        [gDocks addObject:dock];
        if (gKbBarOn && gKbTopOn) {
            UIView *P = KbFindTop(dock);
            if (P) {
                UIStackView *old = objc_getAssociatedObject(dock, kKbBarView);
                if (old) { [old removeFromSuperview]; objc_setAssociatedObject(dock, kKbBarView, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
                if (!gTops) gTops = [NSHashTable weakObjectsHashTable];
                [gTops addObject:P];
                if (!gTopHooked && P.class != UIView.class) {
                    gTopHooked = YES;
                    MSHookMessageEx(P.class, @selector(layoutSubviews), (IMP)new_topLayout, (IMP *)&orig_topLayout);
                    MSHookMessageEx(P.class, @selector(hitTest:withEvent:), (IMP)new_topHit, (IMP *)&orig_topHit);
                }
                KbTopPlace(P);
                return;
            }
            // Chua co hang goi y: thu lai vai lan, trong luc do dung dang thuong
            NSNumber *tr = objc_getAssociatedObject(dock, kKbTopTry);
            if (tr.intValue < 4) {
                objc_setAssociatedObject(dock, kKbTopTry, @(tr.intValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak UIView *wd = dock;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [wd setNeedsLayout]; });
            }
        }
        KbBarPlace(dock);
    } @catch (__unused id x) {}
}

// Nhan cham o muc UIWindow cho dang TrollPad: hang goi y co the nuot/huy cham truoc khi toi nut,
// nen tu tim nut duoi ngon tay va chay hanh dong, sau do nuot cham de khong chon nham goi y.
static void (*orig_winSend)(id, SEL, UIEvent *);
static __weak UITouch *gSwallow;

static UIButton *KbTopButtonAt(UITouch *t) {
    if (!(gKbBarOn && gKbTopOn) || !t.window) return nil;
    const void *keys[2] = { kKbTopL, kKbTopR };
    for (UIView *P in [gTops allObjects]) {
        if (P.window != t.window || P.hidden) continue;
        for (int i = 0; i < 2; i++) {
            UIStackView *g = objc_getAssociatedObject(P, keys[i]);
            if (!g || g.hidden || g.superview != P) continue;
            CGPoint pt = [t locationInView:g];
            if (![g pointInside:pt withEvent:nil]) continue;
            for (UIView *b in g.arrangedSubviews)
                if ([b isKindOfClass:UIButton.class] && CGRectContainsPoint(b.frame, pt)) return (UIButton *)b;
        }
    }
    return nil;
}

static void new_winSend(id self, SEL _cmd, UIEvent *event) {
    @try {
        if (event.type == UIEventTypeTouches && gTops.count > 0) {
            NSSet *ts = event.allTouches;
            if (ts.count == 1) {
                UITouch *t = ts.anyObject;
                if (t == gSwallow) {
                    if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) gSwallow = nil;
                    return;
                }
                if (t.phase == UITouchPhaseBegan) {
                    UIButton *b = KbTopButtonAt(t);
                    if (b) { gSwallow = t; [[AACKbActions shared] tap:b]; return; }
                }
            }
        }
    } @catch (__unused id x) {}
    if (orig_winSend) orig_winSend(self, _cmd, event);
}

static void InstallDockBar(void) {
    MSHookMessageEx(UIWindow.class, @selector(sendEvent:), (IMP)new_winSend, (IMP *)&orig_winSend);
    Class c = NSClassFromString(@"UIKeyboardDockView");
    if (!c) {   // du phong: tim lop co ten chua "KeyboardDock" la con cua UIView
        unsigned int n = 0;
        Class *list = objc_copyClassList(&n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = class_getName(list[i]);
            if (nm && strstr(nm, "KeyboardDock") && class_getSuperclass(list[i]) &&
                [list[i] isSubclassOfClass:UIView.class] && (!c || strlen(nm) < strlen(class_getName(c)))) c = list[i];
        }
        free(list);
    }
    if (!c) return;
    MSHookMessageEx(c, @selector(layoutSubviews), (IMP)new_dockLayout, (IMP *)&orig_dockLayout);
}

// ---- Background Keep-Alive: phat am thanh im lang + background task de app khong bi treo khi xuong nen ----
static NSData *KAWav(void) {
    const uint32_t rate = 8000, n = 8000, dataLen = n * 2;
    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataLen];
    uint32_t v32; uint16_t v16;
    #define KA4(x) do { v32 = (uint32_t)(x); [d appendBytes:&v32 length:4]; } while (0)
    #define KA2(x) do { v16 = (uint16_t)(x); [d appendBytes:&v16 length:2]; } while (0)
    [d appendBytes:"RIFF" length:4]; KA4(36 + dataLen);
    [d appendBytes:"WAVE" length:4];
    [d appendBytes:"fmt " length:4]; KA4(16); KA2(1); KA2(1); KA4(rate); KA4(rate * 2); KA2(2); KA2(16);
    [d appendBytes:"data" length:4]; KA4(dataLen);
    #undef KA4
    #undef KA2
    int16_t *smp = calloc(n, sizeof(int16_t));
    if (smp) {
        for (uint32_t i = 0; i < n; i++) smp[i] = (i & 1) ? 1 : -1;   // bien do ~ -90dB, khong nghe thay
        [d appendBytes:smp length:n * sizeof(int16_t)];
        free(smp);
    } else {
        [d increaseLengthBy:dataLen];
    }
    return d;
}

static id KASession(void) {
    Class c = NSClassFromString(@"AVAudioSession");
    if (!c) {
        dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio", RTLD_LAZY);
        c = NSClassFromString(@"AVAudioSession");
    }
    if (!c) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, NSSelectorFromString(@"sharedInstance"));
}

static BOOL gKAInBg;
static BOOL (*orig_ka_setCat3)(id, SEL, NSString *, NSUInteger, NSError **);
static BOOL (*orig_ka_setCat2)(id, SEL, NSString *, NSError **);
static BOOL (*orig_ka_setCat4)(id, SEL, NSString *, NSString *, NSUInteger, NSError **);
static BOOL (*orig_ka_setAct2)(id, SEL, BOOL, NSError **);
static BOOL (*orig_ka_setAct3)(id, SEL, BOOL, NSUInteger, NSError **);

// Khi dang o nen: app (vd. Facebook) hay doi session sang Ambient / tat session -> keep-alive mat tac dung. Giu lai Playback.
static BOOL KANeedFix(NSString *cat) {
    return gKeepAliveOn && gKAInBg && cat &&
           ([cat isEqualToString:@"AVAudioSessionCategoryAmbient"] || [cat isEqualToString:@"AVAudioSessionCategorySoloAmbient"]);
}
static BOOL new_ka_setCat3(id self, SEL _cmd, NSString *cat, NSUInteger opt, NSError **e) {
    if (KANeedFix(cat)) { cat = @"AVAudioSessionCategoryPlayback"; opt |= 1; }
    return orig_ka_setCat3 ? orig_ka_setCat3(self, _cmd, cat, opt, e) : NO;
}
static BOOL new_ka_setCat2(id self, SEL _cmd, NSString *cat, NSError **e) {
    if (KANeedFix(cat) && orig_ka_setCat3)
        return orig_ka_setCat3(self, NSSelectorFromString(@"setCategory:withOptions:error:"), @"AVAudioSessionCategoryPlayback", 1, e);
    return orig_ka_setCat2 ? orig_ka_setCat2(self, _cmd, cat, e) : NO;
}
static BOOL new_ka_setCat4(id self, SEL _cmd, NSString *cat, NSString *mode, NSUInteger opt, NSError **e) {
    if (KANeedFix(cat)) { cat = @"AVAudioSessionCategoryPlayback"; opt |= 1; }
    return orig_ka_setCat4 ? orig_ka_setCat4(self, _cmd, cat, mode, opt, e) : NO;
}
static BOOL new_ka_setAct2(id self, SEL _cmd, BOOL on, NSError **e) {
    if (!on && gKeepAliveOn && gKAInBg) { if (e) *e = nil; return YES; }
    return orig_ka_setAct2 ? orig_ka_setAct2(self, _cmd, on, e) : NO;
}
static BOOL new_ka_setAct3(id self, SEL _cmd, BOOL on, NSUInteger opt, NSError **e) {
    if (!on && gKeepAliveOn && gKAInBg) { if (e) *e = nil; return YES; }
    return orig_ka_setAct3 ? orig_ka_setAct3(self, _cmd, on, opt, e) : NO;
}
static void KAHook(Class c, NSString *sel, IMP n, IMP *o) {
    SEL sl = NSSelectorFromString(sel);
    if (!c || !class_getInstanceMethod(c, sl)) return;
    MSHookMessageEx(c, sl, n, o);
}
static void KAInstallSessionHooks(void) {
    static BOOL done;
    if (done) return;
    Class c = NSClassFromString(@"AVAudioSession");
    if (!c) return;
    done = YES;
    KAHook(c, @"setCategory:withOptions:error:", (IMP)new_ka_setCat3, (IMP *)&orig_ka_setCat3);
    KAHook(c, @"setCategory:error:", (IMP)new_ka_setCat2, (IMP *)&orig_ka_setCat2);
    KAHook(c, @"setCategory:mode:options:error:", (IMP)new_ka_setCat4, (IMP *)&orig_ka_setCat4);
    KAHook(c, @"setActive:error:", (IMP)new_ka_setAct2, (IMP *)&orig_ka_setAct2);
    KAHook(c, @"setActive:withOptions:error:", (IMP)new_ka_setAct3, (IMP *)&orig_ka_setAct3);
}

@interface AACKeepAlive : NSObject
@property (nonatomic, strong) id player;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) BOOL running;
+ (instancetype)shared;
- (void)install;
- (void)refresh;
@end

@implementation AACKeepAlive
+ (instancetype)shared {
    static AACKeepAlive *k; static dispatch_once_t once;
    dispatch_once(&once, ^{ k = [AACKeepAlive new]; k.bgTask = UIBackgroundTaskInvalid; });
    return k;
}

- (void)install {
    static BOOL done;
    if (done) return;
    done = YES;
    Crumb("keepalive:install");
    gKAInBg = (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground);
    KAInstallSessionHooks();
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    NSOperationQueue *mq = NSOperationQueue.mainQueue;
    __weak AACKeepAlive *ws = self;
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:mq usingBlock:^(NSNotification *n) { gKAInBg = YES; @try { [ws start]; } @catch (__unused id x) {} }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:mq usingBlock:^(NSNotification *n) { gKAInBg = NO; @try { [ws stop]; } @catch (__unused id x) {} }];
    NSArray *names = @[ @"AVAudioSessionInterruptionNotification",
                        @"AVAudioSessionMediaServicesWereResetNotification",
                        @"AVAudioSessionRouteChangeNotification" ];
    for (NSString *nm in names) {
        [nc addObserverForName:nm object:nil queue:mq usingBlock:^(NSNotification *n) {
            AACKeepAlive *s = ws;
            if (!s || !s.running || !gKeepAliveOn) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { if (s.running && gKeepAliveOn) [s playSilent]; } @catch (__unused id x) {}
            });
        }];
    }
}

- (BOOL)playing {
    id p = self.player;
    return p && ((BOOL (*)(id, SEL))objc_msgSend)(p, NSSelectorFromString(@"isPlaying"));
}

- (void)beginTask {
    if (self.bgTask != UIBackgroundTaskInvalid) return;
    __weak AACKeepAlive *ws = self;
    self.bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"AACKeepAlive" expirationHandler:^{
        AACKeepAlive *s = ws;
        if (!s) return;
        UIBackgroundTaskIdentifier t = s.bgTask;
        s.bgTask = UIBackgroundTaskInvalid;
        if (t != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:t];
    }];
}

- (void)endTask {
    UIBackgroundTaskIdentifier t = self.bgTask;
    self.bgTask = UIBackgroundTaskInvalid;
    if (t != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:t];
}

- (void)playSilent {
    @try {
        Crumb("keepalive:session");
        id s = KASession();
        if (!s) return;
        NSError *err = nil;
        NSString *cat = ((id (*)(id, SEL))objc_msgSend)(s, NSSelectorFromString(@"category"));
        NSString *pb = @"AVAudioSessionCategoryPlayback";
        // Chi doi category khi app chua dung Playback/PlayAndRecord; MixWithOthers (=1) de khong ngat nhac/video khac
        if (![cat isEqualToString:pb] && ![cat isEqualToString:@"AVAudioSessionCategoryPlayAndRecord"] && ![cat isEqualToString:@"AVAudioSessionCategoryMultiRoute"]) {
            ((BOOL (*)(id, SEL, NSString *, NSUInteger, NSError **))objc_msgSend)(
                s, NSSelectorFromString(@"setCategory:withOptions:error:"), pb, (NSUInteger)1, &err);
        }
        ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(s, NSSelectorFromString(@"setActive:error:"), YES, &err);
        Crumb("keepalive:player");
        if (!self.player) {
            Class pc = NSClassFromString(@"AVAudioPlayer");
            if (!pc) return;
            id p = [pc alloc];
            p = ((id (*)(id, SEL, NSData *, NSError **))objc_msgSend)(p, NSSelectorFromString(@"initWithData:error:"), KAWav(), &err);
            if (!p) return;
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(p, NSSelectorFromString(@"setNumberOfLoops:"), (NSInteger)-1);
            ((void (*)(id, SEL, float))objc_msgSend)(p, NSSelectorFromString(@"setVolume:"), 0.05f);
            ((BOOL (*)(id, SEL))objc_msgSend)(p, NSSelectorFromString(@"prepareToPlay"));
            self.player = p;
        }
        if (![self playing]) ((BOOL (*)(id, SEL))objc_msgSend)(self.player, NSSelectorFromString(@"play"));
    } @catch (__unused id x) {}
}

- (void)armTimer {
    if (self.timer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    __weak AACKeepAlive *ws = self;
    dispatch_source_set_event_handler(t, ^{
        AACKeepAlive *s = ws;
        if (!s) return;
        Crumb("keepalive:timer");
        if (!gKeepAliveOn || !s.running) { [s stop]; return; }
        [s playSilent];
        if (s.bgTask == UIBackgroundTaskInvalid && UIApplication.sharedApplication.applicationState == UIApplicationStateBackground)
            [s beginTask];
    });
    self.timer = t;
    dispatch_resume(t);
}

- (void)start {
    if (!gKeepAliveOn || !OnMain()) return;
    self.running = YES;
    Crumb("keepalive:start");
    [self beginTask];
    [self playSilent];      // chay NGAY trong luc xuong nen, khong tri hoan
    [self armTimer];
    // App co the doi/tat session ngay sau khi xuong nen -> khang dinh lai nhieu lan
    __weak AACKeepAlive *ws = self;
    double ds[3] = { 0.4, 1.5, 4.0 };
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ds[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            AACKeepAlive *s = ws;
            if (!s || !s.running || !gKeepAliveOn) return;
            @try { [s playSilent]; } @catch (__unused id x) {}
        });
    }
}

- (void)stop {
    Crumb("keepalive:stop");
    self.running = NO;
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    if ([self playing]) ((void (*)(id, SEL))objc_msgSend)(self.player, NSSelectorFromString(@"stop"));
    [self endTask];
}

- (void)refresh {
    if (!gKeepAliveOn) { [self stop]; return; }
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) [self start];
}
@end

static void KeepAliveRefresh(void) { [[AACKeepAlive shared] refresh]; }

// ---- Khoi tao ----
static BOOL IsFacebookFamily(void) {
    NSBundle *b = NSBundle.mainBundle;
    NSString *bid = [b.bundleIdentifier lowercaseString] ?: @"";
    NSString *exe = [[b objectForInfoDictionaryKey:@"CFBundleExecutable"] lowercaseString] ?: @"";
    return [bid containsString:@"facebook"] || [bid containsString:@"messenger"] ||
           [exe isEqualToString:@"facebook"] || [exe isEqualToString:@"messenger"];
}

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
    ReinstallSignals();
    NSUncaughtExceptionHandler *cur = NSGetUncaughtExceptionHandler();
    if (cur != AACExceptionHandler) {
        gPrevEH = cur;
        NSSetUncaughtExceptionHandler(AACExceptionHandler);
    }
    if (n < 8) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ InstallEH(n + 1); });
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

// Lan truoc bi crash: tu sao chep log vao clipboard (1 lan cho moi log) va bao cho nguoi dung,
// de gui log ngay ca khi app sap truoc khi kip mo bang cai dat.
static void NotifyPrevCrash(int attempt) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *t = PeekCrash();
    if (!t.length || [[ud stringForKey:@"AccentColorAll_CrashNotified"] isEqualToString:t]) return;
    UIViewController *top = TopVC();
    if (!top || VCBusy(top)) {
        if (attempt < 12) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NotifyPrevCrash(attempt + 1); });
        return;
    }
    [ud setObject:t forKey:@"AccentColorAll_CrashNotified"];
    UIPasteboard.generalPasteboard.string = t;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Lần chạy trước bị crash"
        message:@"Nội dung lỗi đã được sao chép vào clipboard. Hãy dán và gửi để được sửa. (Cũng xem được trong Cài đặt tweak → Lỗi crash lần trước.)"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

%ctor {
    @autoreleasepool {
        NSString *bp = NSBundle.mainBundle.bundlePath;
        if (!bp || [bp.pathExtension isEqualToString:@"appex"]) return;
        [NSUserDefaults.standardUserDefaults registerDefaults:@{ kMasterKey: @YES, kKbBarKey: @YES, kKbTopKey: @NO, kKeepAliveKey: @YES }];
        InstallSignals();
        {   // Khoi phuc Keep-Alive ve BAT (ban truoc co the da tu tat nham sau mot lan crash khong lien quan)
            NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
            if (![ud boolForKey:@"AccentColorAll_KAMigrated2"]) {
                [ud setBool:YES forKey:@"AccentColorAll_KAMigrated2"];
                [ud setBool:YES forKey:kKeepAliveKey];
                [ud removeObjectForKey:@"AccentColorAll_KAHandled"];
            }
        }
        InstallEH(0);
        gSafe = IsFacebookFamily();
        RefreshCache();
        %init;
        %init(AACContents);
        InstallDockBar();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { NotifyPrevCrash(0); } @catch (__unused id x) {}
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { [[AACKeepAlive shared] install]; } @catch (__unused id x) {}
        });
    }
}

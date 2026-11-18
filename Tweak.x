#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#include <execinfo.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>

#define GET(o, k)    objc_getAssociatedObject(o, k)
#define SET(o, k, v) objc_setAssociatedObject(o, k, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC)
#define CLEAR(o, k)  do { if (GET(o, k)) SET(o, k, nil); } while (0)
#define KEY(n)       static const void *n = &n

static NSString *const kMasterKey  = @"AccentColorAll_Enabled";
static NSString *const kHexKey     = @"AccentColorAll_Hex";
static NSString *const kCrashKey   = @"AccentColorAll_LastCrash";
static NSString *const kDefaultHex = @"B8A8FF";

KEY(kFill);        KEY(kGestureFlag); KEY(kTintVer);    KEY(kIconShape);  KEY(kMonoBlack);
KEY(kAccentSrc);   KEY(kAccentStamp); KEY(kContentsSrc); KEY(kCtl);       KEY(kImgView);
KEY(kOwner);       KEY(kKbSrc);       KEY(kNoShadow);   KEY(kKbImg);      KEY(kInkTint);
KEY(kInkImg);      KEY(kWhiteMark);   KEY(kArrowDone);  KEY(kAttempts);   KEY(kPendShape);
KEY(kStripSrc);    KEY(kStripState);  KEY(kStripOut);
KEY(kSweepPtr);    KEY(kSweepImg);
KEY(kRemSrc);      KEY(kRemState);    KEY(kRemOut);     KEY(kRemStamp);   // anh xanh (app thuong) / anh den (Facebook)
KEY(kHidMark);     // layer bi tweak an (glow) -> neu hoa ra nam trong ban phim thi hien lai
KEY(kGlbSrc);      KEY(kGlbPtr);      KEY(kGlbVer);      KEY(kGlbMul);   KEY(kGlbNeg);   // qua dia cau / icon dock

@interface AACWeak : NSObject
@property (nonatomic, weak) id obj;
@end
@implementation AACWeak
@end

static BOOL gMaster = YES, gDark, gInTry, gInTabFix, gInContents, gInKbFix, gSafe, gInAttach, gGlbAll;
static UIColor   *gColor;
static CGColorRef gCGLight, gCGDark, gCGSoftLight, gCGSoftDark, gCGWhite;
static CGFloat    gRGBL[3], gRGBD[3];
static int        gFillCount, gVersion, gLastKbMode;
static NSMutableArray *gKeep;
static __thread BOOL gRaw;
static volatile int32_t gPending, gHasPend;

#define AAC_MAXDEPTH 12
static __thread int gDepth;
static inline int  AACDepthEnter(void)   { gDepth++; return 0; }
static inline void AACDepthLeave(int *p) { gDepth--; }
#define AAC_DEPTH_SCOPE int _aacScope __attribute__((cleanup(AACDepthLeave))) = AACDepthEnter()

@interface CALayer (AACPrivate)
- (void)setContentsMultiplyColor:(CGColorRef)c;
@end

static inline BOOL OnMain(void) { return [NSThread isMainThread]; }

static BOOL RateOK(CFAbsoluteTime *ws, int *wc, int max) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - *ws > 1.0) { *ws = now; *wc = 0; }
    return ++*wc <= max;
}
#define RATE(max) ({ static CFAbsoluteTime _ws; static int _wc; RateOK(&_ws, &_wc, max); })

// ---------------- Crash log ----------------
static char gSigPath[1024];
static char gCrumb[160];
static NSUncaughtExceptionHandler *gPrevEH;
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
    if (ss.ss_sp) sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = AACSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_ONSTACK;
    int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], &sa, NULL);
}

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
    if (cur != AACExceptionHandler) { gPrevEH = cur; NSSetUncaughtExceptionHandler(AACExceptionHandler); }
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

// ---------------- Mau ----------------
static void TabBarFix(UITabBar *bar);

static UIColor *ColorFromHex(NSString *s) {
    s = [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6) return nil;
    unsigned v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if (![sc scanHexInt:&v] || !sc.isAtEnd) return nil;
    gRaw = YES;
    UIColor *c = [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1.0];
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
    if (lum >= 0.6) return c;
    CGFloat f = (0.6 - lum) / (1.0 - lum);
    gRaw = YES;
    UIColor *o = [UIColor colorWithRed:r + (1 - r) * f green:g + (1 - g) * f blue:b + (1 - b) * f alpha:1.0];
    gRaw = NO;
    return o;
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
    gCGLight = CGColorCreateCopy(light.CGColor);
    gCGDark = CGColorCreateCopy(dark.CGColor);
    gCGSoftLight = CGColorCreateCopyWithAlpha(light.CGColor, 0.2);
    gCGSoftDark = CGColorCreateCopyWithAlpha(dark.CGColor, 0.2);
    gColor = dyn;
    gVersion++;
}

static inline const CGFloat *AccRGB(void) { return gDark ? gRGBD : gRGBL; }
static inline CGColorRef CGFor(BOOL soft) {
    if (gDark) return soft ? gCGSoftDark : gCGDark;
    return soft ? gCGSoftLight : gCGLight;
}
static inline BOOL IsOurs(CGColorRef c) {
    return c == gCGLight || c == gCGDark || c == gCGSoftLight || c == gCGSoftDark || c == gCGWhite;
}

// Phan loai xanh: 1 = xanh dam (nut), 2 = xanh nhat (nen mo)
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
    if (m == kCGColorSpaceModelMonochrome && n >= 2) { *r = *g = *b = k[0]; *a = k[1]; return YES; }
    if (m == kCGColorSpaceModelRGB && n >= 4) { *r = k[0]; *g = k[1]; *b = k[2]; *a = k[3]; return YES; }
    return NO;
}

static inline BOOL DarkRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a, CGFloat thr) { return a >= 0.99 && r < thr && g < thr && b < thr; }
static inline BOOL WhiteRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) { return a >= 0.99 && r > 0.97 && g > 0.97 && b > 0.97; }

static BOOL DarkUI(UIColor *c, CGFloat thr) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    return [c getRed:&r green:&g blue:&b alpha:&a] && DarkRGBA(r, g, b, a, thr);
}
static BOOL DarkCG(CGColorRef c, CGFloat thr) {
    CGFloat r, g, b, a;
    return CGRGBA(c, &r, &g, &b, &a) && DarkRGBA(r, g, b, a, thr);
}
static BOOL IsWhiteColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    return [c getRed:&r green:&g blue:&b alpha:&a] && WhiteRGBA(r, g, b, a);
}
static BOOL IsWhiteCG(CGColorRef c) {
    CGFloat r, g, b, a;
    return CGRGBA(c, &r, &g, &b, &a) && WhiteRGBA(r, g, b, a);
}
#define IsBlackColor(c) DarkUI(c, 0.03)
#define IsInkColor(c)   DarkUI(c, 0.16)
#define IsBlackCG(c)    DarkCG(c, 0.03)
#define IsInkCG(c)      DarkCG(c, 0.16)

static BOOL IsFillCandidateCG(CGColorRef c)  { return IsBlackCG(c) || (gDark && IsWhiteCG(c)); }
static BOOL IsFillCandidateColor(UIColor *c) { return IsBlackColor(c) || (gDark && IsWhiteColor(c)); }

static BOOL NearAccentRGB(CGFloat r, CGFloat g, CGFloat b, CGFloat tol) {
    for (int d = 0; d < 2; d++) {
        const CGFloat *q = d ? gRGBD : gRGBL;
        if (fabs(r - q[0]) < tol && fabs(g - q[1]) < tol && fabs(b - q[2]) < tol) return YES;
    }
    return NO;
}
static BOOL NearAccentCG(CGColorRef c, CGFloat tol, CGFloat amin) {
    CGFloat r, g, b, a;
    return c && gColor && CGRGBA(c, &r, &g, &b, &a) && a >= amin && NearAccentRGB(r, g, b, tol);
}
#define IsAccentCG(c) NearAccentCG(c, 0.02, 0.99)

static BOOL LayerUnderFill(CALayer *l) {
    for (int i = 0; i < 4 && l; i++, l = l.superlayer)
        if (GET(l, kFill) || IsAccentCG(l.backgroundColor)) return YES;
    return NO;
}

static int KbTreeState(CALayer *l);
static BOOL IsKeyboardLayer(CALayer *l);
static BOOL UnderAccentKey(CALayer *l);

static CGColorRef IconShapeColor(CALayer *l) {
    // FIX: chu/so tren phim trang bi to TRANG (trung mau phim) -> mat chu.
    // Trong ban phim chi dung trang khi that su nam duoi nut accent, con lai luon la accent.
    if (OnMain() && (KbTreeState(l) == 1 || IsKeyboardLayer(l))) {
        if (gCGWhite && UnderAccentKey(l)) return gCGWhite;
        return CGFor(NO);
    }
    if (gCGWhite && LayerUnderFill(l.superlayer)) return gCGWhite;
    return CGFor(NO);
}

static CGColorRef LayerRemap(CGColorRef c, int *clsOut) {
    if (!c || !gMaster || IsOurs(c)) return NULL;
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (!cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) return NULL;
    CGFloat r, g, b, a;
    if (!CGRGBA(c, &r, &g, &b, &a)) return NULL;
    int cls = BlueClass(r, g, b);
    if (!cls) return NULL;
    if (clsOut) *clsOut = cls;
    return CGFor(cls == 2);
}

static UIColor *ColorRemap(UIColor *c, int *clsOut) {
    if (!c || !gMaster || gRaw) return nil;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return nil;
    int cls = BlueClass(r, g, b);
    if (!cls) return nil;
    if (clsOut) *clsOut = cls;
    return cls == 2 ? [gColor colorWithAlphaComponent:0.2] : gColor;
}

static UIColor *RemapRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    if (gRaw || !gMaster || !gColor) return nil;
    int cls = BlueClass(r, g, b);
    if (!cls) return nil;
    CGFloat al = (cls == 2 ? 0.2 : 1.0) * a;
    if (al >= 0.99) return gColor;
    gRaw = YES;
    UIColor *res = [gColor colorWithAlphaComponent:al];
    gRaw = NO;
    return res;
}

static BOOL RemapComps(CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (gRaw || !gMaster) return NO;
    int cls = BlueClass(*r, *g, *b);
    if (!cls) return NO;
    const CGFloat *q = AccRGB();
    *a = *a * (cls == 2 ? 0.2 : 1.0);
    *r = q[0]; *g = q[1]; *b = q[2];
    return YES;
}

// ---------------- Xu ly anh ----------------
enum { SN = 24 };

static CGContextRef NewCtx(void *buf, size_t w, size_t h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, buf ? w * 4 : 0, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    return ctx;
}

static BOOL SampleCG(CGImageRef cg, uint8_t *buf) {   // thu nho ve SN x SN
    memset(buf, 0, SN * SN * 4);
    CGContextRef ctx = NewCtx(buf, SN, SN);
    if (!ctx) return NO;
    CGContextDrawImage(ctx, CGRectMake(0, 0, SN, SN), cg);
    CGContextRelease(ctx);
    return YES;
}

static uint8_t *LoadBuf(CGImageRef cg, size_t w, size_t h, CGContextRef *pctx) {
    uint8_t *buf = calloc(w * h, 4);
    if (!buf) return NULL;
    CGContextRef ctx = NewCtx(buf, w, h);
    if (!ctx) { free(buf); return NULL; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    *pctx = ctx;
    return buf;
}

static void FreeBuf(uint8_t *buf, CGContextRef ctx) { CGContextRelease(ctx); free(buf); }

// UIImage -> buffer RGBA (anh da lam phang, toi da 256px). NO neu khong dung duoc.
static BOOL LoadImg(UIImage *img, uint8_t **pbuf, CGContextRef *pctx, size_t *pw, size_t *ph) {
    CGFloat scale = img.scale > 0 ? img.scale : 1;
    CGSize sz = img.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIImage *flat = [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt]
        imageWithActions:^(UIGraphicsImageRendererContext *rc) { [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)]; }];
    CGImageRef cg = flat.CGImage;
    size_t w = cg ? CGImageGetWidth(cg) : 0, h = cg ? CGImageGetHeight(cg) : 0;
    if (!cg || !w || !h || w > 256 || h > 256) return NO;
    uint8_t *buf = LoadBuf(cg, w, h, pctx);
    if (!buf) return NO;
    *pbuf = buf; *pw = w; *ph = h;
    return YES;
}

static UIImage *FinishImage(uint8_t *buf, CGContextRef ctx, CGFloat scale) {
    CGImageRef o = CGBitmapContextCreateImage(ctx);
    FreeBuf(buf, ctx);
    if (!o) return nil;
    UIImage *out = [UIImage imageWithCGImage:o scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(o);
    return out;
}

static inline void Unpm(const uint8_t *px, CGFloat *r, CGFloat *g, CGFloat *b) {
    CGFloat a = px[3];
    *r = fmin(1, px[0] / a); *g = fmin(1, px[1] / a); *b = fmin(1, px[2] / a);
}
static inline void SetAcc(uint8_t *px, const CGFloat *q, CGFloat al) {   // rgb = accent * alpha (premultiplied)
    for (int i = 0; i < 3; i++) px[i] = (uint8_t)lround(fmax(0, fmin(1, q[i])) * al * 255);
}
static inline void SetMix(uint8_t *px, const CGFloat *q, CGFloat t) {    // den -> accent, trang giu nguyen
    for (int i = 0; i < 3; i++) px[i] = (uint8_t)lround((q[i] * (1 - t) + t) * px[3]);
}

static CGImageRef CopyTintedCG(CGImageRef src, CGColorRef color) {
    if (!src || !color) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (!w || !h || w > 512 || h > 512) return NULL;
    CGContextRef ctx = NewCtx(NULL, w, h);
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

static int CGImageIsBlackMono(CGImageRef cg) {
    if (!cg) return 0;
    if (!RATE(120)) return -1;
    uint8_t buf[SN * SN * 4];
    if (!SampleCG(cg, buf)) return 0;
    int solid = 0, clear = 0;
    for (int i = 0; i < SN * SN; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 40) { clear++; continue; }
        solid++;
        if (MAX(px[0], MAX(px[1], px[2])) * 100 > 30 * px[3]) return 0;
    }
    return (solid >= 6 && clear >= 1 && solid * 100 <= SN * SN * 62) ? 1 : 0;
}

static BOOL ImageIsBlackMono(UIImage *img) {
    NSNumber *cached = GET(img, kMonoBlack);
    if (cached) return cached.boolValue;
    if (!img.CGImage || img.images.count > 1) return NO;
    int r = CGImageIsBlackMono(img.CGImage);
    if (r < 0) return NO;
    SET(img, kMonoBlack, @(r == 1));
    return r == 1;
}

// ---------------- Ban phim ----------------
static BOOL KbName(NSString *cn) {
    return [cn hasPrefix:@"UIKB"] || [cn containsString:@"Keyboard"] || [cn containsString:@"UIInputWindow"] ||
           [cn containsString:@"InputSwitcher"] || [cn containsString:@"InputMode"];
}

static BOOL ViewInKeyboard(UIView *v) {
    if (!v) return NO;
    UIWindow *w = v.window;
    if (w && KbName(NSStringFromClass(w.class))) return YES;
    for (int i = 0; i < 10 && v; i++, v = v.superview)
        if (KbName(NSStringFromClass(v.class))) return YES;
    return NO;
}

// Danh sach layer goc cua cac cua so ban phim (chi so sanh con tro, khong bao gio gui message toi chung)
static uintptr_t gKbRootPtr[8];
static int gKbRootN;
static CFAbsoluteTime gKbRootT;

static void RefreshKbRoots(void) {
    gKbRootN = 0;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [((UIWindowScene *)sc).windows copy]) {
            NSString *cn = NSStringFromClass(w.class);
            if ((KbName(cn) || [cn containsString:@"TextEffects"]) && gKbRootN < 8)
                gKbRootPtr[gKbRootN++] = (uintptr_t)(__bridge void *)w.layer;
        }
    }
}

static BOOL KbRootKnown(uintptr_t rp) {
    for (int i = 0; i < gKbRootN; i++) if (gKbRootPtr[i] == rp) return YES;
    return NO;
}

// [FIX] kiem tra nhanh (chi so sanh con tro): layer co nam trong cay cua cua so ban phim khong
static BOOL KbRootLayer(CALayer *l) {
    if (!l) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gKbRootT > 0.3) { RefreshKbRoots(); gKbRootT = CFAbsoluteTimeGetCurrent(); }
    CALayer *r = l;
    for (int i = 0; i < 120 && r.superlayer; i++) r = r.superlayer;
    return KbRootKnown((uintptr_t)(__bridge void *)r);
}

static BOOL IsKeyboardLayer(CALayer *l) {
    if (!l) return NO;
    // 1) theo ten class + layer cua cua so ban phim (chi so sanh con tro, an toan)
    if (OnMain()) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - gKbRootT > 0.3) { RefreshKbRoots(); gKbRootT = CFAbsoluteTimeGetCurrent(); }
        CALayer *c = l;
        for (int i = 0; i < 60 && c; i++, c = c.superlayer) {
            if (KbName(NSStringFromClass(c.class))) return YES;
            if (KbRootKnown((uintptr_t)(__bridge void *)c)) return YES;
        }
    }
    if (gSafe) return NO;   // Facebook: khong gui message toi delegate (co the la con tro treo)
    // 2) theo delegate (cach goc)
    BOOL checked = NO;
    for (int i = 0; i < 10 && l; i++, l = l.superlayer) {
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

// Kiem tra chat che: layer co nam trong cay layer cua mot cua so ban phim khong.
// Tra ve 1 = trong ban phim, 0 = trong cua so thuong, -1 = chua gan vao cua so nao (khong ket luan duoc)
static BOOL InputWindow(UIWindow *w);
static int KbTreeState(CALayer *l) {
    if (!l || !OnMain()) return -1;
    CALayer *root = l;
    for (int i = 0; i < 120 && root.superlayer; i++) root = root.superlayer;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [((UIWindowScene *)sc).windows copy]) {
            if (w.layer == root) return InputWindow(w) ? 1 : 0;
        }
    }
    return -1;
}

// mode 1: nut xanh -> accent | mode 2: icon den (Enter/back) -> accent, giu chi tiet trang
// mode 3: icon trang (qua dia cau, icon menu chon ban phim) -> accent (chi khi allowWhite)
static CGImageRef KbRecolor(CGImageRef src, BOOL allowWhite) {
    gLastKbMode = 0;
    if (!src || !gMaster) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w < 8 || h < 8 || w > 400 || h > 400 || !RATE(900)) return NULL;
    CGContextRef ctx;
    uint8_t *buf = LoadBuf(src, w, h, &ctx);
    if (!buf) return NULL;

    size_t total = w * h;
    int solid = 0, blue = 0, gray = 0, blk = 0, lt = 0, wt = 0, clear = 0;
    for (size_t i = 0; i < total; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) { clear++; continue; }
        solid++;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (BlueClass(r, g, b) == 1) { blue++; continue; }
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.12) continue;
        gray++;
        CGFloat lum = (r + g + b) / 3.0;
        if (lum < 0.3) blk++; else if (lum > 0.75) lt++;
        if (lum > 0.93) wt++;
    }
    BOOL mostlyClear40 = (size_t)clear * 100 >= 40 * total, mostlyClear35 = (size_t)clear * 100 >= 35 * total;
    int mode = 0;
    if (solid >= 30 && blue * 100 >= 35 * solid) mode = 1;
    else if (solid >= 20 && gray * 100 >= 85 * solid && blk >= 6 &&
             (blk * 100 <= 45 * solid || mostlyClear40) &&
             (lt * 100 >= 20 * solid || (size_t)clear * 100 >= 30 * total)) mode = 2;
    else if (allowWhite && !gDark && solid >= 20 && gray * 100 >= 92 * solid &&
             wt * 100 >= 70 * solid && blk * 100 <= 8 * solid && mostlyClear35) mode = 3;
    if (!mode) { FreeBuf(buf, ctx); return NULL; }

    const CGFloat *q = AccRGB();
    for (size_t i = 0; i < total; i++) {
        uint8_t *px = buf + i * 4;
        if (!px[3]) continue;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (mode == 1) {
            if (BlueClass(r, g, b) == 1) SetAcc(px, q, px[3] / 255.0);
            continue;
        }
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.12) continue;
        if (mode == 2) SetMix(px, q, fmax(0, fmin(1, (r + g + b) / 3.0)));
        else SetAcc(px, q, px[3] / 255.0);
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    FreeBuf(buf, ctx);
    if (out) gLastKbMode = mode;
    return out;
}

// ---------------- Bong do ----------------
static BOOL NearControl(CALayer *l) {
    for (int i = 0; i < 4 && l; i++, l = l.superlayer) {
        NSString *cn = NSStringFromClass(l.class);
        if ([cn containsString:@"UISwitch"] || [cn containsString:@"Slider"]) return YES;
    }
    return NO;
}

static BOOL HasAccentMark(CALayer *l) {
    return GET(l, kFill) || GET(l, kIconShape) || GET(l, kContentsSrc) || GET(l, kKbSrc) || IsAccentCG(l.backgroundColor);
}

// Icon trang nam tren nut accent (vd kinh lup tren nut Search) -> phai giu trang
static BOOL UnderAccentKey(CALayer *l) {
    if (!l) return NO;
    CALayer *c = l;
    for (int i = 0; i < 4 && c; i++, c = c.superlayer) {
        if (c != l && HasAccentMark(c) && !GET(c, kWhiteMark)) return YES;
        CALayer *p = c.superlayer;
        if (!p) break;
        CGRect cf = c.frame;
        CGPoint ctr = CGPointMake(CGRectGetMidX(cf), CGRectGetMidY(cf));
        int n = 0;
        for (CALayer *o in p.sublayers) {
            if (++n > 20) break;
            if (o == c || o.hidden || GET(o, kWhiteMark) || !HasAccentMark(o)) continue;
            CGRect of = o.frame;
            if (CGRectContainsPoint(of, ctr) && of.size.width >= cf.size.width) return YES;
        }
    }
    return NO;
}

static BOOL WhiteOK(CALayer *l) { return !gDark && !UnderAccentKey(l); }

static void KillShadowDown(CALayer *l, int depth) {
    if (!l || depth > 4 || !OnMain() || IsKeyboardLayer(l)) return;
    for (CALayer *s in [l.sublayers copy]) {
        CGSize z = s.bounds.size;
        if (z.height > 120 || z.width > 200 || NearControl(s)) continue;
        SET(s, kNoShadow, @YES);
        if (s.shadowOpacity > 0) s.shadowOpacity = 0;
        KillShadowDown(s, depth + 1);
    }
}

static void KillShadowUp(CALayer *l, int levels) {
    if (!l || !OnMain()) return;
    for (int i = 0; i < levels && l; i++, l = l.superlayer) {
        if (IsKeyboardLayer(l)) break;
        CGSize s = l.bounds.size;
        if (s.height > 120 || (i > 0 && s.width > 120) || NearControl(l)) break;
        SET(l, kNoShadow, @YES);
        if (l.shadowOpacity > 0) l.shadowOpacity = 0;
    }
}

static BOOL SubtreeAccent(CALayer *l, int depth, int *budget) {
    if (!l || depth > 5 || *budget <= 0) return NO;
    for (CALayer *sub in l.sublayers) {
        if ((*budget)-- <= 0) break;
        if (HasAccentMark(sub) || SubtreeAccent(sub, depth + 1, budget)) return YES;
    }
    return NO;
}

static BOOL ShadowNamed(CALayer *l) {
    return [NSStringFromClass(l.class) containsString:@"Shadow"];
}

static BOOL ShadowEligible(CALayer *l) {
    if (!gMaster || !OnMain() || IsKeyboardLayer(l)) return NO;
    if (GET(l, kNoShadow)) return YES;
    CGSize s = l.bounds.size;
    if (ShadowNamed(l) && s.height <= 160 && s.width <= 800) return YES;
    if (s.height > 120 || s.width > 200 || NearControl(l)) return NO;
    if (HasAccentMark(l)) return YES;
    CGColorRef sc = l.shadowColor;
    if (sc && (IsAccentCG(sc) || IsOurs(sc))) return YES;
    CALayer *p = l.superlayer;   // bong nam o layer cha/con cua nut accent
    for (int i = 0; i < 6 && p; i++, p = p.superlayer) {
        CGSize ps = p.bounds.size;
        if (ps.height > 120 || ps.width > 200) break;
        if (HasAccentMark(p)) return YES;
    }
    int budget = 60;
    return SubtreeAccent(l, 0, &budget);
}

static void KillShadowIfEligible(CALayer *l) {
    if (l.shadowOpacity > 0 && ShadowEligible(l)) l.shadowOpacity = 0;
}

// ---------------- Chu / icon ban phim ----------------
// Chu den -> accent. Giao dien toi: chu trang -> accent (tru chu nam tren nut accent, vd nhan nut Search/Go)
static BOOL KbTextInk(UIColor *c, UILabel *lb) {
    if (IsInkColor(c)) return YES;
    return lb.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark && IsWhiteColor(c) && !UnderAccentKey(lb.layer);
}

static void KbLabelFix(UILabel *lb) {
    if (!gMaster || !gColor || !OnMain()) return;
    NSString *t = lb.text ?: lb.attributedText.string;
    if (t.length > 3 || !ViewInKeyboard(lb)) return;
    if (KbTextInk(lb.textColor, lb)) lb.textColor = gColor;
    NSAttributedString *as = lb.attributedText;
    if (as.length) {
        UIColor *c = [as attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        if (c && KbTextInk(c, lb)) {
            NSMutableAttributedString *m = [as mutableCopy];
            [m addAttribute:NSForegroundColorAttributeName value:gColor range:NSMakeRange(0, m.length)];
            lb.attributedText = m;
        }
    }
}

static void KbImageFix(UIImageView *iv) {
    if (gInKbFix || !gMaster || !OnMain()) return;
    UIImage *im = iv.image;
    if (!im || !im.CGImage || GET(im, kKbImg)) return;
    if (im.isSymbolImage || im.renderingMode == UIImageRenderingModeAlwaysTemplate || im.images.count > 1) return;
    if (im.size.width > 96 || im.size.height > 96 || !ViewInKeyboard(iv)) return;
    CGImageRef k = KbRecolor(im.CGImage, WhiteOK(iv.layer));
    if (!k) return;
    UIImage *out = [UIImage imageWithCGImage:k scale:im.scale orientation:im.imageOrientation];
    CGImageRelease(k);
    if (!out) return;
    SET(out, kKbImg, @YES);
    gInKbFix = YES;
    iv.image = out;
    gInKbFix = NO;
}

// Anh da duoc to accent ma contentsMultiplyColor cung la accent / den -> accent x accent (bi dam) hoac bi den. Dua multiply ve trang.
// FIX: phat hien theo trung binh co trong so alpha (net mong nhu . , ? #+= truoc day bi bo sot vi alpha sau khi thu nho qua thap)
static BOOL ContentsLooksAccent(CALayer *l) {
    id c = l.contents;
    if (!c || CFGetTypeID((__bridge CFTypeRef)c) != CGImageGetTypeID()) return NO;
    uint8_t buf[SN * SN * 4];
    if (!SampleCG((__bridge CGImageRef)c, buf)) return NO;
    CGFloat sr = 0, sg = 0, sb = 0, sw = 0;
    int n = 0;
    for (int i = 0; i < SN * SN; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        CGFloat wt = px[3] / 255.0;
        sr += r * wt; sg += g * wt; sb += b * wt; sw += wt;
        n++;
    }
    return n >= 1 && sw > 0 && NearAccentRGB(sr / sw, sg / sw, sb / sw, 0.18);
}

// Layer nay da duoc tweak to accent (anh) -> multiply KHONG duoc phep la accent nua
static BOOL TintedByUs(CALayer *l) { return GET(l, kKbSrc) || GET(l, kContentsSrc); }

static void KbEnsureNotBlack(CALayer *l);

static void FixDoubleTint(CALayer *l) {
    if (!l || !gCGWhite) return;
    @try {
        id m = [l valueForKey:@"contentsMultiplyColor"];
        if (!m) return;
        CGColorRef mc = (__bridge CGColorRef)m;
        if (!IsWhiteCG(mc) && NearAccentCG(mc, 0.1, 0.9) && (TintedByUs(l) || ContentsLooksAccent(l))) { [l setContentsMultiplyColor:gCGWhite]; return; }
        // [FIX] chop nhay den/accent (nut space khi doi ngon ngu): layer trong ban phim co multiply DEN
        // (nhan "Tieng Viet (Telex)" / "English (US)" rong hon 64pt nen truoc day khong duoc doi) -> doi ngay
        if (gMaster && OnMain() && IsInkCG(mc)) {
            CGSize z = l.bounds.size;
            if (z.width > 0 && z.height > 0 && z.width <= 220 && z.height <= 160 && IsKeyboardLayer(l)) {
                BOOL ours = TintedByUs(l);
                [l setContentsMultiplyColor:(ours ? gCGWhite : IconShapeColor(l))];
                if (!ours) KbEnsureNotBlack(l);
            }
        }
    } @catch (NSException *e) {}
}

// Dat contents da doi mau len layer (khong de hook xu ly lai)
static void PutContents(CALayer *l, CGImageRef img) {
    gInContents = YES;
    l.contents = (__bridge id)img;
    gInContents = NO;
    FixDoubleTint(l);
}

// FIX chop nhay den/accent: contents la anh TOI (den) ma multiply lai la accent -> den x accent = DEN.
// Phat hien ngay luc set contents / set multiply -> to contents = accent, multiply = trang (giong cac phim khac).
static BOOL ContentsLooksBlack(CALayer *l) {
    id c = l.contents;
    if (!c || CFGetTypeID((__bridge CFTypeRef)c) != CGImageGetTypeID()) return NO;
    uint8_t buf[SN * SN * 4];
    if (!SampleCG((__bridge CGImageRef)c, buf)) return NO;
    CGFloat sl = 0, sw = 0;
    int n = 0;
    for (int i = 0; i < SN * SN; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.15) return NO;
        CGFloat wt = px[3] / 255.0;
        sl += ((r + g + b) / 3.0) * wt;
        sw += wt;
        n++;
    }
    return n >= 2 && sw > 0 && (sl / sw) < 0.25;
}

static void KbEnsureNotBlack(CALayer *l) {
    if (!l || !gMaster || !gCGWhite || gInContents || !OnMain()) return;
    CGSize z = l.bounds.size;
    if (z.width <= 0 || z.height <= 0 || z.width > 220 || z.height > 160) return;
    id c = l.contents;
    if (!c || CFGetTypeID((__bridge CFTypeRef)c) != CGImageGetTypeID()) return;
    id m = nil;
    @try { m = [l valueForKey:@"contentsMultiplyColor"]; } @catch (NSException *e) { return; }
    if (!m) return;
    CGColorRef mc = (__bridge CGColorRef)m;
    if (IsWhiteCG(mc) || !NearAccentCG(mc, 0.1, 0.9)) return;
    if (!ContentsLooksBlack(l) || !IsKeyboardLayer(l)) return;
    CGImageRef k = CopyTintedCG((__bridge CGImageRef)c, IconShapeColor(l));
    if (!k) return;
    SET(l, kContentsSrc, c);
    PutContents(l, k);
    CGImageRelease(k);
    @try { [l setContentsMultiplyColor:gCGWhite]; } @catch (NSException *e) {}
}

// Icon trang da doi accent nhung hoa ra nam duoi nut accent -> tra ve anh goc
static void KbWhiteVerify(CALayer *l) {
    if (!l || !GET(l, kWhiteMark) || !UnderAccentKey(l)) return;
    id src = GET(l, kKbSrc);
    SET(l, kWhiteMark, nil);
    SET(l, kKbSrc, nil);
    if (src) { gInContents = YES; l.contents = src; gInContents = NO; }
}

static void KbLate(CALayer *l) {
    Crumb("KbLate");
    if (!l || !gMaster || !OnMain()) return;
    KbWhiteVerify(l);
    id c = l.contents;
    if (!c || CFGetTypeID((__bridge CFTypeRef)c) != CGImageGetTypeID() || !IsKeyboardLayer(l)) return;
    if (GET(l, kKbSrc) || GET(l, kContentsSrc)) { FixDoubleTint(l); return; }
    CGImageRef k = KbRecolor((__bridge CGImageRef)c, WhiteOK(l));
    if (!k) { FixDoubleTint(l); return; }
    SET(l, kKbSrc, c);
    if (gLastKbMode == 3) SET(l, kWhiteMark, @YES);
    PutContents(l, k);
    CGImageRelease(k);
}

// [FIX] Layer vua duoc gan vao cay ban phim (vd nhan ngon ngu tren nut space khi doi ban phim):
// xu ly DONG BO ngay luc attach, truoc khi CA ve frame dau tien -> khong con khung hinh den.
static void KbAttachTree(CALayer *l, int depth, int *budget) {
    if (!l || depth > 6 || *budget <= 0) return;
    (*budget)--;
    CGSize z = l.bounds.size;
    if (z.width <= 220 && z.height <= 160) {
        if ([l isKindOfClass:CATextLayer.class]) {
            CATextLayer *t = (CATextLayer *)l;
            CGColorRef fc = t.foregroundColor;
            if (fc && IsInkCG(fc)) t.foregroundColor = CGFor(NO);
        }
        if (l.contents) {
            KbLate(l);
            FixDoubleTint(l);
            KbEnsureNotBlack(l);
        }
    }
    for (CALayer *s in [l.sublayers copy]) KbAttachTree(s, depth + 1, budget);
}

static void KbAttachCheck(CALayer *parent, CALayer *child) {
    if (gInAttach || !gMaster || gSafe || !child || !parent || !OnMain() || gDepth > AAC_MAXDEPTH) return;
    if (!KbRootLayer(parent)) return;
    gInAttach = YES;
    @try {
        int budget = 80;
        KbAttachTree(child, 0, &budget);
    } @catch (NSException *e) {}
    gInAttach = NO;
}

// Lop "den" (glow/vien) nam canh lop icon trang cung kich thuoc -> an di
static BOOL HasTwinSibling(CALayer *l) {
    CALayer *p = l.superlayer;
    CGSize s = l.bounds.size;
    if (!p || s.width < 6 || s.height < 6 || s.width > 64 || s.height > 64) return NO;
    int n = 0;
    for (CALayer *o in p.sublayers) {
        if (++n > 12) break;
        if (o == l || o.hidden || GET(o, kInkTint)) continue;
        CGSize t = o.bounds.size;
        if (fabs(t.width - s.width) > 10 || fabs(t.height - s.height) > 10) continue;
        if (o.contents || [o isKindOfClass:CAShapeLayer.class] || o.sublayers.count > 0) return YES;
    }
    return NO;
}

static void GlowCheck(CALayer *l) {
    Crumb("GlowCheck");
    if (!l || !gMaster || !OnMain() || !GET(l, kInkTint)) return;
    // FIX: chu/so tren ban phim bi an nham. Kiem tra chat che theo cay cua so ban phim.
    int ks = KbTreeState(l);
    if (ks == 1 || IsKeyboardLayer(l)) {
        if (GET(l, kHidMark)) { SET(l, kHidMark, nil); l.hidden = NO; }   // da lo an nham -> hien lai
        return;
    }
    if (ks < 0) return;   // chua gan vao cua so nao -> khong ket luan, khong an
    if (l.hidden) return;
    if (HasTwinSibling(l)) { SET(l, kHidMark, @YES); l.hidden = YES; }
}

static void MarkInk(CALayer *l) {
    if (!l || !OnMain()) return;
    SET(l, kInkTint, @YES);
    __weak CALayer *wl = l;
    double delays[3] = { 0.0, 0.3, 1.0 };
    for (int i = 0; i < 3; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GlowCheck(wl); });
}

// ---------------- Refresh ----------------
static void ReapplyContents(CALayer *l) {
    Crumb("ReapplyContents");
    if (!OnMain()) return;
    id src = GET(l, kContentsSrc);
    if (src) {
        CGImageRef t = CopyTintedCG((__bridge CGImageRef)src, IconShapeColor(l));
        if (t) { PutContents(l, t); CGImageRelease(t); }
        return;
    }
    id ks = GET(l, kKbSrc);
    if (ks) {
        CGImageRef t = KbRecolor((__bridge CGImageRef)ks, WhiteOK(l));
        if (t) { PutContents(l, t); CGImageRelease(t); }
    }
}

static void ReapplyShape(CALayer *l) {
    Crumb("ReapplyShape");
    if (![l isKindOfClass:CAShapeLayer.class]) return;
    NSNumber *m = GET(l, kIconShape);
    if (!m) return;
    CAShapeLayer *sh = (CAShapeLayer *)l;
    CGColorRef c = IconShapeColor(l);
    gInTry = YES;
    if (m.intValue & 1) sh.fillColor   = c;
    if (m.intValue & 2) sh.strokeColor = c;
    gInTry = NO;
}

static void RefreshLayerTree(CALayer *l, int depth) {
    if (depth > 40) return;
    ReapplyShape(l);
    ReapplyContents(l);
    for (CALayer *sub in [l.sublayers copy]) RefreshLayerTree(sub, depth + 1);
}

static void RefreshViewTree(UIView *v, int depth) {
    if (depth > 40) return;
    if (gMaster) {
        if ([v isKindOfClass:UISwitch.class]) ((UISwitch *)v).onTintColor = gColor;
        else if ([v isKindOfClass:UISlider.class]) ((UISlider *)v).minimumTrackTintColor = gColor;
    }
    if ([v isKindOfClass:UITabBar.class]) TabBarFix((UITabBar *)v);
    [v tintColorDidChange];
    [v setNeedsDisplay];
    for (UIView *s in [v.subviews copy]) RefreshViewTree(s, depth + 1);
}

static void ApplyAll(void) {
    RefreshCache();
    if (gMaster) {
        [UISwitch appearance].onTintColor = gColor;
        [UISlider appearance].minimumTrackTintColor = gColor;
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [((UIWindowScene *)s).windows copy]) {
            gDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
            w.tintColor = gMaster ? gColor : nil;
            SET(w, kTintVer, @(gVersion));
            RefreshViewTree(w, 0);
            RefreshLayerTree(w.layer, 0);
        }
    }
}

static void FixUnderFill(CALayer *l, int depth) {
    Crumb("FixUnderFill");
    if (!l || depth > 6) return;
    for (CALayer *s in [l.sublayers copy]) {
        ReapplyShape(s);
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
    Crumb("MarkFill");
    if (!OnMain() || l.bounds.size.height > 120 || GET(l, kFill)) return;
    SET(l, kFill, @YES);
    gFillCount++;
    KillShadowUp(l, 5);
    KillShadowDown(l, 0);
    if (gSafe) {
        dispatch_async(dispatch_get_main_queue(), ^{ FixUnderFill(l, 0); });
        return;
    }
    if (!v) v = ((AACWeak *)GET(l, kOwner)).obj;
    __weak UIView *wv = v;
    dispatch_async(dispatch_get_main_queue(), ^{
        FixUnderFill(l, 0);
        UIView *sv = wv;
        if (sv) FixUnderFillView(sv, 0);
    });
}

static BOOL UnderFill(UIView *v) {
    for (int i = 0; i < 4 && v; i++, v = v.superview)
        if (GET(v.layer, kFill)) return YES;
    return NO;
}

static BOOL InControlKnob(CALayer *l) {
    for (int i = 0; i < 8 && l; i++, l = l.superlayer)
        if (GET(l, kCtl)) return YES;
    return NO;
}

static BOOL GlassName(NSString *cn) {
    return [cn containsString:@"Glass"] || [cn containsString:@"Backdrop"] || [cn containsString:@"Material"] ||
           [cn containsString:@"VisualEffect"] || [cn containsString:@"UISwitch"];
}

static BOOL InGlassLayer(CALayer *l) {
    for (int i = 0; i < 8 && l; i++, l = l.superlayer)
        if (GET(l, kCtl) || GlassName(NSStringFromClass(l.class))) return YES;
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
        if ([v isKindOfClass:UISwitch.class] || [v isKindOfClass:UISlider.class] || [v isKindOfClass:UIVisualEffectView.class]) return YES;
        if (GlassName(NSStringFromClass(v.class))) return YES;
    }
    return NO;
}

static void TagControl(UIView *v) {
    if (v && !GET(v.layer, kCtl)) SET(v.layer, kCtl, @YES);
}

static void SetOwner(UIView *v) {
    if (gSafe || GET(v.layer, kOwner)) return;
    AACWeak *w = [AACWeak new];
    w.obj = v;
    SET(v.layer, kOwner, w);
}

static BOOL LooksLikeAvatarView(UIView *v) {
    if (!v) return NO;
    CALayer *l = v.layer;
    if (!l.masksToBounds || l.cornerRadius <= 0) return NO;
    CGSize s = v.bounds.size;
    if (s.width <= 0 || s.height <= 0) return YES;
    return l.cornerRadius >= fmin(s.width, s.height) * 0.25;
}

// ---------------- Nut tron den co mui ten (nut gui, "Hien thi cau tra loi") ----------------
static void ArrowFixView(UIView *v, int depth) {
    Crumb("ArrowFixView");
    if (!v || depth > 3) return;
    for (UIView *sv in [v.subviews copy]) {
        if ([sv isKindOfClass:UIImageView.class]) {
            UIImageView *iv = (UIImageView *)sv;
            UIImage *im = iv.image;
            if (im && im.renderingMode != UIImageRenderingModeAlwaysTemplate && !GET(im, kArrowDone)) {
                UIImage *t = [im imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
                if (t) { SET(t, kArrowDone, @YES); iv.image = t; }
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
    // lay view ngay luc nay (dang trong setter nen delegate con song), giu bang weak -> khong dung delegate treo sau do
    id d0 = l.delegate;
    __weak UIView *wv = [d0 isKindOfClass:UIView.class] ? (UIView *)d0 : nil;
    void (^work)(void) = ^{
        CALayer *ly = wl;
        if (!ly) return;
        FixUnderFill(ly, 0);
        UIView *ov = wv;
        if (ov) ArrowFixView(ov, 0);
    };
    dispatch_async(dispatch_get_main_queue(), work);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), work);
}

// ---------------- Nen den / icon den (layer) ----------------
static void TryBlack(CALayer *l) {
    if (!gMaster || !OnMain() || InGlassLayer(l)) return;
    CGSize sz = l.bounds.size;
    if (l.contents || GET(l, kImgView)) return;
    BOOL round = sz.width > 0 && fabs(sz.width - sz.height) < 2 && l.cornerRadius >= sz.width * 0.45;
    BOOL arrowBtn = round && sz.width >= 10 && sz.width <= 56 && l.sublayers.count > 0 && IsBlackCG(l.backgroundColor);
    if (round && sz.width >= 40 && !arrowBtn) return;
    BOOL nested = LayerUnderFill(l.superlayer);
    CGColorRef bg = l.backgroundColor;
    BOOL cand = IsFillCandidateCG(bg) && !(IsWhiteCG(bg) && InControlKnob(l));
    if (cand && ((sz.height >= 14 && sz.height <= 64 && sz.width >= 14 && (l.cornerRadius >= 6 || nested)) || arrowBtn)) {
        l.backgroundColor = CGFor(NO);
        MarkFill(l, nil);
        if (arrowBtn) ArrowFix(l);
    }
    if (l.borderWidth > 0 && IsBlackCG(l.borderColor) && (nested || LayerUnderFill(l))) l.borderColor = CGFor(NO);
}

static void FixLabelBG(UILabel *lb) {
    if (!gMaster || !OnMain()) return;
    UIColor *bg = lb.backgroundColor;
    if (!bg || !IsFillCandidateColor(bg) || lb.bounds.size.height > 64) return;
    if (UnderFill(lb.superview) || LayerUnderFill(lb.layer.superlayer)) lb.backgroundColor = UIColor.clearColor;
}

static BOOL PathBounds(CAShapeLayer *sh, CGRect *out) {
    CGPathRef path = sh.path;
    if (!path || CGPathIsEmpty(path)) return NO;
    CGRect b = CGPathGetBoundingBox(path);
    if (CGRectIsNull(b) || CGRectIsInfinite(b) || isnan(b.size.width) || isnan(b.size.height)) return NO;
    *out = b;
    return YES;
}

static void TryBlackShape(CAShapeLayer *sh) {
    CGRect b;
    if (!gMaster || !OnMain() || !IsBlackCG(sh.fillColor) || !PathBounds(sh, &b)) return;
    if (b.size.height < 20 || b.size.height > 64 || b.size.width < b.size.height * 1.6) return;
    sh.fillColor = CGFor(NO);
}

// Icon trang co vien/bong den (icon like, comment tren video): bo vien thay vi doi sang accent
static void StripWhiteShapeOutline(CAShapeLayer *sh) {
    if (gInTry || !gMaster || !OnMain()) return;
    CGColorRef st = sh.strokeColor;
    if (!st || sh.lineWidth > 3) return;
    CGFloat r, g, b, a;
    if (!CGRGBA(sh.fillColor, &r, &g, &b, &a) || !WhiteRGBA(r, g, b, a)) return;
    NSNumber *m = GET(sh, kIconShape);
    BOOL ours = (m.intValue & 2) != 0;
    BOOL dark = CGRGBA(st, &r, &g, &b, &a) && r < 0.3 && g < 0.3 && b < 0.3;
    if (!dark && !ours) return;
    CGRect bb;
    if (PathBounds(sh, &bb) && fmax(bb.size.width, bb.size.height) > 64) return;
    gInTry = YES;
    sh.strokeColor = NULL;
    gInTry = NO;
    if (m) SET(sh, kIconShape, @(m.intValue & ~2));
}

static void TryBlackIconShape(CAShapeLayer *sh) {
    CGRect b;
    if (!gMaster || gInTry || !OnMain() || InGlassLayer(sh)) return;
    StripWhiteShapeOutline(sh);
    BOOL fill = IsInkCG(sh.fillColor), stroke = IsInkCG(sh.strokeColor);
    if ((!fill && !stroke) || !PathBounds(sh, &b)) return;
    CGFloat mx = fmax(b.size.width, b.size.height);
    if (mx < 6 || mx > 48) return;
    int bits = 0;
    CGColorRef c = IconShapeColor(sh);
    gInTry = YES;
    if (fill)   { sh.fillColor   = c; bits |= 1; }
    if (stroke) { sh.strokeColor = c; bits |= 2; }
    gInTry = NO;
    SET(sh, kIconShape, @(bits | [GET(sh, kIconShape) intValue]));
    KillShadowUp(sh, 2);
    MarkInk(sh);
}

// ---------------- Hang cho kiem tra lai (app thuong) ----------------
static NSHashTable *gPend;
#define PEND_LOCK @"AACPend"

static void RunCheck(CALayer *l, BOOL shape) {
    Crumb("RunCheck");
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
    SET(l, kPendShape, @(shape));
}

static void PendingRun(CALayer *l) {
    Crumb("PendingRun");
    BOOL has;
    @synchronized (PEND_LOCK) { has = [gPend containsObject:l]; }
    if (!has) return;
    BOOL shape = [GET(l, kPendShape) boolValue];
    RunCheck(l, shape);
    int n = [GET(l, kAttempts) intValue] + 1;
    SET(l, kAttempts, @(n));
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

// ---------------- Bien doi UIImage ----------------
// Icon trang co vien/bong den "nuong" trong anh -> xoa phan toi, giu phan trang
static UIImage *ShadowStripImage(UIImage *img) {
    Crumb("ShadowStripImage");
    if (!img || !gMaster || !OnMain() || GET(img, kStripSrc)) return img;
    if (img.isSymbolImage || img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.images.count > 1) return img;
    if (!UIEdgeInsetsEqualToEdgeInsets(img.capInsets, UIEdgeInsetsZero)) return img;
    CGSize sz = img.size;
    if (sz.width < 14 || sz.height < 14 || sz.width > 64 || sz.height > 64) return img;
    NSNumber *state = GET(img, kStripState);
    if (state) return state.boolValue ? (GET(img, kStripOut) ?: img) : img;
    if (!RATE(50)) return img;

    uint8_t *buf; CGContextRef ctx; size_t w, h;
    if (!LoadImg(img, &buf, &ctx, &w, &h)) { SET(img, kStripState, @NO); return img; }

    int solid = 0, light = 0, dark = 0, darkOpq = 0, colored = 0, clear = 0;
    for (size_t i = 0; i < w * h; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) { clear++; continue; }
        solid++;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.15) { colored++; continue; }
        CGFloat lum = (r + g + b) / 3.0;
        if (lum < 0.35) { dark++; if (px[3] >= 200) darkOpq++; }
        else if (lum > 0.8 && px[3] >= 200) light++;
    }
    // icon that su co nhieu vung trong suot; anh mask/gradient dac thi bo qua
    BOOL ok = solid >= 20 && colored * 10 <= solid && light * 100 >= 20 * solid && dark * 100 >= 5 * solid &&
              darkOpq <= light && (size_t)clear * 100 >= 25 * w * h;
    if (!ok) { FreeBuf(buf, ctx); SET(img, kStripState, @NO); return img; }
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *px = buf + i * 4;
        if (!px[3]) continue;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.15) continue;
        if ((r + g + b) / 3.0 < 0.4) px[0] = px[1] = px[2] = px[3] = 0;
    }
    UIImage *out = FinishImage(buf, ctx, img.scale > 0 ? img.scale : 1);
    if (!out) return img;
    SET(out, kStripSrc, img);
    SET(img, kStripState, @YES);
    SET(img, kStripOut, out);
    return out;
}

static UIImage *IconRemapImage(UIImage *img) {
    if (!img || !gMaster || !OnMain()) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.isSymbolImage) return img;
    CGSize sz = img.size;
    if (sz.width < 8 || sz.height < 8 || sz.width > 64 || sz.height > 64 || !ImageIsBlackMono(img)) return img;
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// App thuong: icon xanh -> accent. Facebook (gSafe): icon den kem chi tiet trang (vd Messenger) -> den thanh accent, giu trang.
static UIImage *ImageRemap(UIImage *img) {
    Crumb("ImageRemap");
    BOOL dual = gSafe;
    if (!img || !gMaster || !OnMain() || GET(img, kRemSrc) || GET(img, kAccentSrc)) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate || (dual && img.isSymbolImage)) return img;
    CGSize sz = img.size;
    CGFloat mn = dual ? 18 : 8, mx = dual ? 44 : 64;
    if (sz.width < mn || sz.height < mn || sz.width > mx || sz.height > mx || img.images.count > 1) return img;

    NSNumber *state = GET(img, kRemState);
    if (state && !state.boolValue) return img;
    int want = gVersion * 2 + (gDark ? 1 : 0);
    if (state) {
        UIImage *cached = GET(img, kRemOut);
        if (cached && [GET(img, kRemStamp) intValue] == want) return cached;
    } else if (!(dual ? RATE(40) : RATE(60))) {
        return img;
    }

    uint8_t *buf; CGContextRef ctx; size_t w, h;
    if (!LoadImg(img, &buf, &ctx, &w, &h)) { SET(img, kRemState, @NO); return img; }

    int solid = 0, hit = 0, other = 0, blk = 0, mid = 0, opq = 0, opqBlk = 0;
    for (size_t i = 0; i < w * h; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        solid++;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (!dual) { if (BlueClass(r, g, b)) hit++; else other++; continue; }
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.12) { other++; continue; }
        CGFloat lum = (r + g + b) / 3.0;
        if (px[3] >= 200) { opq++; if (lum < 0.16) opqBlk++; }
        if (lum < 0.16) blk++;
        else if (lum > 0.25 && lum < 0.75) mid++;
    }
    BOOL ok = dual ? (solid >= 30 && other * 30 <= solid && blk * 100 >= 30 * solid && mid * 100 <= 18 * solid &&
                      opq > 0 && opqBlk * 100 >= 40 * opq)
                   : (solid >= 6 && hit > 0 && other * 40 <= solid);
    if (!ok) { FreeBuf(buf, ctx); SET(img, kRemState, @NO); return img; }

    const CGFloat *q = AccRGB();
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *px = buf + i * 4;
        if (dual) {
            if (!px[3]) continue;
            CGFloat r, g, b;
            Unpm(px, &r, &g, &b);
            if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.12) continue;
            SetMix(px, q, fmax(0, fmin(1, (r + g + b) / 3.0)));
        } else {
            if (px[3] < 24) continue;
            CGFloat r, g, b;
            Unpm(px, &r, &g, &b);
            int cls = BlueClass(r, g, b);
            if (!cls) continue;
            CGFloat al = (px[3] / 255.0) * (cls == 2 ? 0.2 : 1.0);
            SetAcc(px, q, al);
            px[3] = (uint8_t)lround(al * 255);
        }
    }
    UIImage *out = FinishImage(buf, ctx, img.scale > 0 ? img.scale : 1);
    if (!out) return img;
    SET(out, kRemSrc, img);
    SET(img, kRemState, @YES);
    SET(img, kRemOut, out);
    SET(img, kRemStamp, @(want));
    return out;
}

static UIImage *ImgChain(UIImage *img) { return ImageRemap(IconRemapImage(ShadowStripImage(img))); }

static UIColor *IconTintFix(UIColor *c) {
    if (gMaster && c && OnMain()) {
        if (IsInkColor(c)) return gColor;
        UIColor *n = ColorRemap(c, NULL);
        if (n) return n;
    }
    return c;
}

// ---------------- Tab bar ----------------
static BOOL InTabBar(UIView *v) {
    for (int i = 0; i < 10 && v; i++, v = v.superview)
        if ([v isKindOfClass:UITabBar.class]) return YES;
    return NO;
}

static UIImage *TabColorize(UIImage *im) {
    if (!im || !gMaster || !OnMain()) return im;
    int want = gVersion * 2 + (gDark ? 1 : 0);
    UIImage *src = GET(im, kAccentSrc);
    NSNumber *stamp = GET(im, kAccentStamp);
    if (src && stamp.intValue == want) return im;
    UIImage *base = src ?: im;
    CGSize sz = base.size;
    if (sz.width > 80 || sz.height > 80) return im;
    if (!(base.renderingMode == UIImageRenderingModeAlwaysTemplate || base.isSymbolImage || ImageIsBlackMono(base))) return im;
    UIImage *out = [base imageWithTintColor:[UIColor colorWithCGColor:CGFor(NO)] renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!out) return im;
    SET(out, kAccentSrc, base);
    SET(out, kAccentStamp, @(want));
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
    Crumb("TabBarFix");
    if (!bar || !gMaster || gInTabFix || !OnMain()) return;
    gInTabFix = YES;
    TabFixView(bar, 0);
    gInTabFix = NO;
}

static void TabBarFixLater(UITabBar *bar) { dispatch_async(dispatch_get_main_queue(), ^{ TabBarFix(bar); }); }

static void TabLabelFix(UILabel *lb) {
    if (!gMaster || !gColor || !OnMain() || lb.textColor == gColor || !InTabBar(lb)) return;
    lb.textColor = gColor;
}

// ---------------- Quet icon trang cua ban phim (menu chon ban phim trai/giua/phai) ----------------
// Cac icon nay nam trong lop glass/popup nen hook setContents/setImage co the bo sot -> quet dinh ky cua so ban phim va doi sang accent.
// Nut back/Enter (icon den) KHONG dong vao: de mac dinh. (Chi chay giao dien sang, va khong chay o Facebook)
static BOOL InputWindow(UIWindow *w) {
    NSString *cn = NSStringFromClass(w.class);
    return KbName(cn) || [cn containsString:@"TextEffects"] || [cn containsString:@"RemoteKeyboard"];
}

// Ten class cua view/layer thuoc khu vuc qua dia cau / menu chon ban phim
static BOOL KbForceName(NSString *cn) {
    return [cn containsString:@"DockItem"] || [cn containsString:@"DockView"] || [cn containsString:@"Dock"] ||
           [cn containsString:@"InputSwitcher"] || [cn containsString:@"Switcher"] || [cn containsString:@"Globe"] ||
           [cn containsString:@"KeyboardMenu"] || [cn containsString:@"UIKBMenu"] || [cn containsString:@"KBMenu"] ||
           [cn containsString:@"Popover"] || [cn containsString:@"OneHand"] || [cn containsString:@"Handed"];
}

// Icon trang/xam nhat (giu alpha) -> accent. Bo qua nen phim (it vung trong suot) va icon den.
// force = icon cua qua dia cau / menu: noi long nguong (icon trang co do bong xam nhe)
static CGImageRef KbWhiteForce(CGImageRef src, BOOL force) {
    if (!src || !gMaster) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w < 8 || h < 8 || w > 300 || h > 300) return NULL;
    CGContextRef ctx;
    uint8_t *buf = LoadBuf(src, w, h, &ctx);
    if (!buf) return NULL;
    size_t total = w * h;
    int solid = 0, gray = 0, wt = 0, blk = 0, clear = 0;
    CGFloat wthr = force ? 0.70 : 0.85;
    for (size_t i = 0; i < total; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) { clear++; continue; }
        solid++;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.12) continue;
        gray++;
        CGFloat lum = (r + g + b) / 3.0;
        if (lum > wthr) wt++;
        else if (lum < 0.3) blk++;
    }
    BOOL ok = force
        ? (solid >= 12 && gray * 100 >= 85 * solid && wt * 100 >= 40 * solid &&
           blk * 100 <= 20 * solid && (size_t)clear * 100 >= 3 * total)
        : (solid >= 15 && gray * 100 >= 90 * solid && wt * 100 >= 60 * solid &&
           blk * 100 <= 8 * solid && (size_t)clear * 100 >= 8 * total);
    if (!ok) { FreeBuf(buf, ctx); return NULL; }
    const CGFloat *q = AccRGB();
    for (size_t i = 0; i < total; i++) {
        uint8_t *px = buf + i * 4;
        if (!px[3]) continue;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.12) continue;
        SetAcc(px, q, px[3] / 255.0);
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    FreeBuf(buf, ctx);
    return out;
}

// Icon nam trong nut dock (qua dia cau) hoac menu chon ban phim: luon doi accent, bo qua kiem tra "duoi nut accent"
static BOOL KbForceView(UIView *v) {
    for (int i = 0; i < 8 && v; i++, v = v.superview) {
        if (KbForceName(NSStringFromClass(v.class))) return YES;
    }
    return NO;
}

static BOOL KbForceLayer(CALayer *l) {
    for (int i = 0; i < 8 && l; i++, l = l.superlayer) {
        if (KbForceName(NSStringFromClass(l.class))) return YES;
        id d = l.delegate;
        if (d && KbForceName(NSStringFromClass([d class]))) return YES;
    }
    return NO;
}

static UIImage *SweepRecolorImage(UIImage *im, BOOL force) {
    if (!im || GET(im, kKbImg) || im.images.count > 1) return nil;
    if (GET(im, kSweepImg) && !force) return nil;
    UIImage *out = nil;
    if (im.isSymbolImage || im.renderingMode == UIImageRenderingModeAlwaysTemplate) {
        out = [im imageWithTintColor:[UIColor colorWithCGColor:CGFor(NO)] renderingMode:UIImageRenderingModeAlwaysOriginal];
    } else if (im.CGImage && im.size.width <= 96 && im.size.height <= 96) {
        CGImageRef k = KbWhiteForce(im.CGImage, force);
        if (!k && force) k = CopyTintedCG(im.CGImage, CGFor(NO));   // fallback: to accent theo hinh dang (giu alpha)
        if (k) {
            out = [UIImage imageWithCGImage:k scale:im.scale orientation:im.imageOrientation];
            CGImageRelease(k);
        }
    }
    if (!out) { SET(im, kSweepImg, @YES); return nil; }
    SET(out, kKbImg, @YES);
    SET(out, kSweepImg, @YES);
    return out;
}

static void SweepShape(CAShapeLayer *sh) {
    if (gInTry) return;
    BOOL force = KbForceLayer(sh);
    if (!force && !WhiteOK(sh)) return;
    CGRect b;
    if (!PathBounds(sh, &b) || fmax(b.size.width, b.size.height) > 44) return;
    BOOL fill = IsWhiteCG(sh.fillColor), stroke = IsWhiteCG(sh.strokeColor);
    if (!fill && !stroke) return;
    int bits = 0;
    CGColorRef c = CGFor(NO);
    gInTry = YES;
    if (fill)   { sh.fillColor   = c; bits |= 1; }
    if (stroke) { sh.strokeColor = c; bits |= 2; }
    gInTry = NO;
    SET(sh, kIconShape, @(bits | [GET(sh, kIconShape) intValue]));
}

static void SweepLayer(CALayer *l, int depth) {
    if (!l || depth > 30) return;
    CGSize s = l.bounds.size;
    if (!l.hidden && s.width >= 8 && s.height >= 8 && s.width <= 44 && s.height <= 44) {
        if ([l isKindOfClass:CAShapeLayer.class]) {
            SweepShape((CAShapeLayer *)l);
        } else {
            id c = l.contents;
            if (c && CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID() &&
                !GET(l, kKbSrc) && !GET(l, kContentsSrc) && ![l.delegate isKindOfClass:UIImageView.class]) {
                NSNumber *np = GET(l, kSweepPtr);
                uintptr_t p = (uintptr_t)(__bridge void *)c;
                if (!np || (uintptr_t)np.unsignedLongValue != p) {
                    SET(l, kSweepPtr, @((unsigned long)p));
                    BOOL force = !gDark && KbForceLayer(l);
                    // Icon qua dia cau / menu: bo bo loc glass/vibrancy de mau accent hien ra dung
                    if (force && l.compositingFilter) l.compositingFilter = nil;
                    // Chi dong vao layer co multiply trang/khong co (qua dia cau...). Layer phim chu co multiply den/accent -> de nguyen cho logic ban phim.
                    BOOL mulOK = YES;
                    @try {
                        id mm = [l valueForKey:@"contentsMultiplyColor"];
                        if (mm) {
                            CGFloat mr, mg, mb, ma;
                            mulOK = CGRGBA((__bridge CGColorRef)mm, &mr, &mg, &mb, &ma) && mr > 0.9 && mg > 0.9 && mb > 0.9;
                        }
                    } @catch (NSException *e) { mulOK = NO; }
                    if ((mulOK || force) && (force || WhiteOK(l))) {
                        CGImageRef k = KbWhiteForce((__bridge CGImageRef)c, force);
                        if (!k && force && !ContentsLooksAccent(l)) k = CopyTintedCG((__bridge CGImageRef)c, CGFor(NO));
                        if (k) {
                            SET(l, kKbSrc, c);
                            SET(l, kWhiteMark, @YES);
                            PutContents(l, k);
                            CGImageRelease(k);
                            if (force && !mulOK) {   // multiply khong phai trang -> dua ve trang de khong to 2 lan
                                @try { [l setContentsMultiplyColor:gCGWhite]; } @catch (NSException *e) {}
                            }
                        }
                    }
                }
            }
        }
    }
    for (CALayer *sub in [l.sublayers copy]) SweepLayer(sub, depth + 1);
}

static void SweepView(UIView *v, int depth) {
    if (!v || depth > 30) return;
    CGSize s = v.bounds.size;
    if ([v isKindOfClass:UIImageView.class] && s.width >= 8 && s.width <= 56 && s.height <= 56) {
        UIImageView *iv = (UIImageView *)v;
        BOOL force = !gDark && KbForceView(iv);
        // Icon qua dia cau / menu: bo bo loc glass/vibrancy de mau accent hien ra dung
        if (force && iv.layer.compositingFilter) iv.layer.compositingFilter = nil;
        if (iv.image && !GET(iv.image, kKbImg) && (force || WhiteOK(iv.layer))) {
            UIImage *out = SweepRecolorImage(iv.image, force);
            if (out) { gInKbFix = YES; iv.image = out; gInKbFix = NO; }
        }
    } else if ([v isKindOfClass:UIButton.class] && s.width <= 80 && s.height <= 80) {
        UIButton *b = (UIButton *)v;
        UIImage *bi = [b imageForState:UIControlStateNormal];
        BOOL force = !gDark && KbForceView(b);
        if (bi && !GET(bi, kKbImg) && (force || WhiteOK(b.layer))) {
            UIImage *out = SweepRecolorImage(bi, force);
            if (out) { gInKbFix = YES; [b setImage:out forState:UIControlStateNormal]; gInKbFix = NO; }
        }
    }
    for (UIView *sv in [v.subviews copy]) SweepView(sv, depth + 1);
}

// FIX: chu/so tren phim bi to 2 lan (accent x accent -> dam hon cac phim khac). Quet toan bo cay layer ban phim, dua multiply ve trang.
static void FixTintTree(CALayer *l, int depth) {
    if (!l || depth > 30) return;
    if (l.contents) {
        CGSize z = l.bounds.size;
        if (z.width <= 220 && z.height <= 160) { FixDoubleTint(l); KbEnsureNotBlack(l); }
    }
    for (CALayer *sub in [l.sublayers copy]) FixTintTree(sub, depth + 1);
}

// FIX: mo lai nhung layer ban phim da bi an nham (kHidMark) trong luc quet dinh ky
static void UnhideKbLayers(CALayer *l, int depth) {
    if (!l || depth > 30) return;
    if (GET(l, kHidMark)) { SET(l, kHidMark, nil); l.hidden = NO; }
    for (CALayer *sub in [l.sublayers copy]) UnhideKbLayers(sub, depth + 1);
}

static void KbSweepAll(void) {
    Crumb("KbSweepAll");
    if (!gMaster || gSafe || !OnMain()) return;
    BOOL oldDark = gDark;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [((UIWindowScene *)sc).windows copy]) {
            if (w.hidden || w.alpha < 0.01 || !InputWindow(w)) continue;
            UnhideKbLayers(w.layer, 0);
            FixTintTree(w.layer, 0);
            if (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) continue;
            gDark = NO;
            SweepView(w, 0);
            SweepLayer(w.layer, 0);
        }
    }
    gDark = oldDark;
}

static void StartSweep(void) {
    static dispatch_source_t t;
    if (t) return;
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), (uint64_t)(0.3 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{ KbSweepAll(); });
    dispatch_resume(t);
}

// =====================================================================================
// Qua dia cau + icon vung dock (mic, menu chon ban phim...) -> doi sang accent
// Module doc lap, chay bang timer rieng, chi dong vao cua so ban phim -> an toan o MOI app (ke ca Facebook).
// - Giao dien SANG: vung "ten" (class DockItem/Globe/Switcher...) + day cua so ban phim (~76pt)
// - Giao dien TOI (gGlbAll): ca cua so ban phim -> icon/chu trang -> accent (ban sang cua accent, khong cham nen phim)
//   Mau accent dung gDark (ban sang hon o giao dien toi). Icon nam duoi nut accent (kinh lup tren nut Search) giu trang.
// - Vung "ten" -> luon xu ly, kg kiem tra "duoi nut accent"
// - Cach 1: anh CGImage dang icon (xam/trang/den, nhieu vung trong) -> to accent theo hinh dang, multiply trang
// - Cach 1b: anh trang/xam nhat dang DIA DAC (qua dia cau: nen mo, it vung trong) -> cung to accent theo alpha
// - Cach 2: contents khong phai CGImage (backing store / mask) -> dat contentsMultiplyColor = accent
// - Go compositingFilter / filters (vibrancy/glass) cua icon va cac layer cha (nho, hoac rong neu o vung dock)
// =====================================================================================
static inline int GlbStamp(void) { return gVersion * 2 + (gDark ? 1 : 0); }
static BOOL GlbWinAll(UIWindow *w) { return w && KbName(NSStringFromClass(w.class)); }   // cua so ban phim that (khong tinh TextEffects)
static BOOL GlbNameZone(CALayer *l) { return l ? KbForceLayer(l) : NO; }

static BOOL GlbStripZone(CALayer *l, UIWindow *w) {
    if (!l || !w) return NO;
    CGRect r = [w.layer convertRect:l.bounds fromLayer:l];
    if (CGRectIsNull(r) || CGRectIsInfinite(r) || isnan(r.origin.x) || isnan(r.origin.y)) return NO;
    CGFloat H = CGRectGetHeight(w.bounds);
    CGFloat my = CGRectGetMidY(r);
    return my > H - 76.0 && my < H + 8.0;
}

// Anh dang icon: gan nhu chi xam/trang/den, co nhieu vung trong suot, khong phai hinh dac
static BOOL GlbIconLike(CGImageRef cg, int minClear) {
    if (!cg) return NO;
    uint8_t buf[SN * SN * 4];
    if (!SampleCG(cg, buf)) return NO;
    int solid = 0, gray = 0, clear = 0;
    for (int i = 0; i < SN * SN; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) { clear++; continue; }
        solid++;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) <= 0.12) gray++;
    }
    int total = SN * SN;
    return solid >= 6 && gray * 100 >= 90 * solid && solid * 100 <= 70 * total && clear * 100 >= minClear * total;
}

// Qua dia cau la hinh tron dac/mo (nen trang mo + luoi trang) -> chiem >70% o vuong va it vung trong nen GlbIconLike
// loai nham. Nhan dien theo: gan nhu chi xam/trang va do sang trung binh (co trong so alpha) cao.
static BOOL GlbWhiteLike(CGImageRef cg) {
    if (!cg) return NO;
    uint8_t buf[SN * SN * 4];
    if (!SampleCG(cg, buf)) return NO;
    int solid = 0, gray = 0;
    CGFloat sl = 0, sw = 0;
    for (int i = 0; i < SN * SN; i++) {
        const uint8_t *px = buf + i * 4;
        if (px[3] < 24) continue;
        solid++;
        CGFloat r, g, b;
        Unpm(px, &r, &g, &b);
        if (fmax(r, fmax(g, b)) - fmin(r, fmin(g, b)) > 0.12) continue;
        gray++;
        CGFloat wt = px[3] / 255.0;
        sl += ((r + g + b) / 3.0) * wt;
        sw += wt;
    }
    return solid >= 6 && gray * 100 >= 90 * solid && sw > 0 && (sl / sw) >= 0.8;
}

static void GlbUnfilter(CALayer *l) {
    if (!l) return;
    int n = 0;
    BOOL wide = GlbNameZone(l);   // vung dock: vibrancy/glass thuong nam o layer cha rong -> cho phep go bo
    for (CALayer *c = l; c && n < (wide ? 6 : 4); c = c.superlayer, n++) {
        NSString *cn = NSStringFromClass(c.class);
        if ([cn containsString:@"Backdrop"] || [cn containsString:@"Window"]) break;
        CGSize s = c.bounds.size;
        if (s.height > 120 || (!wide && s.width > 120)) break;
        if (c.compositingFilter) c.compositingFilter = nil;
        if (wide && c != l && c.filters.count) c.filters = nil;
    }
    if (l.filters.count) l.filters = nil;
}

// contents khong phai CGImage (hoac anh trang): dat multiply = accent (trang x accent = accent)
static void GlbMultiplyOnly(CALayer *l) {
    if (!gCGWhite) return;
    id m = nil;
    @try { m = [l valueForKey:@"contentsMultiplyColor"]; } @catch (NSException *e) { return; }
    if (m && !GET(l, kGlbMul)) {   // lan dau: chi doi khi multiply dang la trang; da doi roi thi cap nhat theo accent moi
        CGFloat r, g, b, a;
        if (!CGRGBA((__bridge CGColorRef)m, &r, &g, &b, &a) || !(r > 0.9 && g > 0.9 && b > 0.9)) return;
    }
    @try { [l setContentsMultiplyColor:CGFor(NO)]; } @catch (NSException *e) {}
    SET(l, kGlbMul, @(GlbStamp()));
    GlbUnfilter(l);
}

static void GlbViewIn(UIImageView *iv, UIWindow *w) {
    if (iv.hidden) return;
    CGSize s = iv.bounds.size;
    BOOL name = GlbNameZone(iv.layer);
    CGFloat lim = name ? 56 : 40, mn = gGlbAll ? 4 : 12;
    if (s.width < mn || s.width > lim || s.height < mn || s.height > lim) return;
    UIImage *im = iv.image;
    if (!im || im.images.count > 1) return;
    if (!name && ((!gGlbAll && !GlbStripZone(iv.layer, w)) || UnderAccentKey(iv.layer))) return;
    int st = GlbStamp();
    NSNumber *ver = GET(im, kGlbVer);
    if (GET(im, kKbImg) && !ver) { GlbUnfilter(iv.layer); return; }   // da duoc logic san co to accent -> chi go bo loc
    if (!ver) {
        NSNumber *ng = GET(im, kGlbNeg);
        if (ng && ng.boolValue == gGlbAll) return;   // da kiem tra: khong phai icon
    }
    UIImage *base = im;
    if (ver) {
        if (ver.intValue == st) { GlbUnfilter(iv.layer); return; }
        base = GET(im, kGlbSrc) ?: im;
    }
    UIImage *out = nil;
    if (base.isSymbolImage || base.renderingMode == UIImageRenderingModeAlwaysTemplate) {
        out = [base imageWithTintColor:[UIColor colorWithCGColor:CGFor(NO)] renderingMode:UIImageRenderingModeAlwaysOriginal];
    } else if (base.CGImage && (name || GlbIconLike(base.CGImage, 30) || (!gGlbAll && GlbWhiteLike(base.CGImage)))) {
        CGImageRef k = CopyTintedCG(base.CGImage, CGFor(NO));
        if (k) {
            out = [UIImage imageWithCGImage:k scale:base.scale orientation:base.imageOrientation];
            CGImageRelease(k);
        }
    }
    if (!out) { SET(base, kGlbNeg, @(gGlbAll)); return; }
    SET(out, kKbImg, @YES);
    SET(out, kGlbVer, @(st));
    SET(out, kGlbSrc, base);
    gInKbFix = YES;
    iv.image = out;
    gInKbFix = NO;
    GlbUnfilter(iv.layer);
}

// Giao dien (sang/toi) lay theo chinh UIImageView
static void GlbView(UIImageView *iv, UIWindow *w) {
    BOOL od = gDark, oa = gGlbAll;
    gDark = (iv.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    gGlbAll = gDark && GlbWinAll(w);
    GlbViewIn(iv, w);
    gDark = od; gGlbAll = oa;
}

// Doi icon ngay khi UIImageView duoc gan anh / vao cua so (khong cho den dot quet). Chay o moi app.
static void KbGlobeImageFix(UIImageView *iv) {
    if (gInKbFix || !gMaster || !OnMain() || !iv) return;
    UIWindow *w = iv.window;
    if (w && InputWindow(w)) GlbView(iv, w);
}

static void GlbLayer(CALayer *l, UIWindow *w) {
    if (l.hidden) return;
    id c = l.contents;
    if (!c) return;
    CGSize s = l.bounds.size;
    BOOL name = GlbNameZone(l);
    CGFloat lim = name ? 96 : 40, mn = gGlbAll ? 3 : 12;
    if (s.width < mn || s.height < mn || s.width > lim || s.height > lim) return;
    BOOL ivLayer = GET(l, kImgView) || [l.delegate isKindOfClass:UIImageView.class];
    if (!name) {
        if (ivLayer) {
            // layer cua UIImageView co anh -> GlbView xu ly; anh nil (UIKit tu ve vao layer) -> xu ly o day
            id dl = l.delegate;
            UIImageView *div = [dl isKindOfClass:UIImageView.class] ? (UIImageView *)dl : nil;
            if (!(div && !div.image)) return;
        }
        if ((!gGlbAll && !GlbStripZone(l, w)) || UnderAccentKey(l)) return;
    }
    BOOL small = s.width <= 44 && s.height <= 44;
    int st = GlbStamp();
    if (CFGetTypeID((__bridge CFTypeRef)c) != CGImageGetTypeID()) {
        // backing store / IOSurface / mask: khong sua duoc anh -> dung multiply
        if (!name || !small) return;
        NSNumber *mv = GET(l, kGlbMul);
        id mm = nil;
        @try { mm = [l valueForKey:@"contentsMultiplyColor"]; } @catch (NSException *e) { return; }
        if (mv && mv.intValue == st && mm && NearAccentCG((__bridge CGColorRef)mm, 0.1, 0.9)) { GlbUnfilter(l); return; }
        GlbMultiplyOnly(l);
        return;
    }
    uintptr_t cp = (uintptr_t)(__bridge void *)c;
    uintptr_t negKey = cp ^ (gGlbAll ? 1 : 0);
    NSNumber *op = GET(l, kGlbPtr);
    NSNumber *ov = GET(l, kGlbVer);
    id src = c;
    if (op && (uintptr_t)op.unsignedLongValue == cp) {
        if (ov.intValue == st) { GlbUnfilter(l); return; }
        src = GET(l, kGlbSrc) ?: c;
    } else if (GET(l, kKbSrc) || GET(l, kContentsSrc)) {
        GlbUnfilter(l);   // da duoc logic san co to accent -> chi go bo loc
        return;
    } else {
        NSNumber *ng = GET(l, kGlbNeg);
        if (ng && (uintptr_t)ng.unsignedLongValue == negKey) return;   // da kiem tra: khong phai icon
    }
    if (CFGetTypeID((__bridge CFTypeRef)src) != CGImageGetTypeID()) return;
    CGImageRef sc = (__bridge CGImageRef)src;
    // vung ten + layer nho: to accent theo hinh dang (giu alpha); con lai chi lay anh dang icon / dia trang (qua dia cau)
    BOOL like = (name && small) || GlbIconLike(sc, small ? 30 : 60) || (!gGlbAll && small && GlbWhiteLike(sc));
    if (!like) { SET(l, kGlbNeg, @((unsigned long)negKey)); return; }
    CGImageRef k = CopyTintedCG(sc, CGFor(NO));
    if (!k) return;
    SET(l, kGlbSrc, src);
    PutContents(l, k);
    CGImageRelease(k);
    id nc = l.contents;
    if (nc) SET(l, kGlbPtr, @((unsigned long)(uintptr_t)(__bridge void *)nc));
    SET(l, kGlbVer, @(st));
    if (gCGWhite) {
        @try { [l setContentsMultiplyColor:gCGWhite]; } @catch (NSException *e) {}
    }
    GlbUnfilter(l);
}

static void GlbShape(CAShapeLayer *sh, UIWindow *w) {
    if (gInTry || sh.hidden) return;
    CGRect b;
    if (!PathBounds(sh, &b)) return;
    CGFloat mx = fmax(b.size.width, b.size.height);
    BOOL name = GlbNameZone(sh);
    if (mx < 8 || mx > (name ? 48 : 36)) return;
    if (!name && ((!gGlbAll && !GlbStripZone(sh, w)) || UnderAccentKey(sh))) return;
    BOOL fill = IsWhiteCG(sh.fillColor), stroke = IsWhiteCG(sh.strokeColor);
    if (!fill && !stroke) {
        if (GET(sh, kIconShape)) GlbUnfilter(sh);
        return;
    }
    int bits = 0;
    CGColorRef c = CGFor(NO);
    gInTry = YES;
    if (fill)   { sh.fillColor   = c; bits |= 1; }
    if (stroke) { sh.strokeColor = c; bits |= 2; }
    gInTry = NO;
    SET(sh, kIconShape, @(bits | [GET(sh, kIconShape) intValue]));
    GlbUnfilter(sh);
}

static void GlbSweepLayer(CALayer *l, UIWindow *w, int depth) {
    if (!l || depth > 30) return;
    if ([l isKindOfClass:CAShapeLayer.class]) {
        GlbShape((CAShapeLayer *)l, w);
    } else {
        if (gGlbAll && [l isKindOfClass:CATextLayer.class]) {   // giao dien toi: chu trang -> accent
            CATextLayer *t = (CATextLayer *)l;
            if (IsWhiteCG(t.foregroundColor) && !UnderAccentKey(l)) t.foregroundColor = CGFor(NO);
        }
        GlbLayer(l, w);
    }
    for (CALayer *sub in [l.sublayers copy]) GlbSweepLayer(sub, w, depth + 1);
}

static void GlbSweepView(UIView *v, UIWindow *w, int depth) {
    if (!v || depth > 30) return;
    if ([v isKindOfClass:UIImageView.class]) GlbView((UIImageView *)v, w);
    else if (gGlbAll && [v isKindOfClass:UILabel.class]) KbLabelFix((UILabel *)v);
    for (UIView *sv in [v.subviews copy]) GlbSweepView(sv, w, depth + 1);
}

// Cua so ban phim co the nam ngoai windowScene.windows -> gop them UIApplication.windows
static NSArray<UIWindow *> *AllWindows(void) {
    NSMutableArray<UIWindow *> *a = [NSMutableArray new];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class]) [a addObjectsFromArray:((UIWindowScene *)sc).windows];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in UIApplication.sharedApplication.windows) if (![a containsObject:w]) [a addObject:w];
#pragma clang diagnostic pop
    return a;
}

static void GlobeSweepAll(void) {
    Crumb("GlobeSweepAll");
    if (!gMaster || !OnMain() || !gCGWhite) return;
    BOOL oldDark = gDark;
    @try {
        for (UIWindow *w in AllWindows()) {
            if (w.hidden || w.alpha < 0.01 || !InputWindow(w)) continue;
            gDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
            gGlbAll = gDark && GlbWinAll(w);
            GlbSweepView(w, w, 0);
            GlbSweepLayer(w.layer, w, 0);
        }
    } @catch (NSException *e) {}
    gGlbAll = NO;
    gDark = oldDark;
}

static void StartGlobeSweep(void) {
    static dispatch_source_t t;
    if (t) return;
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), (uint64_t)(0.15 * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{ GlobeSweepAll(); });
    dispatch_resume(t);
}

// =====================================================================================
// [FIX] Doi ban phim / ngon ngu (nhan tren nut space "Tieng Viet (Telex)" <-> "English (US)", qua dia cau)
// Khi doi ngon ngu, UIKit tao lai layer nhan va fade -> vai khung hinh dau layer o mau den (chua kip doi).
// Ngoai viec xu ly dong bo luc attach (hook addSublayer), con chay mot loat luot quet "bao ve" ngay sau khi doi.
// =====================================================================================
static void KbGuardTree(CALayer *l, int depth) {
    if (!l || depth > 30) return;
    CGSize z = l.bounds.size;
    if (z.width <= 220 && z.height <= 160) {
        if ([l isKindOfClass:CATextLayer.class]) {
            CATextLayer *t = (CATextLayer *)l;
            CGColorRef fc = t.foregroundColor;
            if (fc && IsInkCG(fc)) t.foregroundColor = CGFor(NO);
        }
        if (l.contents) {
            KbLate(l);
            FixDoubleTint(l);
            KbEnsureNotBlack(l);
        }
    }
    for (CALayer *sub in [l.sublayers copy]) KbGuardTree(sub, depth + 1);
}

static void KbGuardRun(void) {
    if (!gMaster || !OnMain()) return;
    BOOL oldDark = gDark;
    if (!gSafe) {
        @try {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in [((UIWindowScene *)sc).windows copy]) {
                    if (w.hidden || w.alpha < 0.01 || !InputWindow(w)) continue;
                    gDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
                    KbGuardTree(w.layer, 0);
                }
            }
        } @catch (NSException *e) {}
    }
    gDark = oldDark;
    GlobeSweepAll();
}

static void ScheduleKbGuard(void) {
    static const double delays[] = { 0.0, 0.04, 0.1, 0.18, 0.3, 0.45, 0.65, 0.9, 1.3 };
    for (size_t i = 0; i < sizeof delays / sizeof delays[0]; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KbGuardRun(); });
}

// ---------------- Bang cai dat ----------------
static BOOL gPanelShown, gPanelPending;

static void ClosePanelWindow(void) { gPanelShown = NO; gPanelPending = NO; }

static BOOL VCBusy(UIViewController *vc) {
    if (!vc || !vc.viewIfLoaded.window) return YES;
    if (vc.isBeingPresented || vc.isBeingDismissed || vc.isMovingToParentViewController || vc.isMovingFromParentViewController) return YES;
    return vc.transitionCoordinator != nil || [vc isKindOfClass:UIAlertController.class];
}

static UIViewController *TopVC(void) {
    UIWindow *best = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class] || sc.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in [((UIWindowScene *)sc).windows copy]) {
            if (w.hidden || w.windowLevel != UIWindowLevelNormal || !w.rootViewController) continue;
            if (w.isKeyWindow) { best = w; break; }
            if (!best) best = w;
        }
        if (best && best.isKeyWindow) break;
    }
    UIViewController *vc = best.rootViewController;
    for (int i = 0; i < 20 && vc; i++) {
        UIViewController *next = nil, *pr = vc.presentedViewController;
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
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.row == 0) {
        cell.textLabel.text = @"Bật màu nhấn";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new];
        sw.on = [NSUserDefaults.standardUserDefaults boolForKey:kMasterKey];
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
        cell.textLabel.text = ip.row == 2 ? @"Chọn màu…" : @"Lỗi crash lần trước";
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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Lỗi crash lần trước"
        message:(t.length > 1800 ? [t substringToIndex:1800] : t) preferredStyle:UIAlertControllerStyleAlert];
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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Mã màu" message:@"Nhập #RRGGBB" preferredStyle:UIAlertControllerStyleAlert];
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

// ---------------- Chan doan: giu 4 ngon 1 giay -> sao chep cay layer ----------------
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
    BOOL show = kb ? (l.contents != nil || shp || txt) : (l.shadowOpacity > 0 || shp || (l.contents && small));
    if (show) {
        [out appendFormat:@"%d %@ %.0fx%.0f", depth, NSStringFromClass(l.class), s.width, s.height];
        id d = l.delegate;
        if (d) [out appendFormat:@" del=%@", NSStringFromClass([d class])];
        if (l.contents) [out appendFormat:@" contents(%@)", NSStringFromClass([l.contents class])];
        if ([d isKindOfClass:UIImageView.class]) {
            UIImage *dim = ((UIImageView *)d).image;
            [out appendFormat:@" img=%@%@", dim ? @"Y" : @"nil", dim.isSymbolImage ? @"(sym)" : @""];
        }
        if (l.compositingFilter) [out appendFormat:@" cf=%@", l.compositingFilter];
        if (l.filters.count) [out appendFormat:@" filters=%lu", (unsigned long)l.filters.count];
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
    for (UIWindow *w in AllWindows()) {
        NSString *cn = NSStringFromClass(w.class);
        BOOL kb = KbName(cn) || [cn containsString:@"TextEffects"];
        [out appendFormat:@"== %@ level=%.0f kb=%d\n", cn, w.windowLevel, kb];
        DumpLayer(w.layer, 0, kb, out, out.length + 7000);
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
        if (attempt < 8)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ShowPanel(attempt + 1); });
        else
            gPanelPending = NO;
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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

- (void)onDump:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIPasteboard.generalPasteboard.string = DumpAll();
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)pc { ClosePanelWindow(); }

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || gPanelShown || gPanelPending) return;
    Crumb("onLongPress");
    gPanelPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ShowPanel(0); });
}
@end

static void Setup(UIWindow *w) {
    if (!OnMain()) return;
    if (!GET(w, kGestureFlag)) {
        NSString *cn = NSStringFromClass(w.class);
        BOOL skip = w.windowLevel > UIWindowLevelNormal ||
            [cn containsString:@"Keyboard"] || [cn containsString:@"TextEffects"] || [cn containsString:@"Shim"];
        SET(w, kGestureFlag, @YES);
        if (!skip) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:[AACHelper shared] action:@selector(onLongPress:)];
                g.numberOfTouchesRequired = 3;
                g.minimumPressDuration = 1.0;
                g.cancelsTouchesInView = NO;
                g.delaysTouchesBegan = NO;
                g.delaysTouchesEnded = NO;
                g.delegate = [AACHelper shared];
                [w addGestureRecognizer:g];
                UILongPressGestureRecognizer *g2 = [[UILongPressGestureRecognizer alloc] initWithTarget:[AACHelper shared] action:@selector(onDump:)];
                g2.numberOfTouchesRequired = 4;
                g2.minimumPressDuration = 1.0;
                g2.cancelsTouchesInView = NO;
                g2.delegate = [AACHelper shared];
                [w addGestureRecognizer:g2];
            });
        }
    }
    gDark = (w.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NSNumber *tv = GET(w, kTintVer);
    if (!tv || tv.intValue != gVersion) {
        SET(w, kTintVer, @(gVersion));
        w.tintColor = gMaster ? gColor : nil;
    }
}

// ================= HOOKS =================
%hook UIWindow
- (void)makeKeyAndVisible { %orig; Setup(self); }
- (void)becomeKeyWindow { %orig; Setup(self); }
- (void)setRootViewController:(UIViewController *)vc { %orig; Setup(self); }
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    gDark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
}
%end

%hook UIView
- (UIColor *)tintColor {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    if (!gMaster || !gColor) return %orig;
    if (gFillCount > 0 && OnMain() && UnderFill(self) && !InControlView(self)) {
        // FIX: icon tren ban phim (qua dia cau, menu chon ban phim) khong nam duoi nut accent -> giu accent, khong de trang
        if (ViewInKeyboard(self) && !UnderAccentKey(self.layer)) return gColor;
        return UIColor.whiteColor;
    }
    return gColor;
}
- (void)setTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    if (gMaster && c && OnMain() && IsInkColor(c)) {
        %orig(gColor);
        if ([self isKindOfClass:UIImageView.class]) MarkInk(self.layer);
        return;
    }
    %orig;
}
- (void)setBackgroundColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    if (!gMaster || !c) { %orig; return; }
    if (!OnMain()) { UIColor *m = ColorRemap(c, NULL); %orig(m ?: c); return; }
    int cls = 0;
    UIColor *n = ColorRemap(c, &cls);
    if (n && cls == 2 && InGlassLayer(self.layer)) n = nil;
    %orig(n ?: c);
    if (n && cls == 1) MarkFill(self.layer, self);
    else if (!n && IsFillCandidateColor(c)) { SetOwner(self); ScheduleCheck(self.layer, NO); }
}
%end

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    if (!gMaster || !c) { %orig; return; }
    int cls = 0;
    CGColorRef n = LayerRemap(c, &cls);
    if (n && cls == 2 && OnMain() && InGlassLayer(self)) n = NULL;
    if (n) { %orig(n); if (cls == 1 && OnMain()) MarkFill(self, nil); return; }
    %orig;
    if (IsFillCandidateCG(c)) ScheduleCheck(self, NO);
}
- (void)setBorderColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    CGColorRef n = LayerRemap(c, NULL);
    if (n) { %orig(n); return; }
    %orig;
    if (gMaster && IsBlackCG(c)) ScheduleCheck(self, NO);
}
- (void)setContentsMultiplyColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    CGColorRef n = NULL;
    BOOL inkSwap = NO;
    if (gMaster && c) {
        int mcls = 0;
        n = LayerRemap(c, &mcls);
        if (n && mcls == 2 && OnMain() && InGlassLayer(self)) n = NULL;
        if (!n && OnMain() && IsInkCG(c) && !InGlassLayer(self)) {
            CGSize s = self.bounds.size;
            if (s.width <= 64 && s.height <= 64) { n = IconShapeColor(self); inkSwap = YES; }
            // [FIX] nhan chu rong hon 64pt tren ban phim (nhan ngon ngu cua nut space) -> cung doi, khong de den
            else if (self.contents && s.width <= 220 && s.height <= 160 && IsKeyboardLayer(self)) {
                n = (GET(self, kKbSrc) || GET(self, kContentsSrc)) ? gCGWhite : IconShapeColor(self);
                inkSwap = YES;
            }
        }
    }
    // anh cua layer nay da duoc to accent -> multiply de trang, tranh to 2 lan
    // FIX: layer da duoc tweak to accent (kKbSrc/kContentsSrc) trong ban phim -> luon dua ve trang, khong phu thuoc viec doan mau anh
    if (n && n != gCGWhite && OnMain()) {
        BOOL marked = GET(self, kKbSrc) || GET(self, kContentsSrc);
        BOOL kbl = marked || IsKeyboardLayer(self);
        if (kbl && ((marked && IsKeyboardLayer(self)) || ContentsLooksAccent(self))) n = gCGWhite;
    }
    %orig(n ?: c);
    if (inkSwap) MarkInk(self);
    if (n && n != gCGWhite) KbEnsureNotBlack(self);
}
- (void)setShadowOpacity:(float)v {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    if (v > 0 && ShadowEligible(self)) { %orig(0); return; }
    %orig;
}
- (void)setShadowColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    KillShadowIfEligible(self);
}
- (void)setShadowRadius:(CGFloat)r {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    KillShadowIfEligible(self);
}
- (void)setShadowOffset:(CGSize)o {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    KillShadowIfEligible(self);
}
- (void)layoutSublayers {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    Crumb("hook:layoutSublayers");
    %orig;
    if (gHasPend && OnMain()) PendingRun(self);
    if (!gMaster || !OnMain()) return;
    KillShadowIfEligible(self);
    // Ban phim: anh da to accent ma van con multiply accent -> dua ve trang (accent chi 1 lan)
    if (self.contents) {
        CGSize z = self.bounds.size;
        if (z.width <= 220 && z.height <= 160 && IsKeyboardLayer(self)) { FixDoubleTint(self); KbEnsureNotBlack(self); }
    }
}
// [FIX] layer moi gan vao cay ban phim -> doi mau dong bo ngay (khong chop den khi doi ngon ngu)
- (void)addSublayer:(CALayer *)layer {
    %orig;
    KbAttachCheck(self, layer);
}
- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)idx {
    %orig;
    KbAttachCheck(self, layer);
}
- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    %orig;
    KbAttachCheck(self, layer);
}
- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    %orig;
    KbAttachCheck(self, layer);
}
- (void)setContents:(id)contents {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    Crumb("hook:setContents");
    if (gInContents) { %orig; return; }
    CLEAR(self, kContentsSrc);
    CLEAR(self, kKbSrc);
    CLEAR(self, kWhiteMark);
    if (!contents || !gMaster || !OnMain() || CFGetTypeID((__bridge CFTypeRef)contents) != CGImageGetTypeID()) { %orig; return; }

    CGImageRef cg = (__bridge CGImageRef)contents;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    CGSize s = self.bounds.size;
    BOOL isShape = [self isKindOfClass:CAShapeLayer.class];
    BOOL skip = GET(self, kImgView) || isShape || (self.masksToBounds && self.cornerRadius > 0) ||
                w < 8 || h < 8 || w > 192 || h > 192 || s.width > 48 || s.height > 48 ||
                (double)MIN(w, h) / (double)MAX(w, h) < 0.6;
    BOOL monoOK = !skip && !InBackdropLayer(self) && CGImageIsBlackMono(cg) == 1;
    if (!monoOK) {
        BOOL kbSize = w >= 8 && h >= 8 && w <= 400 && h <= 400 && s.width <= 220 && s.height <= 160;
        // Ban phim: nut xanh -> accent, bieu tuong den (Enter) -> accent, icon trang (qua dia cau) -> accent
        if (kbSize && !GET(self, kImgView) && !isShape && IsKeyboardLayer(self)) {
            CGImageRef k = KbRecolor(cg, WhiteOK(self));
            if (k) {
                int km = gLastKbMode;
                SET(self, kKbSrc, contents);
                if (km == 3) SET(self, kWhiteMark, @YES);
                %orig((__bridge id)k);
                FixDoubleTint(self);
                CGImageRelease(k);
                if (km == 3) {   // icon trang co the nam duoi nut accent (kinh lup tren nut Search) -> kiem tra lai
                    __weak CALayer *wl = self;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KbLate(wl); });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KbLate(wl); });
                }
                return;
            }
        }
        %orig;
        KbEnsureNotBlack(self);
        if (w <= 400 && h <= 400 && s.width <= 220 && s.height <= 160 && !isShape) {
            __weak CALayer *wl = self;
            dispatch_async(dispatch_get_main_queue(), ^{ KbLate(wl); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ KbLate(wl); });
        }
        return;
    }

    CGImageRef t = CopyTintedCG(cg, IconShapeColor(self));
    if (!t) { %orig; return; }
    SET(self, kContentsSrc, contents);
    %orig((__bridge id)t);
    FixDoubleTint(self);
    CGImageRelease(t);
    KillShadowUp(self, 2);
}
%end

%hook CATextLayer
- (void)setForegroundColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    CGColorRef n = LayerRemap(c, NULL);
    if (!n && gMaster && c && OnMain() && IsInkCG(c) && IsKeyboardLayer(self)) n = CGFor(NO);
    %orig(n ?: c);
}
%end

%hook CAShapeLayer
- (void)setFillColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    if (!gMaster || !c) { %orig; return; }
    CGColorRef n = LayerRemap(c, NULL);
    if (n) { %orig(n); return; }
    %orig;
    StripWhiteShapeOutline(self);
    if (!gInTry && IsInkCG(c)) ScheduleCheck(self, YES);
}
- (void)setStrokeColor:(CGColorRef)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    if (!gMaster || !c) { %orig; return; }
    CGColorRef n = LayerRemap(c, NULL);
    if (n) { %orig(n); return; }
    %orig;
    StripWhiteShapeOutline(self);
    if (!gInTry && IsInkCG(c)) ScheduleCheck(self, YES);
}
%end

%hook UISegmentedControl
- (void)setSelectedSegmentTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    UIColor *n = (gMaster && c && OnMain() && IsBlackColor(c)) ? gColor : nil;
    %orig(n ?: c);
}
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    if (gMaster && OnMain()) {
        UIColor *cur = self.selectedSegmentTintColor;
        if (cur && IsBlackColor(cur)) self.selectedSegmentTintColor = gColor;
    }
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    UIColor *n = ColorRemap(c, NULL);
    %orig(n ?: c);
}
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    if (self.window) { FixLabelBG(self); TabLabelFix(self); KbLabelFix(self); }
}
- (void)layoutSubviews {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    FixLabelBG(self);
    TabLabelFix(self);
}
%end

%hook UIButton
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    if (self.window && gMaster && OnMain() && ViewInKeyboard(self)) {
        UIColor *tc = [self titleColorForState:UIControlStateNormal];
        if (tc && IsInkColor(tc)) [self setTitleColor:gColor forState:UIControlStateNormal];
    }
}
- (void)setTitleColor:(UIColor *)c forState:(UIControlState)st {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    UIColor *n = ColorRemap(c, NULL);
    %orig(n ?: c, st);
}
- (void)setImage:(UIImage *)img forState:(UIControlState)st {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig(ImgChain(img), st);
}
%end

%hook UIBarButtonItem
- (void)setImage:(UIImage *)img {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig(ImgChain(img));
}
%end

%hook UIImageView
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    if (self.window) { KbImageFix(self); KbGlobeImageFix(self); }
}
- (void)setImage:(UIImage *)img {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    if (OnMain() && !GET(self.layer, kImgView)) SET(self.layer, kImgView, @YES);
    if (OnMain() && LooksLikeAvatarView(self)) { %orig(img); return; }
    UIImage *n = ImgChain(img);
    if (n && gMaster && OnMain()) {
        CGSize s = n.size;
        if (s.width <= 80 && s.height <= 80 && InTabBar(self)) n = TabColorize(n);
    }
    %orig(n);
    if (n && n != img && gMaster && OnMain()) KillShadowUp(self.layer, 2);   // icon da doi accent -> bo bong do
    if (self.window) { KbImageFix(self); KbGlobeImageFix(self); }
    if (n && GET(n, kInkImg) && gMaster && OnMain()) MarkInk(self.layer);
}
%end

%hook UIImage
- (UIImage *)imageWithTintColor:(UIColor *)c renderingMode:(UIImageRenderingMode)m {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    UIColor *n = IconTintFix(c);
    UIImage *o = %orig(n, m);
    if (o && c && n != c && OnMain()) SET(o, kInkImg, @YES);
    return o;
}
- (UIImage *)imageWithTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    UIColor *n = IconTintFix(c);
    UIImage *o = %orig(n);
    if (o && c && n != c && OnMain()) SET(o, kInkImg, @YES);
    return o;
}
%end

%hook UITabBar
- (void)layoutSubviews { %orig; TabBarFix(self); }
- (void)didMoveToWindow { %orig; if (self.window) TabBarFixLater(self); }
- (void)setSelectedItem:(UITabBarItem *)item { %orig; TabBarFixLater(self); }
- (void)traitCollectionDidChange:(UITraitCollection *)prev { %orig; TabBarFixLater(self); }
- (void)setUnselectedItemTintColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig((gMaster && c && OnMain() && IsInkColor(c)) ? gColor : c);
}
%end

%hook UITabBarItemStateAppearance
- (void)setIconColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig((gMaster && c && OnMain() && IsInkColor(c)) ? gColor : c);
}
- (void)setTitleTextAttributes:(NSDictionary<NSAttributedStringKey, id> *)attrs {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    if (gMaster && gColor && OnMain()) {
        NSMutableDictionary *m = attrs ? [attrs mutableCopy] : [NSMutableDictionary new];
        m[NSForegroundColorAttributeName] = gColor;
        attrs = m;
    }
    %orig(attrs);
}
%end

%hook UIImageSymbolConfiguration
+ (UIImageSymbolConfiguration *)configurationWithHierarchicalColor:(UIColor *)c {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    return %orig(IconTintFix(c));
}
+ (UIImageSymbolConfiguration *)configurationWithPaletteColors:(NSArray<UIColor *> *)colors {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
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
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig(gMaster ? gColor : c);
}
- (UIColor *)onTintColor {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    return gMaster ? gColor : %orig;
}
- (void)didMoveToWindow {
    if (gDepth > AAC_MAXDEPTH) { %orig; return; } AAC_DEPTH_SCOPE;
    %orig;
    TagControl(self);
    if (gMaster && OnMain()) self.onTintColor = gColor;
}
%end

%hook UIColor
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    return RemapRGBA(r, g, b, a) ?: %orig;
}
+ (UIColor *)colorWithDisplayP3Red:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    return RemapRGBA(r, g, b, a) ?: %orig;
}
- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    CGFloat nr = r, ng = g, nb = b, na = a;
    if (RemapComps(&nr, &ng, &nb, &na)) return %orig(nr, ng, nb, na);
    return %orig;
}
+ (UIColor *)systemBlueColor {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    if (gMaster && gColor) return gColor;
    return %orig;
}
+ (UIColor *)linkColor {
    if (gDepth > AAC_MAXDEPTH) return %orig; AAC_DEPTH_SCOPE;
    if (gMaster && gColor) return gColor;
    return %orig;
}
%end

static BOOL IsFacebookFamily(void) {
    NSBundle *b = NSBundle.mainBundle;
    NSString *bid = [b.bundleIdentifier lowercaseString] ?: @"";
    NSString *exe = [[b objectForInfoDictionaryKey:@"CFBundleExecutable"] lowercaseString] ?: @"";
    return [bid containsString:@"facebook"] || [bid containsString:@"messenger"] ||
           [exe isEqualToString:@"facebook"] || [exe isEqualToString:@"messenger"];
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
        StartSweep();
        StartGlobeSweep();
        // doi ngon ngu / ban phim -> chay loat luot quet bao ve de khong con chop den (moi app; Facebook chi quet qua dia cau/dock)
        [[NSNotificationCenter defaultCenter] addObserverForName:UITextInputCurrentInputModeDidChangeNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) { ScheduleKbGuard(); }];
    }
}

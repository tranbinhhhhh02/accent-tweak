#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#import <AVFoundation/AVFoundation.h>

// Gộp thành một màu: mọi nhóm cũ cùng trỏ về chỉ số 0.
typedef NS_ENUM(int, AACCat) { AACFill = 0, AACText = 0, AACIcon = 0, AACCount = 1 };

static NSString *const kMasterKey  = @"AccentColorAll_Enabled";
static NSString *const kHexKey     = @"AccentColorAll_Hex";
static NSString *const kBGKey      = @"AccentColorAll_BGKeepAlive";   // Background Keep-Alive, mặc định tắt
static NSString *const kDefaultHex = @"B8A8FF";

static const void *kFill        = &kFill;
static const void *kGestureFlag = &kGestureFlag;
static const void *kTintVer     = &kTintVer;
static const void *kIconShape   = &kIconShape;   // bit1 = fill, bit2 = stroke đã đổi
static const void *kMonoBlack   = &kMonoBlack;   // cache: UIImage là icon đen đơn sắc?
static const void *kAccentSrc   = &kAccentSrc;   // ảnh tab bar đã tô accent -> ảnh gốc
static const void *kAccentStamp = &kAccentStamp; // phiên bản màu đã dùng để tô

// Cache (ghi ở main thread, đọc ở mọi thread). Không bao giờ giải phóng giá trị cũ để tránh use-after-free.
static BOOL        gMaster = YES;
static BOOL        gOn[AACCount];
static UIColor    *gColor[AACCount];
static CGColorRef  gCGLight[AACCount], gCGDark[AACCount], gCGSoftLight[AACCount], gCGSoftDark[AACCount];
static BOOL        gDark = NO;
static int         gFillCount = 0;
static int         gVersion = 0;
static NSMutableArray *gKeep;
static BOOL        gInTry;            // chặn đệ quy khi tự set màu layer
static BOOL        gInTabFix;
static volatile int32_t gPending;     // số kiểm tra layer đang chờ ở main queue (giới hạn để không bị ngập)

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

static NSString *CurHex(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    // Hex_0 = màu "Nút & nền" của bản cũ (giữ lại khi nâng cấp)
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

// Vẽ lại các CAShapeLayer icon đã đổi màu (để đổi màu nhấn có hiệu lực ngay).
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

#pragma mark - Background Keep-Alive

// 1 giây WAV mono 8-bit 22050 Hz toàn mẫu 0x80 (im lặng), tạo trong bộ nhớ.
static NSData *SilentWav(void) {
    static NSData *wav; static dispatch_once_t once;
    dispatch_once(&once, ^{
        const uint32_t rate = 22050, n = 22050;
        NSMutableData *d = [NSMutableData dataWithCapacity:44 + n];
        uint32_t v32; uint16_t v16;
        [d appendBytes:"RIFF" length:4]; v32 = 36 + n; [d appendBytes:&v32 length:4];
        [d appendBytes:"WAVE" length:4];
        [d appendBytes:"fmt " length:4]; v32 = 16; [d appendBytes:&v32 length:4];
        v16 = 1; [d appendBytes:&v16 length:2];            // PCM
        v16 = 1; [d appendBytes:&v16 length:2];            // mono
        v32 = rate; [d appendBytes:&v32 length:4];         // sample rate
        v32 = rate; [d appendBytes:&v32 length:4];         // byte rate
        v16 = 1; [d appendBytes:&v16 length:2];            // block align
        v16 = 8; [d appendBytes:&v16 length:2];            // bits/sample
        [d appendBytes:"data" length:4]; v32 = n; [d appendBytes:&v32 length:4];
        [d increaseLengthBy:n];
        memset((uint8_t *)d.mutableBytes + 44, 0x80, n);
        wav = d;
    });
    return wav;
}

static BOOL HostDeclaresAudioBackground(void) {
    id modes = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
    return [modes isKindOfClass:NSArray.class] && [modes containsObject:@"audio"];
}

@interface AACBackgroundKeepAliveService : NSObject
+ (instancetype)shared;
+ (void)bootstrap;
@property (nonatomic, readonly) BOOL isRunning;
- (void)setEnabled:(BOOL)on;
- (void)startPlayingSilentAudio;
- (void)stopPlayingSilentAudio;
@end

@implementation AACBackgroundKeepAliveService {
    dispatch_queue_t _q;               // mọi thao tác AVAudioSession / AVAudioPlayer chạy ở đây (không chặn main)
    dispatch_source_t _timer;
    AVAudioPlayer *_player;
    volatile BOOL _enabled;
    volatile BOOL _inBackground;
    BOOL _observing;
    UIBackgroundTaskIdentifier _bgTask;
}

+ (instancetype)shared {
    static AACBackgroundKeepAliveService *k; static dispatch_once_t once;
    dispatch_once(&once, ^{
        k = [AACBackgroundKeepAliveService new];
        k->_q = dispatch_queue_create("acc.keepalive", DISPATCH_QUEUE_SERIAL);
        k->_bgTask = UIBackgroundTaskInvalid;
    });
    return k;
}

+ (void)bootstrap {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kBGKey]) [[self shared] setEnabled:YES];
}

- (BOOL)isRunning { return _enabled && _player.isPlaying; }

- (void)setEnabled:(BOOL)on {
    if (!OnMain()) { dispatch_async(dispatch_get_main_queue(), ^{ [self setEnabled:on]; }); return; }
    _enabled = on;
    if (on) {
        [self observe];
        [self armTimer];
        // Phải khởi động khi app đang ở foreground. Lúc app mới mở thì đợi DidBecomeActive để không chen vào quá trình khởi tạo.
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self startPlayingSilentAudio];
    } else {
        [self disarmTimer];
        [self stopPlayingSilentAudio];
        [self endBG];
    }
}

- (void)observe {
    if (_observing) return;
    _observing = YES;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(onInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    [nc addObserver:self selector:@selector(onRoute:)        name:AVAudioSessionRouteChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onReset:)        name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [nc addObserver:self selector:@selector(onResign:)       name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(onBackground:)   name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(onActive:)       name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)startPlayingSilentAudio {
    dispatch_async(_q, ^{ [self q_start]; });
}

- (void)stopPlayingSilentAudio {
    // Chỉ dừng player của mình; KHÔNG deactivate session vì sẽ cắt âm thanh của app gốc.
    dispatch_async(_q, ^{ [self->_player stop]; self->_player = nil; });
}

// --- chạy trên _q ---

// Chỉ can thiệp khi app đang dùng category không chạy được ở nền (mặc định / Ambient).
- (void)q_ensureCategory:(AVAudioSession *)s {
    NSString *cat = s.category;
    if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient] || [cat isEqualToString:AVAudioSessionCategoryAmbient]) {
        NSError *e = nil;
        [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
               options:AVAudioSessionCategoryOptionMixWithOthers error:&e];
    }
}

- (void)q_start {
    if (!_enabled) return;
    NSError *e = nil;
    AVAudioSession *s = AVAudioSession.sharedInstance;
    [self q_ensureCategory:s];
    if (!_player) {
        _player = [[AVAudioPlayer alloc] initWithData:SilentWav() fileTypeHint:AVFileTypeWAVE error:&e];
        _player.numberOfLoops = -1;
        _player.volume = 0.01;
        [_player prepareToPlay];
    }
    if (_player && !_player.isPlaying) {
        [s setActive:YES error:&e];
        [_player play];
    }
}

- (void)q_tick {
    if (!_enabled) return;
    if (!_player || !_player.isPlaying) { [self q_start]; return; }
    if (_inBackground) [self q_ensureCategory:AVAudioSession.sharedInstance];
}

// --- timer (trên _q) ---

- (void)armTimer {
    if (_timer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), 4 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(t, ^{ [ws q_tick]; });
    dispatch_resume(t);
    _timer = t;
}

- (void)disarmTimer {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
}

// --- background task (main) ---

- (void)beginBG {
    if (_bgTask != UIBackgroundTaskInvalid) return;
    _bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"AACKeepAlive" expirationHandler:^{
        [self endBG];
    }];
}

- (void)endBG {
    if (_bgTask == UIBackgroundTaskInvalid) return;
    [UIApplication.sharedApplication endBackgroundTask:_bgTask];
    _bgTask = UIBackgroundTaskInvalid;
}

// --- notification ---

- (void)onInterruption:(NSNotification *)n {
    NSUInteger t = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (t == AVAudioSessionInterruptionTypeEnded) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), _q, ^{ [self q_start]; });
    }
}
// Không đổi category khi route thay đổi (tránh "đánh nhau" với app gốc); chỉ bật lại player nếu nó đã dừng.
- (void)onRoute:(NSNotification *)n {
    dispatch_async(_q, ^{ if (self->_enabled && !self->_player.isPlaying) [self q_start]; });
}
- (void)onReset:(NSNotification *)n {
    dispatch_async(_q, ^{ self->_player = nil; [self q_start]; });
}
- (void)onResign:(NSNotification *)n {
    if (_enabled) [self startPlayingSilentAudio];
}
- (void)onBackground:(NSNotification *)n {
    if (!_enabled) return;
    _inBackground = YES;
    [self beginBG];
    [self startPlayingSilentAudio];
}
- (void)onActive:(NSNotification *)n {
    _inBackground = NO;
    [self endBG];
    if (_enabled) [self startPlayingSilentAudio];
}
@end

#pragma mark - Hỗ trợ hook

static void MarkFill(CALayer *l) {
    if (!OnMain()) return;                  // Facebook/Texture dựng layer ở thread nền
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

// CGColor xanh dương -> CGColor của nhóm cat (đã lưu sẵn, không giải phóng). NULL nếu không áp dụng.
// Hàm thuần (chỉ tính màu) nên an toàn ở mọi thread.
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

// UIColor xanh dương -> màu của nhóm cat. nil nếu không áp dụng. Chỉ gọi ở main thread.
static UIColor *ColorRemap(UIColor *c, int cat, int *clsOut) {
    if (!c || !gOn[cat]) return nil;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return nil;
    int cls = BlueClass(r, g, b);
    if (cls == 0) return nil;
    if (clsOut) *clsOut = cls;
    return cls == 2 ? [gColor[cat] colorWithAlphaComponent:0.2] : gColor[cat];
}

// Nền đen bo tròn cỡ nút/chip (vd nút ✓, thumb segmented, dấu + avatar) -> màu accent. Main thread.
static void TryBlack(CALayer *l) {
    if (!gOn[AACFill] || !OnMain()) return;
    CGColorRef bg = l.backgroundColor;
    if (!IsBlackCG(bg)) return;
    CGSize sz = l.bounds.size;
    if (sz.height < 14 || sz.height > 64 || sz.width < 14 || l.cornerRadius < 6) return;
    l.backgroundColor = CGFor(AACFill, NO);
    MarkFill(l);
}

// Thumb dạng pill vẽ bằng CAShapeLayer màu đen -> accent. Main thread.
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

// Icon vector (CAShapeLayer) đen cỡ nhỏ -> accent. Main thread.
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

// Thay cho hook setBounds/setCornerRadius/setPath (chạy mỗi frame, dễ gây crash):
// khi thấy layer đặt màu đen thì hẹn kiểm tra ở main queue (ngay + sau 0.2s khi layout xong).
static void ScheduleCheck(CALayer *l, BOOL shape) {
    if (!l || gPending > 96) return;
    void (^run)(void) = ^{
        if (shape && [l isKindOfClass:CAShapeLayer.class]) {
            TryBlackShape((CAShapeLayer *)l);
            TryBlackIconShape((CAShapeLayer *)l);
        } else {
            TryBlack(l);
        }
        __sync_fetch_and_sub(&gPending, 1);
    };
    __sync_fetch_and_add(&gPending, 2);
    dispatch_async(dispatch_get_main_queue(), run);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), run);
}

// UIImage nhỏ, nền trong suốt, toàn pixel đen (icon đã "nướng" màu đen, không phải template). Main thread.
static BOOL ImageIsBlackMono(UIImage *img) {
    NSNumber *cached = objc_getAssociatedObject(img, kMonoBlack);
    if (cached) return cached.boolValue;
    // Giới hạn số lần phân tích/giây: app animation (reaction Facebook...) tạo UIImage mới mỗi frame.
    static CFAbsoluteTime winStart; static int winCount;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - winStart > 1.0) { winStart = now; winCount = 0; }
    if (++winCount > 30) return NO;   // không cache -> thử lại sau
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
                int mxc = MAX(px[0], MAX(px[1], px[2]));   // premultiplied
                if (mxc * 255 > 40 * px[3]) { bad++; break; }
            }
            res = (solid >= 6 && clear >= 1 && bad == 0);
        }
    }
    objc_setAssociatedObject(img, kMonoBlack, @(res), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return res;
}

// Icon đen đơn sắc -> template để ăn tint.
static UIImage *IconRemapImage(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || !OnMain()) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.isSymbolImage) return img;
    CGSize sz = img.size;
    if (sz.width < 8 || sz.height < 8 || sz.width > 64 || sz.height > 64) return img;
    if (!ImageIsBlackMono(img)) return img;
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// App tự tô icon bằng màu đen (imageWithTintColor:) -> accent.
static UIColor *IconTintFix(UIColor *c) {
    if (gMaster && gOn[AACIcon] && c && OnMain() && IsBlackColor(c)) return gColor[AACIcon];
    return c;
}

#pragma mark - Tab bar

static BOOL InTabBar(UIView *v) {
    for (int i = 0; i < 10 && v; i++, v = v.superview)
        if ([v isKindOfClass:UITabBar.class]) return YES;
    return NO;
}

// Tô icon tab bar bằng accent (ảnh template / symbol / đen đơn sắc). Idempotent: ảnh đã tô được gắn nhãn.
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
        if (im) {
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TabBarFix(bar); });
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
    self.title = @"AccentColorAll";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 3 : 1; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"Màu nhấn" : @"Continuity & Access";
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1 && !HostDeclaresAudioBackground())
        return @"App này chưa khai báo UIBackgroundModes = audio nên chạy nền chỉ được khoảng 30 giây.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (ip.section == 1) return [self keepAliveCell];

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

- (UITableViewCell *)keepAliveCell {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    UIColor *acc = ColorFromHex(CurHex()) ?: ColorFromHex(kDefaultHex);
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *cv = cell.contentView;

    UIView *box = [UIView new];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = [acc colorWithAlphaComponent:0.15];
    box.layer.cornerRadius = 10;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hourglass" withConfiguration:cfg]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = acc;
    icon.contentMode = UIViewContentModeCenter;
    [box addSubview:icon];

    UILabel *title = [UILabel new];
    title.text = @"Background Keep-Alive";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    title.numberOfLines = 0;

    UILabel *desc = [UILabel new];
    desc.text = @"Keeps the audio session active while enabled; effectiveness depends on the host app's background audio support.";
    desc.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    desc.textColor = UIColor.secondaryLabelColor;
    desc.numberOfLines = 0;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[title, desc]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    UISwitch *sw = [UISwitch new];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.on = [d boolForKey:kBGKey];
    [sw addTarget:self action:@selector(keepAliveChanged:) forControlEvents:UIControlEventValueChanged];
    [sw setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [sw setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    [cv addSubview:box]; [cv addSubview:texts]; [cv addSubview:sw];
    UILayoutGuide *m = cv.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [box.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [box.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
        [box.widthAnchor constraintEqualToConstant:40],
        [box.heightAnchor constraintEqualToConstant:40],
        [icon.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [texts.leadingAnchor constraintEqualToAnchor:box.trailingAnchor constant:14],
        [texts.topAnchor constraintEqualToAnchor:cv.topAnchor constant:12],
        [texts.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-12],
        [texts.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-12],
        [sw.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [sw.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 0) return;
    if (ip.row == 1) [self editHex];
    else if (ip.row == 2) [self pickColor];
}

- (void)masterChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.isOn forKey:kMasterKey];
    ApplyAll();
}

- (void)keepAliveChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.isOn forKey:kBGKey];
    [[AACBackgroundKeepAliveService shared] setEnabled:sw.isOn];
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
    // Chỉ set tint của window khi màu đã đổi (tránh kích hoạt tintColorDidChange lan khắp cây view nhiều lần).
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
    if (!gMaster || !c || !OnMain()) { %orig; return; }
    int cls = 0;
    UIColor *n = ColorRemap(c, AACFill, &cls);
    %orig(n ?: c);
    if (n && cls == 1) MarkFill(self.layer);
    else if (!n && gOn[AACFill] && IsBlackColor(c)) ScheduleCheck(self.layer, NO);
}
%end

// Chỉ xử lý màu (hàm thuần) ngay trong setter; mọi thứ đọc/ghi trạng thái layer dời sang main queue.
%hook CALayer
- (void)setBackgroundColor:(CGColorRef)c {
    if (!gMaster || !c) { %orig; return; }
    int cls = 0;
    CGColorRef n = LayerRemap(c, AACFill, &cls);
    if (n) { %orig(n); if (cls == 1 && OnMain()) MarkFill(self); return; }
    %orig;
    if (gOn[AACFill] && IsBlackCG(c)) ScheduleCheck(self, NO);
}
- (void)setBorderColor:(CGColorRef)c {
    CGColorRef n = gMaster ? LayerRemap(c, AACFill, NULL) : NULL;
    if (n) { %orig(n); return; }
    %orig;
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

// Thanh chọn (segmented): thumb đen -> accent
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
    UIColor *n = (gMaster && OnMain()) ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c);
}
%end

%hook UIButton
- (void)setTitleColor:(UIColor *)c forState:(UIControlState)st {
    UIColor *n = (gMaster && OnMain()) ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c, st);
}
- (void)setImage:(UIImage *)img forState:(UIControlState)st {
    %orig(IconRemapImage(img), st);
}
%end

// Icon ảnh: đen đơn sắc -> template; icon trong tab bar -> tô accent
%hook UIImageView
- (void)setImage:(UIImage *)img {
    UIImage *n = IconRemapImage(img);
    if (n && gMaster && gOn[AACIcon] && OnMain()) {
        CGSize s = n.size;
        if (s.width <= 80 && s.height <= 80 && InTabBar(self)) n = TabColorize(n);
    }
    %orig(n);
}
%end

// Icon app tự tô đen bằng imageWithTintColor:
%hook UIImage
- (UIImage *)imageWithTintColor:(UIColor *)c renderingMode:(UIImageRenderingMode)m {
    return %orig(IconTintFix(c), m);
}
- (UIImage *)imageWithTintColor:(UIColor *)c {
    return %orig(IconTintFix(c));
}
%end

// Tab bar (iOS 26 Liquid Glass): đổi icon sang accent
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
%end

// Switch (nút gạt): luôn dùng accent, kể cả khi app (SwiftUI) tự set màu xanh lá
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
        [NSUserDefaults.standardUserDefaults registerDefaults:@{ kMasterKey: @YES, kBGKey: @NO }];
        RefreshCache();          // phải có màu trước khi hook hoạt động
        %init;
        [AACBackgroundKeepAliveService bootstrap];
    }
}

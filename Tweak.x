// AccentColorAll v4 - đổi màu nhấn cho mọi app khi inject dylib.
// Mở bảng cài đặt: nhấn giữ 3 ngón tay ~1 giây.
// MỘT màu nhấn duy nhất cho: nút, nền chip/pill, viền, switch, slider, chữ link, icon, nét vẽ vector.
// Cài đặt lưu riêng từng app (sandbox iOS).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#import <AVFoundation/AVFoundation.h>

// Gộp thành một màu: mọi nhóm cũ cùng trỏ về chỉ số 0.
typedef NS_ENUM(int, AACCat) { AACFill = 0, AACText = 0, AACIcon = 0, AACCount = 1 };

static NSString *const kMasterKey  = @"AccentColorAll_Enabled";
static NSString *const kDefaultHex = @"B8A8FF";
static const void *kFill           = &kFill;
static const void *kGestureFlag    = &kGestureFlag;
static const void *kIconShape      = &kIconShape;   // bit1 = fill, bit2 = stroke đã đổi
static const void *kMonoBlack      = &kMonoBlack;   // cache: UIImage là icon đen đơn sắc?

static NSString *const kHexKey = @"AccentColorAll_Hex";
static NSString *const kBGKey  = @"AccentColorAll_BGKeepAlive";   // chạy nền, mặc định tắt

// Cache (ghi ở main thread, đọc ở mọi thread). Không bao giờ giải phóng giá trị cũ để tránh use-after-free.
static BOOL        gMaster = YES;
static BOOL        gOn[AACCount];
static UIColor    *gColor[AACCount];
static CGColorRef  gCGLight[AACCount], gCGDark[AACCount], gCGSoftLight[AACCount], gCGSoftDark[AACCount];
static BOOL        gDark = NO;
static int         gFillCount = 0;
static NSMutableArray *gKeep;
static BOOL        gInTry;           // chặn đệ quy khi tự set màu layer

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
    gColor[0] = dyn;
    gCGLight[0] = CGColorCreateCopy(light.CGColor);
    gCGDark[0] = CGColorCreateCopy(dark.CGColor);
    gCGSoftLight[0] = CGColorCreateCopyWithAlpha(light.CGColor, 0.2);
    gCGSoftDark[0] = CGColorCreateCopyWithAlpha(dark.CGColor, 0.2);
    gOn[0] = gMaster;
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
    for (CALayer *sub in l.sublayers) RefreshLayerTree(sub, depth + 1);
}

static void RefreshViewTree(UIView *v, int depth) {
    if (depth > 40) return;
    if (gOn[AACFill]) {
        if ([v isKindOfClass:UISwitch.class]) ((UISwitch *)v).onTintColor = gColor[AACFill];
        else if ([v isKindOfClass:UISlider.class]) ((UISlider *)v).minimumTrackTintColor = gColor[AACFill];
    }
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
            RefreshLayerTree(w.layer, 0);
        }
    }
}

#pragma mark - Chạy nền (phát âm thanh im lặng để app không bị treo khi thoát / tắt màn hình)

// 1 giây WAV mono 8-bit 22050 Hz toàn mẫu 0x80 (im lặng) — cùng định dạng với Background Keep-Alive của IPATweaksPlus.
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

@interface AACKeepAlive : NSObject
+ (instancetype)shared;
- (void)setEnabled:(BOOL)on;
@end

@implementation AACKeepAlive {
    AVAudioPlayer *_player;
    NSTimer *_timer;
    UIBackgroundTaskIdentifier _bgTask;
    BOOL _enabled;
    BOOL _observing;
}

+ (instancetype)shared {
    static AACKeepAlive *k; static dispatch_once_t once;
    dispatch_once(&once, ^{ k = [AACKeepAlive new]; k->_bgTask = UIBackgroundTaskInvalid; });
    return k;
}

- (void)setEnabled:(BOOL)on {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self setEnabled:on]; }); return; }
    _enabled = on;
    if (on) { [self observe]; [self start]; }
    else    { [self stop]; }
}

- (void)observe {
    if (_observing) return;
    _observing = YES;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(onInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    [nc addObserver:self selector:@selector(onRoute:)        name:AVAudioSessionRouteChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onReset:)        name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [nc addObserver:self selector:@selector(onBackground:)   name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(onActive:)       name:UIApplicationDidBecomeActiveNotification object:nil];
}

// Phải khởi động khi app đang ở foreground; vào nền rồi mới bật thì iOS không cho.
- (void)start {
    if (!_enabled) return;
    NSError *e = nil;
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSString *cat = s.category;
    // Chỉ can thiệp khi app đang dùng category không chạy được ở nền (mặc định / Ambient); giữ nguyên PlayAndRecord, Playback...
    if ([cat isEqualToString:AVAudioSessionCategorySoloAmbient] || [cat isEqualToString:AVAudioSessionCategoryAmbient]) {
        [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e];
    }
    [s setActive:YES error:&e];
    if (!_player) {
        _player = [[AVAudioPlayer alloc] initWithData:SilentWav() error:&e];
        _player.numberOfLoops = -1;
        _player.volume = 0.01;
        [_player prepareToPlay];
    }
    if (_player && !_player.isPlaying) [_player play];
    if (!_timer) {
        _timer = [NSTimer timerWithTimeInterval:5.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

- (void)stop {
    [_timer invalidate]; _timer = nil;
    [_player stop]; _player = nil;
    [self endBG];
}

- (void)tick {
    if (!_enabled) return;
    if (!_player || !_player.isPlaying) [self start];
}

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

- (void)onInterruption:(NSNotification *)n {
    NSUInteger t = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (t == AVAudioSessionInterruptionTypeEnded) dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
}
- (void)onRoute:(NSNotification *)n { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); }
- (void)onReset:(NSNotification *)n { dispatch_async(dispatch_get_main_queue(), ^{ self->_player = nil; [self start]; }); }
- (void)onBackground:(NSNotification *)n { if (_enabled) { [self beginBG]; [self start]; } }
- (void)onActive:(NSNotification *)n { [self endBG]; [self start]; }
@end

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
    UIWindow *win = (UIWindow *)g.view;
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
    BOOL on = [d boolForKey:kMasterKey];
    NSString *cur = CurHex();

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Màu nhấn"
        message:[NSString stringWithFormat:@"%@%@",
            on ? [NSString stringWithFormat:@"Đang bật • #%@", cur] : @"Đang tắt",
            ([d boolForKey:kBGKey] && !HostDeclaresAudioBackground()) ? @"\nApp chưa khai báo UIBackgroundModes=audio: chạy nền chỉ được ~30 giây" : @""]
        preferredStyle:UIAlertControllerStyleAlert];
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
        [d setObject:HexFromColor(col) forKey:kHexKey];
        [d setBool:YES forKey:kMasterKey];
        ApplyAll();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Chọn màu…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self later:^{
            UIColorPickerViewController *p = [UIColorPickerViewController new];
            p.delegate = self;
            p.supportsAlpha = NO;
            p.selectedColor = ColorFromHex(cur) ?: ColorFromHex(kDefaultHex);
            [TopVC(win) presentViewController:p animated:YES completion:nil];
        }];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:on ? @"Tắt màu nhấn" : @"Bật màu nhấn" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [d setBool:!on forKey:kMasterKey];
        ApplyAll();
    }]];
    BOOL bg = [d boolForKey:kBGKey];
    [ac addAction:[UIAlertAction actionWithTitle:bg ? @"Chạy nền: bật (nhấn để tắt)" : @"Chạy nền: tắt (nhấn để bật)"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [d setBool:!bg forKey:kBGKey];
        [[AACKeepAlive shared] setEnabled:!bg];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)saveColor:(UIColor *)col {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:HexFromColor(col) forKey:kHexKey];
    [d setBool:YES forKey:kMasterKey];
    ApplyAll();
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)vc { [self saveColor:vc.selectedColor]; }
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc { [self saveColor:vc.selectedColor]; }
@end

#pragma mark - Hỗ trợ hook

static void MarkFill(CALayer *l) {
    if (![NSThread isMainThread]) return;   // Facebook/Texture dựng layer ở thread nền
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

// Thumb dạng pill vẽ bằng CAShapeLayer màu đen (vd thanh chọn 1x / 1.25x) -> màu "Nút & nền".
static void TryBlackShape(CAShapeLayer *sh) {
    if (!gOn[AACFill]) return;
    CGColorRef f = sh.fillColor;
    if (!f || CGColorGetAlpha(f) < 0.99) return;
    const CGFloat *c = CGColorGetComponents(f);
    if (!c) return;
    size_t n = CGColorGetNumberOfComponents(f);
    BOOL black = (n == 2) ? (c[0] < 0.03) : (n >= 4 && c[0] < 0.03 && c[1] < 0.03 && c[2] < 0.03);
    if (!black) return;
    CGPathRef path = sh.path;
    if (!path) return;
    CGRect b = CGPathGetBoundingBox(path);
    if (b.size.height < 20 || b.size.height > 64 || b.size.width < b.size.height * 1.6) return;
    if (![NSThread isMainThread]) return;
    sh.fillColor = CGFor(AACFill, NO);
}

static BOOL IsBlackColor(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return a >= 0.99 && r < 0.03 && g < 0.03 && b < 0.03;
}

static BOOL IsBlackCG(CGColorRef c) {
    if (!c || CGColorGetAlpha(c) < 0.99) return NO;
    const CGFloat *k = CGColorGetComponents(c);
    if (!k) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    if (n == 2) return k[0] < 0.03;
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    if (n < 4 || !cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) return NO;
    return k[0] < 0.03 && k[1] < 0.03 && k[2] < 0.03;
}

// Icon vector (CAShapeLayer) đen cỡ nhỏ (tab bar, nút…) -> màu nhóm "Icon".
static void TryBlackIconShape(CAShapeLayer *sh) {
    if (!gOn[AACIcon] || gInTry || ![NSThread isMainThread]) return;
    BOOL fill = IsBlackCG(sh.fillColor), stroke = IsBlackCG(sh.strokeColor);
    if (!fill && !stroke) return;
    CGPathRef path = sh.path;
    if (!path) return;
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

// UIImage nhỏ, nền trong suốt, toàn pixel đen (icon đã "nướng" màu đen, không phải template).
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
                if (mxc * 255 > 40 * px[3]) { bad++; break; }   // kênh lớn nhất (un-premult) > ~0.16
            }
            res = (solid >= 6 && clear >= 1 && bad == 0);
        }
    }
    objc_setAssociatedObject(img, kMonoBlack, @(res), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return res;
}

// Icon đen đơn sắc -> template để ăn tint (màu nhóm "Icon").
static UIImage *IconRemapImage(UIImage *img) {
    if (!img || !gMaster || !gOn[AACIcon] || ![NSThread isMainThread]) return img;
    if (img.renderingMode == UIImageRenderingModeAlwaysTemplate || img.isSymbolImage) return img;
    CGSize sz = img.size;
    if (sz.width < 8 || sz.height < 8 || sz.width > 64 || sz.height > 64) return img;
    if (!ImageIsBlackMono(img)) return img;
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// App tự tô icon bằng màu đen (imageWithTintColor:) -> đổi sang màu nhóm "Icon".
static UIColor *IconTintFix(UIColor *c) {
    if (gMaster && gOn[AACIcon] && c && IsBlackColor(c)) return gColor[AACIcon];
    return c;
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
- (void)setTintColor:(UIColor *)c {
    if (gMaster && c && IsBlackColor(c)) {
        int cat = TintCat(self);
        if (gOn[cat]) { %orig(gColor[cat]); return; }
    }
    %orig;
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
    if (gMaster) { TryBlackShape(self); TryBlackIconShape(self); }
}
- (void)setPath:(CGPathRef)p {
    %orig;
    if (gMaster) { TryBlackShape(self); TryBlackIconShape(self); }
}
- (void)setStrokeColor:(CGColorRef)c {
    CGColorRef n = gMaster ? LayerRemap(c, AACIcon, NULL) : NULL;
    if (n) { %orig(n); return; }
    %orig;
    if (gMaster) TryBlackIconShape(self);
}
%end

// Thanh chọn (segmented): thumb đen -> màu "Nút & nền"
%hook UISegmentedControl
- (void)setSelectedSegmentTintColor:(UIColor *)c {
    UIColor *n = (gMaster && gOn[AACFill] && c && IsBlackColor(c)) ? gColor[AACFill] : nil;
    %orig(n ?: c);
}
- (void)didMoveToWindow {
    %orig;
    if (gMaster && gOn[AACFill]) {
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
%end

%hook UIButton
- (void)setTitleColor:(UIColor *)c forState:(UIControlState)st {
    UIColor *n = gMaster ? ColorRemap(c, AACText, NULL) : nil;
    %orig(n ?: c, st);
}
- (void)setImage:(UIImage *)img forState:(UIControlState)st {
    %orig(IconRemapImage(img), st);
}
%end

// Icon ảnh: đen đơn sắc -> template
%hook UIImageView
- (void)setImage:(UIImage *)img {
    %orig(IconRemapImage(img));
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

// Switch (nút gạt): luôn dùng màu "Nút & nền", kể cả khi app (SwiftUI) tự set màu xanh lá
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
    if (gMaster && gOn[AACFill]) self.onTintColor = gColor[AACFill];
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
    [NSUserDefaults.standardUserDefaults registerDefaults:@{ kMasterKey: @YES, kBGKey: @NO }];
    RefreshCache();
    if ([NSUserDefaults.standardUserDefaults boolForKey:kBGKey]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [[AACKeepAlive shared] setEnabled:YES]; });
    }
}

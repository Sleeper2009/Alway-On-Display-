#import <UIKit/UIKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <objc/message.h>
/*
 =====================================================================
 LƯU Ý QUAN TRỌNG:
 Các class/selector dưới đây là API PRIVATE của SpringBoard, tên & chữ
 ký thay đổi giữa các phiên bản iOS. Bản này đã được đối chiếu lại theo
 một tweak AOD thật (LastLook) qua "strings"/"nm" trên dylib của nó:

   - SBBacklightController / fullyTurnOffScreen           -> XÁC NHẬN ĐÚNG
   - animateBacklightToFactor:duration:                   -> SAI, thật ra là
     animateBacklightToFactor:duration:source:silently:completion: (5 tham số)
   - SBLockScreenManager _dismissLockScreenAnimated:       -> KHÔNG thấy dùng,
     đã thay bằng NSNotification công khai (UIApplicationDidBecomeActive)
   - SBUIController batteryStateDidChange                  -> KHÔNG có thật,
     đã thay bằng UIDeviceBatteryStateDidChangeNotification (public API)
   - setStatusBarHidden: (UIApplication, deprecated)       -> đã thay bằng
     truy cập ivar "statusBar" qua KVC (kỹ thuật phổ biến, đáng tin cậy hơn
     trên các bản iOS mới)

 Vẫn nên tự class-dump SpringBoard đúng bản iOS bạn target để chắc chắn
 100%, đặc biệt là phần ẩn home indicator / tìm camera-flash view, vì 2
 phần đó chưa xác nhận được qua tweak tham khảo.
 =====================================================================
 */

#define kAODSuite @"com.yourname.aodtweak"
#define kAODModeKey @"AODMode"                    // 1,2,3
#define kAODBrightnessKey @"AODMode2Brightness"    // 0.0 - 1.0
#define kAODTimeoutKey @"AODTimeoutSeconds"        // NSInteger giây
#define kAODChargingKey @"AODAlwaysOnWhileCharging"// BOOL

// ============ Helper đọc settings ============

static NSUserDefaults *_aodDefaults = nil;
static dispatch_once_t _aodDefaultsOnce;

static NSUserDefaults *AODDefaults(void) {
    dispatch_once(&_aodDefaultsOnce, ^{
        _aodDefaults = [[NSUserDefaults alloc] initWithSuiteName:kAODSuite];
    });
    return _aodDefaults;
}

static NSInteger AODCurrentMode(void) {
    NSInteger mode = [AODDefaults() integerForKey:kAODModeKey];
    if (mode < 1 || mode > 3) mode = 1;
    return mode;
}

static CGFloat AODMode2Brightness(void) {
    id v = [AODDefaults() objectForKey:kAODBrightnessKey];
    return v ? [v floatValue] : 0.15f; // mặc định 15%
}

static NSInteger AODTimeoutSeconds(void) {
    id v = [AODDefaults() objectForKey:kAODTimeoutKey];
    return v ? [v integerValue] : 15; // mặc định 15s
}

static BOOL AODAlwaysOnWhileCharging(void) {
    id v = [AODDefaults() objectForKey:kAODChargingKey];
    return v ? [v boolValue] : NO;
}

static BOOL AODIsCharging(void) {
    UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;
    return (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull);
}

// mức backlight sàn cho mode 3 (gần như tắt hẳn nhưng vẫn "sáng" để panel không sleep)
static const CGFloat kAODFloorBacklight = 0.01f;

// ============ Helper gọi API backlight private đúng chữ ký ============

// Chữ ký thật: - (void)animateBacklightToFactor:(CGFloat)factor
//                                       duration:(double)duration
//                                         source:(NSInteger)source
//                                       silently:(BOOL)silently
//                                     completion:(void (^)(void))completion
static void AODAnimateBacklight(CGFloat factor, double duration) {
    Class backlightClass = NSClassFromString(@"SBBacklightController");
    if (!backlightClass) return;
    if (![backlightClass respondsToSelector:@selector(sharedInstance)]) return;

    id controller = [backlightClass performSelector:@selector(sharedInstance)];
    SEL sel = @selector(animateBacklightToFactor:duration:source:silently:completion:);
    if (!controller || ![controller respondsToSelector:sel]) {
        // fallback: nếu chữ ký khác trên bản iOS của bạn, thử lại API cũ 2 tham số
        SEL legacySel = @selector(animateBacklightToFactor:duration:);
        if (controller && [controller respondsToSelector:legacySel]) {
            ((void (*)(id, SEL, CGFloat, double))objc_msgSend)(
                controller, legacySel, factor, duration);
        }
        return;
    }

    void (^completion)(void) = ^{};
    ((void (*)(id, SEL, CGFloat, double, NSInteger, BOOL, id))objc_msgSend)(
        controller, sel, factor, duration, /*source*/ 0, /*silently*/ NO, completion);
}

// ============ AOD Manager: quản lý state, timer, overlay ============

@interface AODManager : NSObject
@property (nonatomic, strong) UIView *blackOverlay;
@property (nonatomic, strong) NSTimer *turnOffTimer;
@property (nonatomic, assign) BOOL aodActive;
+ (instancetype)shared;
- (void)enterAODIfNeeded;
- (void)exitAOD;
- (void)scheduleFullTurnOffTimer;
- (void)cancelTimer;
- (void)applyHiddenUIElements:(BOOL)hidden;
- (void)applyOverlayForMode:(NSInteger)mode;
@end

static AODManager *_sharedAODManager = nil;
static dispatch_once_t _sharedAODManagerOnce;

@implementation AODManager

+ (instancetype)shared {
    dispatch_once(&_sharedAODManagerOnce, ^{
        _sharedAODManager = [AODManager new];
    });
    return _sharedAODManager;
}

- (void)enterAODIfNeeded {
    NSInteger mode = AODCurrentMode();
    if (mode == 1) return; // stock, không can thiệp

    self.aodActive = YES;

    CGFloat targetFactor = (mode == 2) ? AODMode2Brightness() : kAODFloorBacklight;
    AODAnimateBacklight(targetFactor, 0.3);

    [self applyHiddenUIElements:YES];
    [self applyOverlayForMode:mode];
    [self scheduleFullTurnOffTimer];
}

- (void)exitAOD {
    self.aodActive = NO;
    [self cancelTimer];
    [self applyHiddenUIElements:NO];
    if (self.blackOverlay) {
        [UIView animateWithDuration:0.2 animations:^{
            self.blackOverlay.alpha = 0;
        } completion:^(BOOL finished) {
            [self.blackOverlay removeFromSuperview];
            self.blackOverlay = nil;
        }];
    }
}

- (void)scheduleFullTurnOffTimer {
    [self cancelTimer];

    if (AODAlwaysOnWhileCharging() && AODIsCharging()) {
        // Bỏ qua timer khi đang sạc: giữ AOD mãi
        return;
    }

    NSInteger timeout = AODTimeoutSeconds();
    if (timeout <= 0) return;

    self.turnOffTimer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                           target:self
                                                         selector:@selector(forceFullyTurnOff)
                                                         userInfo:nil
                                                          repeats:NO];
}

- (void)cancelTimer {
    [self.turnOffTimer invalidate];
    self.turnOffTimer = nil;
}

- (void)forceFullyTurnOff {
    self.aodActive = NO;
    [self applyHiddenUIElements:NO];
    if (self.blackOverlay) {
        [self.blackOverlay removeFromSuperview];
        self.blackOverlay = nil;
    }

    Class backlightClass = NSClassFromString(@"SBBacklightController");
    if (backlightClass) {
        id controller = [backlightClass respondsToSelector:@selector(sharedInstance)]
            ? [backlightClass performSelector:@selector(sharedInstance)]
            : nil;
        if (controller && [controller respondsToSelector:@selector(fullyTurnOffScreen)]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, @selector(fullyTurnOffScreen));
        }
    }
}

- (void)applyHiddenUIElements:(BOOL)hidden {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) return;

    // Ẩn status bar: truy cập ivar riêng qua KVC thay vì API deprecated
    // (setStatusBarHidden: không còn tác dụng thật trên iOS mới)
    @try {
        UIView *statusBar = [[UIApplication sharedApplication] valueForKey:@"statusBar"];
        if (statusBar) {
            statusBar.hidden = hidden;
            statusBar.alpha = hidden ? 0.0 : 1.0;
        }
    } @catch (__unused NSException *e) {
        // ivar không tồn tại trên bản iOS này -> bỏ qua an toàn
    }

    // Camera + flashlight button trên lock screen: tìm theo tên class chứa
    // "Camera"/"Flashlight"/"Torch". Cần đối chiếu lại bằng class-dump thật,
    // đây chỉ là suy đoán theo cấu trúc view thông thường.
    [self recursivelyHideCameraFlashInView:keyWindow hidden:hidden];
}

- (void)recursivelyHideCameraFlashInView:(UIView *)view hidden:(BOOL)hidden {
    for (UIView *sub in view.subviews) {
        NSString *className = NSStringFromClass([sub class]);
        if ([className containsString:@"Camera"] || [className containsString:@"Flashlight"] ||
            [className containsString:@"Torch"]) {
            sub.hidden = hidden;
            sub.alpha = hidden ? 0.0 : 1.0;
        }
        [self recursivelyHideCameraFlashInView:sub hidden:hidden];
    }
}

- (void)applyOverlayForMode:(NSInteger)mode {
    if (mode != 3) {
        if (self.blackOverlay) {
            [self.blackOverlay removeFromSuperview];
            self.blackOverlay = nil;
        }
        return;
    }

    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) return;

    if (!self.blackOverlay) {
        self.blackOverlay = [[UIView alloc] initWithFrame:keyWindow.bounds];
        self.blackOverlay.backgroundColor = [UIColor blackColor];
        self.blackOverlay.userInteractionEnabled = NO;
        self.blackOverlay.alpha = 0;
        [keyWindow addSubview:self.blackOverlay];
    }
    self.blackOverlay.frame = keyWindow.bounds;
    [keyWindow bringSubviewToFront:self.blackOverlay];

    [UIView animateWithDuration:0.25 animations:^{
        self.blackOverlay.alpha = 0.98; // gần tuyệt đối, không hoàn toàn 1.0 để tránh clip layer phía sau
    }];

    // Giờ/widget/thông báo cần đặt phía TRÊN overlay này (subview index cao hơn)
    // và set alpha ~0.4-0.6 cho chữ - thực hiện ở hook riêng nơi các view đó
    // được tạo/layout (chưa implement trong bản này).
}

@end

// ============ Hooks vào SpringBoard ============

// 1) Chặn fullyTurnOffScreen gốc, thay bằng logic AOD của chúng ta
//    (đã xác nhận class + selector này có thật qua tweak tham khảo)
%hook SBBacklightController

- (void)fullyTurnOffScreen {
    NSInteger mode = AODCurrentMode();
    if (mode == 1) {
        %orig; // Mode 1: hành vi gốc, không can thiệp
        return;
    }

    if (AODAlwaysOnWhileCharging() && AODIsCharging()) {
        [[AODManager shared] enterAODIfNeeded];
        return;
    }

    if (![AODManager shared].aodActive) {
        [[AODManager shared] enterAODIfNeeded];
    } else {
        %orig;
    }
}

%end

// 2) Theo dõi trạng thái sạc bằng NSNotification công khai thay vì hook
//    SBUIController batteryStateDidChange (selector này không tồn tại thật)
%ctor {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;

    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceBatteryStateDidChangeNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        if ([AODManager shared].aodActive) {
            [[AODManager shared] scheduleFullTurnOffTimer];
        }
    }];

    // Thoát AOD khi SpringBoard active trở lại (chạm màn hình / nhận cuộc gọi /
    // mở app...) - thay cho hook SBLockScreenManager không xác nhận được.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification *note) {
        if ([AODManager shared].aodActive) {
            [[AODManager shared] exitAOD];
        }
    }];
}

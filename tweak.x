#import <UIKit/UIKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <objc/message.h>
/*
 =====================================================================
 LƯU Ý QUAN TRỌNG:
 Các class/selector dưới đây (SBBacklightController, fullyTurnOffScreen,
 animateBacklightToFactor:, sharedWallpaperView, SBLockScreenManager,
 SBDashBoardViewController, camera/flashlight button view...) là API
 PRIVATE của SpringBoard, tên & chữ ký thay đổi giữa các phiên bản iOS.
 Trước khi build, hãy class-dump SpringBoard của đúng bản iOS bạn target
 (vd 14.x) và đối chiếu lại tên method/property/ivar bên dưới.
 File này viết theo đúng tên bạn liệt kê, nhưng có thể cần sửa selector.
 =====================================================================
 */

#define kAODSuite @"com.yourname.aodtweak"
#define kAODModeKey @"AODMode"                    // 1,2,3
#define kAODBrightnessKey @"AODMode2Brightness"    // 0.0 - 1.0
#define kAODTimeoutKey @"AODTimeoutSeconds"        // NSInteger giây
#define kAODChargingKey @"AODAlwaysOnWhileCharging"// BOOL

// ============ Helper đọc settings ============

// FIX: Dùng biến toàn cục thay vì static local để tránh __cxa_guard_acquire/release
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
    // Dùng UIDevice, đơn giản & đủ dùng trong SpringBoard process
    UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;
    return (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull);
}

// mức backlight sàn cho mode 3 (gần như tắt hẳn nhưng vẫn "sáng" để panel không sleep)
static const CGFloat kAODFloorBacklight = 0.01f;

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

// FIX: Dùng biến toàn cục thay vì static local trong +shared để tránh C++ guard symbols
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

    // Hạ backlight
    CGFloat targetFactor = (mode == 2) ? AODMode2Brightness() : kAODFloorBacklight;

    // TODO: gọi đúng API backlight thật, ví dụ:
    // [[%c(SBBacklightController) sharedInstance] animateBacklightToFactor:targetFactor
    //                                                              duration:0.3];
    Class backlightClass = NSClassFromString(@"SBBacklightController");
    if (backlightClass) {
        id controller = [backlightClass respondsToSelector:@selector(sharedInstance)]
            ? [backlightClass performSelector:@selector(sharedInstance)]
            : nil;
        if (controller && [controller respondsToSelector:@selector(animateBacklightToFactor:duration:)]) {
            ((void (*)(id, SEL, CGFloat, double))objc_msgSend)(
                controller, @selector(animateBacklightToFactor:duration:), targetFactor, 0.3);
        }
    }

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

    // TODO: gọi lại hàm tắt màn hình thật, ví dụ:
    // [[%c(SBBacklightController) sharedInstance] fullyTurnOffScreen];
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

    // Status bar
    // TODO: đúng API SB có thể là -[SBStatusBarController setStatusBarHidden:]
    [[UIApplication sharedApplication] setStatusBarHidden:hidden withAnimation:UIStatusBarAnimationFade];

    // Home indicator -> thường phải setNeedsUpdateOfHomeIndicatorAutoHidden trên
    // root view controller tương ứng, để %new hook riêng ở phần dưới.

    // Camera + flashlight button trên lock screen: tìm theo accessibilityIdentifier/class
    // vì đây là view riêng của SBDashBoardViewController / SBLockScreenViewController.
    // Ví dụ (cần chỉnh lại theo class-dump thật):
    Class dashboardClass = NSClassFromString(@"SBDashBoardViewController");
    if (dashboardClass) {
        // Duyệt subview để tìm nút camera/flash theo tag hoặc class name chứa "Camera"/"Flashlight"
        [self recursivelyHideCameraFlashInView:keyWindow hidden:hidden];
    }
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

    // Tìm sharedWallpaperView để che lên trên (tuỳ cấu trúc view hierarchy thật)
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
    // và set alpha ~0.4-0.6 cho chữ - thực hiện ở hook riêng bên dưới nơi
    // các view đó được tạo/layout (SBDashBoardViewController, notification views...).
}

@end

// ============ Hooks vào SpringBoard ============

// 1) Chặn fullyTurnOffScreen gốc, thay bằng logic AOD của chúng ta
%hook SBBacklightController

- (void)fullyTurnOffScreen {
    NSInteger mode = AODCurrentMode();
    if (mode == 1) {
        %orig; // Mode 1: hành vi gốc, không can thiệp
        return;
    }

    // Nếu đang sạc và bật "luôn hoạt động khi sạc" -> không tắt, vào AOD luôn
    if (AODAlwaysOnWhileCharging() && AODIsCharging()) {
        [[AODManager shared] enterAODIfNeeded];
        return;
    }

    if (![AODManager shared].aodActive) {
        // Lần đầu màn hình định tắt -> chuyển sang AOD thay vì tắt hẳn
        [[AODManager shared] enterAODIfNeeded];
    } else {
        // Đã ở AOD và timer đã chạy hết -> tắt hẳn thật sự
        %orig;
    }
}

%end

// 2) Theo dõi khi người dùng chạm màn hình / có notification mới -> thoát AOD tạm thời
//    rồi khi hết tương tác lại quay về AOD (tuỳ bạn muốn giữ nguyên hay không,
//    ở đây minh hoạ hook chạm màn hình đánh thức từ AOD).
%hook SBLockScreenManager

- (void)_dismissLockScreenAnimated:(BOOL)animated {
    if ([AODManager shared].aodActive) {
        [[AODManager shared] exitAOD];
    }
    %orig;
}

%end

// 3) Ẩn home indicator: hook root view controller lock screen
%hook SBLockScreenViewController

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([AODManager shared].aodActive && AODCurrentMode() != 1) {
        return YES;
    }
    return %orig;
}

%end

// 4) Theo dõi trạng thái sạc để huỷ/khởi động lại timer ngay khi cắm/rút sạc
%hook SBUIController

- (void)batteryStateDidChange {
    %orig;
    if ([AODManager shared].aodActive) {
        [[AODManager shared] scheduleFullTurnOffTimer];
    }
}

%end

%ctor {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
}

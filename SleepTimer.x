#import "YTLite.h"
#import "Utils/YTLSafeMode.h"

static __weak YTPlayerViewController *sleepPlayer;
static NSTimer *sleepTimer;
static NSDate *sleepFireDate;
static BOOL sleepEndOfVideo;
static const char kSleepGestureKey;

static void YTLSleepCancel(void) {
    [sleepTimer invalidate];
    sleepTimer = nil;
    sleepFireDate = nil;
    sleepEndOfVideo = NO;
}

static void YTLSleepNotify(NSString *message) {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    if (presenter) [[YTLClass(@"YTToastResponderEvent") eventWithMessage:message firstResponder:presenter] send];
}

static void YTLSleepFire(void) {
    YTLSleepCancel();
    YTPlayerViewController *player = sleepPlayer;
    if ([player respondsToSelector:@selector(pause)]) [player pause];
    YTLSleepNotify(LOC(@"SleepTimerDone"));
}

NSString *YTLSleepTimerStatus(void) {
    if (sleepEndOfVideo) return LOC(@"SleepTimerEndOfVideo");
    if (!sleepFireDate) return LOC(@"Disabled");
    NSInteger minutes = (NSInteger)ceil([sleepFireDate timeIntervalSinceNow] / 60.0);
    return [NSString stringWithFormat:LOC(@"SleepTimerLeft"), (long)MAX(minutes, 1)];
}

static void YTLSleepStart(NSInteger minutes) {
    YTLSleepCancel();
    if (minutes < 0) {
        sleepEndOfVideo = YES;
        YTLSleepNotify(LOC(@"SleepTimerEndOfVideo"));
        return;
    }
    if (minutes == 0) {
        YTLSleepNotify(LOC(@"SleepTimerOff"));
        return;
    }
    sleepFireDate = [NSDate dateWithTimeIntervalSinceNow:minutes * 60];
    sleepTimer = [NSTimer timerWithTimeInterval:minutes * 60 repeats:NO block:^(NSTimer *timer) { YTLSleepFire(); }];
    sleepTimer.tolerance = 2;
    [[NSRunLoop mainRunLoop] addTimer:sleepTimer forMode:NSRunLoopCommonModes];
    YTLSleepNotify([NSString stringWithFormat:LOC(@"SleepTimerSet"), (long)minutes]);
}

void YTLPresentSleepTimerMenu(UIViewController *presenter) {
    if (!presenter) presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    YTDefaultSheetController *sheet = [YTLClass(@"YTDefaultSheetController") sheetControllerWithParentResponder:nil];
    if (!sheet || !presenter) return;

    UIImage *icon = [UIImage systemImageNamed:@"moon.zzz"];
    BOOL active = sleepFireDate != nil || sleepEndOfVideo;
    if (active) {
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", LOC(@"SleepTimerOff"), YTLSleepTimerStatus()];
        [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:title iconImage:[UIImage systemImageNamed:@"xmark.circle"] style:0 handler:^{ YTLSleepStart(0); }]];
    }

    for (NSNumber *value in @[@10, @15, @30, @45, @60, @90]) {
        NSString *title = [NSString stringWithFormat:LOC(@"SleepTimerMinutes"), value.longValue];
        [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:title iconImage:icon style:0 handler:^{ YTLSleepStart(value.integerValue); }]];
    }
    [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"SleepTimerEndOfVideo") iconImage:[UIImage systemImageNamed:@"stop.circle"] style:0 handler:^{ YTLSleepStart(-1); }]];

    [sheet presentFromViewController:presenter animated:YES completion:nil];
}

static void YTLSleepTick(YTPlayerViewController *player, YTSingleVideoController *video, double time) {
    if (!player.view.window || [YTLValue(player, @"isPlayingAd") boolValue]) return;
    sleepPlayer = player;
    if (!sleepEndOfVideo) return;
    double total = [video respondsToSelector:@selector(totalMediaTime)] ? video.totalMediaTime : 0;
    if (total > 5 && time >= total - 0.6) YTLSleepFire();
}

@interface YTLSleepGestureTarget : NSObject
@end

@implementation YTLSleepGestureTarget
+ (instancetype)shared {
    static YTLSleepGestureTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTLSleepGestureTarget new]; });
    return target;
}

- (void)longPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || !ytlBool(@"sleepTimer")) return;
    YTLPresentSleepTimerMenu(nil);
}
@end

%hook YTPlayerViewController
- (void)potentiallyMutatedSingleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    @try { YTLSleepTick(self, video, time.time); } @catch (NSException *exception) {}
}

- (void)singleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time { // legacy
    %orig;
    @try { YTLSleepTick(self, video, time.time); } @catch (NSException *exception) {}
}
%end

%hook YTMainAppControlsOverlayView
- (void)layoutSubviews {
    %orig;
    if (!ytlBool(@"sleepTimer")) return;
    UIView *gear = YTLValue(self, @"_overflowButton");
    if (![gear isKindOfClass:[UIView class]] || objc_getAssociatedObject(gear, &kSleepGestureKey)) return;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:[YTLSleepGestureTarget shared] action:@selector(longPress:)];
    press.minimumPressDuration = 0.45;
    [gear addGestureRecognizer:press];
    objc_setAssociatedObject(gear, &kSleepGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end

%hook YTColdConfig
- (BOOL)enableSleepTimerClient { return ytlBool(@"sleepTimer") ? YES : %orig; }
- (BOOL)enableSleepTimerDurationLeftInOption { return ytlBool(@"sleepTimer") ? YES : %orig; }
%end

%ctor {
    if (YTLSafeModeActive()) return;
    %init;
}

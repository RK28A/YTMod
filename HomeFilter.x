#import "YTLite.h"
#import "Utils/YTLSafeMode.h"

static const char kFilterButtonKey;

@interface YTRightNavigationButtons (YTModulation)
- (YTQTMButton *)ytl_filterButton;
@end

static UIImage *YTLFilterIcon(void) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    BOOL active = ytlBool(@"filterShorts") || ytlBool(@"filterPolls");
    return [UIImage systemImageNamed:active ? @"line.3.horizontal.decrease.circle.fill" : @"line.3.horizontal.decrease.circle" withConfiguration:config];
}

static void YTLPresentFilterMenu(UIView *source) {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    YTDefaultSheetController *sheet = [YTLClass(@"YTDefaultSheetController") sheetControllerWithParentResponder:nil];
    if (!sheet || !presenter) return;

    NSArray <NSArray <NSString *> *> *filters = @[@[@"filterShorts", @"FilterShorts"], @[@"filterPolls", @"FilterPolls"]];
    for (NSArray <NSString *> *filter in filters) {
        NSString *key = filter[0];
        NSString *title = [NSString stringWithFormat:@"%@  %@", ytlBool(key) ? @"✓" : @"○", LOC(filter[1])];
        [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:title iconImage:nil style:0 handler:^{
            ytlSetBool(!ytlBool(key), key);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YTLFilterChanged" object:nil];
            [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"FilterRefresh") firstResponder:presenter] send];
        }]];
    }

    [sheet presentFromViewController:presenter animated:YES completion:nil];
}

@interface YTLFilterTarget : NSObject
+ (instancetype)shared;
@end

@implementation YTLFilterTarget
+ (instancetype)shared {
    static YTLFilterTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTLFilterTarget new]; });
    return target;
}

- (void)tapped:(UIButton *)sender {
    YTLPresentFilterMenu(sender);
}
@end

static NSArray *YTLWithFilterButton(YTRightNavigationButtons *container, NSArray *buttons) {
    if (!ytlBool(@"homeFilterBar") || ![buttons isKindOfClass:[NSArray class]]) return buttons;
    YTQTMButton *button = [container ytl_filterButton];
    if (!button || [buttons containsObject:button]) return buttons;
    NSMutableArray *result = [buttons mutableCopy];
    [result insertObject:button atIndex:0];
    return result;
}

%hook YTRightNavigationButtons
%new
- (YTQTMButton *)ytl_filterButton {
    YTQTMButton *button = objc_getAssociatedObject(self, &kFilterButtonKey);
    if (button) return button;

    button = [YTLClass(@"YTQTMButton") iconButton];
    if (!button) return nil;
    button.accessibilityLabel = LOC(@"Filters");
    button.accessibilityIdentifier = @"id.ytmodulation.filter.button";
    if ([button respondsToSelector:@selector(enableNewTouchFeedback)]) [button enableNewTouchFeedback];
    [button setImage:YTLFilterIcon() forState:UIControlStateNormal];
    [button addTarget:[YTLFilterTarget shared] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(self, &kFilterButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak YTQTMButton *weakButton = button;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"YTLFilterChanged" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakButton setImage:YTLFilterIcon() forState:UIControlStateNormal];
    }];
    return button;
}

- (NSArray *)buttons {
    return YTLWithFilterButton(self, %orig);
}

- (NSArray *)visibleButtons {
    return YTLWithFilterButton(self, %orig);
}

- (void)layoutSubviews {
    YTQTMButton *button = ytlBool(@"homeFilterBar") ? [self ytl_filterButton] : objc_getAssociatedObject(self, &kFilterButtonKey);
    if (ytlBool(@"homeFilterBar")) {
        if (button && button.superview != self) [self addSubview:button];
        button.hidden = NO;
    } else {
        button.hidden = YES;
    }

    %orig;

    if (!button || button.hidden) return;
    UIView *reference = self.notificationButton.superview == self && !self.notificationButton.hidden ? self.notificationButton : self.searchButton;
    if (CGRectIsEmpty(button.frame) && reference && !CGRectIsEmpty(reference.frame)) {
        CGRect frame = reference.frame;
        frame.origin.x = CGRectGetMinX(reference.frame) - CGRectGetWidth(frame);
        button.frame = frame;
    }
    button.tintColor = reference.tintColor ?: [UIColor labelColor];
}
%end

%ctor {
    if (YTLSafeModeActive()) return;
    %init;
}

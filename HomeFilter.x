#import "YTLite.h"
#import "Utils/YTLSafeMode.h"

static const NSInteger kHomeFilterTag = 7741;

@interface YTBrowseViewController : UIViewController
- (id)browseIdentifier;
@end

@interface YTLHomeFilterBar : UIView
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIStackView *panel;
@property (nonatomic, weak) UIResponder *responder;
@end

@implementation YTLHomeFilterBar

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.tag = kHomeFilterTag;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = 14;
    self.layer.masksToBounds = YES;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:blur];

    _toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    _toggleButton.tintColor = [UIColor labelColor];
    _toggleButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_toggleButton addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];

    _panel = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self rowWithTitle:LOC(@"FilterShorts") key:@"filterShorts"],
        [self rowWithTitle:LOC(@"FilterPolls") key:@"filterPolls"]
    ]];
    _panel.axis = UILayoutConstraintAxisVertical;
    _panel.spacing = 6;
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.hidden = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[_toggleButton, _panel]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 6;
    content.alignment = UIStackViewAlignmentFill;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor constraintEqualToAnchor:self.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
        [content.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
        [content.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [content.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_toggleButton.heightAnchor constraintEqualToConstant:28]
    ]];

    [self updateTitle];
    return self;
}

- (UIView *)rowWithTitle:(NSString *)title key:(NSString *)key {
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor labelColor];

    UISwitch *toggle = [UISwitch new];
    toggle.on = ytlBool(key);
    toggle.onTintColor = [UIColor colorWithRed:0.75 green:0.50 blue:0.90 alpha:1.0];
    toggle.accessibilityIdentifier = key;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (NSUInteger)activeCount {
    return (ytlBool(@"filterShorts") ? 1 : 0) + (ytlBool(@"filterPolls") ? 1 : 0);
}

- (void)updateTitle {
    NSUInteger count = [self activeCount];
    NSString *arrow = self.panel.hidden ? @"▾" : @"▴";
    NSString *title = count ? [NSString stringWithFormat:@"%@ (%lu) %@", LOC(@"Filters"), (unsigned long)count, arrow] : [NSString stringWithFormat:@"%@ %@", LOC(@"Filters"), arrow];
    [self.toggleButton setTitle:title forState:UIControlStateNormal];
}

- (void)toggle {
    [UIView animateWithDuration:0.2 animations:^{
        self.panel.hidden = !self.panel.hidden;
        [self.superview layoutIfNeeded];
    }];
    [self updateTitle];
}

- (void)switchChanged:(UISwitch *)sender {
    ytlSetBool(sender.on, sender.accessibilityIdentifier);
    [self updateTitle];
    [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"FilterRefresh") firstResponder:self.responder ?: [YTLClass(@"YTUIUtils") topViewControllerForPresenting]] send];
}

- (void)collapse {
    if (self.panel.hidden) return;
    self.panel.hidden = YES;
    [self updateTitle];
}

@end

static BOOL YTLIsHomeBrowse(YTBrowseViewController *controller) {
    id identifier = [controller respondsToSelector:@selector(browseIdentifier)] ? [controller browseIdentifier] : nil;
    NSString *string = [identifier isKindOfClass:[NSString class]] ? identifier : [identifier description];
    if (!string.length) {
        id endpoint = YTLValue(YTLValue(controller, @"navigationEndpoint"), @"browseEndpoint");
        string = YTLValue(endpoint, @"browseId");
    }
    return [string isKindOfClass:[NSString class]] && [string containsString:@"FEwhat_to_watch"];
}

%hook YTBrowseViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    YTLHomeFilterBar *bar = (YTLHomeFilterBar *)[self.view viewWithTag:kHomeFilterTag];
    if (!ytlBool(@"homeFilterBar") || !YTLIsHomeBrowse(self)) {
        [bar removeFromSuperview];
        return;
    }

    if (bar) {
        [self.view bringSubviewToFront:bar];
        return;
    }

    bar = [YTLHomeFilterBar new];
    bar.responder = self;
    [self.view addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12]
    ]];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    YTLHomeFilterBar *bar = (YTLHomeFilterBar *)[self.view viewWithTag:kHomeFilterTag];
    if ([bar isKindOfClass:[YTLHomeFilterBar class]]) [bar collapse];
}
%end

%ctor {
    if (YTLSafeModeActive()) return;
    %init;
}

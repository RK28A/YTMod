#import "YTLite.h"
#import "Utils/YTLSafeMode.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const kSBServer = @"https://sponsor.ajay.app";

static NSMutableDictionary <NSString *, NSArray <NSDictionary *> *> *sbSegments;
static NSMutableSet <NSString *> *sbPending;
static NSMutableSet <NSString *> *sbSkipped;
static NSMutableSet <NSString *> *sbIgnored;
static NSString *sbLastVideoID;
static NSString *sbMarkerVideoID;
static double sbMarkerDuration;
static NSHashTable *sbBarViews;

static void SBRefreshMarkers(void) {
    for (UIView *view in sbBarViews.allObjects) [view setNeedsLayout];
}

NSArray <NSString *> *YTLSponsorBlockCategories(void) {
    return @[@"sponsor", @"selfpromo", @"interaction", @"intro", @"outro", @"preview", @"music_offtopic", @"filler"];
}

NSInteger YTLSponsorBlockMode(NSString *category) {
    return ytlInt([@"sbMode_" stringByAppendingString:category]);
}

void YTLSetSponsorBlockMode(NSString *category, NSInteger mode) {
    ytlSetInt((int)mode, [@"sbMode_" stringByAppendingString:category]);
}

static void SBMigrateModes(void) {
    YTLUserDefaults *defaults = [YTLUserDefaults standardUserDefaults];
    for (NSString *category in YTLSponsorBlockCategories()) {
        NSString *modeKey = [@"sbMode_" stringByAppendingString:category];
        if ([defaults objectForKey:modeKey]) continue;
        [defaults setInteger:[defaults boolForKey:[@"sb_" stringByAppendingString:category]] ? 1 : 0 forKey:modeKey];
    }
}

static NSArray <NSString *> *SBEnabledCategories(void) {
    NSMutableArray *enabled = [NSMutableArray array];
    for (NSString *category in YTLSponsorBlockCategories()) {
        if (YTLSponsorBlockMode(category) != 0) [enabled addObject:category];
    }
    return enabled;
}

static NSString *SBHashPrefix(NSString *videoID) {
    NSData *data = [videoID dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSString stringWithFormat:@"%02x%02x", digest[0], digest[1]];
}

static void SBFetch(NSString *videoID) {
    NSArray *categories = SBEnabledCategories();
    if (categories.count == 0 || [sbPending containsObject:videoID]) return;
    [sbPending addObject:videoID];

    NSData *json = [NSJSONSerialization dataWithJSONObject:categories options:0 error:nil];
    NSString *categoriesParam = [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"%@/api/skipSegments/%@?categories=%@&actionType=skip", kSBServer, SBHashPrefix(videoID), [categoriesParam stringByReplacingOccurrencesOfString:@"," withString:@"%2C"]];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    [request setValue:@"YTLite" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray *segments = [NSMutableArray array];
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;

        if (data && status == 200) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]]) {
                for (NSDictionary *entry in parsed) {
                    if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"videoID"] isEqual:videoID]) continue;
                    for (NSDictionary *segment in entry[@"segments"]) {
                        if (![segment isKindOfClass:[NSDictionary class]]) continue;
                        NSArray *range = segment[@"segment"];
                        if (![range isKindOfClass:[NSArray class]] || range.count != 2) continue;
                        double start = [range[0] doubleValue], end = [range[1] doubleValue];
                        if (end - start < 0.5) continue;
                        [segments addObject:@{
                            @"start": @(start),
                            @"end": @(end),
                            @"category": segment[@"category"] ?: @"sponsor",
                            @"uuid": segment[@"UUID"] ?: [NSString stringWithFormat:@"%@-%f", videoID, start],
                            @"voteable": @([segment[@"UUID"] isKindOfClass:[NSString class]])
                        }];
                    }
                }
            }
        }

        [segments sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"start"] compare:b[@"start"]];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            [sbPending removeObject:videoID];
            sbSegments[videoID] = segments;
            if ([videoID isEqualToString:sbMarkerVideoID]) SBRefreshMarkers();
        });
    }] resume];
}

static NSString *SBCategoryName(NSString *category) {
    NSString *key = [@"SB_" stringByAppendingString:category];
    NSString *name = LOC(key);
    return [name isEqualToString:key] ? category : name;
}

static const NSInteger kSBSkipButtonTag = 9912;
static const NSInteger kSBToastTag = 9913;
static const double kSBLongSegment = 300;
static NSDictionary *sbPendingSegment;
static __weak YTPlayerViewController *sbButtonPlayer;

static void SBSeek(YTPlayerViewController *player, double time) {
    if ([player respondsToSelector:@selector(seekToTime:)]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(player, @selector(seekToTime:), (CGFloat)time);
    }
}

static NSDictionary *sbLastSkipped;
static __weak YTPlayerViewController *sbLastSkippedPlayer;

static NSString *SBUserID(void) {
    YTLUserDefaults *defaults = [YTLUserDefaults standardUserDefaults];
    NSString *userID = [defaults stringForKey:@"sbUserID"];
    if (userID.length < 30) {
        userID = [[[NSUUID UUID].UUIDString stringByAppendingString:[NSUUID UUID].UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
        [defaults setObject:userID forKey:@"sbUserID"];
    }
    return userID;
}

static void SBToast(NSString *message) {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    if (presenter) [[YTLClass(@"YTToastResponderEvent") eventWithMessage:message firstResponder:presenter] send];
}

static void SBVote(NSDictionary *segment, NSInteger type) {
    NSString *uuid = segment[@"uuid"];
    if (![uuid isKindOfClass:[NSString class]] || ![segment[@"voteable"] boolValue]) {
        SBToast(LOC(@"SBVoteFailed"));
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:[kSBServer stringByAppendingString:@"/api/voteOnSponsorTime"]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"UUID" value:uuid],
        [NSURLQueryItem queryItemWithName:@"userID" value:SBUserID()],
        [NSURLQueryItem queryItemWithName:@"type" value:[NSString stringWithFormat:@"%ld", (long)type]]
    ];
    if (!components.URL) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    request.HTTPMethod = @"POST";
    [request setValue:@"YTLite" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            SBToast(status == 200 ? LOC(@"SBVoteSent") : LOC(@"SBVoteFailed"));
        });
    }] resume];
}

static void SBUpdateSkipButton(YTPlayerViewController *player, NSDictionary *segment);

static void SBPresentSegmentMenu(YTPlayerViewController *player, NSDictionary *segment, BOOL skipped) {
    if (!segment) return;
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    YTDefaultSheetController *sheet = [YTLClass(@"YTDefaultSheetController") sheetControllerWithParentResponder:nil];
    if (!sheet || !presenter) return;

    if (skipped) {
        [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"SBUndoSkip") iconImage:[UIImage systemImageNamed:@"arrow.uturn.backward"] style:0 handler:^{
            [sbSkipped addObject:segment[@"uuid"]];
            SBSeek(player, [segment[@"start"] doubleValue]);
        }]];
    }
    [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"SBVoteDown") iconImage:[UIImage systemImageNamed:@"hand.thumbsdown"] style:0 handler:^{
        [sbIgnored addObject:segment[@"uuid"]];
        SBUpdateSkipButton(player, nil);
        if (skipped) SBSeek(player, [segment[@"start"] doubleValue]);
        SBVote(segment, 0);
    }]];
    [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"SBVoteUp") iconImage:[UIImage systemImageNamed:@"hand.thumbsup"] style:0 handler:^{
        SBVote(segment, 1);
    }]];
    [sheet presentFromViewController:presenter animated:YES completion:nil];
}

@interface YTLSBToastTarget : NSObject
@end

@implementation YTLSBToastTarget
+ (instancetype)shared {
    static YTLSBToastTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTLSBToastTarget new]; });
    return target;
}

- (void)tapped:(UITapGestureRecognizer *)gesture {
    gesture.view.hidden = YES;
    SBPresentSegmentMenu(sbLastSkippedPlayer, sbLastSkipped, YES);
}
@end

@interface YTLSponsorSkipButton : UIButton
@end

@implementation YTLSponsorSkipButton
- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.tag = kSBSkipButtonTag;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
    self.layer.cornerRadius = 16;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25].CGColor;
    self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.contentEdgeInsets = UIEdgeInsetsMake(7, 14, 7, 14);
    [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self addTarget:self action:@selector(skip) forControlEvents:UIControlEventTouchUpInside];
    [self addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)]];
    return self;
}

- (void)longPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) SBPresentSegmentMenu(sbButtonPlayer, sbPendingSegment, NO);
}

- (void)skip {
    YTPlayerViewController *player = sbButtonPlayer;
    NSDictionary *segment = sbPendingSegment;
    if (player && segment) {
        [sbSkipped addObject:segment[@"uuid"]];
        SBSeek(player, [segment[@"end"] doubleValue]);
    }
    sbPendingSegment = nil;
    [UIView animateWithDuration:0.2 animations:^{ self.alpha = 0; } completion:^(BOOL finished) { self.hidden = YES; }];
}
@end

static void SBUpdateSkipButton(YTPlayerViewController *player, NSDictionary *segment) {
    UIView *host = player.view;
    YTLSponsorSkipButton *button = (YTLSponsorSkipButton *)[host viewWithTag:kSBSkipButtonTag];

    if (!segment) {
        if (button && !button.hidden) {
            sbPendingSegment = nil;
            [UIView animateWithDuration:0.2 animations:^{ button.alpha = 0; } completion:^(BOOL finished) { button.hidden = YES; }];
        }
        return;
    }

    if (!host.window || ![host.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) return;

    if (![button isKindOfClass:[YTLSponsorSkipButton class]]) {
        button = [YTLSponsorSkipButton new];
        button.hidden = YES;
        [host addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.trailingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor constant:-16],
            [button.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:-56]
        ]];
    }

    sbButtonPlayer = player;
    if ([sbPendingSegment[@"uuid"] isEqual:segment[@"uuid"]] && !button.hidden) return;
    sbPendingSegment = segment;

    double length = [segment[@"end"] doubleValue] - [segment[@"start"] doubleValue];
    NSString *title = length > kSBLongSegment
        ? [NSString stringWithFormat:LOC(@"SBSkipLongButton"), SBCategoryName(segment[@"category"]), (long)round(length / 60)]
        : [NSString stringWithFormat:LOC(@"SBSkipButton"), SBCategoryName(segment[@"category"])];
    [button setTitle:title forState:UIControlStateNormal];
    [host bringSubviewToFront:button];
    button.alpha = 0;
    button.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ button.alpha = 1; }];
}

static void SBShowCenterToast(YTPlayerViewController *player, NSString *message) {
    UIView *host = player.view;
    if (!host.window || message.length == 0) return;

    UILabel *toast = (UILabel *)[host viewWithTag:kSBToastTag];
    if (![toast isKindOfClass:[UILabel class]]) {
        toast = [UILabel new];
        toast.tag = kSBToastTag;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        toast.textColor = [UIColor whiteColor];
        toast.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.numberOfLines = 2;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        toast.layer.cornerRadius = 18;
        toast.layer.masksToBounds = YES;
        toast.userInteractionEnabled = YES;
        [toast addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:[YTLSBToastTarget shared] action:@selector(tapped:)]];
        [host addSubview:toast];
        [NSLayoutConstraint activateConstraints:@[
            [toast.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
            [toast.centerYAnchor constraintEqualToAnchor:host.centerYAnchor],
            [toast.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor multiplier:0.8],
            [toast.heightAnchor constraintGreaterThanOrEqualToConstant:52]
        ]];
    }

    toast.text = [NSString stringWithFormat:@"   %@   \n   %@   ", message, LOC(@"SBTapToUndo")];
    [host bringSubviewToFront:toast];
    [toast.layer removeAllAnimations];
    toast.alpha = 0;
    toast.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; } completion:^(BOOL finished) {
        if (!finished) return;
        [UIView animateWithDuration:0.3 delay:2.6 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ toast.alpha = 0; } completion:^(BOOL done) {
            if (done) toast.hidden = YES;
        }];
    }];
}

static void SBTrackMarkers(YTPlayerViewController *player, YTSingleVideoController *video) {
    if (!player.view.window || ![player.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) return;
    NSString *videoID = player.contentVideoID;
    double duration = [video respondsToSelector:@selector(totalMediaTime)] ? video.totalMediaTime : 0;
    if (videoID.length == 0 || duration <= 0) return;
    if ([videoID isEqualToString:sbMarkerVideoID] && fabs(duration - sbMarkerDuration) < 0.5) return;
    sbMarkerVideoID = videoID;
    sbMarkerDuration = duration;
    SBRefreshMarkers();
}

static void SBHandleTime(YTPlayerViewController *player, double time) {
    if (!ytlBool(@"sponsorBlock")) return;
    if ([YTLValue(player, @"isPlayingAd") boolValue]) return;

    NSString *videoID = player.contentVideoID;
    if (videoID.length == 0) return;

    if (![videoID isEqualToString:sbLastVideoID]) {
        sbLastVideoID = videoID;
        [sbSkipped removeAllObjects];
        [sbIgnored removeAllObjects];
        if (sbSegments.count > 50) [sbSegments removeAllObjects];
    }

    NSArray *segments = sbSegments[videoID];
    if (!segments) {
        SBFetch(videoID);
        return;
    }

    NSDictionary *manual = nil;

    for (NSDictionary *segment in segments) {
        double start = [segment[@"start"] doubleValue], end = [segment[@"end"] doubleValue];
        if (time < start) break;
        if (time >= end - 0.35 || [sbIgnored containsObject:segment[@"uuid"]]) continue;

        NSInteger mode = YTLSponsorBlockMode(segment[@"category"]);
        if (mode == 0) continue;
        BOOL autoSkip = mode == 1 && end - start <= kSBLongSegment && ![sbSkipped containsObject:segment[@"uuid"]];
        if (!autoSkip) {
            if (!manual) manual = segment;
            continue;
        }

        [sbSkipped addObject:segment[@"uuid"]];
        SBSeek(player, end);
        SBUpdateSkipButton(player, nil);

        if (ytlBool(@"sbNotify")) {
            NSString *message = [NSString stringWithFormat:LOC(@"SBSkipped"), SBCategoryName(segment[@"category"])];
            sbLastSkipped = segment;
            sbLastSkippedPlayer = player;
            SBShowCenterToast(player, message);
        }
        return;
    }

    SBUpdateSkipButton(player, manual);
}

%hook YTPlayerViewController
- (void)potentiallyMutatedSingleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    @try {
        SBHandleTime(self, time.time);
        SBTrackMarkers(self, video);
    } @catch (NSException *exception) {}
}

- (void)singleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time { // legacy
    %orig;
    @try {
        SBHandleTime(self, time.time);
        SBTrackMarkers(self, video);
    } @catch (NSException *exception) {}
}
%end

static UIColor *SBCategoryColor(NSString *category) {
    static NSDictionary <NSString *, UIColor *> *colors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIColor *(^rgb)(CGFloat, CGFloat, CGFloat) = ^UIColor *(CGFloat r, CGFloat g, CGFloat b) {
            return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0];
        };
        colors = @{
            @"sponsor": rgb(0, 212, 0),
            @"selfpromo": rgb(255, 255, 0),
            @"interaction": rgb(204, 0, 255),
            @"intro": rgb(0, 255, 255),
            @"outro": rgb(2, 2, 237),
            @"preview": rgb(0, 143, 214),
            @"music_offtopic": rgb(255, 153, 0),
            @"filler": rgb(115, 0, 255)
        };
    });
    return colors[category] ?: colors[@"sponsor"];
}

static const char kSBMarkerLayerKey;
static const char kSBMarkerStateKey;

static BOOL SBIsWatchBar(UIView *barView) {
    if (!barView.window) return NO;
    Class watchClass = NSClassFromString(@"YTWatchView");
    for (UIView *view = barView.superview; view; view = view.superview) {
        NSString *name = NSStringFromClass([view class]);
        if ([name rangeOfString:@"Reel"].location != NSNotFound || [name rangeOfString:@"Shorts"].location != NSNotFound) return NO;
        if (watchClass && [view isKindOfClass:watchClass]) return YES;
    }
    return watchClass == nil;
}

static void SBLayoutMarkers(UIView *barView, CGRect barFrame) {
    CALayer *overlay = objc_getAssociatedObject(barView, &kSBMarkerLayerKey);
    NSArray *segments = sbMarkerVideoID ? sbSegments[sbMarkerVideoID] : nil;
    BOOL visible = ytlBool(@"sponsorBlock") && ytlBool(@"sbMarkers") && segments.count > 0 && sbMarkerDuration > 0 && CGRectGetWidth(barFrame) > 0 && !barView.hidden && SBIsWatchBar(barView);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (!visible) {
        overlay.hidden = YES;
        [CATransaction commit];
        return;
    }

    if (!overlay) {
        overlay = [CALayer layer];
        overlay.zPosition = 50;
        overlay.masksToBounds = YES;
        [barView.layer addSublayer:overlay];
        objc_setAssociatedObject(barView, &kSBMarkerLayerKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat height = MAX(CGRectGetHeight(barFrame), 3.0);
    CGRect frame = CGRectMake(CGRectGetMinX(barFrame), CGRectGetMidY(barFrame) - height / 2, CGRectGetWidth(barFrame), height);
    if (!CGRectEqualToRect(overlay.frame, frame)) overlay.frame = frame;
    overlay.hidden = NO;

    NSArray *enabled = SBEnabledCategories();
    NSString *state = [NSString stringWithFormat:@"%@|%.2f|%.1f|%.1f|%lu|%@", sbMarkerVideoID, sbMarkerDuration, CGRectGetWidth(frame), height, (unsigned long)segments.count, [enabled componentsJoinedByString:@","]];
    if ([objc_getAssociatedObject(barView, &kSBMarkerStateKey) isEqualToString:state]) {
        [CATransaction commit];
        return;
    }
    objc_setAssociatedObject(barView, &kSBMarkerStateKey, state, OBJC_ASSOCIATION_COPY_NONATOMIC);

    overlay.sublayers = nil;
    for (NSDictionary *segment in segments) {
        if (![enabled containsObject:segment[@"category"]]) continue;
        double start = MAX(0, [segment[@"start"] doubleValue]) / sbMarkerDuration;
        double end = MIN(sbMarkerDuration, [segment[@"end"] doubleValue]) / sbMarkerDuration;
        if (end <= start) continue;

        CALayer *layer = [CALayer layer];
        layer.backgroundColor = [SBCategoryColor(segment[@"category"]) colorWithAlphaComponent:0.9].CGColor;
        layer.frame = CGRectMake(floor(start * CGRectGetWidth(frame)), 0, MAX(2.0, ceil((end - start) * CGRectGetWidth(frame))), height);
        [overlay addSublayer:layer];
    }

    [CATransaction commit];
}

@interface YTModularPlayerBarView : UIView
@end

%hook YTModularPlayerBarView
- (void)layoutSubviews {
    %orig;
    @try {
        [sbBarViews addObject:self];
        NSValue *frameValue = YTLValue(self, @"barFrame");
        CGRect barFrame = frameValue ? frameValue.CGRectValue : CGRectZero;
        SBLayoutMarkers(self, barFrame);
    } @catch (NSException *exception) {}
}
%end

%ctor {
    if (YTLSafeModeActive()) return;

    sbSegments = [NSMutableDictionary dictionary];
    sbPending = [NSMutableSet set];
    sbSkipped = [NSMutableSet set];
    sbIgnored = [NSMutableSet set];
    sbBarViews = [NSHashTable weakObjectsHashTable];
    SBMigrateModes();

    %init;
}

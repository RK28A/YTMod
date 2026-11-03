#import "YTLite.h"
#import "Utils/YTLSafeMode.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const kSBServer = @"https://sponsor.ajay.app";

static NSMutableDictionary <NSString *, NSArray <NSDictionary *> *> *sbSegments;
static NSMutableSet <NSString *> *sbPending;
static NSMutableSet <NSString *> *sbSkipped;
static NSString *sbLastVideoID;
static NSString *sbMarkerVideoID;
static double sbMarkerDuration;
static NSHashTable *sbBarViews;
static const NSInteger kSBMarkerTag = 9911;

static void SBRefreshMarkers(void) {
    for (UIView *view in sbBarViews.allObjects) [view setNeedsLayout];
}

NSArray <NSString *> *YTLSponsorBlockCategories(void) {
    return @[@"sponsor", @"selfpromo", @"interaction", @"intro", @"outro", @"preview", @"music_offtopic", @"filler"];
}

static NSArray <NSString *> *SBEnabledCategories(void) {
    NSMutableArray *enabled = [NSMutableArray array];
    for (NSString *category in YTLSponsorBlockCategories()) {
        if (ytlBool([@"sb_" stringByAppendingString:category])) [enabled addObject:category];
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
                            @"uuid": segment[@"UUID"] ?: [NSString stringWithFormat:@"%@-%f", videoID, start]
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
            if (data || status == 404) sbSegments[videoID] = segments;
            if ([videoID isEqualToString:sbMarkerVideoID]) SBRefreshMarkers();
        });
    }] resume];
}

static NSString *SBCategoryName(NSString *category) {
    NSString *key = [@"SB_" stringByAppendingString:category];
    NSString *name = LOC(key);
    return [name isEqualToString:key] ? category : name;
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
        if (sbSegments.count > 50) [sbSegments removeAllObjects];
    }

    NSArray *segments = sbSegments[videoID];
    if (!segments) {
        SBFetch(videoID);
        return;
    }

    for (NSDictionary *segment in segments) {
        double start = [segment[@"start"] doubleValue], end = [segment[@"end"] doubleValue];
        if (time < start) break;
        if (time >= end - 0.35 || [sbSkipped containsObject:segment[@"uuid"]]) continue;

        [sbSkipped addObject:segment[@"uuid"]];

        if ([player respondsToSelector:@selector(seekToTime:)]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(player, @selector(seekToTime:), (CGFloat)end);
        } else {
            return;
        }

        if (ytlBool(@"sbNotify")) {
            NSString *message = [NSString stringWithFormat:LOC(@"SBSkipped"), SBCategoryName(segment[@"category"])];
            [[YTLClass(@"YTToastResponderEvent") eventWithMessage:message firstResponder:player] send];
        }
        return;
    }
}

%hook YTPlayerViewController
- (void)potentiallyMutatedSingleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    @try {
        SBHandleTime(self, time.time);
        SBTrackMarkers(self, video);
    } @catch (NSException *exception) {}
}

- (void)singleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
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

static void SBLayoutMarkers(UIView *barView, CGRect barFrame) {
    UIView *overlay = [barView viewWithTag:kSBMarkerTag];
    NSArray *segments = sbMarkerVideoID ? sbSegments[sbMarkerVideoID] : nil;

    if (!ytlBool(@"sponsorBlock") || !ytlBool(@"sbMarkers") || segments.count == 0 || sbMarkerDuration <= 0 || CGRectGetWidth(barFrame) <= 0) {
        overlay.hidden = YES;
        return;
    }

    if (!overlay) {
        overlay = [[UIView alloc] initWithFrame:CGRectZero];
        overlay.tag = kSBMarkerTag;
        overlay.userInteractionEnabled = NO;
        overlay.backgroundColor = [UIColor clearColor];
        [barView addSubview:overlay];
    }

    CGFloat height = MAX(CGRectGetHeight(barFrame), 3.0);
    overlay.frame = CGRectMake(CGRectGetMinX(barFrame), CGRectGetMidY(barFrame) - height / 2, CGRectGetWidth(barFrame), height);
    overlay.hidden = NO;
    [barView bringSubviewToFront:overlay];

    NSArray *enabled = SBEnabledCategories();
    for (CALayer *layer in [overlay.layer.sublayers copy]) [layer removeFromSuperlayer];

    for (NSDictionary *segment in segments) {
        if (![enabled containsObject:segment[@"category"]]) continue;
        double start = MAX(0, [segment[@"start"] doubleValue]) / sbMarkerDuration;
        double end = MIN(sbMarkerDuration, [segment[@"end"] doubleValue]) / sbMarkerDuration;
        if (end <= start) continue;

        CALayer *layer = [CALayer layer];
        layer.backgroundColor = [SBCategoryColor(segment[@"category"]) colorWithAlphaComponent:0.9].CGColor;
        layer.frame = CGRectMake(floor(start * CGRectGetWidth(barFrame)), 0, MAX(2.0, ceil((end - start) * CGRectGetWidth(barFrame))), height);
        [overlay.layer addSublayer:layer];
    }
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
    sbBarViews = [NSHashTable weakObjectsHashTable];

    %init;
}

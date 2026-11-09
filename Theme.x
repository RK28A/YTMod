#import "YTLite.h"
#import "Utils/YTLSafeMode.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

static NSString *const kThemeChanged = @"YTLThemeChanged";
static const NSInteger kThemeViewTag = 77310;
static NSDictionary *themeCache;
static double themeSurface = 0.55;

typedef NS_ENUM(NSInteger, YTLThemeAnim) { YTLThemeAnimNone, YTLThemeAnimScroll, YTLThemeAnimColors, YTLThemeAnimBoth };
typedef NS_ENUM(NSInteger, YTLThemeEffect) { YTLThemeEffectNone, YTLThemeEffectSnow, YTLThemeEffectRain, YTLThemeEffectStars, YTLThemeEffectBubbles };
typedef NS_ENUM(NSInteger, YTLThemeMode) { YTLThemeModeGradient, YTLThemeModePhoto, YTLThemeModeVideo };

#pragma mark - Config

static NSDictionary *YTLThemeDefaults(void) {
    return @{
        @"mode": @0, @"colors": @[@"#3A1C71", @"#D76D77", @"#FFAF7B"], @"third": @YES,
        @"style": @1, @"angle": @135, @"start": @0.0, @"softness": @1.0,
        @"anim": @0, @"speed": @1.0, @"reverse": @NO,
        @"effect": @0, @"density": @0.5, @"effectSpeed": @1.0,
        @"surface": @0.55, @"dim": @0.3
    };
}

static NSDictionary *YTLThemeConfig(void) {
    if (themeCache) return themeCache;
    NSMutableDictionary *config = [YTLThemeDefaults() mutableCopy];
    NSDictionary *saved = [[YTLUserDefaults standardUserDefaults] dictionaryForKey:@"themeConfig"];
    if ([saved isKindOfClass:[NSDictionary class]]) [config addEntriesFromDictionary:saved];
    themeCache = [config copy];
    themeSurface = [config[@"surface"] doubleValue];
    return themeCache;
}

static void YTLThemeSave(NSDictionary *config) {
    [[YTLUserDefaults standardUserDefaults] setObject:config forKey:@"themeConfig"];
    themeCache = [config copy];
    themeSurface = [config[@"surface"] doubleValue];
    [[NSNotificationCenter defaultCenter] postNotificationName:kThemeChanged object:nil];
}

static UIColor *YTLColorFromHex(NSString *hex) {
    NSString *clean = [([hex isKindOfClass:[NSString class]] ? hex : @"#000000") stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int value = 0;
    [[NSScanner scannerWithString:clean] scanHexInt:&value];
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0 green:((value >> 8) & 0xFF) / 255.0 blue:(value & 0xFF) / 255.0 alpha:1.0];
}

static NSString *YTLHexFromColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    UIColor *resolved = [color resolvedColorWithTraitCollection:[UITraitCollection currentTraitCollection]];
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0;
        [resolved getWhite:&white alpha:&a];
        r = g = b = white;
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)round(MIN(MAX(r, 0), 1) * 255), (int)round(MIN(MAX(g, 0), 1) * 255), (int)round(MIN(MAX(b, 0), 1) * 255)];
}

static NSURL *YTLThemeMediaDirectory(void) {
    NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [documents URLByAppendingPathComponent:@"YTModulation/Theme" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static NSURL *YTLThemeMediaURL(NSDictionary *config) {
    NSString *name = config[@"media"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;
    NSURL *url = [YTLThemeMediaDirectory() URLByAppendingPathComponent:name.lastPathComponent];
    return [[NSFileManager defaultManager] fileExistsAtPath:url.path] ? url : nil;
}

UIColor *YTLThemePaletteColor(NSInteger level, BOOL dark) {
    if (!ytlBool(@"themeEnabled")) return nil;
    static UIColor *cache[2][5];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (int d = 0; d < 2; d++) {
            CGFloat c = d ? 1 : 0;
            cache[d][0] = [UIColor colorWithRed:0 green:0 blue:0 alpha:0];
            cache[d][1] = [UIColor colorWithRed:c green:c blue:c alpha:0.08];
            cache[d][2] = [UIColor colorWithRed:c green:c blue:c alpha:0.13];
            cache[d][3] = [UIColor colorWithRed:c green:c blue:c alpha:0.18];
            CGFloat m = d ? 0.13 : 1;
            cache[d][4] = [UIColor colorWithRed:m green:m blue:m alpha:0.96];
        }
    });
    level = MIN(MAX(level, 0), 4);
    return cache[dark ? 1 : 0][level];
}

#pragma mark - Particles

static UIImage *YTLParticleImage(YTLThemeEffect effect) {
    CGSize size = effect == YTLThemeEffectRain ? CGSizeMake(3, 28) : CGSizeMake(24, 24);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        if (effect == YTLThemeEffectRain) {
            CGFloat locations[] = {0, 1};
            NSArray *colors = @[(id)[UIColor colorWithWhite:1 alpha:0].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.9].CGColor];
            CGGradientRef gradient = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)colors, locations);
            CGContextDrawLinearGradient(ctx, gradient, CGPointZero, CGPointMake(0, size.height), 0);
            CGGradientRelease(gradient);
        } else if (effect == YTLThemeEffectBubbles) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.85].CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeEllipseInRect(ctx, CGRectInset((CGRect){CGPointZero, size}, 2, 2));
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.5].CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(6, 6, 5, 5));
        } else {
            CGFloat locations[] = {0, 1};
            NSArray *colors = @[(id)[UIColor colorWithWhite:1 alpha:1].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
            CGGradientRef gradient = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)colors, locations);
            CGPoint center = CGPointMake(size.width / 2, size.height / 2);
            CGContextDrawRadialGradient(ctx, gradient, center, 0, center, size.width / 2, 0);
            CGGradientRelease(gradient);
        }
    }];
}

static CAEmitterCell *YTLParticleCell(YTLThemeEffect effect, double density, double speed) {
    CAEmitterCell *cell = [CAEmitterCell emitterCell];
    cell.contents = (__bridge id)YTLParticleImage(effect).CGImage;
    density = MIN(MAX(density, 0.05), 1);
    speed = MIN(MAX(speed, 0.2), 3);
    switch (effect) {
        case YTLThemeEffectSnow:
            cell.birthRate = 4 + 36 * density;
            cell.lifetime = 14 / speed;
            cell.velocity = 40 * speed;
            cell.velocityRange = 20 * speed;
            cell.yAcceleration = 6 * speed;
            cell.emissionLongitude = M_PI;
            cell.emissionRange = M_PI / 8;
            cell.scale = 0.35;
            cell.scaleRange = 0.25;
            cell.alphaRange = 0.4;
            cell.spinRange = 1;
            break;
        case YTLThemeEffectRain:
            cell.birthRate = 20 + 180 * density;
            cell.lifetime = 2.5 / speed;
            cell.velocity = 650 * speed;
            cell.velocityRange = 150 * speed;
            cell.emissionLongitude = M_PI;
            cell.scale = 0.8;
            cell.scaleRange = 0.3;
            cell.alphaRange = 0.5;
            cell.color = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
            break;
        case YTLThemeEffectStars:
            cell.birthRate = 2 + 18 * density;
            cell.lifetime = 4 / speed;
            cell.lifetimeRange = 2;
            cell.velocity = 0;
            cell.scale = 0.18;
            cell.scaleRange = 0.15;
            cell.alphaSpeed = -0.25 * speed;
            cell.scaleSpeed = -0.02;
            break;
        case YTLThemeEffectBubbles:
            cell.birthRate = 1 + 9 * density;
            cell.lifetime = 16 / speed;
            cell.velocity = 45 * speed;
            cell.velocityRange = 20 * speed;
            cell.emissionLongitude = -M_PI_2;
            cell.emissionRange = M_PI / 10;
            cell.xAcceleration = 3;
            cell.scale = 0.7;
            cell.scaleRange = 0.5;
            cell.alphaRange = 0.4;
            break;
        default:
            break;
    }
    return cell;
}

#pragma mark - Background view

@interface YTLThemeView : UIView
@property (nonatomic, strong) CALayer *container;
@property (nonatomic, strong) CAGradientLayer *gradient;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) CALayer *dimLayer;
@property (nonatomic, strong) CALayer *tintLayer;
@property (nonatomic, strong) CAEmitterLayer *emitter;
@property (nonatomic, assign) BOOL darkTint;
@property (nonatomic, strong) UIView *canvas;
@property (nonatomic, assign) BOOL windowAligned;
- (void)realign;
@property (nonatomic, copy) NSDictionary *config;
@property (nonatomic, copy) NSURL *loadedMedia;
@property (nonatomic, assign) CGSize builtSize;
@property (nonatomic, assign) BOOL followsSettings;
- (void)applyConfig:(NSDictionary *)config;
@end

@implementation YTLThemeView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor blackColor];

    _canvas = [[UIView alloc] initWithFrame:self.bounds];
    _canvas.userInteractionEnabled = NO;
    [self addSubview:_canvas];

    _container = [CALayer layer];
    _gradient = [CAGradientLayer layer];
    [_container addSublayer:_gradient];
    [_canvas.layer addSublayer:_container];

    _imageView = [[UIImageView alloc] initWithFrame:_canvas.bounds];
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _imageView.clipsToBounds = YES;
    _imageView.hidden = YES;
    [_canvas addSubview:_imageView];

    _dimLayer = [CALayer layer];
    _dimLayer.backgroundColor = [UIColor blackColor].CGColor;
    [_canvas.layer addSublayer:_dimLayer];

    _tintLayer = [CALayer layer];
    [_canvas.layer addSublayer:_tintLayer];

    _emitter = [CAEmitterLayer layer];
    [_canvas.layer addSublayer:_emitter];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)appDidBecomeActive {
    [self.player play];
    self.builtSize = CGSizeZero;
    [self setNeedsLayout];
}

- (void)appWillResignActive {
    [self.player pause];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [self.player play];
        self.builtSize = CGSizeZero;
        [self setNeedsLayout];
    }
}

- (void)applyConfig:(NSDictionary *)config {
    self.config = config;
    self.builtSize = CGSizeZero;
    [self setNeedsLayout];
}

- (NSArray *)baseColors {
    NSArray *hexes = [self.config[@"colors"] isKindOfClass:[NSArray class]] ? self.config[@"colors"] : YTLThemeDefaults()[@"colors"];
    NSUInteger count = [self.config[@"third"] boolValue] ? MIN(hexes.count, 3) : MIN(hexes.count, 2);
    NSMutableArray *colors = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [colors addObject:(id)YTLColorFromHex(hexes[i]).CGColor];
    if (colors.count == 0) [colors addObject:(id)[UIColor blackColor].CGColor];
    if (colors.count == 1) [colors addObject:colors[0]];
    return colors;
}

- (void)realign {
    CGRect frame = self.bounds;
    if (self.windowAligned && self.window) {
        CGPoint origin = [self convertPoint:CGPointZero toView:nil];
        frame = CGRectMake(-origin.x, -origin.y, CGRectGetWidth(self.window.bounds), CGRectGetHeight(self.window.bounds));
    }
    if (!CGRectEqualToRect(self.canvas.frame, frame)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.canvas.frame = frame;
        [CATransaction commit];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self realign];
    CGSize size = self.canvas.bounds.size;
    if (size.width <= 0 || size.height <= 0 || !self.config) return;
    if (CGSizeEqualToSize(size, self.builtSize)) return;
    self.builtSize = size;
    [self rebuild];
}

- (void)rebuild {
    NSDictionary *config = self.config;
    CGRect bounds = self.canvas.bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    CGFloat diagonal = ceil(hypot(width, height));
    YTLThemeMode mode = [config[@"mode"] integerValue];
    NSInteger style = [config[@"style"] integerValue];
    YTLThemeAnim anim = [config[@"anim"] integerValue];
    double speed = MIN(MAX([config[@"speed"] doubleValue], 0.1), 5);
    BOOL reverse = [config[@"reverse"] boolValue];
    double start = MIN(MAX([config[@"start"] doubleValue], 0), 1);
    double softness = MIN(MAX([config[@"softness"] doubleValue], 0), 1);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    [self.container removeAllAnimations];
    [self.gradient removeAllAnimations];
    self.container.hidden = mode != YTLThemeModeGradient;

    if (mode == YTLThemeModeGradient) {
        NSArray *base = [self baseColors];
        BOOL scroll = (anim == YTLThemeAnimScroll || anim == YTLThemeAnimBoth) && style == 1;
        BOOL cycle = anim == YTLThemeAnimColors || anim == YTLThemeAnimBoth;

        self.container.transform = CATransform3DIdentity;
        self.gradient.transform = CATransform3DIdentity;
        self.gradient.anchorPoint = CGPointMake(0.5, 0.5);

        if (style == 2) {
            self.gradient.type = kCAGradientLayerRadial;
            self.container.frame = bounds;
            CGFloat side = MAX(width, height) * 1.5;
            self.gradient.bounds = CGRectMake(0, 0, side, side);
            self.gradient.position = CGPointMake(width / 2, height * (0.15 + 0.7 * start));
            self.gradient.startPoint = CGPointMake(0.5, 0.5);
            self.gradient.endPoint = CGPointMake(1, 1);
        } else {
            self.gradient.type = kCAGradientLayerAxial;
            self.container.bounds = CGRectMake(0, 0, diagonal, diagonal);
            self.container.position = CGPointMake(width / 2, height / 2);
            self.container.transform = CATransform3DMakeRotation(([config[@"angle"] doubleValue] - 90) * M_PI / 180, 0, 0, 1);
            self.gradient.startPoint = CGPointMake(0, 0.5);
            self.gradient.endPoint = CGPointMake(1, 0.5);
        }

        NSArray *colors = base;
        NSArray *locations = nil;
        CGFloat period = 0;

        if (style == 0) {
            colors = @[base[0], base[0]];
        } else if (scroll) {
            NSMutableArray *pattern = [base mutableCopy];
            for (NSInteger i = (NSInteger)base.count - 2; i >= 1; i--) [pattern addObject:base[i]];
            period = diagonal * (0.6 + 1.4 * softness);
            NSInteger repeats = (NSInteger)ceil((diagonal + period) / period) + 1;
            NSMutableArray *full = [NSMutableArray array];
            for (NSInteger r = 0; r < repeats; r++) [full addObjectsFromArray:pattern];
            [full addObject:pattern[0]];
            colors = full;
            self.gradient.anchorPoint = CGPointMake(0, 0.5);
            self.gradient.bounds = CGRectMake(0, 0, period * repeats, diagonal);
            self.gradient.position = CGPointMake(0, diagonal / 2);
        } else {
            NSMutableArray *stops = [NSMutableArray array];
            for (NSUInteger i = 0; i < base.count; i++) {
                double value = start + MAX(softness, 0.02) * (1 - start) * i / (double)(base.count - 1);
                [stops addObject:@(MIN(value, 1))];
            }
            locations = stops;
            if (style != 2) self.gradient.frame = self.container.bounds;
        }

        if (style == 0 && style != 2) self.gradient.frame = self.container.bounds;
        if (style == 2) {
            NSMutableArray *stops = [NSMutableArray array];
            for (NSUInteger i = 0; i < colors.count; i++) [stops addObject:@(MIN(MAX(softness, 0.05) * i / (double)(colors.count - 1), 1))];
            locations = stops;
        }

        self.gradient.colors = colors;
        self.gradient.locations = locations;

        if (scroll) {
            CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position.x"];
            move.fromValue = @(reverse ? -period : 0);
            move.toValue = @(reverse ? 0 : -period);
            move.duration = 10.0 / speed;
            move.repeatCount = HUGE_VALF;
            move.removedOnCompletion = NO;
            [self.gradient addAnimation:move forKey:@"ytlScroll"];
        } else if (style == 2 && (anim == YTLThemeAnimScroll || anim == YTLThemeAnimBoth)) {
            CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            pulse.fromValue = @1.0;
            pulse.toValue = @1.35;
            pulse.duration = 6.0 / speed;
            pulse.autoreverses = YES;
            pulse.repeatCount = HUGE_VALF;
            pulse.removedOnCompletion = NO;
            pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [self.gradient addAnimation:pulse forKey:@"ytlPulse"];
        }

        if (cycle && style != 0 && base.count > 1) {
            NSMutableArray *values = [NSMutableArray array];
            NSUInteger count = base.count;
            for (NSUInteger shift = 0; shift <= count; shift++) {
                NSMutableArray *rotated = [NSMutableArray array];
                for (NSUInteger i = 0; i < colors.count; i++) {
                    NSUInteger index = [base indexOfObject:colors[i]];
                    if (index == NSNotFound) index = i % count;
                    NSInteger next = reverse ? ((NSInteger)index - (NSInteger)shift % (NSInteger)count + (NSInteger)count) % (NSInteger)count : (index + shift) % count;
                    [rotated addObject:base[next]];
                }
                [values addObject:rotated];
            }
            CAKeyframeAnimation *cycleAnimation = [CAKeyframeAnimation animationWithKeyPath:@"colors"];
            cycleAnimation.values = values;
            cycleAnimation.duration = 5.0 * count / speed;
            cycleAnimation.repeatCount = HUGE_VALF;
            cycleAnimation.removedOnCompletion = NO;
            [self.gradient addAnimation:cycleAnimation forKey:@"ytlCycle"];
        }
    }

    NSURL *media = mode == YTLThemeModeGradient ? nil : YTLThemeMediaURL(config);
    [self loadMedia:media mode:mode];

    self.dimLayer.frame = bounds;
    self.dimLayer.opacity = mode == YTLThemeModeGradient ? 0 : MIN(MAX([config[@"dim"] floatValue], 0), 0.95);
    self.tintLayer.frame = bounds;
    self.tintLayer.backgroundColor = self.darkTint ? [UIColor colorWithRed:0 green:0 blue:0 alpha:1].CGColor : [UIColor colorWithRed:1 green:1 blue:1 alpha:1].CGColor;
    self.tintLayer.opacity = MIN(MAX([config[@"surface"] floatValue], 0), 0.95);

    YTLThemeEffect effect = [config[@"effect"] integerValue];
    if (effect == YTLThemeEffectNone) {
        self.emitter.emitterCells = nil;
        self.emitter.hidden = YES;
    } else {
        self.emitter.hidden = NO;
        self.emitter.frame = bounds;
        switch (effect) {
            case YTLThemeEffectStars:
                self.emitter.emitterShape = kCAEmitterLayerRectangle;
                self.emitter.emitterPosition = CGPointMake(width / 2, height / 2);
                self.emitter.emitterSize = bounds.size;
                break;
            case YTLThemeEffectBubbles:
                self.emitter.emitterShape = kCAEmitterLayerLine;
                self.emitter.emitterPosition = CGPointMake(width / 2, height + 20);
                self.emitter.emitterSize = CGSizeMake(width, 1);
                break;
            default:
                self.emitter.emitterShape = kCAEmitterLayerLine;
                self.emitter.emitterPosition = CGPointMake(width / 2, -20);
                self.emitter.emitterSize = CGSizeMake(width * 1.2, 1);
                break;
        }
        self.emitter.emitterCells = @[YTLParticleCell(effect, [config[@"density"] doubleValue], [config[@"effectSpeed"] doubleValue])];
        self.emitter.beginTime = CACurrentMediaTime();
    }

    [CATransaction commit];
}

- (void)loadMedia:(NSURL *)url mode:(YTLThemeMode)mode {
    if ([url isEqual:self.loadedMedia]) {
        self.playerLayer.frame = self.canvas.bounds;
        return;
    }
    self.loadedMedia = url;
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
    self.imageView.image = nil;
    self.imageView.hidden = YES;
    if (!url) return;

    if (mode == YTLThemeModePhoto) {
        self.imageView.image = [UIImage imageWithContentsOfFile:url.path];
        self.imageView.hidden = NO;
        self.imageView.frame = self.canvas.bounds;
        return;
    }

    static AVQueuePlayer *sharedPlayer;
    static AVPlayerLooper *sharedLooper;
    static NSURL *sharedURL;
    if (![sharedURL isEqual:url]) {
        [sharedPlayer pause];
        sharedURL = url;
        sharedPlayer = [AVQueuePlayer queuePlayerWithItems:@[]];
        sharedPlayer.muted = YES;
        sharedPlayer.preventsDisplaySleepDuringVideoPlayback = NO;
        if ([sharedPlayer respondsToSelector:@selector(setAudiovisualBackgroundPlaybackPolicy:)]) [sharedPlayer setValue:@2 forKey:@"audiovisualBackgroundPlaybackPolicy"];
        sharedLooper = [AVPlayerLooper playerLooperWithPlayer:sharedPlayer templateItem:[AVPlayerItem playerItemWithURL:url]];
    }
    self.player = sharedPlayer;
    self.looper = sharedLooper;
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:sharedPlayer];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = self.canvas.bounds;
    [self.canvas.layer insertSublayer:self.playerLayer below:self.dimLayer];
    if (self.window) [sharedPlayer play];
}

@end

#pragma mark - Install in the app

static NSHashTable <YTLThemeView *> *themeBackdrops;
static const char kThemeOriginalColorKey;

static void YTLThemeBackdrop(UIView *host, BOOL dark) {
    if (![host isKindOfClass:[UIView class]]) return;
    YTLThemeView *existing = nil;
    for (UIView *subview in host.subviews) {
        if (subview.tag == kThemeViewTag && [subview isKindOfClass:[YTLThemeView class]]) {
            existing = (YTLThemeView *)subview;
            break;
        }
    }
    if (!ytlBool(@"themeEnabled")) {
        if (existing) {
            [existing removeFromSuperview];
            id original = objc_getAssociatedObject(host, &kThemeOriginalColorKey);
            if (original) host.backgroundColor = [original isKindOfClass:[UIColor class]] ? original : nil;
            objc_setAssociatedObject(host, &kThemeOriginalColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!existing) {
        if (!objc_getAssociatedObject(host, &kThemeOriginalColorKey)) objc_setAssociatedObject(host, &kThemeOriginalColorKey, host.backgroundColor ?: (id)[NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        existing = [[YTLThemeView alloc] initWithFrame:host.bounds];
        existing.tag = kThemeViewTag;
        existing.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        existing.darkTint = dark;
        existing.windowAligned = YES;
        [host insertSubview:existing atIndex:0];
        [existing applyConfig:YTLThemeConfig()];
        if (!themeBackdrops) themeBackdrops = [NSHashTable weakObjectsHashTable];
        [themeBackdrops addObject:existing];
    } else {
        if (existing.darkTint != dark) {
            existing.darkTint = dark;
            [existing applyConfig:YTLThemeConfig()];
        }
        if (host.subviews.firstObject != existing) [host sendSubviewToBack:existing];
        if (!CGRectEqualToRect(existing.frame, host.bounds)) existing.frame = host.bounds;
        [existing realign];
    }
    if (host.backgroundColor && CGColorGetAlpha(host.backgroundColor.CGColor) > 0) host.backgroundColor = [UIColor clearColor];
}

static BOOL YTLHostIsDark(UIView *host) {
    id style = YTLValue(host, @"pageStyle");
    if ([style respondsToSelector:@selector(integerValue)]) return [style integerValue] == 1;
    return host.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight;
}

static void YTLThemeRefreshAll(void) {
    for (YTLThemeView *view in [themeBackdrops allObjects]) [view applyConfig:YTLThemeConfig()];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) [window.rootViewController.viewIfLoaded setNeedsLayout];
    }
}

static BOOL YTLIsPageColor(UIColor *color) {
    if (!color) return NO;
    CGFloat h = 0, sat = 0, b = 0, a = 0;
    if (![color getHue:&h saturation:&sat brightness:&b alpha:&a]) {
        CGFloat w = 0;
        if (![color getWhite:&w alpha:&a]) return NO;
        b = w;
        sat = 0;
    }
    return a > 0.9 && sat < 0.25 && (b < 0.16 || b > 0.95);
}

static BOOL YTLSkipThemeClear(UIView *view) {
    if ([view isKindOfClass:[YTLThemeView class]] || [view isKindOfClass:[UIImageView class]] || [view isKindOfClass:[UIVisualEffectView class]] || [view isKindOfClass:[UIControl class]]) return YES;
    NSString *name = NSStringFromClass([view class]);
    for (NSString *word in @[@"Player", @"Video", @"Thumbnail", @"Image", @"Avatar", @"Keyboard", @"Camera", @"Glass", @"Reel", @"Shorts"]) {
        if ([name rangeOfString:word].location != NSNotFound) return YES;
    }
    return NO;
}

static void YTLClearPageBackgrounds(UIView *root) {
    CGSize rootSize = root.bounds.size;
    if (rootSize.width <= 0 || rootSize.height <= 0) return;
    NSMutableArray <UIView *> *queue = [NSMutableArray arrayWithArray:root.subviews];
    NSMutableArray <NSNumber *> *depths = [NSMutableArray array];
    for (NSUInteger i = 0; i < queue.count; i++) [depths addObject:@1];
    NSUInteger visited = 0;
    while (queue.count && visited < 600) {
        UIView *view = queue.firstObject;
        NSInteger depth = depths.firstObject.integerValue;
        [queue removeObjectAtIndex:0];
        [depths removeObjectAtIndex:0];
        visited++;
        if (view.hidden || YTLSkipThemeClear(view)) continue;

        CGSize size = view.bounds.size;
        if (size.width >= rootSize.width * 0.85 && size.height >= rootSize.height * 0.2 && YTLIsPageColor(view.backgroundColor)) {
            view.backgroundColor = [UIColor clearColor];
            id node = YTLValue(view, @"asyncdisplaykit_node");
            if ([node respondsToSelector:@selector(setBackgroundColor:)]) [node setBackgroundColor:[UIColor clearColor]];
        }
        if (depth >= 16 || size.width < rootSize.width * 0.5) continue;
        for (UIView *subview in view.subviews) {
            [queue addObject:subview];
            [depths addObject:@(depth + 1)];
        }
    }
}

static const char kThemeClearTimeKey;

static void YTLThemeClearIfNeeded(UIView *root) {
    if (!ytlBool(@"themeEnabled")) return;
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *last = objc_getAssociatedObject(root, &kThemeClearTimeKey);
    if (last && now - last.doubleValue < 0.4) return;
    objc_setAssociatedObject(root, &kThemeClearTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTLClearPageBackgrounds(root);
}

%hook YTAppView
- (void)layoutSubviews {
    %orig;
    YTLThemeBackdrop((UIView *)(id)self, YTLHostIsDark((UIView *)(id)self));
    YTLThemeClearIfNeeded((UIView *)(id)self);
}
%end

%hook YTWatchView
- (void)layoutSubviews {
    %orig;
    YTLThemeBackdrop((UIView *)(id)self, YTLHostIsDark((UIView *)(id)self));
    YTLThemeClearIfNeeded((UIView *)(id)self);
}
%end

%hook YTHeaderView
- (void)layoutSubviews {
    %orig;
    YTLThemeBackdrop((UIView *)(id)self, ((UIView *)(id)self).traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight);
}
%end

%hook YTSettingsViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!ytlBool(@"themeEnabled")) return;
    UIView *view = ((UIViewController *)(id)self).viewIfLoaded;
    YTLThemeBackdrop(view, view.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight);
    UIView *collection = YTLValue(self, @"collectionView");
    if ([collection isKindOfClass:[UIView class]]) collection.backgroundColor = [UIColor clearColor];
    if (view) YTLClearPageBackgrounds(view);
}
%end

%hook YTEngagementPanelView
- (void)layoutSubviews {
    %orig;
    YTLThemeBackdrop(self, self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight);
}
%end

#pragma mark - Editor

@interface YTLThemeEditorViewController : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) NSMutableDictionary *config;
@property (nonatomic, strong) YTLThemeView *preview;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) NSMutableDictionary <NSString *, UILabel *> *valueLabels;
@property (nonatomic, strong) NSMutableDictionary <NSString *, UIView *> *controls;
@property (nonatomic, strong) NSMutableArray <UIView *> *colorWells;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UIButton *mediaButton;
@end

@implementation YTLThemeEditorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"CustomTheme");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.config = [YTLThemeConfig() mutableCopy];
    self.valueLabels = [NSMutableDictionary dictionary];
    self.controls = [NSMutableDictionary dictionary];
    self.colorWells = [NSMutableArray array];

    self.preview = [[YTLThemeView alloc] initWithFrame:CGRectZero];
    self.preview.translatesAutoresizingMaskIntoConstraints = NO;
    self.preview.layer.cornerRadius = 18;
    self.preview.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:self.preview];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 10;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.preview.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.preview.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.preview.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.preview.heightAnchor constraintEqualToConstant:170],
        [scroll.topAnchor constraintEqualToAnchor:self.preview.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16]
    ]];

    [self buildRows];
    [self refresh:NO];
}

- (UIView *)card:(NSArray <UIView *> *)rows {
    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:rows];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 12;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 14;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14]
    ]];
    return card;
}

- (UILabel *)header:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = [text uppercaseString];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    return label;
}

- (UIView *)row:(NSString *)title control:(UIView *)control {
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:16];
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    return row;
}

- (UIView *)segmentedFor:(NSString *)key items:(NSArray <NSString *> *)items {
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:items];
    control.accessibilityIdentifier = key;
    [control addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.controls[key] = control;
    return control;
}

- (UIView *)sliderFor:(NSString *)key title:(NSString *)title min:(float)min max:(float)max {
    UISlider *slider = [UISlider new];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.accessibilityIdentifier = key;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    self.controls[key] = slider;

    UILabel *name = [UILabel new];
    name.text = title;
    name.font = [UIFont systemFontOfSize:15];
    UILabel *value = [UILabel new];
    value.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    value.textColor = [UIColor secondaryLabelColor];
    value.textAlignment = NSTextAlignmentRight;
    [value setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.valueLabels[key] = value;

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[name, value]];
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[top, slider]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 4;
    return column;
}

- (UIView *)colorRow {
    UIStackView *row = [UIStackView new];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    Class wellClass = NSClassFromString(@"UIColorWell");
    for (NSInteger i = 0; i < 3; i++) {
        UIControl *well = wellClass ? [[wellClass alloc] initWithFrame:CGRectMake(0, 0, 36, 36)] : nil;
        if (!well) continue;
        well.tag = i;
        [well setValue:@NO forKey:@"supportsAlpha"];
        [well addTarget:self action:@selector(colorChanged:) forControlEvents:UIControlEventValueChanged];
        [well.widthAnchor constraintEqualToConstant:36].active = YES;
        [well.heightAnchor constraintEqualToConstant:36].active = YES;
        [self.colorWells addObject:well];
        [row addArrangedSubview:well];
    }
    UIView *spacer = [UIView new];
    [row addArrangedSubview:spacer];
    UILabel *third = [UILabel new];
    third.text = LOC(@"ThemeThirdColor");
    third.font = [UIFont systemFontOfSize:14];
    third.textColor = [UIColor secondaryLabelColor];
    UISwitch *toggle = [UISwitch new];
    toggle.accessibilityIdentifier = @"third";
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    self.controls[@"third"] = toggle;
    [row addArrangedSubview:third];
    [row addArrangedSubview:toggle];
    return row;
}

- (UIView *)presetRow {
    UIScrollView *scroll = [UIScrollView new];
    scroll.showsHorizontalScrollIndicator = NO;
    UIStackView *row = [UIStackView new];
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
        [scroll.heightAnchor constraintEqualToConstant:40]
    ]];
    NSArray <NSString *> *names = @[@"PresetAurora", @"PresetSunset", @"PresetOcean", @"PresetNeon", @"PresetForest", @"PresetSnow", @"PresetRain", @"PresetNight"];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:LOC(names[i]) forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        button.backgroundColor = [UIColor tertiarySystemFillColor];
        button.layer.cornerRadius = 16;
        button.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
        button.tag = i;
        [button addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:button];
    }
    return scroll;
}

- (void)buildRows {
    self.enabledSwitch = [UISwitch new];
    [self.enabledSwitch addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:[self card:@[[self row:LOC(@"CustomThemeEnable") control:self.enabledSwitch]]]];

    [self.stack addArrangedSubview:[self header:LOC(@"ThemePresets")]];
    [self.stack addArrangedSubview:[self presetRow]];

    [self.stack addArrangedSubview:[self header:LOC(@"ThemeBackground")]];
    self.mediaButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.mediaButton addTarget:self action:@selector(pickMedia) forControlEvents:UIControlEventTouchUpInside];
    self.mediaButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.stack addArrangedSubview:[self card:@[
        [self segmentedFor:@"mode" items:@[LOC(@"ThemeGradient"), LOC(@"ThemePhoto"), LOC(@"ThemeVideo")]],
        self.mediaButton,
        [self sliderFor:@"dim" title:LOC(@"ThemeDim") min:0 max:0.95]
    ]]];

    [self.stack addArrangedSubview:[self header:LOC(@"ThemeColors")]];
    [self.stack addArrangedSubview:[self card:@[
        [self colorRow],
        [self segmentedFor:@"style" items:@[LOC(@"ThemeSolid"), LOC(@"ThemeLinear"), LOC(@"ThemeRadial")]],
        [self sliderFor:@"angle" title:LOC(@"ThemeAngle") min:0 max:360],
        [self sliderFor:@"start" title:LOC(@"ThemeStart") min:0 max:1],
        [self sliderFor:@"softness" title:LOC(@"ThemeSoftness") min:0 max:1]
    ]]];

    [self.stack addArrangedSubview:[self header:LOC(@"ThemeAnimation")]];
    [self.stack addArrangedSubview:[self card:@[
        [self segmentedFor:@"anim" items:@[LOC(@"ThemeAnimNone"), LOC(@"ThemeAnimScroll"), LOC(@"ThemeAnimColors"), LOC(@"ThemeAnimBoth")]],
        [self sliderFor:@"speed" title:LOC(@"ThemeSpeed") min:0.1 max:5],
        [self segmentedFor:@"reverse" items:@[LOC(@"ThemeDirectionNormal"), LOC(@"ThemeDirectionReverse")]]
    ]]];

    [self.stack addArrangedSubview:[self header:LOC(@"ThemeEffects")]];
    [self.stack addArrangedSubview:[self card:@[
        [self segmentedFor:@"effect" items:@[LOC(@"ThemeAnimNone"), LOC(@"ThemeSnow"), LOC(@"ThemeRain"), LOC(@"ThemeStars"), LOC(@"ThemeBubbles")]],
        [self sliderFor:@"density" title:LOC(@"ThemeDensity") min:0.05 max:1],
        [self sliderFor:@"effectSpeed" title:LOC(@"ThemeEffectSpeed") min:0.2 max:3]
    ]]];

    [self.stack addArrangedSubview:[self header:LOC(@"ThemeReadability")]];
    [self.stack addArrangedSubview:[self card:@[[self sliderFor:@"surface" title:LOC(@"ThemeSurface") min:0 max:1]]]];

    UILabel *note = [UILabel new];
    note.text = LOC(@"ThemeRestartNote");
    note.numberOfLines = 0;
    note.font = [UIFont systemFontOfSize:13];
    note.textColor = [UIColor secondaryLabelColor];
    [self.stack addArrangedSubview:note];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:LOC(@"ThemeReset") forState:UIControlStateNormal];
    [reset setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(resetTheme) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:reset];
}

- (NSString *)valueText:(NSString *)key value:(double)value {
    if ([key isEqualToString:@"angle"]) return [NSString stringWithFormat:@"%d°", (int)round(value)];
    if ([key isEqualToString:@"speed"] || [key isEqualToString:@"effectSpeed"]) return [NSString stringWithFormat:@"%.1fx", value];
    return [NSString stringWithFormat:@"%d %%", (int)round(value * 100)];
}

- (void)refresh:(BOOL)save {
    if (save) YTLThemeSave(self.config);
    self.enabledSwitch.on = ytlBool(@"themeEnabled");

    for (NSString *key in self.controls) {
        UIView *control = self.controls[key];
        id value = self.config[key];
        if ([control isKindOfClass:[UISlider class]]) {
            ((UISlider *)control).value = [value floatValue];
            self.valueLabels[key].text = [self valueText:key value:[value doubleValue]];
        } else if ([control isKindOfClass:[UISegmentedControl class]]) {
            ((UISegmentedControl *)control).selectedSegmentIndex = [value integerValue];
        } else if ([control isKindOfClass:[UISwitch class]]) {
            ((UISwitch *)control).on = [value boolValue];
        }
    }

    NSArray *hexes = self.config[@"colors"];
    for (UIControl *well in self.colorWells) {
        if ((NSUInteger)well.tag < hexes.count) [well setValue:YTLColorFromHex(hexes[well.tag]) forKey:@"selectedColor"];
        well.alpha = well.tag == 2 && ![self.config[@"third"] boolValue] ? 0.35 : 1;
    }

    NSInteger mode = [self.config[@"mode"] integerValue];
    self.mediaButton.hidden = mode == YTLThemeModeGradient;
    self.valueLabels[@"dim"].superview.superview.hidden = mode == YTLThemeModeGradient;
    BOOL hasMedia = YTLThemeMediaURL(self.config) != nil;
    [self.mediaButton setTitle:LOC(mode == YTLThemeModeVideo ? (hasMedia ? @"ThemeChangeVideo" : @"ThemeChooseVideo") : (hasMedia ? @"ThemeChangePhoto" : @"ThemeChoosePhoto")) forState:UIControlStateNormal];

    [self.preview applyConfig:self.config];
}

- (void)segmentChanged:(UISegmentedControl *)control {
    NSString *key = control.accessibilityIdentifier;
    self.config[key] = [key isEqualToString:@"reverse"] ? @(control.selectedSegmentIndex == 1) : @(control.selectedSegmentIndex);
    [self refresh:YES];
    if ([key isEqualToString:@"mode"] && control.selectedSegmentIndex != YTLThemeModeGradient && !YTLThemeMediaURL(self.config)) [self pickMedia];
}

- (void)sliderChanged:(UISlider *)slider {
    NSString *key = slider.accessibilityIdentifier;
    double value = slider.value;
    if ([key isEqualToString:@"angle"]) value = round(value);
    else if ([key isEqualToString:@"speed"] || [key isEqualToString:@"effectSpeed"]) value = round(value * 10) / 10;
    else value = round(value * 100) / 100;
    self.config[key] = @(value);
    self.valueLabels[key].text = [self valueText:key value:value];
    [self.preview applyConfig:self.config];
}

- (void)sliderEnded:(UISlider *)slider {
    [self refresh:YES];
}

- (void)switchChanged:(UISwitch *)toggle {
    self.config[toggle.accessibilityIdentifier] = @(toggle.on);
    [self refresh:YES];
}

- (void)colorChanged:(UIControl *)well {
    UIColor *color = [well valueForKey:@"selectedColor"];
    if (!color) return;
    NSMutableArray *hexes = [self.config[@"colors"] mutableCopy] ?: [NSMutableArray array];
    while (hexes.count < 3) [hexes addObject:@"#000000"];
    hexes[well.tag] = YTLHexFromColor(color);
    self.config[@"colors"] = hexes;
    if (well.tag == 2) self.config[@"third"] = @YES;
    [self refresh:YES];
}

- (void)enabledChanged:(UISwitch *)toggle {
    ytlSetBool(toggle.on, @"themeEnabled");
    YTLThemeRefreshAll();
    UIViewController *responder = self.navigationController.presentingViewController;
    if ([responder respondsToSelector:@selector(parentResponder)]) [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"ThemeRestartToast") firstResponder:responder] send];
}

- (void)presetTapped:(UIButton *)button {
    NSArray <NSDictionary *> *presets = @[
        @{@"colors": @[@"#00C9A7", @"#845EC2", @"#2C73D2"], @"third": @YES, @"style": @1, @"angle": @120, @"anim": @3, @"speed": @0.6, @"effect": @0, @"mode": @0},
        @{@"colors": @[@"#FF5F6D", @"#FFC371", @"#8E2DE2"], @"third": @YES, @"style": @1, @"angle": @180, @"anim": @1, @"speed": @0.5, @"effect": @0, @"mode": @0},
        @{@"colors": @[@"#0F2027", @"#203A43", @"#2C5364"], @"third": @YES, @"style": @1, @"angle": @160, @"anim": @1, @"speed": @0.4, @"effect": @4, @"density": @0.3, @"mode": @0},
        @{@"colors": @[@"#F72585", @"#7209B7", @"#4CC9F0"], @"third": @YES, @"style": @1, @"angle": @45, @"anim": @3, @"speed": @1.5, @"effect": @0, @"mode": @0},
        @{@"colors": @[@"#134E5E", @"#71B280", @"#0B3D2E"], @"third": @YES, @"style": @2, @"start": @0.4, @"anim": @2, @"speed": @0.5, @"effect": @0, @"mode": @0},
        @{@"colors": @[@"#1E3C72", @"#2A5298", @"#E0EAFC"], @"third": @YES, @"style": @1, @"angle": @180, @"anim": @0, @"effect": @1, @"density": @0.5, @"effectSpeed": @1.0, @"mode": @0},
        @{@"colors": @[@"#232526", @"#414345", @"#1C1C1C"], @"third": @YES, @"style": @1, @"angle": @180, @"anim": @0, @"effect": @2, @"density": @0.6, @"effectSpeed": @1.0, @"mode": @0},
        @{@"colors": @[@"#000000", @"#0B0B2B", @"#1B1B4D"], @"third": @YES, @"style": @2, @"start": @0.2, @"anim": @0, @"effect": @3, @"density": @0.6, @"effectSpeed": @0.6, @"mode": @0}
    ];
    if ((NSUInteger)button.tag >= presets.count) return;
    [self.config addEntriesFromDictionary:presets[button.tag]];
    if (!self.config[@"start"] || ![presets[button.tag] objectForKey:@"start"]) self.config[@"start"] = @0;
    self.config[@"softness"] = @1;
    if (!ytlBool(@"themeEnabled")) {
        ytlSetBool(YES, @"themeEnabled");
        YTLThemeRefreshAll();
    }
    [self refresh:YES];
}

- (void)resetTheme {
    self.config = [YTLThemeDefaults() mutableCopy];
    [self refresh:YES];
}

- (void)pickMedia {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) return;
    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    BOOL video = [self.config[@"mode"] integerValue] == YTLThemeModeVideo;
    picker.mediaTypes = video ? @[@"public.movie"] : @[@"public.image"];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *directory = YTLThemeMediaDirectory();
    NSString *old = self.config[@"media"];
    NSString *name = nil;

    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    if (videoURL) {
        name = [NSString stringWithFormat:@"background-%ld.%@", (long)[[NSDate date] timeIntervalSince1970], videoURL.pathExtension.length ? videoURL.pathExtension : @"mov"];
        [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:[directory URLByAppendingPathComponent:name] error:nil];
        self.config[@"mode"] = @(YTLThemeModeVideo);
    } else if (image) {
        CGFloat maxSide = 2400;
        CGFloat scale = MIN(1, maxSide / MAX(image.size.width, image.size.height));
        CGSize size = CGSizeMake(floor(image.size.width * scale), floor(image.size.height * scale));
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1;
        UIImage *resized = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [image drawInRect:(CGRect){CGPointZero, size}];
        }];
        name = [NSString stringWithFormat:@"background-%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
        [UIImageJPEGRepresentation(resized, 0.9) writeToURL:[directory URLByAppendingPathComponent:name] atomically:YES];
        self.config[@"mode"] = @(YTLThemeModePhoto);
    }

    if (name) {
        self.config[@"media"] = name;
        if ([old isKindOfClass:[NSString class]] && old.length && ![old isEqualToString:name]) {
            [[NSFileManager defaultManager] removeItemAtURL:[directory URLByAppendingPathComponent:old.lastPathComponent] error:nil];
        }
        if (!ytlBool(@"themeEnabled")) ytlSetBool(YES, @"themeEnabled");
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
    [self refresh:YES];
    YTLThemeRefreshAll();
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)done {
    YTLThemeRefreshAll();
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

%hook YTBaseInnerTubeViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!ytlBool(@"themeEnabled")) return;
    UIView *view = ((UIViewController *)(id)self).viewIfLoaded;
    if (YTLIsPageColor(view.backgroundColor)) view.backgroundColor = [UIColor clearColor];
    if (view) YTLClearPageBackgrounds(view);
}
%end

%hook YTSearchViewController
- (void)viewDidLoad {
    %orig;
    YTLThemeBackdrop(self.view, self.view.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    YTLThemeBackdrop(self.view, self.view.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight);
}
%end

void YTLPresentThemeEditor(void) {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    if (!presenter) return;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[YTLThemeEditorViewController new]];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

%ctor {
    if (YTLSafeModeActive()) return;
    YTLThemeConfig();
    [[NSNotificationCenter defaultCenter] addObserverForName:kThemeChanged object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        YTLThemeRefreshAll();
    }];
    %init;
}

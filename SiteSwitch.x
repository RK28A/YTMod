#import "YTLite.h"
#import "Utils/YTLSafeMode.h"
#import <WebKit/WebKit.h>

@interface YTHeaderView : UIView
@end

static const char kSiteTapKey;
static NSMutableDictionary <NSString *, UIImage *> *siteIcons;

#pragma mark - Site list

static NSURL *YTLNormalizeSite(NSString *raw) {
    raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return nil;
    if (![raw containsString:@"://"]) raw = [@"https://" stringByAppendingString:raw];
    NSURL *url = [NSURL URLWithString:raw];
    return url.host.length ? url : nil;
}

static NSArray <NSString *> *YTLDefaultSites(void) {
    static NSArray *sites;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *list = [NSMutableArray array];
        NSString *path = [NSBundle.ytl_defaultBundle pathForResource:@"DefaultSites" ofType:@"txt"];
        NSString *content = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
        for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *entry = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (entry.length && ![entry hasPrefix:@"#"]) [list addObject:entry];
        }
        sites = list;
    });
    return sites;
}

NSString *YTLSiteKey(NSString *entry) {
    NSURL *url = YTLNormalizeSite(entry);
    if (!url) return nil;
    NSString *host = url.host.lowercaseString;
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    NSString *path = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]].lowercaseString ?: @"";
    return path.length ? [NSString stringWithFormat:@"%@/%@", host, path] : host;
}

NSInteger YTLSiteIndex(NSArray <NSString *> *list, NSString *entry) {
    NSString *key = YTLSiteKey(entry);
    if (!key) return NSNotFound;
    for (NSUInteger i = 0; i < list.count; i++) {
        if ([YTLSiteKey(list[i]) isEqualToString:key]) return (NSInteger)i;
    }
    return NSNotFound;
}

NSArray <NSString *> *YTLSiteList(void) {
    YTLUserDefaults *defaults = [YTLUserDefaults standardUserDefaults];
    NSArray *saved = [defaults arrayForKey:@"siteList"];
    NSMutableArray *list = [NSMutableArray array];
    if (saved) {
        [list addObjectsFromArray:saved];
    } else {
        NSString *legacy = [defaults stringForKey:@"siteURL"];
        if (legacy.length) [list addObject:legacy];
    }

    NSMutableArray <NSString *> *clean = [NSMutableArray array];
    for (id entry in list) {
        if ([entry isKindOfClass:[NSString class]] && YTLSiteKey(entry) && YTLSiteIndex(clean, entry) == NSNotFound) [clean addObject:entry];
    }

    NSArray *seenValue = [defaults arrayForKey:@"siteDefaultsSeen"];
    NSMutableSet <NSString *> *seen = [NSMutableSet setWithArray:[seenValue isKindOfClass:[NSArray class]] ? seenValue : @[]];
    BOOL changed = NO;
    for (NSString *entry in YTLDefaultSites()) {
        NSString *key = YTLSiteKey(entry);
        if (!key || [seen containsObject:key]) continue;
        [seen addObject:key];
        changed = YES;
        if (YTLSiteIndex(clean, entry) == NSNotFound) [clean addObject:entry];
    }

    if (changed || (saved && clean.count != saved.count)) {
        [defaults setObject:seen.allObjects forKey:@"siteDefaultsSeen"];
        [defaults setObject:clean forKey:@"siteList"];
    }
    return clean;
}

void YTLSetSiteList(NSArray <NSString *> *list) {
    [[YTLUserDefaults standardUserDefaults] setObject:list ?: @[] forKey:@"siteList"];
}

NSURL *YTLSiteURL(void) {
    return YTLNormalizeSite(YTLSiteList().firstObject);
}

static NSString *YTLSiteName(NSURL *url) {
    NSString *host = [url.host hasPrefix:@"www."] ? [url.host substringFromIndex:4] : url.host;
    NSArray *parts = [host componentsSeparatedByString:@"."];
    NSString *name = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(0, parts.count - 1)] componentsJoinedByString:@"."] : host;
    name = [name stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    return name.length ? [name capitalizedString] : host;
}

static void YTLLoadSiteIcon(NSURL *site, void (^completion)(UIImage *image)) {
    if (!site.host) return;
    NSString *host = site.host;
    UIImage *cached = siteIcons[host];
    if (cached) {
        completion(cached);
        return;
    }

    NSArray <NSString *> *candidates = @[
        [NSString stringWithFormat:@"https://%@/apple-touch-icon.png", host],
        [NSString stringWithFormat:@"https://www.google.com/s2/favicons?domain=%@&sz=128", host],
        [NSString stringWithFormat:@"https://%@/favicon.ico", host]
    ];

    __block void (^attempt)(NSUInteger);
    attempt = ^(NSUInteger index) {
        if (index >= candidates.count) {
            attempt = nil;
            return;
        }
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:candidates[index]] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *image = data ? [UIImage imageWithData:data scale:[UIScreen mainScreen].scale] : nil;
            if (!image || image.size.width < 8) {
                attempt(index + 1);
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                siteIcons[host] = image;
                completion(image);
            });
            attempt = nil;
        }] resume];
    };
    attempt(0);
}

static void YTLPromptAddSite(void (^completion)(NSURL *url)) {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"SiteAdd") message:LOC(@"SiteURLDesc") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"example.com";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *value = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSURL *url = YTLNormalizeSite(value);
        if (!url) return;
        NSMutableArray *list = [YTLSiteList() mutableCopy];
        NSInteger existing = YTLSiteIndex(list, value);
        if (existing != NSNotFound) {
            url = YTLNormalizeSite(list[existing]) ?: url;
            [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"SiteDuplicate") firstResponder:presenter] send];
        } else {
            [list addObject:value];
            YTLSetSiteList(list);
        }
        if (completion) completion(url);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Dropdown

@interface YTLSiteDropdownItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSURL *iconURL;
@property (nonatomic, copy) void (^action)(void);
@end

@implementation YTLSiteDropdownItem
@end

@interface YTLSiteDropdown : UIControl
@property (nonatomic, strong) UIView *card;
+ (void)showItems:(NSArray <YTLSiteDropdownItem *> *)items fromRect:(CGRect)rect inView:(UIView *)host;
- (void)dismiss;
@end

@implementation YTLSiteDropdown

+ (void)showItems:(NSArray <YTLSiteDropdownItem *> *)items fromRect:(CGRect)rect inView:(UIView *)host {
    if (!host || items.count == 0) return;
    for (UIView *view in host.subviews) {
        if ([view isKindOfClass:self]) [view removeFromSuperview];
    }

    YTLSiteDropdown *dropdown = [[self alloc] initWithFrame:host.bounds];
    dropdown.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dropdown.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.18];
    [dropdown addTarget:dropdown action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];

    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [[UIColor separatorColor] CGColor];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceVertical = NO;
    [card.contentView addSubview:scroll];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    for (NSUInteger i = 0; i < items.count; i++) {
        [stack addArrangedSubview:[dropdown rowForItem:items[i]]];
        if (i + 1 < items.count) {
            UIView *separator = [UIView new];
            separator.backgroundColor = [UIColor separatorColor];
            [separator.heightAnchor constraintEqualToConstant:0.5].active = YES;
            [stack addArrangedSubview:separator];
        }
    }

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-4],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];

    CGFloat width = MIN(270, CGRectGetWidth(host.bounds) - 24);
    CGFloat contentHeight = [stack systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height + 8;
    UIEdgeInsets safe = host.safeAreaInsets;
    CGFloat below = CGRectGetHeight(host.bounds) - safe.bottom - CGRectGetMaxY(rect) - 18;
    CGFloat above = CGRectGetMinY(rect) - safe.top - 18;
    BOOL up = below < MIN(contentHeight, 220) && above > below;
    CGFloat height = MIN(contentHeight, MIN(MAX(up ? above : below, 120), CGRectGetHeight(host.bounds) * 0.6));
    scroll.scrollEnabled = contentHeight > height;
    CGFloat x = MIN(MAX(12, CGRectGetMaxX(rect) - width), CGRectGetWidth(host.bounds) - width - 12);
    if (CGRectGetMinX(rect) < CGRectGetWidth(host.bounds) / 2) x = MIN(MAX(12, CGRectGetMinX(rect)), CGRectGetWidth(host.bounds) - width - 12);
    CGFloat y = up ? CGRectGetMinY(rect) - 6 - height : CGRectGetMaxY(rect) + 6;
    dropdown.card = card;
    [dropdown addSubview:card];
    [host addSubview:dropdown];

    dropdown.alpha = 0;
    CGFloat anchorX = MIN(MAX((CGRectGetMidX(rect) - x) / width, 0.1), 0.9);
    card.layer.anchorPoint = CGPointMake(anchorX, up ? 1 : 0);
    card.frame = CGRectMake(x, y, width, height);
    card.transform = CGAffineTransformMakeScale(0.94, 0.94);
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4 options:0 animations:^{
        dropdown.alpha = 1;
        card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (UIView *)rowForItem:(YTLSiteDropdownItem *)item {
    UIControl *row = [UIControl new];
    [row.heightAnchor constraintEqualToConstant:52].active = YES;

    UIImageView *icon = [[UIImageView alloc] initWithImage:item.image];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFill;
    icon.clipsToBounds = YES;
    icon.layer.cornerRadius = 7;
    icon.tintColor = [UIColor labelColor];
    icon.backgroundColor = [UIColor tertiarySystemFillColor];
    if (item.iconURL) YTLLoadSiteIcon(item.iconURL, ^(UIImage *image) { icon.image = image; });

    UILabel *title = [UILabel new];
    title.text = item.title;
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];

    UILabel *subtitle = [UILabel new];
    subtitle.text = item.subtitle;
    subtitle.font = [UIFont systemFontOfSize:12];
    subtitle.textColor = [UIColor secondaryLabelColor];
    subtitle.hidden = item.subtitle.length == 0;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 1;
    labels.userInteractionEnabled = NO;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[icon, labels]];
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 12;
    content.userInteractionEnabled = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:30],
        [icon.heightAnchor constraintEqualToConstant:30],
        [content.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-14],
        [content.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];

    objc_setAssociatedObject(row, @selector(rowForItem:), item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [row addTarget:self action:@selector(rowHighlight:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [row addTarget:self action:@selector(rowUnhighlight:) forControlEvents:UIControlEventTouchCancel | UIControlEventTouchDragExit | UIControlEventTouchUpInside];
    return row;
}

- (void)rowHighlight:(UIControl *)row {
    row.backgroundColor = [UIColor tertiarySystemFillColor];
}

- (void)rowUnhighlight:(UIControl *)row {
    row.backgroundColor = [UIColor clearColor];
}

- (void)rowTapped:(UIControl *)row {
    YTLSiteDropdownItem *item = objc_getAssociatedObject(row, @selector(rowForItem:));
    [self dismissThen:item.action];
}

- (void)dismiss {
    [self dismissThen:nil];
}

- (void)dismissThen:(void (^)(void))action {
    [UIView animateWithDuration:0.15 animations:^{
        self.alpha = 0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
        if (action) action();
    }];
}

@end

static UIImage *YTLYouTubeIcon(void) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
    return [[UIImage systemImageNamed:@"play.rectangle.fill" withConfiguration:config] imageWithTintColor:[UIColor colorWithRed:1.0 green:0.0 blue:0.2 alpha:1.0] renderingMode:UIImageRenderingModeAlwaysOriginal];
}

#pragma mark - Ad blocker

static NSArray <NSString *> *YTLAdHosts(void) {
    static NSArray *hosts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hosts = @[
            @"doubleclick.net", @"googlesyndication.com", @"googleadservices.com", @"adservice.google.com", @"googletagservices.com", @"pagead2.googlesyndication.com",
            @"amazon-adsystem.com", @"adnxs.com", @"criteo.com", @"criteo.net", @"pubmatic.com", @"rubiconproject.com", @"openx.net", @"casalemedia.com",
            @"taboola.com", @"outbrain.com", @"revcontent.com", @"mgid.com", @"smartadserver.com", @"teads.tv", @"33across.com", @"yieldmo.com", @"sharethrough.com",
            @"popads.net", @"popcash.net", @"propellerads.com", @"propellerclick.com", @"onclickads.net", @"onclkds.com", @"adsterra.com", @"adsterratech.com",
            @"exoclick.com", @"exosrv.com", @"juicyads.com", @"trafficjunky.net", @"trafficstars.com", @"hilltopads.net", @"a-ads.com", @"adcash.com", @"clickadu.com",
            @"clickaine.com", @"adskeeper.com", @"adskeeper.co.uk", @"monetag.com", @"bidgear.com", @"ad-maven.com", @"admaven.com", @"pushame.com", @"pushwhy.com",
            @"richpush.co", @"evadav.com", @"galaksion.com", @"zeroredirect1.com", @"zeroredirect2.com", @"highperformanceformat.com", @"profitabledisplaynetwork.com",
            @"realsrv.com", @"tsyndicate.com", @"syndication.exdynsrv.com", @"magsrv.com", @"pemsrv.com", @"dolohen.com", @"adtng.com", @"aclib.net", @"acscdn.com",
            @"bebi.com", @"wpadmngr.com", @"vidoomy.com", @"adform.net", @"seedtag.com", @"quantserve.com", @"scorecardresearch.com", @"moatads.com",
            @"ads.yahoo.com", @"advertising.com", @"zedo.com", @"buysellads.com", @"carbonads.net", @"infolinks.com", @"media.net", @"yandexadexchange.net",
            @"an.yandex.ru", @"mc.yandex.ru", @"adriver.ru", @"directadvert.ru", @"pushnami.com", @"onesignal.com"
        ];
    });
    return hosts;
}

static BOOL YTLHostMatches(NSString *host, NSArray <NSString *> *domains) {
    host = host.lowercaseString;
    if (host.length == 0) return NO;
    for (NSString *domain in domains) {
        if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    }
    return NO;
}

static BOOL YTLIsAuthHost(NSString *host) {
    return YTLHostMatches(host, @[@"accounts.google.com", @"google.com", @"apple.com", @"appleid.apple.com", @"facebook.com", @"discord.com", @"twitter.com", @"x.com", @"github.com", @"microsoftonline.com", @"live.com", @"twitch.tv", @"paypal.com"]);
}

static NSString *YTLRootDomain(NSString *host) {
    NSArray *parts = [host.lowercaseString componentsSeparatedByString:@"."];
    if (parts.count <= 2) return host.lowercaseString;
    NSString *last2 = [[parts subarrayWithRange:NSMakeRange(parts.count - 2, 2)] componentsJoinedByString:@"."];
    if ([@[@"co.uk", @"com.br", @"co.jp", @"com.au", @"co.in"] containsObject:last2] && parts.count > 2) {
        return [[parts subarrayWithRange:NSMakeRange(parts.count - 3, 3)] componentsJoinedByString:@"."];
    }
    return last2;
}

static NSString *YTLAdRulesJSON(void) {
    NSMutableArray *rules = [NSMutableArray array];
    for (NSString *host in YTLAdHosts()) {
        NSString *escaped = [host stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
        [rules addObject:@{
            @"trigger": @{@"url-filter": [NSString stringWithFormat:@"^https?://([^/]+\\.)?%@[:/]", escaped], @"resource-type": @[@"script", @"image", @"style-sheet", @"raw", @"media", @"popup", @"font", @"svg-document"]},
            @"action": @{@"type": @"block"}
        }];
        [rules addObject:@{
            @"trigger": @{@"url-filter": [NSString stringWithFormat:@"^https?://([^/]+\\.)?%@[:/]", escaped], @"resource-type": @[@"document"], @"load-type": @[@"third-party"]},
            @"action": @{@"type": @"block"}
        }];
    }
    [rules addObject:@{
        @"trigger": @{@"url-filter": @".*"},
        @"action": @{@"type": @"css-display-none", @"selector": @"ins.adsbygoogle, iframe[src*='doubleclick.net'], iframe[src*='googlesyndication'], iframe[id^='google_ads_iframe'], div[id^='div-gpt-ad'], div[id^='taboola-'], div[class*='OUTBRAIN'], a[href*='/aff_c?'], a[href*='popads.net'], a[href*='adsterra'], a[href*='exoclick']"}
    }];
    NSData *data = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static void YTLLoadAdRules(void (^completion)(WKContentRuleList *list)) {
    static WKContentRuleList *cached;
    if (cached) {
        completion(cached);
        return;
    }
    WKContentRuleListStore *store = [WKContentRuleListStore defaultStore];
    NSString *identifier = @"ytmodulation-adblock-2";
    [store lookUpContentRuleListForIdentifier:identifier completionHandler:^(WKContentRuleList *list, NSError *error) {
        if (list) {
            cached = list;
            completion(list);
            return;
        }
        NSString *json = YTLAdRulesJSON();
        if (!json) return;
        [store compileContentRuleListForIdentifier:identifier encodedContentRuleList:json completionHandler:^(WKContentRuleList *compiled, NSError *compileError) {
            if (!compiled) return;
            cached = compiled;
            completion(compiled);
        }];
    }];
}

static NSString *const kYTLPopupGuardScript = @"(function(){"
    "if(window.__ytlGuard)return;window.__ytlGuard=1;"
    "var last=0;['touchend','click','keydown'].forEach(function(n){document.addEventListener(n,function(){last=Date.now();},true);});"
    "var open=window.open;"
    "window.open=function(u,n,f){if(Date.now()-last>1200)return null;return open.apply(window,arguments);};"
    "document.addEventListener('click',function(e){var a=e.target&&e.target.closest?e.target.closest('a[target=_blank]'):null;"
    "if(!a)return;var h=a.getAttribute('href')||'';if(/^javascript:/i.test(h)){return;}"
    "try{var u=new URL(h,location.href);var r=a.getBoundingClientRect();"
    "if((r.width>=window.innerWidth*0.9&&r.height>=window.innerHeight*0.6)||getComputedStyle(a).opacity==='0'){e.preventDefault();e.stopImmediatePropagation();}}catch(x){}},true);"
    "})();";

static NSString *const kYTLCosmeticScript = @"(function(){"
    "if(window.__ytlCosmetic)return;window.__ytlCosmetic=1;"
    "var LABEL=/^(publicit[eé]s?|advertisements?|advertising|sponsoris[eé]e?s?|sponsored|annonces?|anzeige|pubblicit[aà]|publicidad)$/i;"
    "var STRIP=/publicit[eé]s?|advertisements?|advertising|sponsoris[eé]e?s?|sponsored|annonces?|anzeige|pubblicit[aà]|publicidad/gi;"
    "var NAG=/(cliqu\\w* sur (une|les|nos) pubs?|(d[eé]sactiv\\w*|coupe\\w*) (votre|ton|l'|le )?(bloqueur|adblock)|disable (your )?ad ?block|support us by clicking)/i;"
    "function rest(el){return ((el.innerText||el.textContent||'').replace(STRIP,'')).replace(/\\s+/g,'');}"
    "function hide(el){if(el&&el!==document.body&&el!==document.documentElement)el.style.setProperty('display','none','important');}"
    "function media(el){return el.querySelector&&el.querySelector('img,iframe,video,picture,a[href],canvas,ins,[style*=background]');}"
    "function clean(root){"
    "var all=(root||document.body||document).querySelectorAll('span,p,div,h1,h2,h3,h4,h5,h6,small,strong,b,label,header,figcaption,a');"
    "for(var i=0;i<all.length;i++){var el=all[i];if(el.__ytlSeen)continue;"
    "var text=(el.textContent||'').trim();if(text.length>90)continue;"
    "if(el.children.length===0&&LABEL.test(text)){el.__ytlSeen=1;"
    "var box=el;for(var d=0;d<6&&box.parentElement&&box.parentElement!==document.body;d++){var p=box.parentElement;if(rest(p).length>0)break;box=p;}"
    "if(box!==el&&rest(box).length===0&&media(box)){hide(box);}else{hide(el);var n=el.nextElementSibling;if(n&&rest(n).length===0&&media(n))hide(n);}"
    "}else if(el.children.length<=2&&NAG.test(text)){el.__ytlSeen=1;hide(el);}}"
    "document.querySelectorAll('a[rel~=sponsored]').forEach(function(a){hide(a);});}"
    "var t;function run(){clearTimeout(t);t=setTimeout(function(){try{clean();}catch(e){}},150);}"
    "if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',run);else run();"
    "new MutationObserver(run).observe(document.documentElement,{childList:true,subtree:true});"
    "})();";

static NSString *const kYTLMovixScript = @"(function(){"
    "var anc=location.ancestorOrigins?Array.prototype.join.call(location.ancestorOrigins,' '):'';"
    "if(!/movix/i.test(location.hostname+' '+anc))return;"
    "if(window.__ytlMovix)return;window.__ytlMovix=1;"
    "try{window.open=function(){return null;};}catch(x){}"
    "var SHORT=/(^|\\.)(ja\\.cat|bit\\.ly|tinyurl\\.com|cutt\\.ly|shorturl\\.at|t\\.ly|is\\.gd|rebrand\\.ly|bc\\.vc|ouo\\.io|ouo\\.press|shrinkme\\.io|exe\\.io|adf\\.ly|linkvertise\\.com|clk\\.sh)$/i;"
    "var ADW=/(^|[-_\\s])(ads?|advert\\w*|sponsor\\w*|publicite|casino|vpn)([-_\\s]|$)/i;"
    "function hide(e){if(e&&e!==document.body&&e!==document.documentElement)e.style.setProperty('display','none','important');}"
    "function trap(e){var cs=getComputedStyle(e);if(cs.position!=='fixed'&&cs.position!=='absolute')return false;"
    "var r=e.getBoundingClientRect();if(r.width<innerWidth*0.6||r.height<innerHeight*0.5)return false;"
    "if(e.querySelector('video,iframe,canvas,img,svg,button,input,select,textarea'))return false;if((e.innerText||'').trim().length)return false;"
    "var bg=cs.backgroundColor;return parseFloat(cs.opacity)<0.1||bg==='transparent'||/rgba\\(.*,\\s*0\\)$/.test(bg);}"
    "function clean(){"
    "document.querySelectorAll('a[href]').forEach(function(a){try{if(SHORT.test(new URL(a.href,location.href).hostname))hide(a.closest('li,article,[class*=comment]')||a);}catch(x){}});"
    "document.querySelectorAll('[id],[class]').forEach(function(e){var s=(e.id||'')+' '+(typeof e.className==='string'?e.className:'');if(ADW.test(s)&&!e.querySelector('video'))hide(e);});"
    "document.querySelectorAll('body > div, body > a, body > span').forEach(function(e){if(trap(e))e.remove();});"
    "document.querySelectorAll('iframe').forEach(function(f){var r=f.getBoundingClientRect();if(r.width<=2&&r.height<=2)f.remove();});}"
    "var t;function run(){clearTimeout(t);t=setTimeout(function(){try{clean();}catch(e){}},200);}"
    "if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',run);else run();"
    "new MutationObserver(run).observe(document.documentElement,{childList:true,subtree:true});"
    "})();";

#pragma mark - Site view controller

@interface YTLSiteViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) NSURL *siteURL;
@property (nonatomic, assign) CFTimeInterval trustedLoadUntil;
@property (nonatomic, strong) NSMutableSet <NSString *> *trustedRoots;
@property (nonatomic, assign) BOOL mediaFullscreen;
@property (nonatomic, assign) BOOL mediaPiP;
+ (instancetype)shared;
- (void)showSite:(NSURL *)url;
@end

static void YTLOpenSiteURL(NSURL *url);

static NSMutableSet <NSString *> *siteVisitedHosts;

static NSString *YTLBareHost(NSString *host) {
    host = [host.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]];
    return [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
}

static BOOL YTLShouldPersistCookie(NSHTTPCookie *cookie, NSSet <NSString *> *hosts) {
    if (!cookie.sessionOnly) return NO;
    NSString *domain = YTLBareHost(cookie.domain);
    if (domain.length == 0) return NO;
    for (NSString *blocked in @[@"google", @"youtube", @"gstatic", @"googleapis", @"youtu.be", @"ggpht"]) {
        if ([domain isEqualToString:blocked] || [domain hasPrefix:[blocked stringByAppendingString:@"."]] || [domain containsString:[@"." stringByAppendingString:[blocked stringByAppendingString:@"."]]]) return NO;
    }
    for (NSString *host in hosts) {
        if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    }
    return NO;
}

@interface YTLSitePopupController : UIViewController <WKUIDelegate, WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation YTLSitePopupController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)done {
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    if (webView.URL.host) [siteVisitedHosts addObject:YTLBareHost(webView.URL.host)];
    self.title = webView.URL.host;
}

- (void)webViewDidClose:(WKWebView *)webView {
    [self done];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (navigationAction.request.URL) [webView loadRequest:navigationAction.request];
    return nil;
}

@end

@implementation YTLSiteViewController

+ (instancetype)shared {
    static YTLSiteViewController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [YTLSiteViewController new];
        controller.modalPresentationStyle = UIModalPresentationFullScreen;
        controller.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    });
    return controller;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.allowsInlineMediaPlayback = YES;
    configuration.allowsPictureInPictureMediaPlayback = YES;
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    if (ytlBool(@"siteAdBlock")) {
        [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:kYTLPopupGuardScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
        [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:kYTLCosmeticScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:NO]];
        [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:kYTLMovixScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
    if (!siteVisitedHosts) siteVisitedHosts = [NSMutableSet set];
    for (NSString *entry in YTLSiteList()) {
        NSString *host = YTLNormalizeSite(entry).host;
        if (host) [siteVisitedHosts addObject:YTLBareHost(host)];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(persistSessionCookies) name:UIApplicationDidEnterBackgroundNotification object:nil];

    NSString *autofillScript = @"(function(){"
        "if(window.__ytlAF)return;window.__ytlAF=1;"
        "function bad(i){var a=(i.getAttribute('autocomplete')||'').toLowerCase();return !a||a==='off'||a==='false'||a==='nope';}"
        "function fix(){document.querySelectorAll('input[type=password]').forEach(function(p){"
        "var hint=((p.name||'')+' '+(p.id||'')+' '+(p.placeholder||'')).toLowerCase();"
        "if(bad(p))p.setAttribute('autocomplete',/new|confirm|repeat|register|signup|inscri/.test(hint)?'new-password':'current-password');"
        "var scope=p.form||document;var prev=null;"
        "scope.querySelectorAll('input[type=email],input[type=text],input[type=tel],input:not([type])').forEach(function(i){if(i.compareDocumentPosition(p)&4)prev=i;});"
        "if(prev&&bad(prev))prev.setAttribute('autocomplete','username');});"
        "document.querySelectorAll('input[type=email]').forEach(function(i){if(bad(i))i.setAttribute('autocomplete','username');});}"
        "fix();var t;new MutationObserver(function(){clearTimeout(t);t=setTimeout(fix,300);}).observe(document.documentElement,{childList:true,subtree:true});"
        "})();";
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:autofillScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:NO]];

    NSString *mediaScript = @"(function(){"
        "if(window.__ytlMedia)return;window.__ytlMedia=1;"
        "function send(){var fs=!!(document.fullscreenElement||document.webkitFullscreenElement||document.webkitCurrentFullScreenElement);"
        "var pip=!!document.pictureInPictureElement;"
        "document.querySelectorAll('video').forEach(function(v){if(v.webkitDisplayingFullscreen)fs=true;if(v.webkitPresentationMode&&v.webkitPresentationMode!=='inline'){if(v.webkitPresentationMode==='picture-in-picture')pip=true;else fs=true;}});"
        "try{window.webkit.messageHandlers.ytlMedia.postMessage({fullscreen:fs,pip:pip});}catch(e){}}"
        "['fullscreenchange','webkitfullscreenchange','webkitbeginfullscreen','webkitendfullscreen','enterpictureinpicture','leavepictureinpicture','webkitpresentationmodechanged'].forEach(function(n){document.addEventListener(n,send,true);});"
        "var rf=Element.prototype.requestFullscreen||Element.prototype.webkitRequestFullscreen;"
        "function nativeFS(el){var v=(el&&el.tagName==='VIDEO')?el:(el&&el.querySelector&&el.querySelector('video'))||document.querySelector('video');"
        "if(v&&v.webkitEnterFullscreen){try{v.webkitEnterFullscreen();return Promise.resolve();}catch(e){}}return Promise.reject(new Error('fullscreen'));}"
        "Element.prototype.requestFullscreen=function(){return nativeFS(this);};"
        "Element.prototype.webkitRequestFullscreen=function(){return nativeFS(this);};"
        "Element.prototype.webkitRequestFullScreen=function(){return nativeFS(this);};"
        "})();";
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:mediaScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    [configuration.userContentController addScriptMessageHandler:self name:@"ytlMedia"];

    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    _webView.translatesAutoresizingMaskIntoConstraints = NO;
    _webView.allowsBackForwardNavigationGestures = YES;
    _webView.navigationDelegate = self;
    _webView.UIDelegate = self;
    if (ytlBool(@"siteAdBlock")) {
        __weak WKWebView *weakWebView = _webView;
        YTLLoadAdRules(^(WKContentRuleList *list) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakWebView.configuration.userContentController addContentRuleList:list];
            });
        });
    }
    _webView.customUserAgent = [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%@ Mobile/15E148 Safari/604.1", [[UIDevice currentDevice].systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"], [UIDevice currentDevice].systemVersion];
    [self.view addSubview:_webView];

    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(reload:) forControlEvents:UIControlEventValueChanged];
    _webView.scrollView.refreshControl = refresh;

    _backButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _backButton.frame = CGRectMake(0, 0, 52, 52);
    _backButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    _backButton.layer.cornerRadius = 26;
    _backButton.layer.shadowColor = [UIColor blackColor].CGColor;
    _backButton.layer.shadowOpacity = 0.35;
    _backButton.layer.shadowRadius = 6;
    _backButton.layer.shadowOffset = CGSizeMake(0, 2);
    [_backButton setImage:YTLYouTubeIcon() forState:UIControlStateNormal];
    _backButton.accessibilityLabel = @"YouTube";
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    doubleTap.numberOfTapsRequired = 2;
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showSitesMenu)];
    [singleTap requireGestureRecognizerToFail:doubleTap];
    [_backButton addGestureRecognizer:doubleTap];
    [_backButton addGestureRecognizer:singleTap];
    [_backButton addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [self.view addSubview:_backButton];

    [NSLayoutConstraint activateConstraints:@[
        [_webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (CGPointEqualToPoint(self.backButton.center, CGPointMake(26, 26))) {
        UIEdgeInsets insets = self.view.safeAreaInsets;
        self.backButton.center = CGPointMake(CGRectGetWidth(self.view.bounds) - 26 - 16, CGRectGetHeight(self.view.bounds) - insets.bottom - 26 - 24);
    }
    [self.view bringSubviewToFront:self.backButton];
}

- (void)showSite:(NSURL *)url {
    [self loadViewIfNeeded];
    if (!url) return;
    BOOL sameSite = url.host && [YTLRootDomain(url.host) isEqualToString:YTLRootDomain(self.webView.URL.host ?: @"")];
    if (!sameSite || !self.webView.URL) {
        self.siteURL = url;
        self.trustedLoadUntil = CACurrentMediaTime() + 15;
        [self.webView stopLoading];
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

- (void)reload:(UIRefreshControl *)control {
    [self.webView reload];
    [control endRefreshing];
}

- (void)drag:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];
    CGPoint center = CGPointMake(gesture.view.center.x + translation.x, gesture.view.center.y + translation.y);
    CGRect bounds = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    center.x = MIN(MAX(center.x, CGRectGetMinX(bounds) + 26), CGRectGetMaxX(bounds) - 26);
    center.y = MIN(MAX(center.y, CGRectGetMinY(bounds) + 26), CGRectGetMaxY(bounds) - 26);
    gesture.view.center = center;
    [gesture setTranslation:CGPointZero inView:self.view];
}

- (void)updateBackButton {
    BOOL hide = self.mediaFullscreen || self.mediaPiP;
    if (!hide) self.backButton.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{
        self.backButton.alpha = hide ? 0 : 1;
    } completion:^(BOOL finished) {
        self.backButton.hidden = hide;
    }];
}

- (void)showSitesMenu {
    for (UIView *view in self.view.subviews) {
        if ([view isKindOfClass:[YTLSiteDropdown class]]) {
            [(YTLSiteDropdown *)view dismiss];
            return;
        }
    }
    [self showMenuFromRect:self.backButton.frame];
}

- (void)showMenuFromRect:(CGRect)rect {
    NSMutableArray <YTLSiteDropdownItem *> *items = [NSMutableArray array];

    YTLSiteDropdownItem *youtube = [YTLSiteDropdownItem new];
    youtube.title = @"YouTube";
    youtube.subtitle = LOC(@"SiteBackToYouTube");
    youtube.image = YTLYouTubeIcon();
    __weak typeof(self) weakSelf = self;
    youtube.action = ^{ [weakSelf close]; };
    [items addObject:youtube];

    if (self.siteURL) {
        YTLSiteDropdownItem *home = [YTLSiteDropdownItem new];
        home.title = YTLSiteName(self.siteURL);
        home.subtitle = LOC(@"SiteHome");
        home.iconURL = self.siteURL;
        home.image = siteIcons[self.siteURL.host] ?: [UIImage systemImageNamed:@"house.fill"];
        NSURL *siteURL = self.siteURL;
        home.action = ^{ [weakSelf.webView loadRequest:[NSURLRequest requestWithURL:siteURL]]; };
        [items addObject:home];
    }

    for (NSString *entry in YTLSiteList()) {
        NSURL *url = YTLNormalizeSite(entry);
        if (!url || [url.host isEqualToString:self.siteURL.host]) continue;
        YTLSiteDropdownItem *item = [YTLSiteDropdownItem new];
        item.title = YTLSiteName(url);
        item.subtitle = url.host;
        item.iconURL = url;
        item.image = siteIcons[url.host] ?: [UIImage systemImageNamed:@"globe"];
        item.action = ^{ [weakSelf showSite:url]; };
        [items addObject:item];
    }

    [YTLSiteDropdown showItems:items fromRect:rect inView:self.view];
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"ytlMedia"] && [message.body isKindOfClass:[NSDictionary class]]) {
        self.mediaFullscreen = [message.body[@"fullscreen"] boolValue];
        self.mediaPiP = [message.body[@"pip"] boolValue];
        [self updateBackButton];
    }
}

- (void)pauseMedia {
    SEL modern = NSSelectorFromString(@"pauseAllMediaPlaybackWithCompletionHandler:");
    SEL legacy = NSSelectorFromString(@"pauseAllMediaPlayback:");
    if ([self.webView respondsToSelector:modern]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.webView, modern, ^{});
    } else if ([self.webView respondsToSelector:legacy]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.webView, legacy, ^{});
    }
    [self.webView evaluateJavaScript:@"document.querySelectorAll('video,audio').forEach(function(m){try{m.pause();}catch(e){}});" completionHandler:nil];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    if (self.trustedLoadUntil > 0) self.trustedLoadUntil = MIN(self.trustedLoadUntil, CACurrentMediaTime() + 3);
    if (webView.URL.host) [siteVisitedHosts addObject:YTLBareHost(webView.URL.host)];
}

- (void)persistSessionCookies {
    if (!self.isViewLoaded || !self.webView) return;
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    NSSet <NSString *> *hosts = [siteVisitedHosts copy];
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    [store getAllCookies:^(NSArray <NSHTTPCookie *> *cookies) {
        dispatch_group_t group = dispatch_group_create();
        for (NSHTTPCookie *cookie in cookies) {
            if (!YTLShouldPersistCookie(cookie, hosts)) continue;
            NSMutableDictionary *properties = [cookie.properties mutableCopy];
            [properties removeObjectForKey:NSHTTPCookieDiscard];
            [properties removeObjectForKey:NSHTTPCookieMaximumAge];
            properties[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSinceNow:30 * 24 * 3600];
            NSHTTPCookie *persistent = [NSHTTPCookie cookieWithProperties:properties];
            if (!persistent) continue;
            dispatch_group_enter(group);
            [store setCookie:persistent completionHandler:^{ dispatch_group_leave(group); }];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (task != UIBackgroundTaskInvalid) {
                [app endBackgroundTask:task];
                task = UIBackgroundTaskInvalid;
            }
        });
    }];
}

- (void)close {
    [self pauseMedia];
    [self persistSessionCookies];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)isUserSiteHost:(NSString *)host {
    NSString *root = YTLRootDomain(host);
    if ([self.trustedRoots containsObject:root]) return YES;
    if ([root isEqualToString:YTLRootDomain(self.webView.URL.host ?: self.siteURL.host)]) return YES;
    for (NSString *entry in YTLSiteList()) {
        NSString *siteHost = YTLNormalizeSite(entry).host;
        if (siteHost && [YTLRootDomain(siteHost) isEqualToString:root]) return YES;
    }
    return NO;
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *host = url.host;
    if (!ytlBool(@"siteAdBlock") || host.length == 0) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (YTLHostMatches(host, YTLAdHosts())) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    BOOL mainFrame = navigationAction.targetFrame.isMainFrame;
    BOOL userClick = navigationAction.navigationType == WKNavigationTypeLinkActivated || navigationAction.navigationType == WKNavigationTypeFormSubmitted || navigationAction.navigationType == WKNavigationTypeBackForward || navigationAction.navigationType == WKNavigationTypeReload;
    if (mainFrame && CACurrentMediaTime() < self.trustedLoadUntil) {
        if (!self.trustedRoots) self.trustedRoots = [NSMutableSet set];
        [self.trustedRoots addObject:YTLRootDomain(host)];
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (mainFrame && !userClick && webView.URL.host && ![self isUserSiteHost:host] && !YTLIsAuthHost(host) && [self isUserSiteHost:webView.URL.host]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (navigationAction.targetFrame) return nil;
    NSString *popupHost = navigationAction.request.URL.host;
    if (ytlBool(@"siteAdBlock")) {
        if (popupHost.length == 0 || YTLHostMatches(popupHost, YTLAdHosts())) return nil;
        if (!YTLIsAuthHost(popupHost) && ![self isUserSiteHost:popupHost]) {
            if (navigationAction.navigationType == WKNavigationTypeLinkActivated) [webView loadRequest:navigationAction.request];
            return nil;
        }
    }
    if (self.presentedViewController || !self.view.window) {
        if (navigationAction.request.URL) [webView loadRequest:navigationAction.request];
        return nil;
    }

    WKWebView *popup = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    popup.customUserAgent = webView.customUserAgent;
    YTLSitePopupController *controller = [YTLSitePopupController new];
    controller.webView = popup;
    popup.UIDelegate = controller;
    popup.navigationDelegate = controller;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:navigation animated:YES completion:nil];
    return popup;
}

@end

static void YTLOpenSiteURL(NSURL *url) {
    if (!url) return;
    YTLSiteViewController *site = [YTLSiteViewController shared];
    [site showSite:url];
    if (site.presentingViewController) return;
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    if (!presenter || presenter == site) return;
    [presenter presentViewController:site animated:YES completion:nil];
}

#pragma mark - YouTube logo

static BOOL YTLShowSitesMenuForLogo(UIView *logo) {
    if (!logo || !logo.window || !ytlBool(@"siteSwitch")) return NO;

    NSArray <NSString *> *sites = YTLSiteList();
    if (sites.count == 0) {
        YTLPromptAddSite(^(NSURL *url) { YTLOpenSiteURL(url); });
        return YES;
    }

    NSMutableArray <YTLSiteDropdownItem *> *items = [NSMutableArray array];
    for (NSString *entry in sites) {
        NSURL *url = YTLNormalizeSite(entry);
        if (!url) continue;
        YTLSiteDropdownItem *item = [YTLSiteDropdownItem new];
        item.title = YTLSiteName(url);
        item.subtitle = url.host;
        item.iconURL = url;
        item.image = siteIcons[url.host] ?: [UIImage systemImageNamed:@"globe"];
        item.action = ^{ YTLOpenSiteURL(url); };
        [items addObject:item];
    }

    YTLSiteDropdownItem *add = [YTLSiteDropdownItem new];
    add.title = LOC(@"SiteAdd");
    add.image = [UIImage systemImageNamed:@"plus"];
    add.action = ^{ YTLPromptAddSite(^(NSURL *url) { YTLOpenSiteURL(url); }); };
    [items addObject:add];

    UIView *host = logo.window;
    [YTLSiteDropdown showItems:items fromRect:[logo convertRect:logo.bounds toView:host] inView:host];
    return YES;
}

@interface YTLSiteTapHandler : NSObject
@end

@implementation YTLSiteTapHandler
+ (instancetype)shared {
    static YTLSiteTapHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [YTLSiteTapHandler new]; });
    return handler;
}

- (void)logoTapped:(UITapGestureRecognizer *)gesture {
    YTLShowSitesMenuForLogo(gesture.view);
}
@end

static void YTLAttachSiteTap(UIView *view) {
    if (!view || objc_getAssociatedObject(view, &kSiteTapKey)) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[YTLSiteTapHandler shared] action:@selector(logoTapped:)];
    tap.cancelsTouchesInView = YES;
    view.userInteractionEnabled = YES;
    [view addGestureRecognizer:tap];
    objc_setAssociatedObject(view, &kSiteTapKey, tap, OBJC_ASSOCIATION_ASSIGN);
}

%hook YTHeaderLogoControllerImpl
- (void)setLogoView:(UIView *)logoView {
    %orig;
    if (ytlBool(@"siteSwitch")) YTLAttachSiteTap(logoView);
}

- (void)didTapLogoView {
    UIView *logoView = YTLValue(self, @"logoView");
    if ([logoView isKindOfClass:[UIView class]] && YTLShowSitesMenuForLogo(logoView)) return;
    %orig;
}
%end

%hook YTNavigationBarTitleView
- (void)setCustomView:(UIView *)customView {
    %orig;
    if (ytlBool(@"siteSwitch")) YTLAttachSiteTap(customView);
}
%end

%hook YTHeaderView
- (void)setCustomTitleView:(UIView *)customTitleView {
    %orig;
    if (ytlBool(@"siteSwitch")) YTLAttachSiteTap(customTitleView);
}

- (void)layoutSubviews {
    %orig;
    if (!ytlBool(@"siteSwitch")) return;
    UIView *custom = [self respondsToSelector:@selector(customTitleView)] ? [self performSelector:@selector(customTitleView)] : nil;
    YTLAttachSiteTap(custom);
}
%end

%ctor {
    if (YTLSafeModeActive()) return;
    siteIcons = [NSMutableDictionary dictionary];
    %init(YTHeaderLogoControllerImpl = YTLClass(@"YTHeaderLogoControllerImpl"));
    for (NSString *entry in YTLSiteList()) YTLLoadSiteIcon(YTLNormalizeSite(entry), ^(UIImage *image) {});
}

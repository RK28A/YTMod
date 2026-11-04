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

NSArray <NSString *> *YTLSiteList(void) {
    YTLUserDefaults *defaults = [YTLUserDefaults standardUserDefaults];
    NSArray *list = [defaults arrayForKey:@"siteList"];
    if (!list) {
        NSString *legacy = [defaults stringForKey:@"siteURL"];
        NSMutableArray *initial = [YTLDefaultSites() mutableCopy];
        if (legacy.length && ![initial containsObject:legacy]) [initial insertObject:legacy atIndex:0];
        list = initial;
    }
    NSMutableArray *clean = [NSMutableArray array];
    for (id entry in list) {
        if ([entry isKindOfClass:[NSString class]] && YTLNormalizeSite(entry) && ![clean containsObject:entry]) [clean addObject:entry];
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
        if (![list containsObject:value]) [list addObject:value];
        YTLSetSiteList(list);
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

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];

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
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-4],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor]
    ]];

    CGFloat width = MIN(270, CGRectGetWidth(host.bounds) - 24);
    CGSize size = [card systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat x = MIN(MAX(12, CGRectGetMinX(rect)), CGRectGetWidth(host.bounds) - width - 12);
    CGFloat y = CGRectGetMaxY(rect) + 6;
    card.frame = CGRectMake(x, y, width, size.height);
    dropdown.card = card;
    [dropdown addSubview:card];
    [host addSubview:dropdown];

    dropdown.alpha = 0;
    card.transform = CGAffineTransformMakeScale(0.94, 0.94);
    card.layer.anchorPoint = CGPointMake(0.15, 0);
    card.frame = CGRectMake(x, y, width, size.height);
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

#pragma mark - Site view controller

@interface YTLSiteViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) NSURL *siteURL;
@property (nonatomic, assign) BOOL mediaFullscreen;
@property (nonatomic, assign) BOOL mediaPiP;
+ (instancetype)shared;
- (void)showSite:(NSURL *)url;
@end

static void YTLOpenSiteURL(NSURL *url);

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

    NSString *logoScript = @"(function(){"
        "if(window.__ytlBack)return;window.__ytlBack=1;"
        "var host=location.hostname.replace(/^www\\./,'');"
        "var name=host.split('.')[0].toLowerCase().replace(/[^a-z0-9]/g,'');"
        "function norm(t){return (t||'').toLowerCase().replace(/[^a-z0-9]/g,'');}"
        "function isRoot(a){if(!a||!a.getAttribute)return false;var h=a.getAttribute('href');if(h===null)return false;"
        "try{var u=new URL(h,location.href);return u.hostname.replace(/^www\\./,'')===host&&(u.pathname==='/'||u.pathname==='')&&!u.search;}catch(e){return false;}}"
        "function logoOf(el){for(var n=el,i=0;n&&i<6;n=n.parentElement,i++){"
        "if(n.tagName==='A'&&isRoot(n))return n;"
        "var c=(n.className&&n.className.baseVal!==undefined?n.className.baseVal:n.className)||'';var id=n.id||'';"
        "if(/logo|brand/i.test(c+' '+id))return n;"
        "if(n.tagName==='IMG'&&(/logo/i.test(n.alt||'')||/logo/i.test(n.src||'')||(name&&norm(n.alt).indexOf(name)>=0)))return n;"
        "if(name&&name.length>2&&n.children.length===0&&norm(n.textContent)===name)return n;}"
        "return null;}"
        "document.addEventListener('click',function(e){var l=logoOf(e.target);if(!l)return;e.preventDefault();e.stopPropagation();"
        "var r=l.getBoundingClientRect();window.webkit.messageHandlers.ytlBack.postMessage({x:r.left,y:r.top,w:r.width,h:r.height});},true);"
        "})();";
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:logoScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    [configuration.userContentController addScriptMessageHandler:self name:@"ytlBack"];

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
    [_backButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
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
    if (![self.siteURL.host isEqualToString:url.host] || !self.webView.URL) {
        self.siteURL = url;
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

- (void)showLogoMenuFromRect:(CGRect)rect {
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

    CGRect anchor = [self.webView convertRect:rect toView:self.view];
    [YTLSiteDropdown showItems:items fromRect:anchor inView:self.view];
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"ytlBack"]) {
        NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
        CGRect rect = CGRectMake([body[@"x"] doubleValue], [body[@"y"] doubleValue], [body[@"w"] doubleValue], [body[@"h"] doubleValue]);
        [self showLogoMenuFromRect:rect];
    } else if ([message.name isEqualToString:@"ytlMedia"] && [message.body isKindOfClass:[NSDictionary class]]) {
        self.mediaFullscreen = [message.body[@"fullscreen"] boolValue];
        self.mediaPiP = [message.body[@"pip"] boolValue];
        [self updateBackButton];
    }
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!navigationAction.targetFrame.isMainFrame && navigationAction.request.URL) [webView loadRequest:navigationAction.request];
    return nil;
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

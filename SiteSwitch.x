#import "YTLite.h"
#import "Utils/YTLSafeMode.h"
#import <WebKit/WebKit.h>

@interface YTHeaderView : UIView
@end

static const NSInteger kSiteIconTag = 6621;
static const char kSiteTapKey;
static UIImage *siteIcon;
static NSString *siteIconHost;

NSURL *YTLSiteURL(void) {
    NSString *raw = [[YTLUserDefaults standardUserDefaults] stringForKey:@"siteURL"];
    raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return nil;
    if (![raw containsString:@"://"]) raw = [@"https://" stringByAppendingString:raw];
    NSURL *url = [NSURL URLWithString:raw];
    return url.host.length ? url : nil;
}

static BOOL YTLSiteSwitchReady(void) {
    return ytlBool(@"siteSwitch") && YTLSiteURL() != nil;
}

static void YTLLoadSiteIcon(void (^completion)(UIImage *image)) {
    NSURL *site = YTLSiteURL();
    if (!site) return;
    if (siteIcon && [siteIconHost isEqualToString:site.host]) {
        completion(siteIcon);
        return;
    }

    NSString *host = site.host;
    NSArray <NSString *> *candidates = @[
        [NSString stringWithFormat:@"%@://%@/apple-touch-icon.png", site.scheme ?: @"https", host],
        [NSString stringWithFormat:@"https://www.google.com/s2/favicons?domain=%@&sz=128", host],
        [NSString stringWithFormat:@"%@://%@/favicon.ico", site.scheme ?: @"https", host]
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
                siteIcon = image;
                siteIconHost = host;
                completion(image);
            });
            attempt = nil;
        }] resume];
    };
    attempt(0);
}

@interface YTLSiteViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, copy) NSString *loadedHost;
@property (nonatomic, assign) BOOL mediaFullscreen;
@property (nonatomic, assign) BOOL mediaPiP;
+ (instancetype)shared;
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
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

    NSString *script = @"(function(){"
        "if(window.__ytlBack)return;window.__ytlBack=1;"
        "var host=location.hostname.replace(/^www\\./,'');"
        "var name=host.split('.')[0].toLowerCase().replace(/[^a-z0-9]/g,'');"
        "function norm(t){return (t||'').toLowerCase().replace(/[^a-z0-9]/g,'');}"
        "function isRoot(a){if(!a||!a.getAttribute)return false;var h=a.getAttribute('href');if(h===null)return false;"
        "try{var u=new URL(h,location.href);return u.hostname.replace(/^www\\./,'')===host&&(u.pathname==='/'||u.pathname==='')&&!u.search;}catch(e){return false;}}"
        "function isLogo(el){for(var n=el,i=0;n&&i<6;n=n.parentElement,i++){"
        "if(n.tagName==='A'&&isRoot(n))return true;"
        "var c=(n.className&&n.className.baseVal!==undefined?n.className.baseVal:n.className)||'';var id=n.id||'';"
        "if(/logo|brand/i.test(c+' '+id))return true;"
        "if(n.tagName==='IMG'&&(/logo/i.test(n.alt||'')||/logo/i.test(n.src||'')||(name&&norm(n.alt).indexOf(name)>=0)))return true;"
        "if(name&&name.length>2&&n.children.length===0&&norm(n.textContent)===name)return true;}"
        "return false;}"
        "document.addEventListener('click',function(e){if(isLogo(e.target)){e.preventDefault();e.stopPropagation();"
        "window.webkit.messageHandlers.ytlBack.postMessage(1);}},true);"
        "})();";
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    [configuration.userContentController addScriptMessageHandler:self name:@"ytlBack"];

    NSString *mediaScript = @"(function(){"
        "if(window.__ytlMedia)return;window.__ytlMedia=1;"
        "function send(){var fs=!!(document.fullscreenElement||document.webkitFullscreenElement||document.webkitCurrentFullScreenElement);"
        "var pip=!!document.pictureInPictureElement;"
        "document.querySelectorAll('video').forEach(function(v){if(v.webkitDisplayingFullscreen)fs=true;if(v.webkitPresentationMode&&v.webkitPresentationMode!=='inline'){if(v.webkitPresentationMode==='picture-in-picture')pip=true;else fs=true;}});"
        "window.webkit.messageHandlers.ytlMedia.postMessage({fullscreen:fs,pip:pip});}"
        "['fullscreenchange','webkitfullscreenchange'].forEach(function(n){document.addEventListener(n,send,true);});"
        "['webkitbeginfullscreen','webkitendfullscreen','enterpictureinpicture','leavepictureinpicture','webkitpresentationmodechanged'].forEach(function(n){document.addEventListener(n,send,true);});"
        "})();";
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:mediaScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    [configuration.userContentController addScriptMessageHandler:self name:@"ytlMedia"];

    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    _webView.translatesAutoresizingMaskIntoConstraints = NO;
    _webView.allowsBackForwardNavigationGestures = YES;
    _webView.navigationDelegate = self;
    _webView.UIDelegate = self;
    if ([_webView respondsToSelector:@selector(fullscreenState)]) [_webView addObserver:self forKeyPath:@"fullscreenState" options:NSKeyValueObservingOptionNew context:NULL];
    if ([configuration.preferences respondsToSelector:@selector(setElementFullscreenEnabled:)]) [configuration.preferences setValue:@YES forKey:@"elementFullscreenEnabled"];
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
    UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightBold];
    [_backButton setImage:[UIImage systemImageNamed:@"play.rectangle.fill" withConfiguration:symbol] forState:UIControlStateNormal];
    _backButton.tintColor = [UIColor colorWithRed:1.0 green:0.0 blue:0.2 alpha:1.0];
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

- (BOOL)isWebFullscreen {
    if ([self.webView respondsToSelector:@selector(fullscreenState)] && [[self.webView valueForKey:@"fullscreenState"] integerValue] != 0) return YES;
    return self.mediaFullscreen;
}

- (void)updateBackButton {
    BOOL hide = [self isWebFullscreen] || self.mediaPiP;
    if (self.backButton.hidden == hide) return;
    if (!hide) self.backButton.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{
        self.backButton.alpha = hide ? 0 : 1;
    } completion:^(BOOL finished) {
        self.backButton.hidden = hide;
    }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"fullscreenState"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateBackButton]; });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (CGPointEqualToPoint(self.backButton.center, CGPointMake(26, 26))) {
        UIEdgeInsets insets = self.view.safeAreaInsets;
        self.backButton.center = CGPointMake(CGRectGetWidth(self.view.bounds) - 26 - 16, CGRectGetHeight(self.view.bounds) - insets.bottom - 26 - 24);
    }
    [self.view bringSubviewToFront:self.backButton];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSURL *url = YTLSiteURL();
    if (url && (!self.webView.URL || ![self.loadedHost isEqualToString:url.host])) {
        self.loadedHost = url.host;
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

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"ytlBack"]) [self showLogoMenu];
    if ([message.name isEqualToString:@"ytlMedia"] && [message.body isKindOfClass:[NSDictionary class]]) {
        self.mediaFullscreen = [message.body[@"fullscreen"] boolValue];
        self.mediaPiP = [message.body[@"pip"] boolValue];
        [self updateBackButton];
    }
}

- (void)showLogoMenu {
    if (self.presentedViewController) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"SiteBackToYouTube") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self close];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"SiteHome") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSURL *url = YTLSiteURL();
        if (url) [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), 80, 0, 0);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!navigationAction.targetFrame.isMainFrame && navigationAction.request.URL) [webView loadRequest:navigationAction.request];
    return nil;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDefault;
}

@end

static void YTLPromptSiteURL(void (^completion)(void)) {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"SiteURL") message:LOC(@"SiteURLDesc") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"example.com";
        field.text = [[YTLUserDefaults standardUserDefaults] stringForKey:@"siteURL"];
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *value = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [[YTLUserDefaults standardUserDefaults] setObject:value ?: @"" forKey:@"siteURL"];
        if (YTLSiteURL() && completion) completion();
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void YTLOpenSite(void) {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    YTLSiteViewController *site = [YTLSiteViewController shared];
    if (!presenter || site.presentingViewController || presenter == site) return;
    [presenter presentViewController:site animated:YES completion:nil];
}

@interface YTLSiteTapHandler : NSObject
+ (instancetype)shared;
@end

@implementation YTLSiteTapHandler
+ (instancetype)shared {
    static YTLSiteTapHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [YTLSiteTapHandler new]; });
    return handler;
}

- (void)logoTapped:(UITapGestureRecognizer *)gesture {
    [self showSiteIconOnLogo:gesture.view];
}

- (BOOL)showSiteIconOnLogo:(UIView *)logo {
    if (!logo || !logo.window || !ytlBool(@"siteSwitch")) return NO;
    if (!YTLSiteURL()) {
        YTLPromptSiteURL(^{ YTLOpenSite(); });
        return YES;
    }
    if ([logo viewWithTag:kSiteIconTag]) {
        YTLOpenSite();
        [self restoreLogo:logo];
        return YES;
    }

    CGFloat size = MAX(MIN(CGRectGetHeight(logo.bounds), 30), 22);
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(0, (CGRectGetHeight(logo.bounds) - size) / 2, size, size)];
    icon.tag = kSiteIconTag;
    icon.contentMode = UIViewContentModeScaleAspectFill;
    icon.clipsToBounds = YES;
    icon.layer.cornerRadius = size * 0.22;
    icon.backgroundColor = [UIColor secondarySystemBackgroundColor];
    icon.image = siteIcon ?: [UIImage systemImageNamed:@"globe"];
    icon.tintColor = [UIColor labelColor];
    icon.userInteractionEnabled = YES;
    icon.alpha = 0;
    [icon addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(iconTapped:)]];

    UIView *cover = [[UIView alloc] initWithFrame:logo.bounds];
    cover.tag = kSiteIconTag + 1;
    cover.backgroundColor = logo.superview.backgroundColor ?: [UIColor systemBackgroundColor];
    cover.userInteractionEnabled = YES;
    [cover addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(iconTapped:)]];
    cover.alpha = 0;
    [logo addSubview:cover];
    [logo addSubview:icon];

    YTLLoadSiteIcon(^(UIImage *image) { icon.image = image; });

    [UIView animateWithDuration:0.2 animations:^{
        icon.alpha = 1;
        cover.alpha = 1;
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self restoreLogo:logo];
    });
    return YES;
}

- (void)iconTapped:(UITapGestureRecognizer *)gesture {
    UIView *logo = gesture.view.superview;
    YTLOpenSite();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self restoreLogo:logo];
    });
}

- (void)restoreLogo:(UIView *)logo {
    UIView *icon = [logo viewWithTag:kSiteIconTag];
    UIView *cover = [logo viewWithTag:kSiteIconTag + 1];
    if (!icon && !cover) return;
    [UIView animateWithDuration:0.2 animations:^{
        icon.alpha = 0;
        cover.alpha = 0;
    } completion:^(BOOL finished) {
        [icon removeFromSuperview];
        [cover removeFromSuperview];
    }];
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

@interface YTLSiteTapHandler (Logo)
- (BOOL)showSiteIconOnLogo:(UIView *)logo;
@end

%hook YTHeaderLogoControllerImpl
- (void)setLogoView:(UIView *)logoView {
    %orig;
    if (ytlBool(@"siteSwitch")) YTLAttachSiteTap(logoView);
}

- (void)didTapLogoView {
    UIView *logoView = YTLValue(self, @"logoView");
    if ([logoView isKindOfClass:[UIView class]] && [[YTLSiteTapHandler shared] showSiteIconOnLogo:logoView]) return;
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
    %init(YTHeaderLogoControllerImpl = YTLClass(@"YTHeaderLogoControllerImpl"));
    if (YTLSiteSwitchReady()) YTLLoadSiteIcon(^(UIImage *image) {});
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:[YTLUserDefaults standardUserDefaults] queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (YTLSiteSwitchReady()) YTLLoadSiteIcon(^(UIImage *image) {});
    }];
}

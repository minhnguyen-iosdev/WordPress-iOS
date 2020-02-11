@import WebKit;

#import "SharingAuthorizationWebViewController.h"
#import "Blog.h"
#import "WPUserAgent.h"
#import "WordPress-Swift.h"

#pragma mark - SharingAuthorizationWebViewController

/**
 *	@brief	classify actions taken by web API
 */
typedef NS_ENUM(NSInteger, AuthorizeAction) {
    AuthorizeActionNone,
    AuthorizeActionUnknown,
    AuthorizeActionRequest,
    AuthorizeActionVerify,
    AuthorizeActionDeny,
};

static NSString * const SharingAuthorizationLoginURL = @"https://wordpress.com/wp-login.php";
static NSString * const SharingAuthorizationPrefix = @"https://public-api.wordpress.com/connect/";
static NSString * const SharingAuthorizationRequest = @"action=request";
static NSString * const SharingAuthorizationVerify = @"action=verify";
static NSString * const SharingAuthorizationDeny = @"action=deny";

// Special handling for the inconsistent way that services respond to a user's choice to decline oauth authorization.
// Tumblr is uncooporative and doesn't respond in a way that clearly indicates failure.
// Path does not set the action param or call the callback. It forwards to its own URL ending in /decline.
static NSString * const SharingAuthorizationPathDecline = @"/decline";
// LinkedIn
static NSString * const SharingAuthorizationUserRefused = @"oauth_problem=user_refused";
// Twitter
static NSString * const SharingAuthorizationDenied = @"denied=";
// Facebook and Google+
static NSString * const SharingAuthorizationAccessDenied = @"error=access_denied";


@interface SharingAuthorizationWebViewController ()

/**
 *	@brief	verification loading -- dismiss on completion
 */
@property (nonatomic, assign) BOOL loadingVerify;
/**
 *	@brief	publicize service being authorized
 */
@property (nonatomic, strong) PublicizeService *publicizer;

@property (nonatomic, strong) NSMutableArray *hosts;

@end

@implementation SharingAuthorizationWebViewController

+ (instancetype)controllerWithPublicizer:(PublicizeService *)publicizer
                           connectionURL:(NSURL *)connectionURL
                                 forBlog:(Blog *)blog
{
    NSParameterAssert(publicizer);
    NSParameterAssert(blog);
    
    SharingAuthorizationWebViewController *webViewController = [[self alloc] initWithNibName:@"WPWebViewController" bundle:nil];

    webViewController.authenticator = [[WebViewAuthenticator alloc] initWithBlog:blog];
    webViewController.publicizer = publicizer;
    webViewController.secureInteraction = YES;
    webViewController.url = connectionURL;
    
    return webViewController;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];

    [self cleanup];
}


#pragma mark - Instance Methods

- (NSMutableArray *)hosts
{
    if (!_hosts) {
        _hosts = [NSMutableArray array];
    }
    return _hosts;
}


- (void)saveHostFromURL:(NSURL *)url
{
    NSString *host = url.host;
    if (!host || [host containsString:@"wordpress"] || [self.hosts containsObject:host]) {
        return;
    }
    NSArray *components = [host componentsSeparatedByString:@"."];
    // A bit of paranioa here. The components should never be less than two but just in case...
    NSString *hostName = ([components count] > 1) ? [components objectAtIndex:[components count] - 2] : [components firstObject];
    [self.hosts addObject:hostName];
}

- (void)cleanup
{
    // Log out of the authenticed service.
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [storage cookies]) {
        for (NSString *host in self.hosts) {
            if ([cookie.domain containsString:host]) {
                [storage deleteCookie:cookie];
            }
        }
    }
}

- (IBAction)dismiss
{
    if ([self.delegate respondsToSelector:@selector(authorizeDidCancel:)]) {
        [self.delegate authorizeDidCancel:self.publicizer];
    }
}

- (void)handleAuthorizationAllowed
{
    // Note: There are situations where this can be called in error due to how
    // individual services choose to reply to an authorization request.
    // Delegates should expect to handle a false positive.
    if ([self.delegate respondsToSelector:@selector(authorizeDidSucceed:)]) {
        [self.delegate authorizeDidSucceed:self.publicizer];
    }
}

- (void)displayLoadError:(NSError *)error
{
    if ([self.delegate respondsToSelector:@selector(authorize:didFailWithError:)]) {
        [self.delegate authorize:self.publicizer didFailWithError:error];
    }
}

- (AuthorizeAction)requestedAuthorizeAction:(NSURL *)url
{
    NSString *requested = [url absoluteString];
    
    // Path oauth declines are handled by a redirect to a path.com URL, so check this first.
    NSRange denyRange = [requested rangeOfString:SharingAuthorizationPathDecline];
    if (denyRange.location != NSNotFound) {
        return AuthorizeActionDeny;
    }

    if (![requested hasPrefix:SharingAuthorizationPrefix]) {
        return AuthorizeActionNone;
    }

    NSRange requestRange = [requested rangeOfString:SharingAuthorizationRequest];
    if (requestRange.location != NSNotFound) {
        return AuthorizeActionRequest;
    }

    // Check the rest of the various decline ranges
    denyRange = [requested rangeOfString:SharingAuthorizationDeny];
    if (denyRange.location != NSNotFound) {
        return AuthorizeActionDeny;
    }
    // LinkedIn
    denyRange = [requested rangeOfString:SharingAuthorizationUserRefused];
    if (denyRange.location != NSNotFound) {
        return AuthorizeActionDeny;
    }
    // Twitter
    denyRange = [requested rangeOfString:SharingAuthorizationDenied];
    if (denyRange.location != NSNotFound) {
        return AuthorizeActionDeny;
    }
    // Facebook and Google+
    denyRange = [requested rangeOfString:SharingAuthorizationAccessDenied];
    if (denyRange.location != NSNotFound) {
        return AuthorizeActionDeny;
    }

    // If we've made it this far and verifyRange is found then we're *probably*
    // verifying the oauth request.  There are edge cases ( :cough: tumblr :cough: )
    // where verification is declined and we get a false positive.
    NSRange verifyRange = [requested rangeOfString:SharingAuthorizationVerify];
    if (verifyRange.location != NSNotFound) {
        return AuthorizeActionVerify;
    }

    return AuthorizeActionUnknown;
}

#pragma mark - WKWebViewNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    // Prevent a second verify load by someone happy clicking.
    if (self.loadingVerify) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    AuthorizeAction action = [self requestedAuthorizeAction:navigationAction.request.URL];
    switch (action) {
        case AuthorizeActionNone:
        case AuthorizeActionUnknown:
        case AuthorizeActionRequest:
            [super webView:webView decidePolicyForNavigationAction:navigationAction decisionHandler:decisionHandler];
            return;

        case AuthorizeActionVerify:
            self.loadingVerify = YES;
            decisionHandler(WKNavigationActionPolicyAllow);
            return;

        case AuthorizeActionDeny:
            [self dismiss];
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(null_unspecified WKNavigation *)navigation withError:(NSError *)error
{
    if (self.loadingVerify && error.code == NSURLErrorCancelled) {
        // Authenticating to Facebook and Twitter can return an false
        // NSURLErrorCancelled (-999) error. However the connection still succeeds.
        [self handleAuthorizationAllowed];
        return;
    }
    [super webView:webView didFailNavigation:navigation withError:error];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(null_unspecified WKNavigation *)navigation
{
    [self saveHostFromURL:webView.URL];

    if (self.loadingVerify) {
        [self handleAuthorizationAllowed];
    } else {
        [super webView:webView didFinishNavigation:navigation];
    }
}

@end
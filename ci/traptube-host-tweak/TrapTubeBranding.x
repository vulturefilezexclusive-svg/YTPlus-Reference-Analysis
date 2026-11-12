#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

#import "YTSettingsViewController.h"
#import "YTSettingsSectionItem.h"
#import "YTSettingsCell.h"
#import "YTIIcon.h"
#import "YTPivotBarItemView.h"
#import "YTQTMButton.h"
#import "YTIPivotBarRenderer.h"
#import "YTIPivotBarSupportedRenderers.h"
#import "YTIPivotBarItemRenderer.h"
#import "YTIcon.h"

@interface WelcomeVC : UIViewController
@end

@interface DVNAlertController : UIViewController
@end

@interface YTPivotBarView : UIView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer;
@end

@interface YTPivotBarViewController : UIViewController
@property (nonatomic, copy) NSString *selectedPivotIdentifier;
- (void)selectItemWithPivotIdentifier:(NSString *)identifier;
- (void)updateViewsWithSelectedPivotIdentifier:(NSString *)identifier;
@end

@interface YTAppPivotBarController : NSObject
@end

static NSString * const TTStemPivotIdentifier = @"TRAPTUBE_STEM_STUDIO";
static char TTStemStudioControllerKey;

static char TTPlayerEQHookAssociationKey;

static void TTAttachEQToPlayerItem(id item) {
    if (!item) return;
    Class hookClass = NSClassFromString(@"TrapTubeAudioHook");
    SEL attachSelector = NSSelectorFromString(@"attachInBackgroundTo:");
    if (!hookClass || ![hookClass respondsToSelector:attachSelector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(hookClass, attachSelector, item);
}

static void TTAttachEQToPlayerItemWhenReady(id item) {
    if (!item) return;
    Class hookClass = NSClassFromString(@"TrapTubeAudioHook");
    SEL attachSelector = NSSelectorFromString(@"attachWhenReadyInBackgroundTo:");
    if (!hookClass || ![hookClass respondsToSelector:attachSelector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(hookClass, attachSelector, item);
}

static void TTInstallPlayerEQHook(id player) {
    if (!player || objc_getAssociatedObject(player, &TTPlayerEQHookAssociationKey)) return;
    Class hookClass = NSClassFromString(@"TrapTubeAudioHook");
    SEL initSelector = NSSelectorFromString(@"new");
    SEL installSelector = NSSelectorFromString(@"installOn:");
    if (!hookClass || ![hookClass respondsToSelector:initSelector]) {
        NSLog(@"[TrapTube EQ] TrapTubeAudioHook class unavailable; stream EQ not installed");
        return;
    }
    id hook = ((id (*)(id, SEL))objc_msgSend)(hookClass, initSelector);
    if (![hook respondsToSelector:installSelector]) {
        NSLog(@"[TrapTube EQ] TrapTubeAudioHook does not respond to installOn:; stream EQ not installed");
        return;
    }
    objc_setAssociatedObject(player, &TTPlayerEQHookAssociationKey, hook, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(hook, installSelector, player);
}

#pragma mark - TrapTube accent

static UIFont *TTBrandDisplayFont(CGFloat size) {
    UIFont *font = [UIFont fontWithName:@"RubikSprayPaint-Regular" size:size];
    if (!font) font = [UIFont fontWithName:@"MarkerFelt-Wide" size:size];
    if (!font) font = [UIFont fontWithName:@"AvenirNextCondensed-HeavyItalic" size:size];
    if (!font) font = [UIFont systemFontOfSize:size weight:UIFontWeightBlack];
    return font;
}

static BOOL TTIsTrapTubeBrandText(NSString *text) {
    return [text isKindOfClass:NSString.class] &&
           [text rangeOfString:@"TrapTube" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void TTStyleTrapTubeBrandLabel(UILabel *label) {
    if (!label || !TTIsTrapTubeBrandText(label.text)) return;
    label.font = TTBrandDisplayFont(label.font.pointSize > 0 ? label.font.pointSize : 18);
    label.layer.shadowColor = [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:0.9].CGColor;
    label.layer.shadowOffset = CGSizeMake(0, 1);
    label.layer.shadowRadius = 2.0;
    label.layer.shadowOpacity = 0.65;
}

static UIColor *TTColorFromHex(NSString *hex) {
    NSString *value = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (value.length != 6) return [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:1.0];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    if (![scanner scanHexInt:&rgb]) return [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:1.0];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSString *TTAccentHex(void) {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"TrapTube.AccentHex"];
    return saved.length == 6 ? saved : @"D1091F";
}

static UIColor *TTAccentColor(void) {
    return TTColorFromHex(TTAccentHex());
}

static UIColor *TTStemBackgroundColor(void) {
    return [UIColor colorWithRed:0.025 green:0.025 blue:0.035 alpha:1.0];
}

static UIColor *TTStemMutedColor(void) {
    return TTColorFromHex(@"A6A4A6");
}

static void TTApplyAccentToWindow(UIWindow *window) {
    if (!window) return;
    window.tintColor = TTAccentColor();
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
}

static void TTApplyAccentGlobally(void) {
    UIColor *accent = TTAccentColor();
    UIColor *background = TTStemBackgroundColor();
    UIColor *surface = TTColorFromHex(@"141417");
    UIColor *muted = TTStemMutedColor();

    UINavigationBar *navigation = [UINavigationBar appearance];
    navigation.tintColor = accent;
    navigation.barTintColor = background;
    navigation.barStyle = UIBarStyleBlack;
    navigation.titleTextAttributes = @{ NSForegroundColorAttributeName: UIColor.whiteColor, NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold] };
    navigation.largeTitleTextAttributes = @{ NSForegroundColorAttributeName: UIColor.whiteColor, NSFontAttributeName: [UIFont systemFontOfSize:32 weight:UIFontWeightBold] };

    UITabBar *tabs = [UITabBar appearance];
    tabs.tintColor = accent;
    tabs.unselectedItemTintColor = muted;
    tabs.barTintColor = background;
    tabs.backgroundColor = background;
    tabs.barStyle = UIBarStyleBlack;

    UITableView *tables = [UITableView appearance];
    tables.backgroundColor = background;
    tables.separatorColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];
    [UITableViewCell appearance].backgroundColor = surface;

    [UISwitch appearance].onTintColor = accent;
    [UISlider appearance].minimumTrackTintColor = accent;
    [UISlider appearance].maximumTrackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.18];
    [UISegmentedControl appearance].selectedSegmentTintColor = accent;
    [UIProgressView appearance].progressTintColor = accent;
    [UIProgressView appearance].trackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.12];
    [UIActivityIndicatorView appearance].color = accent;
    // Do not set keyboardAppearance through global appearance proxies. UIKit may
    // apply these setters while the host creates private text-view subclasses
    // off the main thread (for example ASTextKitComponentsTextView). TrapTube
    // leaves keyboard styling to the system unless an owned editor sets it
    // directly during main-thread view construction.

    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        TTApplyAccentToWindow(window);
    }
}

static void TTApplyStemStudioSurfaceToView(UIView *view) {
    if (!view) return;
    UIColor *background = TTStemBackgroundColor();
    UIColor *surface = TTColorFromHex(@"141417");
    UIColor *accent = TTAccentColor();

    if ([view isKindOfClass:UITableView.class]) {
        UITableView *table = (UITableView *)view;
        table.backgroundColor = background;
        table.separatorColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];
    } else if ([view isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *cell = (UITableViewCell *)view;
        cell.backgroundColor = surface;
        cell.contentView.backgroundColor = surface;
        if (!cell.selectedBackgroundView) {
            UIView *selected = [[UIView alloc] initWithFrame:cell.bounds];
            selected.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.075];
            cell.selectedBackgroundView = selected;
        }
    } else if ([view isKindOfClass:UISwitch.class]) {
        ((UISwitch *)view).onTintColor = accent;
    } else if ([view isKindOfClass:UISlider.class]) {
        ((UISlider *)view).minimumTrackTintColor = accent;
    } else if ([view isKindOfClass:UISegmentedControl.class]) {
        ((UISegmentedControl *)view).selectedSegmentTintColor = accent;
    } else if ([view isKindOfClass:UIProgressView.class]) {
        ((UIProgressView *)view).progressTintColor = accent;
    }

    for (UIView *child in view.subviews) {
        TTApplyStemStudioSurfaceToView(child);
    }
}

static UINavigationController *TTAppNavigationController(YTPivotBarViewController *pivot) {
    id parent = pivot.parentViewController;
    id candidate = nil;
    @try {
        if ([parent respondsToSelector:NSSelectorFromString(@"appNavigationController")]) {
            candidate = [parent valueForKey:@"appNavigationController"];
        }
    } @catch (__unused NSException *exception) {}
    if ([candidate isKindOfClass:UINavigationController.class]) return candidate;
    return pivot.navigationController;
}

static void TTShowStemStudio(YTPivotBarViewController *pivot) {
    UINavigationController *navigation = TTAppNavigationController(pivot);
    if (navigation && objc_getAssociatedObject(navigation.topViewController, &TTStemStudioControllerKey)) return;

    Class factory = NSClassFromString(@"TrapTubeStemStudioFactory");
    SEL selector = NSSelectorFromString(@"makeViewController");
    UIViewController *controller = nil;
    if (factory && [factory respondsToSelector:selector]) {
        controller = ((id (*)(id, SEL))objc_msgSend)(factory, selector);
    }
    if (!controller) {
        controller = [[UIViewController alloc] init];
        controller.view.backgroundColor = [UIColor colorWithRed:0.025 green:0.025 blue:0.035 alpha:1];
        UILabel *label = [[UILabel alloc] init];
        label.text = @"Stem Studio is unavailable";
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [controller.view addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
            [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor]
        ]];
    }
    controller.title = @"Stem Studio";
    objc_setAssociatedObject(controller, &TTStemStudioControllerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (navigation) {
        [navigation pushViewController:controller animated:YES];
    } else {
        UIViewController *presenter = pivot.parentViewController ?: pivot;
        [presenter presentViewController:controller animated:YES completion:nil];
    }
}

static void TTHideStemStudio(YTPivotBarViewController *pivot) {
    UINavigationController *navigation = TTAppNavigationController(pivot);
    UIViewController *top = navigation.topViewController;
    if (top && objc_getAssociatedObject(top, &TTStemStudioControllerKey)) {
        [navigation popViewControllerAnimated:NO];
    }
}

static void TTSelectStemStudio(YTPivotBarViewController *pivot) {
    pivot.selectedPivotIdentifier = TTStemPivotIdentifier;
    SEL update = NSSelectorFromString(@"updateViewsWithSelectedPivotIdentifier:");
    if ([pivot respondsToSelector:update]) {
        ((void (*)(id, SEL, id))objc_msgSend)(pivot, update, TTStemPivotIdentifier);
    }
    TTShowStemStudio(pivot);
}

static NSString *TTLocalizedYTLite(NSString *key) {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"YTLite" ofType:@"bundle"];
    NSBundle *bundle = path.length ? [NSBundle bundleWithPath:path] : nil;
    NSString *value = [bundle localizedStringForKey:key value:nil table:nil];
    return value.length ? value : key;
}

static BOOL TTStringContainsBrand(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return NO;
    NSString *lower = value.lowercaseString;
    return [lower containsString:@"ytlite"] ||
           [lower containsString:@"ytplus"] ||
           [lower containsString:@"youtube plus"];
}

static BOOL TTShouldHideSettingsSection(NSString *title) {
    if (![title isKindOfClass:NSString.class] || title.length == 0) return NO;
    NSString *value = title.lowercaseString;
    NSArray<NSString *> *hiddenSections = @[
        @"account", @"developer", @"dayanch96", @"credits", @"special thanks", @"discord", @"social", @"support",
        @"github", @"telegram", @"twitter", @"open source", @"contributors",
        @"feedback", @"traptube plus preferences", @"traptube plus: 6.0~b2", @"6.0~b2"
    ];
    for (NSString *label in hiddenSections) {
        if ([value containsString:label]) return YES;
    }
    return NO;
}

static BOOL TTShouldHideSettingsItem(id item) {
    NSString *title = nil;
    NSString *detail = nil;
    NSString *identifier = nil;
    @try {
        if ([item respondsToSelector:@selector(title)]) title = [item title];
        if ([item respondsToSelector:NSSelectorFromString(@"titleDescription")]) detail = ((id (*)(id, SEL))objc_msgSend)(item, NSSelectorFromString(@"titleDescription"));
        if ([item respondsToSelector:NSSelectorFromString(@"formattedSettingSummary")]) {
            id summary = ((id (*)(id, SEL))objc_msgSend)(item, NSSelectorFromString(@"formattedSettingSummary"));
            if (summary) detail = [NSString stringWithFormat:@"%@ %@", detail ?: @"", summary];
        }
        if ([item respondsToSelector:@selector(accessibilityIdentifier)]) identifier = [item accessibilityIdentifier];
    } @catch (__unused NSException *exception) {}
    NSString *value = [NSString stringWithFormat:@"%@ %@ %@", title ?: @"", detail ?: @"", identifier ?: @""].lowercaseString;
    if (value.length == 0) return NO;
    if ([value containsString:@"traptube plus: 6.0~b2"] ||
        ([value containsString:@"traptube"] && [value containsString:@"6.0~b2"]) ||
        [value containsString:@"ytplus"] ||
        [value containsString:@"ytlite"] ||
        [value containsString:@"youtube plus"]) return YES;
    NSArray<NSString *> *hiddenLabels = @[
        @"subscription status", @"manage account", @"log out", @"logout", @"sign out",
        @"discord rpc", @"discord rich presence", @"discord",
        @"twitter", @"support", @"github", @"telegram", @"social",
        @"developer", @"dayanch96", @"credits", @"special thanks", @"open source", @"contributors", @"feedback",
        @"traptube plus preferences", @"youtube plus preferences", @"ytplus preferences",
        @"volumeboostyt", @"enable volumeboostyt", @"remember volume"
    ];
    for (NSString *label in hiddenLabels) {
        if ([value containsString:label]) return YES;
    }
    return NO;
}

static BOOL TTShouldHideRenderedSettingsText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0) return NO;
    // Trim first: the prune path aggregates label text with a leading space,
    // which otherwise defeats the exact header matches below.
    NSString *value = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSArray<NSString *> *removed = @[
        @"subscription status", @"manage account", @"log out", @"logout", @"sign out",
        @"discord rpc", @"discord rich presence", @"discord", @"dayanch96",
        @"support development", @"support", @"github repository", @"github", @"my telegram channel", @"telegram",
        @"contributors", @"open source libraries", @"open source", @"special thanks", @"twitter", @"social",
        @"feedback", @"developer", @"credits", @"ytplus", @"ytlite", @"youtube plus",
        @"traptube plus preferences", @"traptube plus: 6.0~b2", @"6.0~b2"
    ];
    for (NSString *needle in removed) {
        if ([value containsString:needle]) return YES;
    }
    // These are section headings, not generic words to suppress throughout YouTube.
    if ([value isEqualToString:@"account"] || [value isEqualToString:@"developer"] ||
        [value isEqualToString:@"credits"]) return YES;
    return NO;
}

static void TTAppendVisibleSettingsText(UIView *view, NSMutableString *buffer, NSUInteger depth) {
    if (!view || depth > 7) return;
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length) [buffer appendFormat:@" %@", text];
    } else if ([view isKindOfClass:UIButton.class]) {
        NSString *text = ((UIButton *)view).currentTitle;
        if (text.length) [buffer appendFormat:@" %@", text];
    } else if ([view isKindOfClass:UITextField.class]) {
        NSString *text = ((UITextField *)view).text;
        if (text.length) [buffer appendFormat:@" %@", text];
    } else if ([view isKindOfClass:UITextView.class]) {
        NSString *text = ((UITextView *)view).text;
        if (text.length) [buffer appendFormat:@" %@", text];
    }
    if (view.accessibilityLabel.length) [buffer appendFormat:@" %@", view.accessibilityLabel];
    for (UIView *child in view.subviews) {
        TTAppendVisibleSettingsText(child, buffer, depth + 1);
    }
}

static void TTPruneRemovedSettingsRows(UIView *root) {
    for (UIView *view in [root.subviews copy]) {
        BOOL isRow = [view isKindOfClass:UITableViewCell.class] ||
                     [view isKindOfClass:UICollectionViewCell.class] ||
                     [NSStringFromClass(view.class) containsString:@"HeaderFooterView"];
        if (isRow) {
            NSMutableString *text = [NSMutableString string];
            TTAppendVisibleSettingsText(view, text, 0);
            if (TTShouldHideRenderedSettingsText(text)) {
                view.hidden = YES;
                view.accessibilityElementsHidden = YES;
                view.frame = CGRectZero;
                continue;
            }
        }
        TTPruneRemovedSettingsRows(view);
    }
}

static BOOL TTIsYTLiteSettingsSection(NSString *title, NSArray *items) {
    if (TTStringContainsBrand(title)) return YES;
    NSSet *markers = [NSSet setWithArray:@[
        TTLocalizedYTLite(@"Contributors"),
        TTLocalizedYTLite(@"OpenSourceLibs"),
        TTLocalizedYTLite(@"SupportDevelopment")
    ]];
    for (id item in items) {
        NSString *itemTitle = [item respondsToSelector:@selector(title)] ? [item title] : nil;
        if ([markers containsObject:itemTitle]) return YES;
    }
    return NO;
}

#pragma mark - Hue wheel

@interface TTHueWheelView : UIView
@property (nonatomic, assign) CGFloat hue;
@property (nonatomic, copy) void (^changed)(CGFloat hue);
@end

@implementation TTHueWheelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
        _hue = 0.98;
        self.accessibilityLabel = @"Hue color wheel";
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;
    CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat dimension = MIN(rect.size.width, rect.size.height);
    CGFloat radius = dimension * 0.365;
    CGFloat lineWidth = dimension * 0.105;
    CGContextSetLineWidth(context, lineWidth);
    CGContextSetLineCap(context, kCGLineCapButt);

    for (NSInteger index = 0; index < 360; index++) {
        CGFloat start = ((CGFloat)index / 360.0) * M_PI * 2.0 - M_PI_2;
        CGFloat end = ((CGFloat)(index + 1) / 360.0) * M_PI * 2.0 - M_PI_2;
        UIColor *color = [UIColor colorWithHue:(CGFloat)index / 360.0 saturation:1.0 brightness:1.0 alpha:1.0];
        CGContextSetStrokeColorWithColor(context, color.CGColor);
        CGContextAddArc(context, center.x, center.y, radius, start, end, 0);
        CGContextStrokePath(context);
    }

    CGFloat markerAngle = self.hue * M_PI * 2.0 - M_PI_2;
    CGPoint marker = CGPointMake(center.x + cos(markerAngle) * radius,
                                 center.y + sin(markerAngle) * radius);
    CGFloat markerRadius = lineWidth * 0.55;
    CGContextSetFillColorWithColor(context, UIColor.blackColor.CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(center.x - radius * 0.56,
                                                   center.y - radius * 0.56,
                                                   radius * 1.12, radius * 1.12));
    CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
    CGContextSetLineWidth(context, 3.0);
    CGContextStrokeEllipseInRect(context, CGRectMake(marker.x - markerRadius,
                                                     marker.y - markerRadius,
                                                     markerRadius * 2.0,
                                                     markerRadius * 2.0));
    CGContextSetFillColorWithColor(context, [UIColor colorWithHue:self.hue saturation:1 brightness:1 alpha:1].CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(marker.x - markerRadius * 0.62,
                                                   marker.y - markerRadius * 0.62,
                                                   markerRadius * 1.24,
                                                   markerRadius * 1.24));
}

- (void)updateFromTouch:(UITouch *)touch {
    CGPoint point = [touch locationInView:self];
    CGFloat dx = point.x - CGRectGetMidX(self.bounds);
    CGFloat dy = point.y - CGRectGetMidY(self.bounds);
    CGFloat angle = atan2(dy, dx) + M_PI_2;
    CGFloat value = fmod(angle / (M_PI * 2.0) + 1.0, 1.0);
    self.hue = value;
    [self setNeedsDisplay];
    if (self.changed) self.changed(value);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateFromTouch:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateFromTouch:touches.anyObject];
}

@end

#pragma mark - Saturation / value square

@interface TTSaturationValueView : UIView
@property (nonatomic, assign) CGFloat hue;
@property (nonatomic, assign) CGFloat saturation;
@property (nonatomic, assign) CGFloat brightness;
@property (nonatomic, copy) void (^changed)(CGFloat saturation, CGFloat brightness);
@end

@implementation TTSaturationValueView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.layer.cornerRadius = 16.0;
        self.layer.masksToBounds = YES;
        _hue = 0.98;
        _saturation = 0.92;
        _brightness = 0.82;
        self.accessibilityLabel = @"Saturation and brightness selector";
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;
    UIColor *pureHue = [UIColor colorWithHue:self.hue saturation:1.0 brightness:1.0 alpha:1.0];
    CGContextSaveGState(context);
    CGContextAddRect(context, rect);
    CGContextClip(context);

    CGContextSetFillColorWithColor(context, pureHue.CGColor);
    CGContextFillRect(context, rect);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSArray *horizontalColors = @[(id)UIColor.whiteColor.CGColor, (id)pureHue.CGColor];
    CGFloat horizontalLocations[] = {0.0, 1.0};
    CGGradientRef horizontal = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)horizontalColors, horizontalLocations);
    CGContextDrawLinearGradient(context, horizontal, CGPointMake(CGRectGetMinX(rect), CGRectGetMidY(rect)),
                                CGPointMake(CGRectGetMaxX(rect), CGRectGetMidY(rect)), 0);
    CGGradientRelease(horizontal);

    NSArray *verticalColors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                                (id)[UIColor colorWithWhite:0 alpha:1].CGColor];
    CGFloat verticalLocations[] = {0.0, 1.0};
    CGGradientRef vertical = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)verticalColors, verticalLocations);
    CGContextDrawLinearGradient(context, vertical, CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)),
                                CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect)), 0);
    CGGradientRelease(vertical);
    CGColorSpaceRelease(colorSpace);

    CGFloat markerX = self.saturation * rect.size.width;
    CGFloat markerY = (1.0 - self.brightness) * rect.size.height;
    CGFloat markerRadius = 9.0;
    CGContextSetStrokeColorWithColor(context, UIColor.blackColor.CGColor);
    CGContextSetLineWidth(context, 4.0);
    CGContextStrokeEllipseInRect(context, CGRectMake(markerX - markerRadius, markerY - markerRadius,
                                                     markerRadius * 2.0, markerRadius * 2.0));
    CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
    CGContextSetLineWidth(context, 2.0);
    CGContextStrokeEllipseInRect(context, CGRectMake(markerX - markerRadius, markerY - markerRadius,
                                                     markerRadius * 2.0, markerRadius * 2.0));
    CGContextRestoreGState(context);
}

- (void)updateFromTouch:(UITouch *)touch {
    CGPoint point = [touch locationInView:self];
    CGFloat width = MAX(1.0, self.bounds.size.width);
    CGFloat height = MAX(1.0, self.bounds.size.height);
    self.saturation = MIN(1.0, MAX(0.0, point.x / width));
    self.brightness = 1.0 - MIN(1.0, MAX(0.0, point.y / height));
    [self setNeedsDisplay];
    if (self.changed) self.changed(self.saturation, self.brightness);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateFromTouch:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateFromTouch:touches.anyObject];
}

@end

#pragma mark - Theme settings controller

@interface TrapTubeThemeViewController : UIViewController
@property (nonatomic, strong) TTHueWheelView *hueWheel;
@property (nonatomic, strong) TTSaturationValueView *svSquare;
@property (nonatomic, strong) UIView *preview;
@property (nonatomic, assign) CGFloat hue;
@property (nonatomic, assign) CGFloat saturation;
@property (nonatomic, assign) CGFloat brightness;
@end

@implementation TrapTubeThemeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TrapTube Appearance";
    self.view.backgroundColor = [UIColor colorWithRed:0.025 green:0.025 blue:0.035 alpha:1.0];

    CGFloat hue = 0.98, saturation = 0.92, brightness = 0.82;
    CGFloat initialAlpha = 1.0;
    [TTAccentColor() getHue:&hue saturation:&saturation brightness:&brightness alpha:&initialAlpha];
    self.hue = hue; self.saturation = saturation; self.brightness = brightness;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20]
    ]];

    UILabel *intro = [[UILabel alloc] init];
    intro.text = @"Choose TrapTube's accent color";
    intro.textColor = UIColor.whiteColor;
    intro.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    intro.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:intro];

    self.preview = [[UIView alloc] init];
    self.preview.translatesAutoresizingMaskIntoConstraints = NO;
    self.preview.layer.cornerRadius = 13;
    self.preview.layer.borderWidth = 1;
    self.preview.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.2].CGColor;
    [NSLayoutConstraint activateConstraints:@[
        [self.preview.widthAnchor constraintEqualToConstant:54],
        [self.preview.heightAnchor constraintEqualToConstant:54]
    ]];
    [stack addArrangedSubview:self.preview];

    UILabel *hueLabel = [[UILabel alloc] init];
    hueLabel.text = @"HUE";
    hueLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    hueLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    [stack addArrangedSubview:hueLabel];

    self.hueWheel = [[TTHueWheelView alloc] init];
    self.hueWheel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hueWheel.hue = hue;
    [NSLayoutConstraint activateConstraints:@[
        [self.hueWheel.widthAnchor constraintEqualToConstant:218],
        [self.hueWheel.heightAnchor constraintEqualToConstant:218]
    ]];
    [stack addArrangedSubview:self.hueWheel];

    UILabel *svLabel = [[UILabel alloc] init];
    svLabel.text = @"SATURATION  /  BRIGHTNESS";
    svLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    svLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    [stack addArrangedSubview:svLabel];

    self.svSquare = [[TTSaturationValueView alloc] init];
    self.svSquare.translatesAutoresizingMaskIntoConstraints = NO;
    self.svSquare.hue = hue;
    self.svSquare.saturation = saturation;
    self.svSquare.brightness = brightness;
    [NSLayoutConstraint activateConstraints:@[
        [self.svSquare.widthAnchor constraintEqualToConstant:300],
        [self.svSquare.heightAnchor constraintEqualToConstant:154]
    ]];
    [stack addArrangedSubview:self.svSquare];

    UILabel *presetsLabel = [[UILabel alloc] init];
    presetsLabel.text = @"TRAPTUBE PRESETS";
    presetsLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    presetsLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    [stack addArrangedSubview:presetsLabel];

    UIStackView *presets = [[UIStackView alloc] init];
    presets.axis = UILayoutConstraintAxisHorizontal;
    presets.alignment = UIStackViewAlignmentCenter;
    presets.distribution = UIStackViewDistributionEqualSpacing;
    presets.spacing = 12;
    NSArray *colors = @[
        [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:1],
        [UIColor colorWithRed:0.62 green:0.015 blue:0.07 alpha:1],
        [UIColor colorWithRed:0.10 green:0.82 blue:0.26 alpha:1],
        [UIColor colorWithRed:0.42 green:0.20 blue:0.95 alpha:1],
        [UIColor colorWithRed:0.05 green:0.68 blue:0.95 alpha:1]
    ];
    for (NSInteger index = 0; index < colors.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = index;
        button.backgroundColor = colors[index];
        button.layer.cornerRadius = 17;
        button.layer.borderWidth = 1.5;
        button.layer.borderColor = [UIColor whiteColor].CGColor;
        [button.widthAnchor constraintEqualToConstant:34].active = YES;
        [button.heightAnchor constraintEqualToConstant:34].active = YES;
        [button addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [presets addArrangedSubview:button];
    }
    [stack addArrangedSubview:presets];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:@"Reset to TrapTube Red" forState:UIControlStateNormal];
    reset.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [reset addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:reset];

    __weak typeof(self) weakSelf = self;
    self.hueWheel.changed = ^(CGFloat value) {
        weakSelf.hue = value;
        weakSelf.svSquare.hue = value;
        [weakSelf.svSquare setNeedsDisplay];
        [weakSelf updatePreviewAndPersist];
    };
    self.svSquare.changed = ^(CGFloat sat, CGFloat val) {
        weakSelf.saturation = sat;
        weakSelf.brightness = val;
        [weakSelf updatePreviewAndPersist];
    };
    [self updatePreviewAndPersist];
}

- (UIColor *)selectedColor {
    return [UIColor colorWithHue:self.hue saturation:self.saturation brightness:self.brightness alpha:1.0];
}

- (void)updatePreviewAndPersist {
    UIColor *color = [self selectedColor];
    self.preview.backgroundColor = color;
    CGFloat red = 0, green = 0, blue = 0, alpha = 1;
    [color getRed:&red green:&green blue:&blue alpha:&alpha];
    NSString *hex = [NSString stringWithFormat:@"%02X%02X%02X",
                     (int)round(red * 255), (int)round(green * 255), (int)round(blue * 255)];
    [[NSUserDefaults standardUserDefaults] setObject:hex forKey:@"TrapTube.AccentHex"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    TTApplyAccentGlobally();
}

- (void)setFromColor:(UIColor *)color {
    CGFloat alpha = 1.0;
    [color getHue:&_hue saturation:&_saturation brightness:&_brightness alpha:&alpha];
    self.hueWheel.hue = self.hue;
    self.svSquare.hue = self.hue;
    self.svSquare.saturation = self.saturation;
    self.svSquare.brightness = self.brightness;
    [self.hueWheel setNeedsDisplay];
    [self.svSquare setNeedsDisplay];
    [self updatePreviewAndPersist];
}

- (void)presetTapped:(UIButton *)sender {
    NSArray *colors = @[
        [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:1],
        [UIColor colorWithRed:0.62 green:0.015 blue:0.07 alpha:1],
        [UIColor colorWithRed:0.10 green:0.82 blue:0.26 alpha:1],
        [UIColor colorWithRed:0.42 green:0.20 blue:0.95 alpha:1],
        [UIColor colorWithRed:0.05 green:0.68 blue:0.95 alpha:1]
    ];
    if (sender.tag < colors.count) [self setFromColor:colors[sender.tag]];
}

- (void)resetTapped {
    [self setFromColor:[UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:1]];
}

@end

#pragma mark - Stream volume boost controls

// The controls are hosted in SwiftUI by TrapTubeAudioBoostFactory. This keeps
// the settings destination consistent with the native Stem Studio surfaces.

#pragma mark - Settings registration

static void TTPrepareSettingsItems(NSMutableArray *items, YTSettingsViewController *settings) {
    NSString *contributors = TTLocalizedYTLite(@"Contributors");
    NSString *openSource = TTLocalizedYTLite(@"OpenSourceLibs");
    NSString *support = TTLocalizedYTLite(@"SupportDevelopment");
    NSIndexSet *removeIndexes = [items indexesOfObjectsPassingTest:^BOOL(id item, NSUInteger index, BOOL *stop) {
        NSString *title = [item respondsToSelector:@selector(title)] ? [item title] : nil;
        return TTShouldHideSettingsItem(item) ||
               [title isEqualToString:contributors] ||
               [title isEqualToString:openSource] ||
               [title isEqualToString:support];
    }];
    if (removeIndexes.count) [items removeObjectsAtIndexes:removeIndexes];

    BOOL appearanceAdded = NO;
    BOOL boostAdded = NO;
    for (id item in items) {
        NSString *identifier = [item respondsToSelector:@selector(accessibilityIdentifier)] ? [item accessibilityIdentifier] : nil;
        if ([identifier isEqualToString:@"TrapTubeAppearance"]) appearanceAdded = YES;
        if ([identifier isEqualToString:@"TrapTubeStreamVolumeBoost"]) boostAdded = YES;
    }
    if (appearanceAdded && boostAdded) return;

    __weak YTSettingsViewController *weakSettings = settings;
    Class settingsItemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL itemFactory = sel_registerName("itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (!settingsItemClass || ![settingsItemClass respondsToSelector:itemFactory]) {
        NSLog(@"[TrapTube] YTSettingsSectionItem factory unavailable; skipping custom settings rows");
        return;
    }

    if (!boostAdded) {
        id boostDetail = ^NSString *{
            return @"Adjust stream gain beyond the normal volume range";
        };
        id boostSelect = ^BOOL(id cell, NSUInteger index) {
            __strong YTSettingsViewController *strongSettings = weakSettings;
            if (!strongSettings) return NO;
            Class factory = NSClassFromString(@"TrapTubeAudioBoostFactory");
            SEL make = NSSelectorFromString(@"makeViewController");
            UIViewController *controller = nil;
            if (factory && [factory respondsToSelector:make]) {
                controller = ((id (*)(id, SEL))objc_msgSend)(factory, make);
            }
            if (!controller) return NO;
            [strongSettings pushViewController:controller];
            return YES;
        };
        id boost = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            settingsItemClass, itemFactory, @"Stream Volume Boost", @"TrapTubeStreamVolumeBoost", boostDetail, boostSelect
        );
        if (boost) [items insertObject:boost atIndex:0];
    }

    if (!appearanceAdded) {
        id appearanceDetail = ^NSString *{
            return @"Set the TrapTube accent color";
        };
        id appearanceSelect = ^BOOL(id cell, NSUInteger index) {
            __strong YTSettingsViewController *strongSettings = weakSettings;
            if (!strongSettings) return NO;
            TrapTubeThemeViewController *controller = [[TrapTubeThemeViewController alloc] init];
            [strongSettings pushViewController:controller];
            return YES;
        };
        id appearance = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            settingsItemClass, itemFactory, @"TrapTube Appearance", @"TrapTubeAppearance", appearanceDetail, appearanceSelect
        );
        if (appearance) [items insertObject:appearance atIndex:0];
    }
}


%hook AVPlayer

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
    id result = %orig;
    TTInstallPlayerEQHook(result);
    return result;
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    %orig;
    TTInstallPlayerEQHook(self);
}

- (instancetype)initWithURL:(NSURL *)url {
    id result = %orig;
    TTInstallPlayerEQHook(result);
    return result;
}

- (void)play {
    %orig;
    TTInstallPlayerEQHook(self);
}

- (void)playImmediatelyAtRate:(float)rate {
    %orig;
    TTInstallPlayerEQHook(self);
}

%end

%hook AVPlayerItem

+ (instancetype)playerItemWithURL:(NSURL *)url {
    id result = %orig;
    TTAttachEQToPlayerItem(result);
    return result;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset {
    id result = %orig;
    TTAttachEQToPlayerItem(result);
    return result;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    id result = %orig;
    TTAttachEQToPlayerItem(result);
    return result;
}

- (instancetype)initWithURL:(NSURL *)url {
    id result = %orig;
    TTAttachEQToPlayerItem(result);
    return result;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
    id result = %orig;
    TTAttachEQToPlayerItem(result);
    return result;
}

- (instancetype)initWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    id result = %orig;
    TTAttachEQToPlayerItem(result);
    return result;
}

- (void)setAudioMix:(AVAudioMix *)audioMix {
    %orig;
    // Any code assigning this item a mix is a signal the item is entering a
    // real playback pipeline. If our tap is not part of that mix, the Swift
    // attach path re-checks and installs it (it de-dupes per item).
    TTAttachEQToPlayerItem(self);
}

- (AVAudioMix *)audioMix {
    AVAudioMix *mix = %orig;
    // The playback pipeline reads the mix while building its render graph,
    // so a read is the most reliable "entering real playback" signal there
    // is. Schedule an asynchronous attach only: a synchronous one could
    // re-enter through the attach path's own mix reads.
    TTAttachEQToPlayerItemWhenReady(self);
    return mix;
}

%end

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    %orig;
    if (player) {
        TTInstallPlayerEQHook(player);
        TTAttachEQToPlayerItem([player currentItem]);
    }
}

%end

%hook AVQueuePlayer

- (instancetype)initWithItems:(NSArray<AVPlayerItem *> *)items {
    id result = %orig;
    TTInstallPlayerEQHook(result);
    return result;
}

%end

#pragma mark - First-launch cleanup and host hooks

static BOOL TTSuppressPresentation(UIViewController *controller) {
    if (!controller) return NO;
    NSString *className = NSStringFromClass(controller.class);
    if ([className isEqualToString:@"WelcomeVC"]) return YES;

    if ([className isEqualToString:@"DVNAlertController"]) {
        NSString *title = nil;
        NSString *message = nil;
        @try {
            if ([controller respondsToSelector:@selector(title)]) title = [controller valueForKey:@"title"];
            if ([controller respondsToSelector:@selector(message)]) message = [controller valueForKey:@"message"];
        } @catch (__unused NSException *exception) {}
        NSString *combined = [NSString stringWithFormat:@"%@ %@", title ?: @"", message ?: @""].lowercaseString;
        if ([title.lowercaseString isEqualToString:@"advanced"] ||
            [combined containsString:@"advanced mode"] ||
            [combined containsString:@"advanced settings"] ||
            [combined containsString:@"ytlite"] ||
            [combined containsString:@"ytplus"] ||
            [combined containsString:@"youtube plus"]) return YES;
    }
    return NO;
}

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    if (TTSuppressPresentation(viewControllerToPresent)) {
        if (completion) completion();
        return;
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    TTApplyAccentToWindow(self.view.window);
    TTApplyStemStudioSurfaceToView(self.view);
}

%end

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (TTSuppressPresentation(viewController)) return;
    %orig;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    NSMutableArray *filtered = [NSMutableArray array];
    for (UIViewController *controller in viewControllers) {
        if (!TTSuppressPresentation(controller)) [filtered addObject:controller];
    }
    %orig(filtered, animated);
}

%end

static BOOL TTIsRemovedVersionFooter(NSString *text);

// MARK: - YTPlus (YTLite) settings model filtering
//
// The Plus settings screen never uses YTSettingsViewController. It is built
// from DVNTableModel / DVNSection / DVNCell objects (signatures confirmed from
// the host binary) assembled by YTPSettingsBuilder and rendered by
// DVNTableViewController. Filtering at the model chokepoints below removes
// the Account / Developer / Credits sections, the Discord RPC row and the
// version footer before anything is rendered.

static BOOL TTShouldHideDVNCellText(NSString *title) {
    if (![title isKindOfClass:NSString.class] || title.length == 0) return NO;
    NSString *value = title.lowercaseString;
    if (([value containsString:@"traptube"] || [value containsString:@"ytplus"] ||
         [value containsString:@"youtube plus"]) && [value containsString:@"6.0~b2"]) return YES;
    // Deliberately narrower than TTShouldHideSettingsItem: that list also
    // matches feature pages' own rows (it emptied the Volume Boost page,
    // whose cells are titled after the feature). Only the rows the user
    // asked to remove from the Plus settings belong here; whole sections
    // are dropped by header in TTIsRemovedDVNSection.
    NSArray<NSString *> *labels = @[
        @"subscription status", @"manage account", @"log out", @"logout",
        @"discord",
        @"support development", @"github repository", @"my telegram channel", @"follow me",
        @"contributors", @"open source librar", @"special thanks",
        @"traptube plus preferences", @"youtube plus preferences", @"ytplus preferences"
    ];
    for (NSString *label in labels) {
        if ([value containsString:label]) return YES;
    }
    return NO;
}

static BOOL TTIsVolumeBoostModel(id model) {
    if (!model) return NO;
    NSString *title = nil;
    @try {
        if ([model respondsToSelector:@selector(title)]) title = [model valueForKey:@"title"];
    } @catch (NSException *exception) {}
    return [title isKindOfClass:NSString.class] &&
           [title.lowercaseString containsString:@"volumeboost"];
}

static BOOL TTIsRemovedDVNCell(id cell) {
    if (!cell) return NO;
    NSString *cellTitle = nil;
    @try {
        if ([cell respondsToSelector:@selector(title)]) cellTitle = [cell valueForKey:@"title"];
    } @catch (NSException *exception) {}
    if ([cellTitle.lowercaseString containsString:@"volumeboost"]) return NO;
    if (TTShouldHideDVNCellText(cellTitle)) return YES;
    NSString *key = nil;
    NSString *identifier = nil;
    @try {
        if ([cell respondsToSelector:@selector(key)]) key = [cell valueForKey:@"key"];
        if ([cell respondsToSelector:@selector(identifier)]) identifier = [cell valueForKey:@"identifier"];
    } @catch (NSException *exception) {}
    NSString *identity = [NSString stringWithFormat:@"%@ %@",
                            [key isKindOfClass:NSString.class] ? key : @"",
                            [identifier isKindOfClass:NSString.class] ? identifier : @""].lowercaseString;
    if ([identity containsString:@"discord"]) return YES;
    if ([identity containsString:@"patreon"]) return YES;
    return NO;
}

static BOOL TTIsRemovedDVNSection(id section) {
    if (!section) return NO;
    NSString *header = nil;
    NSString *identifier = nil;
    @try {
        if ([section respondsToSelector:@selector(header)]) header = [section valueForKey:@"header"];
        if ([section respondsToSelector:@selector(identifier)]) identifier = [section valueForKey:@"identifier"];
    } @catch (NSException *exception) {}
    // Narrower than TTShouldHideSettingsSection on purpose: broad terms in
    // that list (support, github, telegram) can appear in kept pages.
    NSArray<NSString *> *removedSections = @[
        @"account", @"developer", @"dayanch96", @"credits",
        @"traptube plus preferences", @"youtube plus preferences", @"ytplus preferences", @"6.0~b2"
    ];
    for (NSString *label in removedSections) {
        if ([header isKindOfClass:NSString.class] && [header.lowercaseString containsString:label]) return YES;
        if ([identifier isKindOfClass:NSString.class] && [identifier.lowercaseString containsString:label]) return YES;
    }
    return NO;
}

static NSArray *TTFilteredDVNCells(NSArray *cells) {
    if (![cells isKindOfClass:NSArray.class]) return cells;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:cells.count];
    for (id cell in cells) {
        if (!TTIsRemovedDVNCell(cell)) [kept addObject:cell];
    }
    return kept.count == cells.count ? cells : [kept copy];
}

static void TTFilterDVNSectionCells(id section) {
    if (!section || ![section respondsToSelector:@selector(cells)] ||
        ![section respondsToSelector:@selector(setCells:)]) return;
    NSArray *cells = nil;
    @try { cells = [section valueForKey:@"cells"]; } @catch (NSException *exception) {}
    if ([cells isKindOfClass:NSArray.class] && cells.count) {
        NSArray *filtered = TTFilteredDVNCells(cells);
        if (filtered != cells) {
            @try { [section setValue:filtered forKey:@"cells"]; } @catch (NSException *exception) {}
        }
    }
}

static NSArray *TTFilteredDVNSections(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class]) return sections;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:sections.count];
    for (id section in sections) {
        if (TTIsRemovedDVNSection(section)) continue;
        TTFilterDVNSectionCells(section);
        [kept addObject:section];
    }
    return [kept copy];
}

%hook DVNTableModel

- (void)addSection:(id)section {
    if (TTIsVolumeBoostModel(self)) { %orig; return; }
    if (TTIsRemovedDVNSection(section)) return;
    TTFilterDVNSectionCells(section);
    %orig;
}

- (void)addSections:(NSArray *)sections {
    if (TTIsVolumeBoostModel(self)) { %orig; return; }
    %orig(TTFilteredDVNSections(sections));
}

- (void)setSections:(NSArray *)sections {
    if (TTIsVolumeBoostModel(self)) { %orig; return; }
    %orig(TTFilteredDVNSections(sections));
}

- (void)setFooter:(NSString *)footer {
    if (footer.length && TTIsRemovedVersionFooter(footer)) {
        %orig(nil);
        return;
    }
    %orig;
}

+ (id)modelWithTitle:(NSString *)title sections:(NSArray *)sections {
    return %orig(title, TTFilteredDVNSections(sections));
}

+ (id)modelWithTitle:(NSString *)title header:(NSString *)header footer:(NSString *)footer sections:(NSArray *)sections {
    if (footer.length && TTIsRemovedVersionFooter(footer)) footer = nil;
    return %orig(title, header, footer, TTFilteredDVNSections(sections));
}

%end

%hook DVNSection

- (void)setCells:(NSArray *)cells {
    %orig(TTFilteredDVNCells(cells));
}

- (void)addCell:(id)cell {
    if (TTIsRemovedDVNCell(cell)) return;
    %orig;
}

- (void)addCells:(NSArray *)cells {
    %orig(TTFilteredDVNCells(cells));
}

- (void)_appendCells:(NSArray *)cells {
    %orig(TTFilteredDVNCells(cells));
}

- (void)setFooter:(NSString *)footer {
    if (footer.length && TTIsRemovedVersionFooter(footer)) {
        %orig(nil);
        return;
    }
    %orig;
}

%end

%hook DVNTableViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIViewController *controller = (UIViewController *)self;
    // Backstop for content populated lazily (e.g. cellsProvider sections):
    // run the rendered-row pruning pass once the Plus table is on screen.
    dispatch_async(dispatch_get_main_queue(), ^{
        TTPruneRemovedSettingsRows(controller.view);
    });
}

%end

%hook WelcomeVC

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = (UIViewController *)self;
        if (controller.presentingViewController) {
            [controller dismissViewControllerAnimated:NO completion:nil];
        } else if (controller.navigationController.topViewController == controller) {
            [controller.navigationController popViewControllerAnimated:NO];
        }
    });
}

%end

%hook YTSettingsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // Apply the section cleanup before the settings panel is first presented.
    TTPruneRemovedSettingsRows(self.view);
}

- (void)viewDidLayoutSubviews {
    %orig;
    TTApplyStemStudioSurfaceToView(self.view);
    // Re-apply after each layout because the host lazily rebuilds some settings
    // rows after the initial section model has been populated.
    TTPruneRemovedSettingsRows(self.view);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // The host can insert Account/Developer/Credits content during appearance.
    // Run once more after that insertion pass so the removed groups do not remain.
    dispatch_async(dispatch_get_main_queue(), ^{
        TTPruneRemovedSettingsRows(self.view);
    });
}

- (void)setSectionItems:(NSMutableArray *)sectionItems
             forCategory:(NSInteger)category
                   title:(NSString *)title
                    icon:(YTIIcon *)icon
         titleDescription:(NSString *)titleDescription
            headerHidden:(BOOL)headerHidden {
    // The VolumeBoostYT feature's own settings section must pass through
    // untouched: its rows are titled after the feature, and the generic
    // removal list matches those titles, which emptied the whole page.
    if (title && [title.lowercaseString containsString:@"volumeboost"]) {
        %orig;
        return;
    }

    // Remove entire unwanted sections and their rows, while leaving unrelated
    // YouTube settings categories untouched.
    if (TTShouldHideSettingsSection(title)) {
        %orig([NSMutableArray array], category, title, icon, titleDescription, YES);
        return;
    }

    NSMutableArray *filtered = [sectionItems mutableCopy] ?: [NSMutableArray array];
    NSIndexSet *hiddenRows = [filtered indexesOfObjectsPassingTest:^BOOL(id item, NSUInteger index, BOOL *stop) {
        return TTShouldHideSettingsItem(item);
    }];
    if (hiddenRows.count) [filtered removeObjectsAtIndexes:hiddenRows];

    if (TTIsYTLiteSettingsSection(title, sectionItems)) {
        TTPrepareSettingsItems(filtered, self);
        %orig(filtered, category, @"TrapTube Settings", icon, titleDescription, headerHidden);
        return;
    }

    if (filtered.count != sectionItems.count) {
        // If filtering emptied the section, hide its header too so no orphan
        // section title (e.g. an empty "Account") remains above nothing.
        %orig(filtered, category, title, icon, titleDescription,
              filtered.count == 0 ? YES : headerHidden);
        return;
    }
    %orig;
}

%end

%hook YTPivotBarView

- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    if (renderer) {
        NSMutableArray<YTIPivotBarSupportedRenderers *> *items = [renderer itemsArray];
        BOOL alreadyPresent = [items indexOfObjectPassingTest:^BOOL(YTIPivotBarSupportedRenderers *entry, NSUInteger index, BOOL *stop) {
            return [[[entry pivotBarItemRenderer] pivotIdentifier] isEqualToString:TTStemPivotIdentifier];
        }] != NSNotFound;
        if (!alreadyPresent) {
            // Resolve the private YouTube renderer class dynamically. A direct
            // Objective-C class reference creates an undefined _OBJC_CLASS_ symbol
            // in the injected tweak on some host builds and prevents dyld startup.
            Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
            SEL factory = sel_registerName("pivotSupportedRenderersWithBrowseId:title:iconType:");
            id stem = nil;
            if (rendererClass && [rendererClass respondsToSelector:factory]) {
                stem = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
                    rendererClass, factory, @"FEwhat_to_watch", @"Stem Studio", YT_AUDIO
                );
            }
            if (!stem) {
                NSLog(@"[TrapTube] Pivot renderer factory unavailable; leaving host tabs unchanged");
                %orig;
                return;
            }
            id item = [stem pivotBarItemRenderer];
            // Keep private renderer property access runtime-only so this tweak
            // does not bind to SDK-specific declarations at compile time.
            SEL setPivotIdentifier = NSSelectorFromString(@"setPivotIdentifier:");
            SEL setTargetId = NSSelectorFromString(@"setTargetId:");
            SEL setNavigationEndpoint = NSSelectorFromString(@"setNavigationEndpoint:");
            SEL setIconType = NSSelectorFromString(@"setIconType:");
            if ([item respondsToSelector:setPivotIdentifier]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, setPivotIdentifier, TTStemPivotIdentifier);
            }
            if ([item respondsToSelector:setTargetId]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, setTargetId, TTStemPivotIdentifier);
            }
            if ([item respondsToSelector:setNavigationEndpoint]) {
                ((void (*)(id, SEL, id))objc_msgSend)(item, setNavigationEndpoint, nil);
            }
            if ([item respondsToSelector:setIconType]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(item, setIconType, YT_AUDIO);
            }
            [items addObject:stem];
        }
    }
    %orig;
}

%end

%hook YTPivotBarViewController

- (void)selectItemWithPivotIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:TTStemPivotIdentifier]) {
        TTSelectStemStudio(self);
        return;
    }
    TTHideStemStudio(self);
    %orig;
}

%end

%hook YTAppPivotBarController

- (void)pivotBarViewController:(YTPivotBarViewController *)controller
 didTapItemWithPivotIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:TTStemPivotIdentifier]) {
        TTSelectStemStudio(controller);
        return;
    }
    TTHideStemStudio(controller);
    %orig;
}

%end

%hook YTPivotBarItemView

- (void)setRenderer:(id)renderer {
    %orig;
    self.navigationButton.tintColor = TTAccentColor();
    [self.navigationButton setTitleColor:TTAccentColor() forState:UIControlStateSelected];
}

%end


#pragma mark - Host-wide TrapTube identity

static NSString *TTRebrandedHostText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0) return text;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed caseInsensitiveCompare:@"YouTube"] == NSOrderedSame) {
        return [text stringByReplacingOccurrencesOfString:trimmed withString:@"TrapTube"];
    }
    // Only rewrite explicit product/brand UI phrases. Creator-authored video titles
    // and descriptions that merely discuss YouTube remain untouched unless they
    // are clearly a short branded control/header phrase.
    NSArray<NSString *> *brandPhrases = @[
        @"YouTube Premium", @"YouTube Music", @"YouTube Shorts",
        @"YouTube Kids", @"YouTube TV", @"YouTube Studio",
        @"YouTube Originals", @"YouTube Settings"
    ];
    for (NSString *phrase in brandPhrases) {
        NSRange range = [text rangeOfString:phrase options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            NSString *replacement = [phrase stringByReplacingOccurrencesOfString:@"YouTube" withString:@"TrapTube"];
            return [text stringByReplacingCharactersInRange:range withString:replacement];
        }
    }
    // Header/action copy such as "Sign in to YouTube" or "Watch on YouTube".
    if (text.length <= 80) {
        NSRange range = [text rangeOfString:@"YouTube" options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            return [text stringByReplacingCharactersInRange:range withString:@"TrapTube"];
        }
    }
    return text;
}

static BOOL TTIsYouTubeWordmarkAssetName(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return NO;
    NSString *lower = name.lowercaseString;
    BOOL identifiesYouTube = [lower containsString:@"youtube"] ||
                             [lower containsString:@"you_tube"] ||
                             [lower containsString:@"yt_logo"];
    // Never replace square app-icon assets with the horizontal header wordmark.
    BOOL isSquareIcon = [lower containsString:@"app_icon"] ||
                        [lower containsString:@"icon"] ||
                        [lower containsString:@"60x60"] ||
                        [lower containsString:@"76x76"];
    BOOL identifiesWordmark = [lower containsString:@"wordmark"] ||
                              [lower containsString:@"logotype"] ||
                              [lower containsString:@"logo_lockup"] ||
                              [lower containsString:@"header_logo"] ||
                              ([lower containsString:@"logo"] && !isSquareIcon);
    return identifiesYouTube && identifiesWordmark && !isSquareIcon;
}

static UIImage *TTTrapTubeWordmark(void) {
    static UIImage *wordmark = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *text = @"TrapTube";
        // Keep the replacement close to the stock YouTube wordmark footprint
        // (about 90x20 pt). The previous 42 pt render sprawled across headers
        // and overlapped neighbouring buttons such as the settings gear.
        UIFont *font = TTBrandDisplayFont(24);
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:0.95];
        shadow.shadowOffset = CGSizeMake(1.5, 1.5);
        shadow.shadowBlurRadius = 1.5;
        NSDictionary *attributes = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: UIColor.whiteColor,
            NSStrokeColorAttributeName: [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:1.0],
            NSStrokeWidthAttributeName: @(-1.2),
            NSShadowAttributeName: shadow
        };
        CGSize textSize = [text sizeWithAttributes:attributes];
        CGSize canvas = CGSizeMake(ceil(textSize.width + 6.0), ceil(textSize.height + 6.0));
        UIGraphicsBeginImageContextWithOptions(canvas, NO, 0.0);
        [text drawAtPoint:CGPointMake(3.0, (canvas.height - textSize.height) * 0.5)
           withAttributes:attributes];
        wordmark = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return wordmark;
}

static BOOL TTIsRemovedVersionFooter(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0) return NO;
    NSString *value = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    // Match the footer as it is actually rendered: "TrapTube Plus: 6.0~b2 ...".
    return [value containsString:@"traptube plus: 6.0~b2"] ||
           ([value containsString:@"traptube"] && [value containsString:@"6.0~b2"]);
}

%hook UILabel
- (void)setText:(NSString *)text {
    if (TTIsRemovedVersionFooter(text)) {
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        %orig(@"");
        return;
    }
    %orig(TTRebrandedHostText(text));
    TTStyleTrapTubeBrandLabel(self);
}
- (void)setAttributedText:(NSAttributedString *)text {
    if (TTIsRemovedVersionFooter(text.string)) {
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        %orig(nil);
        return;
    }
    if (TTIsTrapTubeBrandText(text.string)) {
        NSMutableAttributedString *styled = [text mutableCopy];
        [styled addAttribute:NSFontAttributeName value:TTBrandDisplayFont(self.font.pointSize > 0 ? self.font.pointSize : 18)
                       range:NSMakeRange(0, styled.length)];
        %orig(styled);
        TTStyleTrapTubeBrandLabel(self);
    } else {
        %orig(text);
    }
}
- (void)setFont:(UIFont *)font {
    %orig(TTIsTrapTubeBrandText(self.text) ? TTBrandDisplayFont(font.pointSize) : font);
}
%end

%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    if (TTIsRemovedVersionFooter(title)) {
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        %orig(@"", state);
        return;
    }
    %orig(TTRebrandedHostText(title), state);
    if (TTIsTrapTubeBrandText(title)) self.titleLabel.font = TTBrandDisplayFont(self.titleLabel.font.pointSize > 0 ? self.titleLabel.font.pointSize : 16);
}
%end

%hook UINavigationItem
- (void)setTitle:(NSString *)title {
    NSString *displayTitle = TTRebrandedHostText(title);
    %orig(displayTitle);
    if (TTIsTrapTubeBrandText(displayTitle)) {
        UILabel *brandTitle = [[UILabel alloc] init];
        brandTitle.text = displayTitle;
        brandTitle.font = TTBrandDisplayFont(20);
        brandTitle.textColor = UIColor.whiteColor;
        brandTitle.textAlignment = NSTextAlignmentCenter;
        brandTitle.layer.shadowColor = [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:0.9].CGColor;
        brandTitle.layer.shadowOffset = CGSizeMake(0, 1);
        brandTitle.layer.shadowRadius = 2.0;
        brandTitle.layer.shadowOpacity = 0.7;
        [brandTitle sizeToFit];
        self.titleView = brandTitle;
    }
}
%end

%hook UIBarButtonItem
- (void)setTitle:(NSString *)title {
    %orig(TTRebrandedHostText(title));
    if (TTIsTrapTubeBrandText(title)) {
        NSDictionary *attributes = @{ NSFontAttributeName: TTBrandDisplayFont(16),
                                       NSForegroundColorAttributeName: UIColor.whiteColor };
        [self setTitleTextAttributes:attributes forState:UIControlStateNormal];
        [self setTitleTextAttributes:attributes forState:UIControlStateHighlighted];
    }
}
%end

%hook UITabBarItem
- (void)setTitle:(NSString *)title {
    %orig(TTRebrandedHostText(title));
    if (TTIsTrapTubeBrandText(title)) {
        NSDictionary *attributes = @{ NSFontAttributeName: TTBrandDisplayFont(11),
                                       NSForegroundColorAttributeName: UIColor.whiteColor };
        [self setTitleTextAttributes:attributes forState:UIControlStateNormal];
        [self setTitleTextAttributes:attributes forState:UIControlStateSelected];
    }
}
%end

%hook UITextField
- (void)setPlaceholder:(NSString *)placeholder {
    %orig(TTRebrandedHostText(placeholder));
}
%end

%hook UISearchBar
- (void)setPlaceholder:(NSString *)placeholder {
    %orig(TTRebrandedHostText(placeholder));
}
%end

%hook UIAlertController
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)preferredStyle {
    return %orig(TTRebrandedHostText(title), TTRebrandedHostText(message), preferredStyle);
}
%end

%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name {
    if (TTIsYouTubeWordmarkAssetName(name)) {
        UIImage *wordmark = TTTrapTubeWordmark();
        if (wordmark) return wordmark;
    }
    return %orig;
}
+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    if (TTIsYouTubeWordmarkAssetName(name)) {
        UIImage *wordmark = TTTrapTubeWordmark();
        if (wordmark) return wordmark;
    }
    return %orig;
}
%end


#pragma mark - TrapTube hostile takeover launch overlay

static UIWindow *TTLaunchOverlayWindow = nil;
static BOOL TTLaunchOverlayPresented = NO;

static void TTShowHostileTakeoverSplash(void) {
    if (TTLaunchOverlayPresented) return;

    UIWindow *hostWindow = nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (!candidate.hidden && candidate.windowScene) {
            hostWindow = candidate;
            break;
        }
    }
    if (!hostWindow) return;

    TTLaunchOverlayPresented = YES;
    UIWindow *overlay = [[UIWindow alloc] initWithWindowScene:hostWindow.windowScene];
    overlay.frame = hostWindow.windowScene.coordinateSpace.bounds;
    overlay.windowLevel = UIWindowLevelAlert + 2.0;
    overlay.backgroundColor = [UIColor colorWithRed:0.012 green:0.010 blue:0.016 alpha:1.0];
    overlay.userInteractionEnabled = NO;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = overlay.backgroundColor;
    controller.view.userInteractionEnabled = NO;

    UIImageView *logo = [[UIImageView alloc] init];
    NSString *logoPath = [[NSBundle mainBundle] pathForResource:@"TrapTubeLaunchLogoV4" ofType:@"png"];
    if (logoPath.length) logo.image = [UIImage imageWithContentsOfFile:logoPath];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:logo];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"TrapTube";
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.font = TTBrandDisplayFont(44);
    title.layer.shadowColor = [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:0.95].CGColor;
    title.layer.shadowOffset = CGSizeMake(1.5, 1.5);
    title.layer.shadowRadius = 2.0;
    title.layer.shadowOpacity = 0.8;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:title];

    UILabel *tagline = [[UILabel alloc] init];
    tagline.attributedText = [[NSAttributedString alloc] initWithString:@"HOSTILE YOUTUBE TAKEOVER" attributes:@{NSKernAttributeName: @1.4}];
    tagline.textColor = [UIColor colorWithRed:0.91 green:0.035 blue:0.12 alpha:1.0];
    tagline.textAlignment = NSTextAlignmentCenter;
    tagline.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    tagline.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:tagline];

    UIView *accentLine = [[UIView alloc] init];
    accentLine.backgroundColor = [UIColor colorWithRed:0.82 green:0.035 blue:0.12 alpha:1.0];
    accentLine.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:accentLine];

    [NSLayoutConstraint activateConstraints:@[
        [logo.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [logo.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor constant:-82.0],
        [logo.widthAnchor constraintEqualToConstant:164.0],
        [logo.heightAnchor constraintEqualToConstant:164.0],
        [title.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:logo.bottomAnchor constant:20.0],
        [title.leadingAnchor constraintGreaterThanOrEqualToAnchor:controller.view.leadingAnchor constant:24.0],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:controller.view.trailingAnchor constant:-24.0],
        [tagline.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [tagline.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:9.0],
        [tagline.leadingAnchor constraintGreaterThanOrEqualToAnchor:controller.view.leadingAnchor constant:18.0],
        [tagline.trailingAnchor constraintLessThanOrEqualToAnchor:controller.view.trailingAnchor constant:-18.0],
        [accentLine.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [accentLine.topAnchor constraintEqualToAnchor:tagline.bottomAnchor constant:18.0],
        [accentLine.widthAnchor constraintEqualToConstant:54.0],
        [accentLine.heightAnchor constraintEqualToConstant:3.0]
    ]];

    overlay.rootViewController = controller;
    TTLaunchOverlayWindow = overlay;
    overlay.hidden = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.28 animations:^{
            TTLaunchOverlayWindow.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            TTLaunchOverlayWindow.hidden = YES;
            TTLaunchOverlayWindow.rootViewController = nil;
            TTLaunchOverlayWindow = nil;
        }];
    });
}

// Forward declaration: the UIWindow hook below invokes this scheduler before
// its implementation appears later in this file.
static void TTScheduleHostileTakeoverSplash(NSUInteger attempt);

// Present the branded overlay synchronously as soon as the app's first
// scene window becomes visible. The old 200 ms constructor timer allowed the
// embedded YouTube host's own launch mark to render first.
%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    if (self.windowScene && !TTLaunchOverlayPresented) {
        TTShowHostileTakeoverSplash();
        if (!TTLaunchOverlayPresented) TTScheduleHostileTakeoverSplash(0);
    }
}
%end

static void TTScheduleHostileTakeoverSplash(NSUInteger attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((attempt == 0 ? 0.20 : 0.18) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (TTLaunchOverlayPresented) return;
        TTShowHostileTakeoverSplash();
        if (!TTLaunchOverlayPresented && attempt < 20) {
            TTScheduleHostileTakeoverSplash(attempt + 1);
        }
    });
}

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"advancedMode"];
    [defaults setBool:YES forKey:@"advancedModeReminder"];
    [defaults synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{
        TTApplyAccentGlobally();
        TTScheduleHostileTakeoverSplash(0);
    });
}

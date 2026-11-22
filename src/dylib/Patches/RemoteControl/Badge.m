#import "RemoteControl.h"

// A floating pill at the bottom of each Dia window while an agent controls Dia, with a button to take over.

NSNotificationName const DPRemoteControlDidChange = @"DPRemoteControlDidChange";

@interface DPRemoteBadgePanel : NSPanel
@property (nonatomic, strong) NSView *dot, *halo;
@property (nonatomic, strong) NSTextField *headline, *detail;
@property (nonatomic, strong) NSButton *button;
@property (nonatomic, strong) NSStackView *row;
@property (nonatomic, copy) NSString *shown;
@end

static const void *DPBadgeKey = &DPBadgeKey;
static NSArray<DPRemoteClient *> *DPLastControllers;
static NSDate *DPLastSeen;

static NSColor *DPColorFor(NSString *name) {
    NSDictionary<NSString *, NSColor *> *colors = @{
        @"Claude" : [NSColor colorWithSRGBRed:0.85 green:0.47 blue:0.34 alpha:1],
        @"Codex" : NSColor.labelColor,
        @"T3 Code" : NSColor.systemPurpleColor,
        @"Paseo" : NSColor.systemGreenColor,
        @"Ardia" : NSColor.systemPinkColor,
    };
    return colors[name] ?: NSColor.systemBlueColor;
}

static NSString *DPTitleFor(NSArray<DPRemoteClient *> *clients) {
    if (clients.count == 1) return [NSString stringWithFormat:@"%@ is controlling Dia", clients[0].name];
    if (clients.count == 2) return [NSString stringWithFormat:@"%@ and %@ are controlling Dia", clients[0].name, clients[1].name];
    return [NSString stringWithFormat:@"%@ and %lu others are controlling Dia", clients[0].name, (unsigned long)clients.count - 1];
}

static NSView *DPBackground(void) {
    Class glass = NSClassFromString(@"NSGlassEffectView");
    if (glass) {
        NSView *view = [glass new];
        DPSetValueForKey(view, @"cornerRadius", @22);
        return view;
    }
    NSVisualEffectView *view = [NSVisualEffectView new];
    view.material = NSVisualEffectMaterialHUDWindow;
    view.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    view.state = NSVisualEffectStateActive;
    view.wantsLayer = YES;
    view.layer.cornerRadius = 22;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
    return view;
}

static NSView *DPCircle(CGFloat size) {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size, size)];
    view.wantsLayer = YES;
    view.layer.cornerRadius = size / 2;
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [view.widthAnchor constraintEqualToConstant:size].active = YES;
    [view.heightAnchor constraintEqualToConstant:size].active = YES;
    return view;
}

@implementation DPRemoteBadgePanel

- (instancetype)init {
    if (!(self = [super initWithContentRect:NSMakeRect(0, 0, 320, 44) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                    backing:NSBackingStoreBuffered defer:YES]))
        return nil;
    self.opaque = NO;
    self.backgroundColor = NSColor.clearColor;
    self.hasShadow = YES;
    self.releasedWhenClosed = NO;
    self.becomesKeyOnlyIfNeeded = YES;
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    self.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    self.alphaValue = 0;

    NSView *background = DPBackground();
    self.contentView = background;

    _halo = DPCircle(16);
    _dot = DPCircle(8);
    NSView *signal = [NSView new];
    signal.translatesAutoresizingMaskIntoConstraints = NO;
    [signal addSubview:_halo];
    [signal addSubview:_dot];
    [NSLayoutConstraint activateConstraints:@[
        [signal.widthAnchor constraintEqualToConstant:16], [signal.heightAnchor constraintEqualToConstant:16],
        [_halo.centerXAnchor constraintEqualToAnchor:signal.centerXAnchor], [_halo.centerYAnchor constraintEqualToAnchor:signal.centerYAnchor],
        [_dot.centerXAnchor constraintEqualToAnchor:signal.centerXAnchor], [_dot.centerYAnchor constraintEqualToAnchor:signal.centerYAnchor],
    ]];

    _headline = [NSTextField labelWithString:@""];
    _headline.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _headline.textColor = NSColor.labelColor;
    _detail = [NSTextField labelWithString:@""];
    _detail.font = [NSFont systemFontOfSize:11];
    _detail.textColor = NSColor.secondaryLabelColor;
    NSStackView *text = [NSStackView stackViewWithViews:@[ _headline, _detail ]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 0;

    _button = [NSButton buttonWithTitle:@"Take Over" target:self action:@selector(press:)];
    _button.bezelStyle = NSBezelStylePush;
    _button.controlSize = NSControlSizeLarge;
    _button.imagePosition = NSImageLeading;
    _button.imageHugsTitle = YES;

    _row = [NSStackView stackViewWithViews:@[ signal, text, _button ]];
    _row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _row.alignment = NSLayoutAttributeCenterY;
    _row.spacing = 10;
    [_row setCustomSpacing:18 afterView:text];
    _row.edgeInsets = NSEdgeInsetsMake(6, 16, 6, 6);
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *host = background;
    if ([background respondsToSelector:NSSelectorFromString(@"setContentView:")]) {
        host = [NSView new];
        DPSetValueForKey(background, @"contentView", host);
    }
    [host addSubview:_row];
    [NSLayoutConstraint activateConstraints:@[
        [_row.leadingAnchor constraintEqualToAnchor:host.leadingAnchor], [_row.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [_row.topAnchor constraintEqualToAnchor:host.topAnchor], [_row.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
    return self;
}

- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }

- (void)press:(id)sender {
    if (DPRemotePaused()) DPRemoteResume();
    else DPRemoteTakeOver();
}

- (void)pulse:(BOOL)on {
    [self.halo.layer removeAllAnimations];
    self.halo.hidden = !on;
    if (!on) return;
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @0.5;
    grow.toValue = @1.25;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.6;
    fade.toValue = @0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[ grow, fade ];
    group.duration = 1.6;
    group.repeatCount = HUGE_VALF;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    self.halo.layer.anchorPoint = CGPointMake(0.5, 0.5);
    self.halo.layer.position = CGPointMake(NSMidX(self.halo.frame), NSMidY(self.halo.frame));
    [self.halo.layer addAnimation:group forKey:@"pulse"];
}

- (void)showControllers:(NSArray<DPRemoteClient *> *)clients paused:(BOOL)paused {
    NSString *key = paused ? @"paused" : [[clients valueForKey:@"name"] componentsJoinedByString:@","];
    if ([key isEqual:self.shown]) return;
    self.shown = key;
    NSColor *color = paused ? NSColor.tertiaryLabelColor : DPColorFor(clients.firstObject.name);
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.dot.layer.backgroundColor = color.CGColor;
        self.halo.layer.backgroundColor = color.CGColor;
    }];
    if (paused) {
        self.headline.stringValue = @"Remote control paused";
        self.detail.stringValue = @"Agents can’t connect until you resume";
        self.button.title = @"Resume";
        self.button.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
        self.button.bezelColor = nil;
    } else {
        self.headline.stringValue = DPTitleFor(clients);
        NSString *via = clients.count == 1 ? clients[0].via : nil;
        self.detail.stringValue = via ? [NSString stringWithFormat:@"via %@", via] : @"Pages can change without you";
        self.button.title = @"Take Over";
        self.button.image = [NSImage imageWithSystemSymbolName:@"hand.raised.fill" accessibilityDescription:nil];
        self.button.bezelColor = NSColor.controlAccentColor;
    }
    self.button.keyEquivalent = @"";
    [self pulse:!paused];
    NSSize size = self.row.fittingSize;
    [self setContentSize:NSMakeSize(ceil(size.width), MAX(44, ceil(size.height)))];
    [self invalidateShadow];
}

@end

static BOOL DPIsBrowserWindow(NSWindow *window) {
    return DPIsKind(window, DPDiaWindow) && window.isVisible && !window.isMiniaturized && window.level == NSNormalWindowLevel;
}

static void DPPlace(DPRemoteBadgePanel *badge, NSWindow *parent) {
    NSRect frame = parent.frame;
    NSSize size = badge.frame.size;
    [badge setFrameOrigin:NSMakePoint(round(NSMidX(frame) - size.width / 2), NSMinY(frame) + 18)];
}

static void DPFade(DPRemoteBadgePanel *badge, CGFloat alpha, void (^done)(void)) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.22;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        badge.animator.alphaValue = alpha;
    } completionHandler:done];
}

static void DPHideBadge(NSWindow *window) {
    DPRemoteBadgePanel *badge = DPGet(window, DPBadgeKey);
    if (!badge || badge.alphaValue == 0) return;
    DPFade(badge, 0, ^{
        if (badge.alphaValue > 0) return;
        badge.shown = nil;
        [badge.parentWindow removeChildWindow:badge];
        [badge orderOut:nil];
    });
}

void DPRemoteBadgeSync(void) {
    BOOL paused = DPRemotePaused();
    NSArray<DPRemoteClient *> *clients = DPRemoteControl.on ? DPRemoteControllers() : @[];
    // Between an agent's commands its tool may reconnect; hold the badge briefly so it doesn't flicker.
    if (clients.count) {
        DPLastControllers = clients;
        DPLastSeen = NSDate.date;
    } else if (DPLastSeen && -DPLastSeen.timeIntervalSinceNow < 2 && DPRemoteControl.on && !paused) {
        clients = DPLastControllers;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DPRemoteBadgeSync(); });
    }
    BOOL show = DPRemoteControl.on && (paused || clients.count);
    for (NSWindow *window in NSApp.windows) {
        if (!DPIsKind(window, DPDiaWindow)) continue;
        if (!show || !DPIsBrowserWindow(window)) {
            DPHideBadge(window);
            continue;
        }
        DPRemoteBadgePanel *badge = DPGet(window, DPBadgeKey);
        if (!badge) {
            badge = [DPRemoteBadgePanel new];
            DPSet(window, DPBadgeKey, badge);
        }
        [badge showControllers:clients paused:paused];
        DPPlace(badge, window);
        if (badge.parentWindow != window) [window addChildWindow:badge ordered:NSWindowAbove];
        if (badge.alphaValue < 1) DPFade(badge, 1, nil);
    }
}

void DPInstallRemoteBadge(void) {
    DPOnLaunch(^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        void (^sync)(NSNotification *) = ^(NSNotification *note) { DPRemoteBadgeSync(); };
        [center addObserverForName:DPRemoteControlDidChange object:nil queue:NSOperationQueue.mainQueue usingBlock:sync];
        for (NSNotificationName name in @[ NSWindowDidResizeNotification, NSWindowDidDeminiaturizeNotification, NSWindowDidChangeOcclusionStateNotification ])
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (DPIsKind(note.object, DPDiaWindow) && (DPRemotePaused() || DPLastSeen)) DPRemoteBadgeSync();
            }];
    });
}

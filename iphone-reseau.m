// iphone-reseau : affiche le type de réseau cellulaire de l'iPhone en partage de connexion.
// S'appuie sur SFRemoteHotspotSession (framework privé Sharing), la même source que le menu Wi-Fi.
// Usage : iphone-reseau [--json] [--timeout secondes]
//         iphone-reseau --menubar [--interval secondes]   (icône permanente dans la barre des menus)
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

@interface HotspotDelegate : NSObject
@property (nonatomic, copy) NSArray *devices;
@property (nonatomic, strong) NSDate *lastUpdate;
@property (nonatomic) BOOL stopOnResult;
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation HotspotDelegate
- (void)session:(id)session updatedFoundDevices:(NSArray *)devices {
    self.devices = devices;
    self.lastUpdate = [NSDate date];
    // Appelé depuis une file XPC : l'interface ne se met à jour que sur le fil principal
    if (self.onChange) dispatch_async(dispatch_get_main_queue(), self.onChange);
    if (self.stopOnResult && devices.count > 0) CFRunLoopStop(CFRunLoopGetMain());
}
@end

// networkType est un code interne ; la description de l'objet contient le libellé lisible (« 5G », « LTE »…)
static NSString *networkTypeLabel(id device) {
    NSString *desc = [device description];
    NSRange r = [desc rangeOfString:@"network type: "];
    if (r.location == NSNotFound) return [[device valueForKey:@"networkType"] stringValue];
    NSString *rest = [desc substringFromIndex:NSMaxRange(r)];
    return [[rest componentsSeparatedByString:@","] firstObject];
}

static NSDictionary *deviceInfo(id d) {
    return @{
        @"nom": [d valueForKey:@"deviceName"] ?: @"",
        @"reseau": networkTypeLabel(d) ?: @"",
        @"signal": [d valueForKey:@"signalStrength"] ?: @0,
        @"batterie": [d valueForKey:@"batteryLife"] ?: @0,
        @"modele": [d valueForKey:@"model"] ?: @"",
    };
}

// Seuil au-delà duquel la connexion est signalée comme lente
static const double kSlowLatencyMs = 250;
// Géométrie de l'icône (en points) : hauteur de l'image, position et épaisseur de la barre
static const CGFloat kIconHeight = 22, kBarY = 2, kBarHeight = 2;

// Mesure latence et perte vers 1.1.1.1 avec ping (4 paquets), sans bloquer la boucle principale.
// Le résultat arrive sur la file principale : latence en ms (-1 si inconnue) et perte en %.
static void probeConnection(void (^done)(double latencyMs, double lossPercent)) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/ping"];
    task.arguments = @[@"-q", @"-c", @"4", @"-i", @"0.2", @"-t", @"3", @"1.1.1.1"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.terminationHandler = ^(NSTask *t) {
        NSString *s = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
        double latency = -1, loss = 100;
        NSRegularExpression *lossRe = [NSRegularExpression regularExpressionWithPattern:@"([0-9.]+)% packet loss" options:0 error:nil];
        NSRegularExpression *rttRe = [NSRegularExpression regularExpressionWithPattern:@"= [0-9.]+/([0-9.]+)/" options:0 error:nil];
        NSTextCheckingResult *m = [lossRe firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (m) loss = [[s substringWithRange:[m rangeAtIndex:1]] doubleValue];
        m = [rttRe firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (m) latency = [[s substringWithRange:[m rangeAtIndex:1]] doubleValue];
        dispatch_async(dispatch_get_main_queue(), ^{ done(latency, loss); });
    };
    if (![task launchAndReturnError:nil]) done(-1, 100);
}

// Icône fixe de la barre des menus : le libellé et, dessous, le rail vide de la barre de progression.
// Le remplissage est un calque animé par Core Animation (voir runMenuBar), l'image n'est jamais redessinée.
// Sans couleur, l'image est en « template » : macOS applique la couleur du thème.
static NSImage *titleImage(NSString *label, CGFloat width, NSDictionary *attrs, NSColor *color) {
    NSColor *ink = color ?: NSColor.blackColor;
    NSMutableDictionary *a = [attrs mutableCopy];
    a[NSForegroundColorAttributeName] = ink;
    NSSize textSize = [label sizeWithAttributes:a];
    NSImage *image = [NSImage imageWithSize:NSMakeSize(width, kIconHeight) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [label drawAtPoint:NSMakePoint(floor((width - textSize.width) / 2), 5) withAttributes:a];
        [[ink colorWithAlphaComponent:0.3] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, kBarY, width, kBarHeight) xRadius:1 yRadius:1] fill];
        return YES;
    }];
    image.template = (color == nil);
    return image;
}

// Vue transparente aux clics, pour superposer la barre animée au bouton sans le bloquer
@interface PassthroughView : NSView
@end

@implementation PassthroughView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

static NSMenuItem *infoItem(NSString *title, NSColor *color) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    if (color) item.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSForegroundColorAttributeName: color, NSFontAttributeName: [NSFont menuFontOfSize:0]}];
    return item;
}

static int runMenuBar(id session, HotspotDelegate *delegate, double interval) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];  // pas d'icône dans le Dock

    NSStatusItem *statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    statusItem.menu = menu;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]};

    // Au-delà de ce délai sans nouvelle de l'iPhone, on considère le partage coupé
    const double staleAfter = interval * 2 + 10;
    __block NSDate *nextRefresh = [NSDate dateWithTimeIntervalSinceNow:interval];
    __block double latencyMs = -1, lossPercent = -1;  // -1 : pas encore mesuré

    // État affiché, recalculé seulement quand les données changent
    __block NSString *label = nil;
    __block NSColor *alert = nil;
    __block CGFloat iconWidth = 16;
    __block NSInteger lastCountdown = -1;
    NSMenuItem *countdownItem = infoItem(@"", NSColor.secondaryLabelColor);

    // Calque de remplissage posé sur le rail de l'icône. Core Animation l'anime de lui-même,
    // de façon fluide et sans que ce processus ait à se réveiller.
    NSStatusBarButton *button = statusItem.button;
    PassthroughView *barHost = [[PassthroughView alloc] initWithFrame:button.bounds];
    barHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    barHost.wantsLayer = YES;
    [button addSubview:barHost];
    CALayer *fill = [CALayer layer];
    fill.anchorPoint = CGPointMake(0, 0);
    fill.cornerRadius = kBarHeight / 2;
    [barHost.layer addSublayer:fill];

    // Replace le calque sous le rail et relance son remplissage là où il en est
    void (^animateBar)(void) = ^{
        double remaining = MAX([nextRefresh timeIntervalSinceNow], 0);
        double progress = MIN(MAX(1 - remaining / interval, 0), 1);
        [barHost layoutSubtreeIfNeeded];
        NSSize size = barHost.bounds.size;
        __block CGColorRef color = NULL;
        [button.effectiveAppearance performAsCurrentDrawingAppearance:^{ color = (alert ?: NSColor.labelColor).CGColor; }];

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [fill removeAllAnimations];
        fill.backgroundColor = color;
        fill.position = CGPointMake(round((size.width - iconWidth) / 2), round((size.height - kIconHeight) / 2) + kBarY);
        fill.bounds = CGRectMake(0, 0, iconWidth, kBarHeight);
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        grow.fromValue = @(iconWidth * progress);
        grow.toValue = @(iconWidth);
        grow.duration = remaining;
        grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [fill addAnimation:grow forKey:@"progress"];
        [CATransaction commit];
    };

    void (^rebuild)(void) = ^{
        BOOL fresh = delegate.lastUpdate && -[delegate.lastUpdate timeIntervalSinceNow] < staleAfter;
        NSDictionary *info = (fresh && delegate.devices.count > 0) ? deviceInfo(delegate.devices.firstObject) : nil;

        // Problèmes détectés : rouge si plus d'internet, orange si la connexion est dégradée
        NSMutableArray *problems = [NSMutableArray array];
        BOOL offline = lossPercent >= 100;
        if (offline) [problems addObject:@"Pas d'accès à internet"];
        else {
            if (latencyMs > kSlowLatencyMs) [problems addObject:[NSString stringWithFormat:@"Latence élevée (%.0f ms)", latencyMs]];
            if (lossPercent > 0) [problems addObject:[NSString stringWithFormat:@"Perte de paquets (%.0f %%)", lossPercent]];
        }
        if (info) {
            NSString *type = [info[@"reseau"] uppercaseString];
            if (!([type containsString:@"5G"] || [type containsString:@"LTE"] || [type containsString:@"4G"]))
                [problems addObject:[NSString stringWithFormat:@"Réseau dégradé (%@)", info[@"reseau"]]];
        }
        NSColor *newAlert = offline ? NSColor.systemRedColor : (problems.count > 0 ? NSColor.systemOrangeColor : nil);
        NSString *newLabel = info ? info[@"reseau"] : @"—";
        if (![newLabel isEqualToString:label] || newAlert != alert) {
            label = newLabel;
            alert = newAlert;
            iconWidth = ceil(MAX([label sizeWithAttributes:attrs].width, 16));
            button.image = titleImage(label, iconWidth, attrs, alert);
        }
        animateBar();  // recale aussi la couleur si le thème clair/sombre a changé

        [menu removeAllItems];
        for (NSString *p in problems) [menu addItem:infoItem(p, alert)];
        if (problems.count > 0) [menu addItem:NSMenuItem.separatorItem];
        if (info) {
            [menu addItem:infoItem(info[@"nom"], nil)];
            [menu addItem:infoItem([NSString stringWithFormat:@"Réseau : %@", info[@"reseau"]], nil)];
            [menu addItem:infoItem([NSString stringWithFormat:@"Signal : %@/4", info[@"signal"]], nil)];
            [menu addItem:infoItem([NSString stringWithFormat:@"Batterie : %@ %%", info[@"batterie"]], nil)];
        } else {
            [menu addItem:infoItem(@"Pas de partage de connexion détecté", nil)];
        }
        if (latencyMs >= 0)
            [menu addItem:infoItem([NSString stringWithFormat:@"Latence : %.0f ms · perte %.0f %%", latencyMs, lossPercent], nil)];
        [menu addItem:countdownItem];
        [menu addItem:NSMenuItem.separatorItem];
        [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Quitter" action:@selector(terminate:) keyEquivalent:@"q"]];
    };

    delegate.onChange = rebuild;
    void (^probe)(void) = ^{
        probeConnection(^(double latency, double loss) { latencyMs = latency; lossPercent = loss; rebuild(); });
    };

    [session performSelector:@selector(startBrowsing)];
    probe();
    rebuild();

    // Les minuteurs tournent aussi pendant que le menu est ouvert (NSRunLoopCommonModes)
    NSTimer *refresh = [NSTimer timerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) {
        // Relancer la recherche force sharingd à renvoyer un état à jour
        [session performSelector:@selector(stopBrowsing)];
        [session performSelector:@selector(startBrowsing)];
        probe();
        nextRefresh = [NSDate dateWithTimeIntervalSinceNow:interval];
        rebuild();
    }];
    [NSRunLoop.mainRunLoop addTimer:refresh forMode:NSRunLoopCommonModes];

    // Compte à rebours du menu : une fois par seconde suffit
    NSTimer *countdownTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        NSInteger countdown = (NSInteger)ceil(MAX([nextRefresh timeIntervalSinceNow], 0));
        if (countdown != lastCountdown) {
            lastCountdown = countdown;
            countdownItem.attributedTitle = [[NSAttributedString alloc]
                initWithString:[NSString stringWithFormat:@"Prochaine mise à jour dans %ld s", (long)countdown]
                    attributes:@{NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSFontAttributeName: [NSFont menuFontOfSize:0]}];
        }
    }];
    countdownTimer.tolerance = 0.2;  // laisse macOS regrouper les réveils pour économiser l'énergie
    [NSRunLoop.mainRunLoop addTimer:countdownTimer forMode:NSRunLoopCommonModes];

    [NSApp run];
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL json = NO, menubar = NO;
        double timeout = 10, interval = 10;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--json")) json = YES;
            else if (!strcmp(argv[i], "--menubar")) menubar = YES;
            else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atof(argv[++i]);
            else if (!strcmp(argv[i], "--interval") && i + 1 < argc) interval = MAX(atof(argv[++i]), 5);
        }

        if (!dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW)) {
            fprintf(stderr, "Impossible de charger Sharing.framework\n");
            return 2;
        }
        Class sessionClass = NSClassFromString(@"SFRemoteHotspotSession");
        if (!sessionClass) {
            fprintf(stderr, "SFRemoteHotspotSession introuvable sur cette version de macOS\n");
            return 2;
        }

        id session = [[sessionClass alloc] init];
        HotspotDelegate *delegate = [HotspotDelegate new];
        [session setValue:delegate forKey:@"delegate"];

        if (menubar) return runMenuBar(session, delegate, interval);

        delegate.stopOnResult = YES;
        [session performSelector:@selector(startBrowsing)];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout, false);
        [session performSelector:@selector(stopBrowsing)];

        if (delegate.devices.count == 0) {
            fprintf(stderr, "Aucun iPhone en partage de connexion détecté\n");
            return 1;
        }

        NSMutableArray *out = [NSMutableArray array];
        for (id d in delegate.devices) [out addObject:deviceInfo(d)];

        if (json) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
            printf("%s\n", [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
        } else {
            for (NSDictionary *d in out) {
                printf("%s : %s · signal %s/4 · batterie %s %%\n",
                       [d[@"nom"] UTF8String], [d[@"reseau"] UTF8String],
                       [[d[@"signal"] description] UTF8String], [[d[@"batterie"] description] UTF8String]);
            }
        }
    }
    return 0;
}

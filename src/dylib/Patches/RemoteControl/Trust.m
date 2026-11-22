#import "RemoteControl.h"

static NSString *const DPTrustedKey = @"remoteControlTrusted";
static NSMutableSet<NSString *> *DPAllowedForNow;
static NSMutableDictionary<NSString *, NSDate *> *DPDenied;
static BOOL DPAsking;

static NSUserDefaults *DPSettings(void) {
    static NSUserDefaults *settings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ settings = [[NSUserDefaults alloc] initWithSuiteName:@"com.diapatches"]; });
    return settings;
}

NSArray<NSString *> *DPRemoteTrustedNames(void) {
    NSArray *saved = [DPSettings() arrayForKey:DPTrustedKey];
    return saved ?: @[ @"Claude", @"Codex", @"Paseo", @"T3 Code" ];
}

static void DPSaveTrusted(NSArray<NSString *> *names) {
    [DPSettings() setObject:[names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] forKey:DPTrustedKey];
    [NSNotificationCenter.defaultCenter postNotificationName:DPRemoteControlDidChange object:nil];
}

void DPRemoteForgetTrusted(NSString *name) {
    NSMutableArray<NSString *> *names = [DPRemoteTrustedNames() mutableCopy];
    [names removeObject:name];
    DPSaveTrusted(names);
}

// Only a named agent, command or app is trusted for good: an unnamed process could be anything, so it is only
// ever allowed until Dia quits.
BOOL DPRemoteTrusted(DPRemoteClient *client) {
    @synchronized(DPSettings()) {
        if ([DPAllowedForNow containsObject:client.name]) return YES;
    }
    if (!client.known) return NO;
    for (NSString *name in DPRemoteTrustedNames())
        if ([name caseInsensitiveCompare:client.name] == NSOrderedSame) return YES;
    return NO;
}

void DPRemoteAddTrusted(NSString *name) {
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) return;
    for (NSString *existing in DPRemoteTrustedNames())
        if ([existing caseInsensitiveCompare:name] == NSOrderedSame) return;
    DPSaveTrusted([DPRemoteTrustedNames() arrayByAddingObject:name]);
}

void DPRemoteAsk(DPRemoteClient *client) {
    if (DPAsking || DPTesting) return;
    NSDate *denied = DPDenied[client.name];
    if (denied && -denied.timeIntervalSinceNow < 30) return;  // Tools retry; don't ask again at once.

    DPAsking = YES;
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:@"Let %@ control Dia?", client.name];
    alert.informativeText = @"It could read and change any page, including sites you’re signed in to.";
    if (client.path) {
        NSTextField *where = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"%@\nProcess %d", client.path, client.pid]];
        where.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        where.textColor = NSColor.tertiaryLabelColor;
        where.alignment = NSTextAlignmentCenter;
        where.selectable = YES;
        where.preferredMaxLayoutWidth = 200;
        where.frame = NSMakeRect(0, 0, 200, where.fittingSize.height);
        alert.accessoryView = where;
    }
    [alert addButtonWithTitle:@"Don’t Allow"];
    if (client.known) [alert addButtonWithTitle:@"Always Allow"];
    [alert addButtonWithTitle:@"Allow Until Dia Quits"];
    NSModalResponse response = [alert runModal];
    DPAsking = NO;

    NSInteger button = response - NSAlertFirstButtonReturn;
    if (button == 0) {
        if (!DPDenied) DPDenied = [NSMutableDictionary dictionary];
        DPDenied[client.name] = NSDate.date;
    } else if (client.known && button == 1) {
        DPRemoteAddTrusted(client.name);
    } else {
        @synchronized(DPSettings()) {
            if (!DPAllowedForNow) DPAllowedForNow = [NSMutableSet set];
            [DPAllowedForNow addObject:client.name];
        }
    }
}

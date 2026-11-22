#import "RemoteControl.h"
#import "Settings/Settings.h"
#import "Updates/Updates.h"

static BOOL DPLaunchedOn;

int DPRemoteControlPort(void) {
    static int port;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger saved = [[[NSUserDefaults alloc] initWithSuiteName:@"com.diapatches"] integerForKey:@"remoteControlPort"];
        port = saved > 1024 && saved < 65536 ? (int)saved : 9222;
    });
    return port;
}

static NSString *DPPortFlag(void) { return [NSString stringWithFormat:@"--remote-debugging-port=%d", DPRemoteControlPort()]; }

static void DPInstallRemoteControl(void) {
    DPLaunchedOn = DPRemoteControl.on;
    if (DPLaunchedOn) DPAddLaunchFlag(DPPortFlag());
    else DPDropLaunchFlag(DPPortFlag());
    DPInstallRemoteGate();
    DPInstallRemoteBadge();
}

static void DPApplyRemoteControl(DPPatch *patch) {
    if (!patch->on && DPRemotePaused()) DPRemoteResume();
    DPRemoteBadgeSync();
    if (DPTesting || patch->on == DPLaunchedOn || patch->on != DPSavedOn(patch)) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = patch->on ? @"Relaunch Dia to turn on remote control" : @"Relaunch Dia to turn off remote control";
    alert.informativeText = patch->on ? @"Until then, agents can’t connect." : @"Until then, trusted agents can still connect.";
    [alert addButtonWithTitle:@"Relaunch"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) DPHandOffAndQuit(@[ @"apply" ]);
}

// The trusted list, rebuilt whenever it changes.
@interface DPTrustedList : NSStackView
@property (nonatomic, weak) NSTextField *field;
@end

@implementation DPTrustedList
- (instancetype)init {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.alignment = NSLayoutAttributeLeading;
    self.spacing = 0;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refill) name:DPRemoteControlDidChange object:nil];
    [self refill];
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refill {
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    for (NSString *name in DPRemoteTrustedNames()) {
        NSButton *remove = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(remove:)];
        remove.identifier = name;
        remove.controlSize = NSControlSizeSmall;
        [rows addObject:DPRow(DPLabel(name, 13, NSFontWeightRegular, NSColor.labelColor), remove)];
    }
    if (!rows.count) [rows addObject:DPRow(DPLabel(@"No trusted apps. Every agent asks first.", 13, NSFontWeightRegular, NSColor.secondaryLabelColor), [NSView new])];
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.placeholderString = @"App or command, like orca";
    field.target = self;
    field.action = @selector(add:);
    [field.widthAnchor constraintEqualToConstant:200].active = YES;
    NSButton *add = [NSButton buttonWithTitle:@"Add" target:self action:@selector(add:)];
    add.controlSize = NSControlSizeSmall;
    NSStackView *adder = [NSStackView stackViewWithViews:@[ field, add ]];
    adder.spacing = 8;
    self.field = field;
    [rows addObject:DPRow(DPLabel(@"Add", 13, NSFontWeightRegular, NSColor.labelColor), adder)];
    NSView *group = DPGroup(rows);
    DPFillStack(self, @[ group ]);
    [group.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
}
- (void)remove:(NSButton *)sender { DPRemoteForgetTrusted(sender.identifier); }
- (void)add:(id)sender { DPRemoteAddTrusted(self.field.stringValue); }
@end

@interface DPAddressRow : NSObject
@end
@implementation DPAddressRow
+ (void)copyAddress:(id)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[NSString stringWithFormat:@"http://127.0.0.1:%d", DPRemoteControlPort()] forType:NSPasteboardTypeString];
}
@end

static NSArray<NSView *> *DPRemoteControlRows(void) {
    NSTextField *address = DPLabel([NSString stringWithFormat:@"http://127.0.0.1:%d", DPRemoteControlPort()], 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    address.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    address.selectable = YES;
    NSButton *copy = [NSButton buttonWithTitle:@"Copy" target:DPAddressRow.class action:@selector(copyAddress:)];
    copy.controlSize = NSControlSizeSmall;
    NSStackView *trailing = [NSStackView stackViewWithViews:@[ address, copy ]];
    trailing.spacing = 8;
    NSView *addressRow = DPGroup(@[ DPRow(DPLabel(@"Address", 13, NSFontWeightRegular, NSColor.labelColor), trailing) ]);

    NSTextField *header = DPHeader(@"Trusted");
    NSTextField *hint = DPLabel(@"These connect without asking. Dia names a connection by the agent, command or app it comes from, like Claude in Ghostty or orca. Anything else asks first. A process Dia can’t name can only be allowed until Dia quits.",
                                11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    return @[ addressRow, header, [DPTrustedList new], hint ];
}

DP_PATCH(DPRemoteControl) {
    .key = @"remoteControl",
    .order = 125,
    .section = @"Network",
    .title = @"Remote Control",
    .detail = @"Let trusted agents like Claude and Codex control Dia through the Chrome DevTools Protocol, signed in as you. Others ask first. A badge shows who is in control, with a button to take over. Relaunch Dia after turning it on.",
    .symbol = @"dot.radiowaves.left.and.right antenna.radiowaves.left.and.right",
    .tint = @"systemCyanColor",
    .relaunch = YES,
    .classes = DPClasses(DPDiaAppConfiguration),
    .rows = DPRemoteControlRows,
    .install = DPInstallRemoteControl,
    .apply = DPApplyRemoteControl,
};

#import "StdPatch/StdPatch.h"

extern DPPatch DPRemoteControl;

// The port tools connect to: http://127.0.0.1:<port>.
int DPRemoteControlPort(void);

// Who opened a connection: `name` is the agent or app, `via` the app it runs in, if different.
@interface DPRemoteClient : NSObject
@property (nonatomic, copy) NSString *name, *via, *path;
@property (nonatomic) pid_t pid;
@property (nonatomic) BOOL known;  // Has a name: a known agent, a named command or an app.
@end
DPRemoteClient *DPRemoteClientForPeerPort(int peerPort, int localPort);

// Gate.m: accepts or turns away each connection to the port, and tracks the ones it let in.
void DPInstallRemoteGate(void);
NSArray<DPRemoteClient *> *DPRemoteControllers(void);  // Connected long enough to count as control.
void DPRemoteTakeOver(void);
void DPRemoteResume(void);
BOOL DPRemotePaused(void);

// Trust.m
BOOL DPRemoteTrusted(DPRemoteClient *client);
NSArray<NSString *> *DPRemoteTrustedNames(void);
void DPRemoteForgetTrusted(NSString *name);
void DPRemoteAddTrusted(NSString *name);
void DPRemoteAsk(DPRemoteClient *client);

// Badge.m
void DPInstallRemoteBadge(void);
void DPRemoteBadgeSync(void);
extern NSNotificationName const DPRemoteControlDidChange;

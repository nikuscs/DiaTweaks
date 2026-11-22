#import "RemoteControl.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <netinet/in.h>
#import <os/lock.h>

// Dia's engine accepts DevTools connections with accept(). Its import is rebound to DPAccept, which asks who is
// connecting before the engine sees the socket, so a tool that isn't trusted never gets to send a command.

@interface DPRemoteConnection : NSObject
@property (nonatomic) int fd, peerPort;
@property (nonatomic, strong) DPRemoteClient *client;
@property (nonatomic, strong) NSDate *since;
@end
@implementation DPRemoteConnection
@end

static int (*DPRealAccept)(int, struct sockaddr *, socklen_t *);
static os_unfair_lock DPLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, DPRemoteConnection *> *DPConnections;
static BOOL DPPausedFlag;
static NSTimer *DPWatch;

static int DPPortOf(int fd, BOOL peer) {
    struct sockaddr_storage addr;
    socklen_t len = sizeof addr;
    if ((peer ? getpeername(fd, (struct sockaddr *)&addr, &len) : getsockname(fd, (struct sockaddr *)&addr, &len)) != 0) return -1;
    if (addr.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&addr)->sin_port);
    if (addr.ss_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)&addr)->sin6_port);
    return -1;
}

static void DPChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:DPRemoteControlDidChange object:nil];
    });
}

static void DPStartWatching(void);

static int DPAccept(int listener, struct sockaddr *addr, socklen_t *len) {
    int fd = DPRealAccept(listener, addr, len);
    if (fd < 0 || !DPRemoteControl.on) return fd;
    int port = DPRemoteControlPort();
    if (DPPortOf(listener, NO) != port) return fd;
    int peerPort = DPPortOf(fd, YES);
    DPRemoteClient *client = DPRemoteClientForPeerPort(peerPort, port);
    if (client.pid == getpid()) return fd;  // Dia talking to itself.

    os_unfair_lock_lock(&DPLock);
    BOOL paused = DPPausedFlag;
    os_unfair_lock_unlock(&DPLock);
    if (paused || !DPRemoteTrusted(client)) {
        // A tool checking the port is open connects and hangs up at once, before Dia can see who it was: no need to ask.
        char byte;
        BOOL gone = !client.pid && recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0;
        close(fd);
        if (!paused && !gone) dispatch_async(dispatch_get_main_queue(), ^{ DPRemoteAsk(client); });
        errno = EAGAIN;  // The engine waits for the next connection as if none had come.
        return -1;
    }

    DPRemoteConnection *connection = [DPRemoteConnection new];
    connection.fd = fd;
    connection.peerPort = peerPort;
    connection.client = client;
    connection.since = NSDate.date;
    os_unfair_lock_lock(&DPLock);
    DPConnections[@(fd)] = connection;
    os_unfair_lock_unlock(&DPLock);
    dispatch_async(dispatch_get_main_queue(), ^{ DPStartWatching(); });
    DPChanged();
    return fd;
}

// Short requests like /json/version come and go; only a connection that stays a moment counts as control.
NSArray<DPRemoteClient *> *DPRemoteControllers(void) {
    NSMutableArray<DPRemoteClient *> *clients = [NSMutableArray array];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    os_unfair_lock_lock(&DPLock);
    for (DPRemoteConnection *connection in DPConnections.allValues) {
        if (-connection.since.timeIntervalSinceNow < 0.8 || [names containsObject:connection.client.name]) continue;
        [names addObject:connection.client.name];
        [clients addObject:connection.client];
    }
    os_unfair_lock_unlock(&DPLock);
    [clients sortUsingComparator:^NSComparisonResult(DPRemoteClient *a, DPRemoteClient *b) { return [a.name compare:b.name]; }];
    return clients;
}

// Drops connections the engine has closed: the descriptor is gone or now belongs to another peer.
static void DPPrune(void) {
    BOOL changed = NO;
    os_unfair_lock_lock(&DPLock);
    for (NSNumber *key in DPConnections.allKeys) {
        DPRemoteConnection *connection = DPConnections[key];
        if (DPPortOf(connection.fd, YES) != connection.peerPort || DPPortOf(connection.fd, NO) != DPRemoteControlPort()) {
            [DPConnections removeObjectForKey:key];
            changed = YES;
        }
    }
    BOOL empty = DPConnections.count == 0;
    os_unfair_lock_unlock(&DPLock);
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:DPRemoteControlDidChange object:nil];
    else DPRemoteBadgeSync();  // A connection may just have lasted long enough to count.
    if (empty) {
        [DPWatch invalidate];
        DPWatch = nil;
    }
}

static void DPStartWatching(void) {
    if (DPWatch) return;
    DPWatch = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *_) { DPPrune(); }];
    DPWatch.tolerance = 0.1;
}

void DPRemoteTakeOver(void) {
    os_unfair_lock_lock(&DPLock);
    DPPausedFlag = YES;
    // Shutting down, not closing: the engine still owns the descriptor, sees the end of the stream and cleans up.
    for (DPRemoteConnection *connection in DPConnections.allValues)
        if (DPPortOf(connection.fd, YES) == connection.peerPort) shutdown(connection.fd, SHUT_RDWR);
    os_unfair_lock_unlock(&DPLock);
    [NSNotificationCenter.defaultCenter postNotificationName:DPRemoteControlDidChange object:nil];
}

void DPRemoteResume(void) {
    os_unfair_lock_lock(&DPLock);
    DPPausedFlag = NO;
    os_unfair_lock_unlock(&DPLock);
    [NSNotificationCenter.defaultCenter postNotificationName:DPRemoteControlDidChange object:nil];
}

BOOL DPRemotePaused(void) {
    os_unfair_lock_lock(&DPLock);
    BOOL paused = DPPausedFlag;
    os_unfair_lock_unlock(&DPLock);
    return paused;
}

// Points the engine's imported accept() at DPAccept.
static void DPRebind(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (!dladdr(header, &info) || !strstr(info.dli_fname, "/ArcCore.framework/")) return;
    void *real = dlsym(RTLD_DEFAULT, "accept");
    unsigned long size = 0;
    void **got = (void **)getsectiondata((const struct mach_header_64 *)header, "__DATA_CONST", "__got", &size);
    if (!got || !real) return;
    for (unsigned long i = 0; i < size / sizeof(void *); i++) {
        if (got[i] != real) continue;
        vm_address_t page = (vm_address_t)&got[i] & ~(vm_page_size - 1);
        if (vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
        DPRealAccept = real;
        got[i] = (void *)DPAccept;
        vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);
    }
}

void DPInstallRemoteGate(void) {
    DPConnections = [NSMutableDictionary dictionary];
    _dyld_register_func_for_add_image(DPRebind);
}

#import "RemoteControl.h"
#import <libproc.h>
#import <netinet/in.h>
#import <sys/sysctl.h>

@implementation DPRemoteClient
@end

// Each process owning one end of a TCP connection whose local port is `localPort` and remote port `remotePort`.
static pid_t DPPidWithSocket(int localPort, int remotePort) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return 0;
    pid_t *pids = calloc((size_t)count + 64, sizeof(pid_t));
    count = proc_listallpids(pids, (int)(((size_t)count + 64) * sizeof(pid_t)));
    pid_t found = 0, me = getpid();
    for (int i = 0; i < count && !found; i++) {
        pid_t pid = pids[i];
        if (pid <= 1 || pid == me) continue;
        int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (bytes <= 0) continue;
        struct proc_fdinfo *fds = malloc((size_t)bytes);
        bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
        int n = bytes > 0 ? bytes / (int)PROC_PIDLISTFD_SIZE : 0;
        for (int j = 0; j < n; j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo info;
            if (proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof info) != sizeof info) continue;
            if (info.psi.soi_kind != SOCKINFO_TCP) continue;
            struct in_sockinfo in = info.psi.soi_proto.pri_tcp.tcpsi_ini;
            if (ntohs((uint16_t)in.insi_lport) == localPort && ntohs((uint16_t)in.insi_fport) == remotePort) {
                found = pid;
                break;
            }
        }
        free(fds);
    }
    free(pids);
    return found;
}

static pid_t DPParent(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return 0;
    return (pid_t)info.pbi_ppid;
}

static NSString *DPPath(pid_t pid) {
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath(pid, buf, sizeof buf) > 0 ? @(buf) : nil;
}

// The name a process was started as, and the script an interpreter runs: `node /x/cli.js` gives node and /x/cli.js.
// Versioned installs need the first: Claude Code runs from …/claude/versions/2.1.0 as `claude`.
static NSArray<NSString *> *DPArgs(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return nil;
    char *buf = malloc(size);
    NSString *argv0 = @"", *script = @"";
    if (sysctl(mib, 3, buf, &size, NULL, 0) == 0) {
        int argc = *(int *)buf;
        char *p = buf + sizeof(int), *end = buf + size;
        p += strnlen(p, (size_t)(end - p));  // Executable path.
        while (p < end && !*p) p++;
        for (int i = 0; i < argc && p < end; i++) {
            if (i == 0) argv0 = @(p) ?: @"";
            else if (*p != '-') { script = @(p) ?: @""; break; }
            p += strnlen(p, (size_t)(end - p)) + 1;
        }
    }
    free(buf);
    return @[ argv0, script ];
}

// The agent or app a process is, by its app bundle, executable or script name.
static NSString *DPBundleName(NSString *path) {
    NSRange app = [path rangeOfString:@".app/"];  // The outermost app: helpers live inside the main one.
    return app.location == NSNotFound ? nil : [path substringToIndex:app.location].lastPathComponent;
}

static BOOL DPIsGeneric(NSString *name) {
    static NSSet<NSString *> *generic;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        generic = [NSSet setWithArray:@[ @"zsh", @"-zsh", @"bash", @"-bash", @"sh", @"fish", @"nu", @"login", @"env", @"sudo", @"tmux", @"screen",
                                         @"node", @"bun", @"deno", @"python", @"python3", @"ruby", @"npx", @"bunx", @"uv", @"uvx", @"index", @"cli", @"main" ]];
    });
    return !name.length || [generic containsObject:name.lowercaseString];
}

// What a process calls itself: the name it was started as (Claude Code runs from …/claude/versions/2.1.0 as `claude`),
// or for an interpreter, the script it runs. Empty for shells and bare interpreters.
static NSString *DPIdentity(NSString *path, NSArray<NSString *> *args) {
    NSString *exe = path.lastPathComponent, *argv0 = args.firstObject.lastPathComponent;
    NSString *script = args.count > 1 ? args[1] : @"";
    NSString *name = argv0.length ? argv0 : exe;
    if (DPIsGeneric(exe) || DPIsGeneric(argv0)) {
        name = script.lastPathComponent.stringByDeletingPathExtension;
        if (DPIsGeneric(name)) name = script.stringByDeletingLastPathComponent.lastPathComponent;  // …/orca/cli.js is orca.
    }
    return DPIsGeneric(name) || [name hasPrefix:@"."] ? @"" : name;
}

// The agents and apps known by name.
static NSString *DPKnownName(NSString *identity, NSString *bundle) {
    NSString *name = identity.lowercaseString, *app = bundle.lowercaseString ?: @"";
    NSArray<NSArray<NSString *> *> *known = @[
        @[ @"claude", @"Claude" ], @[ @"codex", @"Codex" ], @[ @"opencode", @"OpenCode" ], @[ @"gemini", @"Gemini" ],
        @[ @"cursor-agent", @"Cursor" ], @[ @"t3 code", @"T3 Code" ], @[ @"paseo", @"Paseo" ], @[ @"ardia", @"Ardia" ],
        @[ @"cursor", @"Cursor" ], @[ @"conductor", @"Conductor" ], @[ @"orca", @"Orca" ], @[ @"amp", @"Amp" ],
    ];
    for (NSArray<NSString *> *pair in known)
        if ([name isEqual:pair[0]] || [app hasPrefix:pair[0]]) return pair[1];
    return nil;
}

static NSString *DPAppName(pid_t pid) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return app.activationPolicy == NSApplicationActivationPolicyRegular ? app.localizedName : nil;
}

DPRemoteClient *DPRemoteClientForPeerPort(int peerPort, int localPort) {
    DPRemoteClient *client = [DPRemoteClient new];
    pid_t pid = DPPidWithSocket(peerPort, localPort);
    client.pid = pid;
    client.path = pid ? DPPath(pid) : nil;
    client.name = @"An unknown app";
    if (!pid) return client;

    // Walk up from the process that connected. A known agent names it; failing that, the first named command
    // (a CLI like `orca`) does; failing that, the app it runs in. The next app above the name says where it runs.
    NSString *name = nil, *command = nil;
    for (pid_t p = pid; p > 1; p = DPParent(p)) {
        NSString *path = DPPath(p);
        NSString *identity = DPIdentity(path, DPArgs(p));
        // Python and others run from an app bundle without being apps.
        NSString *bundle = DPIsGeneric(path.lastPathComponent) ? nil : DPBundleName(path).stringByDeletingPathExtension;
        NSString *app = DPAppName(p) ?: bundle;
        NSString *known = DPKnownName(identity, DPBundleName(path));
        if (!name) {
            if (known) name = known;
            else if (app) {
                name = command ?: app;
                if (command) client.via = app;
                if (command) break;
            } else if (!command && identity.length) command = identity;
            continue;
        }
        NSString *where = known ?: app;
        if (where && ![where isEqual:name]) {
            client.via = where;
            break;
        }
    }
    if (!name) name = command;
    if (name) {
        client.name = name;
        client.known = YES;
    }
    return client;
}

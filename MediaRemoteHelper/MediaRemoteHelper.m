// MusicFloat's optional MediaRemote bridge.
//
// MediaRemote is a private framework. This process is deliberately kept out of
// the app target so a framework ABI change or an invalid signing identity can
// be contained by terminating the helper and falling back to AppleScript.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <libproc.h>
#import <signal.h>
#import <unistd.h>

typedef void (*MRRegisterForNotifications)(dispatch_queue_t queue);
typedef void (*MRUnregisterForNotifications)(void);
typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t queue, void (^completion)(NSDictionary *));
typedef void (*MRGetNowPlayingPID)(dispatch_queue_t queue, void (^completion)(int));
typedef void (*MRGetNowPlayingPlaying)(dispatch_queue_t queue, void (^completion)(bool));

static dispatch_queue_t g_stateQueue;
static dispatch_source_t g_parentMonitor;
static pid_t g_parentPID;
static MRRegisterForNotifications g_registerNotifications;
static MRUnregisterForNotifications g_unregisterNotifications;
static MRGetNowPlayingInfo g_getNowPlayingInfo;
static MRGetNowPlayingPID g_getNowPlayingPID;
static MRGetNowPlayingPlaying g_getNowPlayingPlaying;
static BOOL g_requestPending;

static NSString *const kInfoChangedNotification = @"kMRMediaRemoteNowPlayingInfoDidChangeNotification";
static NSString *const kPlayingChangedNotification = @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification";
static NSString *const kPIDKey = @"kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey";
static NSString *const kTitleKey = @"kMRMediaRemoteNowPlayingInfoTitle";
static NSString *const kArtistKey = @"kMRMediaRemoteNowPlayingInfoArtist";
static NSString *const kAlbumKey = @"kMRMediaRemoteNowPlayingInfoAlbum";
static NSString *const kDurationKey = @"kMRMediaRemoteNowPlayingInfoDuration";
static NSString *const kElapsedKey = @"kMRMediaRemoteNowPlayingInfoElapsedTime";
static NSString *const kTimestampKey = @"kMRMediaRemoteNowPlayingInfoTimestamp";
static NSString *const kPlaybackRateKey = @"kMRMediaRemoteNowPlayingInfoPlaybackRate";
static NSString *const kUniqueIdentifierKey = @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier";
static NSString *const kContentIdentifierKey = @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier";

static void writeJSON(NSDictionary *payload) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data || error) {
        return;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// Resolves the bundle identifier from the process's executable path. Avoids
// NSRunningApplication so this helper does not load AppKit (~0.7 MB footprint).
static NSString *bundleIdentifierForPID(int pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) {
        return nil;
    }
    NSString *executable = [NSString stringWithUTF8String:path];
    NSRange contents = [executable rangeOfString:@".app/Contents/MacOS/" options:NSBackwardsSearch];
    if (contents.location == NSNotFound) {
        return nil;
    }
    NSString *bundlePath = [executable substringToIndex:contents.location + 4];
    return [NSBundle bundleWithPath:bundlePath].bundleIdentifier;
}

static NSNumber *numberValue(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSString *stringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static void emitState(NSDictionary *info, int pid, BOOL isPlaying) {
    NSString *bundleIdentifier = nil;
    if (pid > 0) {
        bundleIdentifier = bundleIdentifierForPID(pid);
    }

    // MusicFloat is an Apple Music bridge. Do not silently turn another media
    // app's metadata into an Apple Music track.
    if (bundleIdentifier && ![bundleIdentifier isEqualToString:@"com.apple.Music"]) {
        writeJSON(@{ @"version": @1, @"status": @"stopped" });
        return;
    }

    NSString *title = stringValue(info[kTitleKey]);
    NSString *artist = stringValue(info[kArtistKey]) ?: @"";
    NSString *album = stringValue(info[kAlbumKey]) ?: @"";
    NSNumber *duration = numberValue(info[kDurationKey]);
    NSNumber *elapsed = numberValue(info[kElapsedKey]);
    NSNumber *playbackRate = numberValue(info[kPlaybackRateKey]);
    NSString *uniqueIdentifier = stringValue(info[kUniqueIdentifierKey]);
    NSString *contentIdentifier = stringValue(info[kContentIdentifierKey]);

    if (!title.length || !bundleIdentifier.length) {
        writeJSON(@{ @"version": @1, @"status": @"stopped" });
        return;
    }

    NSDate *timestamp = [info[kTimestampKey] isKindOfClass:[NSDate class]] ? info[kTimestampKey] : nil;
    NSMutableDictionary *state = [@{
        @"version": @1,
        @"status": isPlaying ? @"playing" : @"paused",
        @"title": title,
        @"artist": artist,
        @"album": album,
        @"duration": duration ?: @0,
        @"elapsed": elapsed ?: @0,
        @"rate": playbackRate ?: (isPlaying ? @1 : @0),
        @"bundleIdentifier": bundleIdentifier,
    } mutableCopy];

    if (timestamp) {
        state[@"timestamp"] = @([timestamp timeIntervalSince1970]);
    }
    if (uniqueIdentifier.length) {
        state[@"uniqueIdentifier"] = uniqueIdentifier;
    }
    if (contentIdentifier.length) {
        state[@"contentIdentifier"] = contentIdentifier;
    }
    writeJSON(state);
}

static void requestState(void) {
    dispatch_async(g_stateQueue, ^{
        if (g_requestPending) {
            return;
        }
        g_requestPending = YES;

        __block NSDictionary *info = @{};
        __block int pid = 0;
        __block BOOL isPlaying = NO;
        dispatch_group_t group = dispatch_group_create();

        dispatch_group_enter(group);
        g_getNowPlayingInfo(g_stateQueue, ^(NSDictionary *value) {
            info = [value isKindOfClass:[NSDictionary class]] ? value : @{};
            dispatch_group_leave(group);
        });

        dispatch_group_enter(group);
        g_getNowPlayingPID(g_stateQueue, ^(int value) {
            pid = value;
            dispatch_group_leave(group);
        });

        dispatch_group_enter(group);
        g_getNowPlayingPlaying(g_stateQueue, ^(bool value) {
            isPlaying = value;
            dispatch_group_leave(group);
        });

        dispatch_group_notify(group, g_stateQueue, ^{
            g_requestPending = NO;
            emitState(info, pid, isPlaying);
        });
    });
}

static void handleSignal(int signalNumber) {
    if (signalNumber == SIGTERM || signalNumber == SIGINT) {
        // Keep the signal handler async-signal-safe. The parent owns this
        // process and the OS tears down the private framework connection.
        _exit(0);
    }
}

static BOOL loadMediaRemote(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!handle) {
        return NO;
    }

#define LOAD_SYMBOL(name, type) ((type)dlsym(handle, name))
    g_registerNotifications = LOAD_SYMBOL("MRMediaRemoteRegisterForNowPlayingNotifications", MRRegisterForNotifications);
    g_unregisterNotifications = LOAD_SYMBOL("MRMediaRemoteUnregisterForNowPlayingNotifications", MRUnregisterForNotifications);
    g_getNowPlayingInfo = LOAD_SYMBOL("MRMediaRemoteGetNowPlayingInfo", MRGetNowPlayingInfo);
    g_getNowPlayingPID = LOAD_SYMBOL("MRMediaRemoteGetNowPlayingApplicationPID", MRGetNowPlayingPID);
    g_getNowPlayingPlaying = LOAD_SYMBOL("MRMediaRemoteGetNowPlayingApplicationIsPlaying", MRGetNowPlayingPlaying);
#undef LOAD_SYMBOL

    return g_registerNotifications && g_unregisterNotifications && g_getNowPlayingInfo &&
           g_getNowPlayingPID && g_getNowPlayingPlaying;
}

int main(void) {
    @autoreleasepool {
        g_stateQueue = dispatch_queue_create("cv.musicfloat.mediaremote-helper", DISPATCH_QUEUE_SERIAL);
        g_parentPID = getppid();
        // Exit with the parent without a periodic wakeup.
        g_parentMonitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)g_parentPID, DISPATCH_PROC_EXIT, g_stateQueue);
        dispatch_source_set_event_handler(g_parentMonitor, ^{
            _exit(0);
        });
        dispatch_resume(g_parentMonitor);
        if (getppid() != g_parentPID) {
            _exit(0);
        }
        signal(SIGTERM, handleSignal);
        signal(SIGINT, handleSignal);

        if (!loadMediaRemote()) {
            writeJSON(@{ @"version": @1, @"status": @"unavailable", @"reason": @"mediaremote-load-failed" });
            return 2;
        }

        writeJSON(@{ @"version": @1, @"status": @"ready" });
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:kInfoChangedNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            requestState();
        }];
        [center addObserverForName:kPlayingChangedNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            requestState();
        }];

        g_registerNotifications(g_stateQueue);
        requestState();
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}

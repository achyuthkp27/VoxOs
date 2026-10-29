#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

#import "VoxOSNowPlaying.h"

// MediaRemote is private, so nothing here links against it: the two functions are looked up at run
// time, the queue's classes are reached by name, and every message is guarded by
// respondsToSelector:, so a macOS that renames something answers "no queue" rather than crashing.

typedef void (^VoxOSQueueAnswer)(id queue, NSError *error);
typedef void (*VoxOSRequestQueue)(id request, dispatch_queue_t queue, VoxOSQueueAnswer answer);
typedef bool (*VoxOSSendCommand)(int command, id options);

/// MediaRemote's command for "play this item of the queue".
static const int VoxOSPlayItemInQueue = 131;
static const NSUInteger VoxOSQueueLimit = 100;
static const int64_t VoxOSWait = 2 * NSEC_PER_SEC;

static void *mediaRemote(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    return handle;
}

static void answer(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    NSString *line = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static void fail(NSString *reason) { answer(@{@"error" : reason}); }

/// An object-returning message, or nil when the receiver does not answer it.
static id ask(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(receiver, selector);
}

static NSString *text(id value) {
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0 ? value : nil;
}

static NSUInteger environmentNumber(const char *name, NSUInteger fallback) {
    const char *value = getenv(name);
    if (value == NULL) return fallback;
    long long number = atoll(value);
    return number > 0 ? (NSUInteger)number : fallback;
}

/// One item as VoxOS reads it; nil for an item with no title.
static NSDictionary *describe(id item) {
    id metadata = ask(item, @"metadata");
    NSString *title = text(ask(metadata, @"title"));
    if (title == nil) return nil;
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:title forKey:@"title"];
    NSString *artist = text(ask(metadata, @"trackArtistName"));
    if (artist) entry[@"artist"] = artist;
    NSString *album = text(ask(metadata, @"albumName"));
    if (album) entry[@"album"] = album;
    if ([metadata respondsToSelector:NSSelectorFromString(@"duration")]) {
        double duration = ((double (*)(id, SEL))objc_msgSend)(metadata, NSSelectorFromString(@"duration"));
        if (duration > 0) entry[@"duration"] = @(duration);
    }
    NSDictionary *format = ask(ask(metadata, @"activeFormat"), @"dictionaryRepresentation");
    if ([format isKindOfClass:NSDictionary.class] && [NSJSONSerialization isValidJSONObject:format]) {
        entry[@"format"] = format;
    }
    NSString *identifier = text(ask(item, @"identifier"));
    if (identifier) entry[@"id"] = identifier;
    return entry;
}

void voxos_now_playing_queue(void) {
    VoxOSRequestQueue request = (VoxOSRequestQueue)dlsym(mediaRemote(), "MRMediaRemoteRequestNowPlayingPlaybackQueueSync");
    Class requestClass = NSClassFromString(@"MRPlaybackQueueRequest");
    SEL make = NSSelectorFromString(@"defaultPlaybackQueueRequestWithRange:");
    if (request == NULL || requestClass == nil || ![requestClass respondsToSelector:make]) {
        fail(@"this macOS does not offer the playback queue");
        return;
    }
    NSUInteger length = MIN(environmentNumber("VOXOS_QUEUE_LENGTH", 10), VoxOSQueueLimit);
    id queueRequest = ((id(*)(id, SEL, NSRange))objc_msgSend)(requestClass, make, NSMakeRange(0, length));
    for (NSString *name in @[ @"setIncludeMetadata:", @"setIncludeInfo:" ]) {
        SEL selector = NSSelectorFromString(name);
        if ([queueRequest respondsToSelector:selector]) ((void (*)(id, SEL, BOOL))objc_msgSend)(queueRequest, selector, YES);
    }

    __block NSArray *items = nil;
    __block NSString *problem = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("com.achyuthkp.voxos.now-playing", DISPATCH_QUEUE_SERIAL);
    request(queueRequest, queue, ^(id playbackQueue, NSError *error) {
        if (error != nil) {
            problem = error.localizedDescription ?: @"the queue could not be read";
        } else {
            NSMutableArray *found = [NSMutableArray array];
            for (id item in ask(playbackQueue, @"contentItems") ?: @[]) {
                NSDictionary *entry = describe(item);
                if (entry) [found addObject:entry];
            }
            items = found;
        }
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, VoxOSWait)) != 0) {
        fail(@"the queue did not answer in time");
    } else if (problem) {
        fail(problem);
    } else {
        answer(@{@"items" : items ?: @[]});
    }
}

void voxos_now_playing_play_item(void) {
    VoxOSSendCommand send = (VoxOSSendCommand)dlsym(mediaRemote(), "MRMediaRemoteSendCommand");
    if (send == NULL) {
        fail(@"this macOS does not offer playback commands");
        return;
    }
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    options[@"kMRMediaRemoteOptionPlaybackQueueOffset"] = @(environmentNumber("VOXOS_QUEUE_OFFSET", 0));
    const char *identifier = getenv("VOXOS_CONTENT_ITEM_ID");
    if (identifier != NULL && identifier[0] != '\0') {
        options[@"kMRMediaRemoteOptionContentItemID"] = [NSString stringWithUTF8String:identifier];
    }
    bool sent = send(VoxOSPlayItemInQueue, options);
    // The command is delivered asynchronously; leaving at once can drop it.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    answer(@{@"sent" : @(sent)});
}

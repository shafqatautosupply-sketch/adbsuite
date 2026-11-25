#import "ADBManager.h"
#import "ADBKit.h"
#include "adbapi.h"

NSString *const ADBTargetChangedNotification = @"ADBTargetChanged";
NSString *const ADBControlStatusNotification = @"ADBControlStatus";

static NSString *LastErr(void) {
    char e[700]; adbapi_last_error(e, sizeof e);
    return [NSString stringWithUTF8String:e] ?: @"";
}
static NSString *Str(const char *p, size_t n) {
    NSString *s = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding];
    return s ?: [[NSString alloc] initWithBytes:p length:n encoding:NSISOLatin1StringEncoding] ?: @"";
}

/* ------------------------------------------------------------------ */
@implementation ADBSession {
    NSString *_host, *_service; int _port; BOOL _framed;
    adbapi_stream *_stream; BOOL _running; BOOL _stopRequested;
    ADBUTF8Decoder *_dout, *_derr;
}
@synthesize running = _running;

static void session_cb(int kind, const uint8_t *d, size_t n, void *u) {
    ADBSession *s = (__bridge ADBSession *)u;
    [s deliver:kind bytes:d length:n];
}

- (id)initWithHost:(NSString *)host port:(int)port service:(NSString *)service framed:(BOOL)framed {
    if ((self = [super init])) {
        _host = [host copy]; _port = port; _service = [service copy]; _framed = framed;
        _dout = [ADBUTF8Decoder new]; _derr = [ADBUTF8Decoder new];
    }
    return self;
}

- (void)deliver:(int)kind bytes:(const uint8_t *)d length:(size_t)n {
    if (kind != 1 && kind != 2) return;
    NSString *t = [(kind == 2 ? _derr : _dout) feed:d length:n];
    if (!t.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onData) self.onData(t, kind); });
}

- (void)start {
    if (_running) return;
    _stream = adbapi_stream_new([_host UTF8String], _port, [_service UTF8String], _framed ? 1 : 0,
                                session_cb, (__bridge void *)self);
    if (!_stream) { if (self.onClose) self.onClose(-1, @"Cannot create stream"); return; }
    _running = YES;
    [NSThread detachNewThreadSelector:@selector(runLoop) toTarget:self withObject:nil];
}

- (void)runLoop {
    @autoreleasepool {
        int rc = adbapi_stream_run(_stream);
        NSString *err = rc < 0 ? LastErr() : nil;
        adbapi_stream *s;
        @synchronized (self) { s = _stream; _stream = NULL; }
        adbapi_stream_free(s);
        dispatch_async(dispatch_get_main_queue(), ^{
            _running = NO;
            if (self.onClose) self.onClose(rc, err);
        });
    }
}

- (void)sendString:(NSString *)s {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized (self) { if (_stream && d.length) adbapi_stream_send(_stream, d.bytes, d.length); }
}
- (void)stop {
    @synchronized (self) { if (_stream) adbapi_stream_stop(_stream); }
}
@end

/* ------------------------------------------------------------------ */
@implementation ADBManager {
    dispatch_queue_t _ioq, _xferq;
    NSMutableArray *_saved, *_forwards;
    ADBSession *_control;
}
@synthesize saved = _saved, forwards = _forwards;

+ (ADBManager *)shared {
    static ADBManager *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [ADBManager new]; });
    return m;
}

- (id)init {
    if ((self = [super init])) {
        NSString *lib = ADBFirst(NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES));
        NSString *home = [lib stringByAppendingPathComponent:@"ADBSuite"];
        [[NSFileManager defaultManager] createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
        adbapi_init([home UTF8String]);
        _ioq = dispatch_queue_create("adbsuite.io", DISPATCH_QUEUE_SERIAL);
        _xferq = dispatch_queue_create("adbsuite.xfer", DISPATCH_QUEUE_SERIAL);
        _forwards = [NSMutableArray array];
        NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
        _saved = [NSMutableArray arrayWithArray:[u objectForKey:@"saved"] ?: @[]];
        self.host = [u stringForKey:@"host"];
        self.port = (int)[u integerForKey:@"port"];
        self.deviceName = [u stringForKey:@"name"];
        if (!self.host.length) self.host = nil;
    }
    return self;
}

- (BOOL)hasTarget { return self.host.length && self.port > 0; }
- (NSString *)targetString { return [self hasTarget] ? [NSString stringWithFormat:@"%@:%d", self.host, self.port] : @"No device"; }

- (void)persist {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    [u setObject:_saved forKey:@"saved"];
    [u setObject:self.host ?: @"" forKey:@"host"];
    [u setInteger:self.port forKey:@"port"];
    [u setObject:self.deviceName ?: @"" forKey:@"name"];
    [u synchronize];
}

- (void)setTargetHost:(NSString *)host port:(int)port name:(NSString *)name {
    BOOL changed = ![host isEqualToString:self.host] || port != self.port;
    self.host = host; self.port = port; self.deviceName = name;
    if (changed) [self resetControl];
    [self persist];
    [[NSNotificationCenter defaultCenter] postNotificationName:ADBTargetChangedNotification object:nil];
}

- (void)saveCurrentTarget {
    if (![self hasTarget]) return;
    for (NSUInteger i = 0; i < _saved.count; i++) {
        NSMutableDictionary *d = [_saved[i] mutableCopy];
        if ([d[@"host"] isEqualToString:self.host]) {
            d[@"port"] = @(self.port); if (self.deviceName.length) d[@"name"] = self.deviceName;
            _saved[i] = d; [self persist]; return;
        }
    }
    [_saved addObject:@{@"name": self.deviceName.length ? self.deviceName : self.host, @"host": self.host, @"port": @(self.port)}];
    [self persist];
}
- (void)removeSavedAtIndex:(NSUInteger)i { if (i < _saved.count) { [_saved removeObjectAtIndex:i]; [self persist]; } }
- (void)updatePortForHost:(NSString *)host port:(int)port {
    for (NSUInteger i = 0; i < _saved.count; i++) {
        if ([_saved[i][@"host"] isEqualToString:host]) {
            NSMutableDictionary *d = [_saved[i] mutableCopy]; d[@"port"] = @(port); _saved[i] = d;
        }
    }
    if ([host isEqualToString:self.host]) { self.port = port; [self resetControl]; }
    [self persist];
    [[NSNotificationCenter defaultCenter] postNotificationName:ADBTargetChangedNotification object:nil];
}

/* ---- one-shot calls ---- */
static void OnMain(dispatch_block_t b) { dispatch_async(dispatch_get_main_queue(), b); }

- (void)shell:(NSString *)cmd completion:(void (^)(NSString *, int, NSString *))cb {
    NSString *h = self.host; int p = self.port;
    if (![self hasTarget]) { OnMain(^{ cb(@"", -1, @"No device selected. Open the Devices tab."); }); return; }
    dispatch_async(_ioq, ^{
        char *out = NULL; size_t n = 0; int code = 0;
        int rc = adbapi_shell([h UTF8String], p, [cmd UTF8String], &out, &n, &code);
        NSString *err = rc ? LastErr() : nil;
        NSString *s = out ? Str(out, n) : @"";
        free(out);
        OnMain(^{ cb(s, code, err); });
    });
}

- (void)service:(NSString *)svc completion:(void (^)(NSData *, NSString *))cb {
    NSString *h = self.host; int p = self.port;
    if (![self hasTarget]) { OnMain(^{ cb(nil, @"No device selected. Open the Devices tab."); }); return; }
    dispatch_async(_ioq, ^{
        uint8_t *out = NULL; size_t n = 0;
        int rc = adbapi_service([h UTF8String], p, [svc UTF8String], &out, &n);
        NSString *err = rc ? LastErr() : nil;
        NSData *d = out ? [NSData dataWithBytes:out length:n] : [NSData data];
        free(out);
        OnMain(^{ cb(rc ? nil : d, err); });
    });
}

- (void)probeHost:(NSString *)host port:(int)port completion:(void (^)(BOOL, NSString *, NSString *))cb {
    dispatch_async(_ioq, ^{
        char banner[2048] = "";
        int rc = adbapi_probe([host UTF8String], port, banner, sizeof banner);
        NSString *err = rc ? LastErr() : nil, *b = [NSString stringWithUTF8String:banner] ?: @"";
        OnMain(^{ cb(rc == 0, b, err); });
    });
}

- (void)pairHost:(NSString *)host port:(int)port code:(NSString *)code completion:(void (^)(BOOL, NSString *))cb {
    dispatch_async(_ioq, ^{
        int rc = adbapi_pair([host UTF8String], port, [code UTF8String]);
        char info[512] = ""; adbapi_last_info(info, sizeof info);
        NSString *msg = rc ? LastErr() : ([NSString stringWithUTF8String:info] ?: @"Paired");
        OnMain(^{ cb(rc == 0, msg); });
    });
}

static void disc_cb(int kind, const char *name, const char *host, int port, void *u) {
    NSMutableArray *a = (__bridge NSMutableArray *)u;
    [a addObject:@{@"kind": @(kind), @"name": [NSString stringWithUTF8String:name] ?: @"",
                   @"host": [NSString stringWithUTF8String:host] ?: @"", @"port": @(port)}];
}
- (void)discoverWithCompletion:(void (^)(NSArray *, NSArray *))cb {
    dispatch_async(_ioq, ^{
        NSMutableArray *all = [NSMutableArray array];
        adbapi_discover(5000, disc_cb, (__bridge void *)all);
        NSMutableArray *c = [NSMutableArray array], *p = [NSMutableArray array];
        for (NSDictionary *d in all) { if ([d[@"kind"] intValue] == 1) [p addObject:d]; else [c addObject:d]; }
        OnMain(^{ cb(c, p); });
    });
}
- (void)findPortForHost:(NSString *)host completion:(void (^)(int))cb {
    dispatch_async(_ioq, ^{ int p = adbapi_find_port([host UTF8String], 5000); OnMain(^{ cb(p); }); });
}

/* ---- transfers ---- */
typedef void (^ADBProgressBlock)(uint64_t done, uint64_t total);
static void xfer_cb(uint64_t d, uint64_t t, void *u) {
    ADBProgressBlock b = (__bridge ADBProgressBlock)u;
    b(d, t);
}

- (void)push:(NSString *)local to:(NSString *)remote progress:(void (^)(double))progress
  completion:(void (^)(BOOL, NSString *))cb {
    NSString *h = self.host; int p = self.port;
    if (![self hasTarget]) { OnMain(^{ cb(NO, @"No device selected"); }); return; }
    dispatch_async(_xferq, ^{
        __block double last = -1;
        ADBProgressBlock pb = ^(uint64_t d, uint64_t t) {
            if (!progress || !t) return;
            double f = (double)d / (double)t;
            if (f - last >= 0.01 || f >= 1.0) { last = f; OnMain(^{ progress(f); }); }
        };
        int rc = adbapi_push([h UTF8String], p, [local UTF8String], [remote UTF8String], xfer_cb, (__bridge void *)pb);
        NSString *err = rc ? LastErr() : nil;
        OnMain(^{ cb(rc == 0, err); });
    });
}

- (void)pull:(NSString *)remote to:(NSString *)local total:(unsigned long long)total
    progress:(void (^)(double, unsigned long long))progress completion:(void (^)(BOOL, NSString *))cb {
    NSString *h = self.host; int p = self.port;
    if (![self hasTarget]) { OnMain(^{ cb(NO, @"No device selected"); }); return; }
    dispatch_async(_xferq, ^{
        __block double last = -1;
        ADBProgressBlock pb = ^(uint64_t d, uint64_t t) {
            if (!progress) return;
            double f = t ? (double)d / (double)t : 0;
            if (f - last >= 0.01 || (!t && d % (256 * 1024) < 65536)) { last = f; OnMain(^{ progress(f, d); }); }
        };
        int rc = adbapi_pull([h UTF8String], p, [remote UTF8String], [local UTF8String], total, xfer_cb, (__bridge void *)pb);
        NSString *err = rc ? LastErr() : nil;
        OnMain(^{ cb(rc == 0, err); });
    });
}

- (NSString *)publicKey {
    char k[1100];
    return adbapi_pubkey(k, sizeof k) == 0 ? [NSString stringWithUTF8String:k] : LastErr();
}

/* ---- control channel (persistent sh, used by the Remote tab) ---- */
- (void)setControlStatus:(NSString *)s {
    _controlStatus = [s copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:ADBControlStatusNotification object:nil];
}

- (void)resetControl {
    ADBSession *c = _control; _control = nil;
    [c stop];
}

- (void)sendControl:(NSString *)line {
    if (![self hasTarget]) { self.controlStatus = @"No device selected"; return; }
    if (!_control || !_control.running) {
        ADBSession *s = [self newShellSession];
        __weak ADBManager *me = self;
        __weak ADBSession *ws = s;
        s.onClose = ^(int code, NSString *err) {
            ADBManager *m = me;
            if (m && m->_control == ws) {
                m->_control = nil;
                m.controlStatus = (code < 0 && err.length) ? err : @"Control channel closed";
            }
        };
        s.onData = ^(NSString *t, int kind) { if (kind == 2) me.controlStatus = [t adb_trimmed]; };
        _control = s;
        self.controlStatus = @"Connecting...";
        [s start];
    }
    [_control sendString:[line stringByAppendingString:@"\n"]];
}

/* ---- sessions ---- */
- (ADBSession *)newShellSession {
    return [[ADBSession alloc] initWithHost:self.host port:self.port service:@"shell,v2,raw:" framed:YES];
}
- (ADBSession *)newSessionForCommand:(NSString *)cmd {
    return [[ADBSession alloc] initWithHost:self.host port:self.port
                                    service:[@"shell,v2,raw:" stringByAppendingString:cmd] framed:YES];
}

/* ---- port forwarding ---- */
- (NSString *)startForwardLocalPort:(int)lp remoteService:(NSString *)svc bindAll:(BOOL)all {
    if (![self hasTarget]) return @"No device selected";
    adbapi_fwd *f = adbapi_forward_start([self.host UTF8String], self.port, lp, [svc UTF8String], all ? 1 : 0);
    if (!f) return LastErr();
    [_forwards addObject:@{@"local": @(lp), @"service": svc, @"all": @(all), @"handle": [NSValue valueWithPointer:f]}];
    return nil;
}
- (void)stopForwardAtIndex:(NSUInteger)i {
    if (i >= _forwards.count) return;
    adbapi_fwd *f = [_forwards[i][@"handle"] pointerValue];
    [_forwards removeObjectAtIndex:i];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ adbapi_forward_stop(f); });
}
@end

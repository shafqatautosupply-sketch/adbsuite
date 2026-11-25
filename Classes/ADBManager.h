#import <Foundation/Foundation.h>

extern NSString *const ADBTargetChangedNotification;
extern NSString *const ADBControlStatusNotification;

/* A streaming connection (terminal, logcat, control channel) running on its own thread. */
@interface ADBSession : NSObject
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, copy) void (^onData)(NSString *text, int kind);        /* main thread; kind 1 out, 2 err */
@property (nonatomic, copy) void (^onClose)(int code, NSString *error);     /* main thread */
- (id)initWithHost:(NSString *)host port:(int)port service:(NSString *)service framed:(BOOL)framed;
- (void)start;
- (void)sendString:(NSString *)s;
- (void)stop;
@end

@interface ADBManager : NSObject
+ (ADBManager *)shared;

@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) int port;
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, readonly) NSMutableArray *saved;       /* @{@"name",@"host",@"port"} */
@property (nonatomic, readonly) NSMutableArray *forwards;    /* @{@"local",@"service",@"all",@"handle"} */
@property (nonatomic, copy) NSString *controlStatus;

- (BOOL)hasTarget;
- (NSString *)targetString;
- (void)setTargetHost:(NSString *)host port:(int)port name:(NSString *)name;
- (void)saveCurrentTarget;
- (void)removeSavedAtIndex:(NSUInteger)index;
- (void)updatePortForHost:(NSString *)host port:(int)port;

/* all completions are delivered on the main thread */
- (void)shell:(NSString *)cmd completion:(void (^)(NSString *out, int code, NSString *err))cb;
- (void)service:(NSString *)svc completion:(void (^)(NSData *data, NSString *err))cb;
- (void)probeHost:(NSString *)host port:(int)port completion:(void (^)(BOOL ok, NSString *banner, NSString *err))cb;
- (void)pairHost:(NSString *)host port:(int)port code:(NSString *)code completion:(void (^)(BOOL ok, NSString *msg))cb;
- (void)discoverWithCompletion:(void (^)(NSArray *connect, NSArray *pairing))cb;
- (void)findPortForHost:(NSString *)host completion:(void (^)(int port))cb;
- (void)push:(NSString *)local to:(NSString *)remote progress:(void (^)(double f))progress
  completion:(void (^)(BOOL ok, NSString *err))cb;
- (void)pull:(NSString *)remote to:(NSString *)local total:(unsigned long long)total
  progress:(void (^)(double f, unsigned long long done))progress completion:(void (^)(BOOL ok, NSString *err))cb;
- (NSString *)publicKey;

/* persistent low-latency channel for remote-control key presses */
- (void)sendControl:(NSString *)commandLine;
- (void)resetControl;

/* port forwarding */
- (NSString *)startForwardLocalPort:(int)lp remoteService:(NSString *)svc bindAll:(BOOL)all;   /* nil on success */
- (void)stopForwardAtIndex:(NSUInteger)i;

/* helpers */
- (ADBSession *)newShellSession;                         /* persistent sh, no pty */
- (ADBSession *)newSessionForCommand:(NSString *)cmd;    /* streaming command (logcat, top...) */
@end

#import "ScreenViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"

@implementation ScreenViewController {
    UIImageView *_iv; UILabel *_info; BOOL _live, _control, _busy; UIImage *_img;
    UIBarButtonItem *_liveItem, *_ctlItem; NSDate *_t0;
}

- (id)init {
    if ((self = [super init])) {
        self.title = @"Screen";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Screen" image:[UIImage imageNamed:@"tab_screen"] tag:5];
    }
    return self;
}

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor blackColor]; self.view = v;
    _iv = [[UIImageView alloc] initWithFrame:v.bounds];
    _iv.contentMode = UIViewContentModeScaleAspectFit; _iv.userInteractionEnabled = YES;
    _iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [v addSubview:_iv];
    _info = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, v.bounds.size.width, 18)];
    _info.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5]; _info.textColor = [UIColor whiteColor];
    _info.font = [UIFont systemFontOfSize:11]; _info.textAlignment = NSTextAlignmentCenter;
    _info.autoresizingMask = UIViewAutoresizingFlexibleWidth; _info.text = @"Tap Capture";
    [v addSubview:_info];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [_iv addGestureRecognizer:tap]; [_iv addGestureRecognizer:pan];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    _liveItem = [[UIBarButtonItem alloc] initWithTitle:@"Live: off" style:UIBarButtonItemStyleBordered target:self action:@selector(toggleLive)];
    _ctlItem = [[UIBarButtonItem alloc] initWithTitle:@"Touch: off" style:UIBarButtonItemStyleBordered target:self action:@selector(toggleControl)];
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Capture" style:UIBarButtonItemStyleBordered target:self action:@selector(capture)], flex,
        _liveItem, flex, _ctlItem, flex,
        [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleBordered target:self action:@selector(saveToPhotos)], flex,
        [[UIBarButtonItem alloc] initWithTitle:@"Rec" style:UIBarButtonItemStyleBordered target:self action:@selector(record)]];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.navigationController setToolbarHidden:NO animated:animated]; }
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _live = NO; _liveItem.title = @"Live: off";
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)capture {
    if (_busy) return;
    if (![[ADBManager shared] hasTarget]) { [ADBAlert alert:@"Screen" message:@"No device selected. Open the Devices tab."]; return; }
    _busy = YES; _t0 = [NSDate date];
    _info.text = @"Capturing...";
    [[ADBManager shared] service:@"exec:screencap -p" completion:^(NSData *data, NSString *err) {
        _busy = NO;
        if (err) { _live = NO; _liveItem.title = @"Live: off"; _info.text = err; return; }
        UIImage *img = [UIImage imageWithData:data];
        if (!img) { _live = NO; _liveItem.title = @"Live: off"; _info.text = [NSString stringWithFormat:@"Not an image (%lu bytes) - screencap unsupported?", (unsigned long)data.length]; return; }
        _img = img; _iv.image = img;
        _info.text = [NSString stringWithFormat:@"%dx%d  %.1fs  %@", (int)img.size.width, (int)img.size.height, -[_t0 timeIntervalSinceNow], ADBHumanSize(data.length)];
        if (_live && self.view.window) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (_live) [self capture]; });
    }];
}
- (void)toggleLive {
    _live = !_live; _liveItem.title = _live ? @"Live: on" : @"Live: off";
    if (_live) [self capture];
}
- (void)toggleControl { _control = !_control; _ctlItem.title = _control ? @"Touch: on" : @"Touch: off"; }

- (void)saveToPhotos {
    if (!_img) return;
    UIImageWriteToSavedPhotosAlbum(_img, nil, nil, NULL);
    [ADBHUD toast:@"Saved to Photos"];
}

/* image point -> device pixel */
- (BOOL)devicePoint:(CGPoint)pt out:(CGPoint *)out {
    if (!_img) return NO;
    CGSize is = _img.size, vs = _iv.bounds.size;
    CGFloat s = MIN(vs.width / is.width, vs.height / is.height);
    CGSize d = CGSizeMake(is.width * s, is.height * s);
    CGPoint o = CGPointMake((vs.width - d.width) / 2, (vs.height - d.height) / 2);
    CGFloat x = (pt.x - o.x) / s, y = (pt.y - o.y) / s;
    if (x < 0 || y < 0 || x > is.width || y > is.height) return NO;
    *out = CGPointMake(x * _img.scale, y * _img.scale);
    return YES;
}
- (void)onTap:(UITapGestureRecognizer *)g {
    CGPoint p;
    if (!_control || ![self devicePoint:[g locationInView:_iv] out:&p]) return;
    [[ADBManager shared] sendControl:[NSString stringWithFormat:@"input tap %d %d", (int)p.x, (int)p.y]];
    if (!_live) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self capture]; });
}
- (void)onPan:(UIPanGestureRecognizer *)g {
    static CGPoint start; static NSDate *t;
    if (g.state == UIGestureRecognizerStateBegan) { start = [g locationInView:_iv]; t = [NSDate date]; }
    if (g.state != UIGestureRecognizerStateEnded || !_control) return;
    CGPoint a, b;
    if (![self devicePoint:start out:&a] || ![self devicePoint:[g locationInView:_iv] out:&b]) return;
    int ms = MAX(80, MIN(1200, (int)(-[t timeIntervalSinceNow] * 1000)));
    [[ADBManager shared] sendControl:[NSString stringWithFormat:@"input swipe %d %d %d %d %d", (int)a.x, (int)a.y, (int)b.x, (int)b.y, ms]];
    if (!_live) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self capture]; });
}

- (void)record {
    [ADBAlert sheet:@"Record screen" buttons:@[@"10 seconds", @"30 seconds", @"60 seconds", @"180 seconds"] destructive:-1 from:self handler:^(NSInteger i) {
        int secs[] = {10, 30, 60, 180}; int n = secs[i];
        NSString *remote = @"/sdcard/adbsuite_rec.mp4";
        [ADBHUD show:[NSString stringWithFormat:@"Recording %d s...", n]];
        [[ADBManager shared] shell:[NSString stringWithFormat:@"screenrecord --time-limit %d %@ 2>&1", n, remote] completion:^(NSString *out, int code, NSString *err) {
            if (err || code != 0) { [ADBHUD hide]; [ADBAlert alert:@"Recording failed" message:err ?: out]; return; }
            NSString *dir = [ADBDocumentsDir() stringByAppendingPathComponent:@"Recordings"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *local = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"rec_%d.mp4", (int)[[NSDate date] timeIntervalSince1970]]];
            [ADBHUD showProgress:@"Downloading recording..."];
            [[ADBManager shared] pull:remote to:local total:0 progress:^(double f, unsigned long long done) {
                [ADBHUD setProgress:0 text:[NSString stringWithFormat:@"%@", ADBHumanSize(done)]];
            } completion:^(BOOL ok, NSString *e2) {
                [ADBHUD hide];
                [[ADBManager shared] shell:[NSString stringWithFormat:@"rm -f %@", remote] completion:^(NSString *o, int c, NSString *e) {}];
                [ADBAlert alert:ok ? @"Recording saved" : @"Download failed" message:ok ? local : e2];
            }];
        }];
    }];
}
@end

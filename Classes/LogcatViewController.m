#import "LogcatViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"

#define MAX_LINES 6000

@implementation LogcatViewController {
    UITextView *_tv; UITextField *_filter; UISegmentedControl *_lvl;
    ADBSession *_s; NSMutableArray *_lines; NSString *_partial;
    BOOL _dirty, _auto, _paused; NSTimer *_timer; UIBarButtonItem *_run, *_autoItem;
}

- (id)init {
    if ((self = [super init])) {
        self.title = @"Logcat"; _lines = [NSMutableArray array]; _partial = @""; _auto = YES;
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Logcat" image:[UIImage imageNamed:@"tab_logcat"] tag:6];
    }
    return self;
}

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor blackColor]; self.view = v;
    _filter = [[UITextField alloc] initWithFrame:CGRectMake(6, 6, v.bounds.size.width - 12, 28)];
    _filter.borderStyle = UITextBorderStyleRoundedRect; _filter.placeholder = @"Filter (tag, text, pid...)";
    _filter.font = [UIFont systemFontOfSize:14]; _filter.delegate = self; _filter.returnKeyType = UIReturnKeyDone;
    _filter.autocapitalizationType = UITextAutocapitalizationTypeNone; _filter.autocorrectionType = UITextAutocorrectionTypeNo;
    _filter.clearButtonMode = UITextFieldViewModeWhileEditing;
    _filter.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_filter addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventEditingChanged];
    [v addSubview:_filter];
    _tv = ADBMakeConsole(CGRectMake(0, 40, v.bounds.size.width, v.bounds.size.height - 40));
    _tv.font = ADBMonoFont(9);
    [v addSubview:_tv];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _lvl = [[UISegmentedControl alloc] initWithItems:@[@"V", @"D", @"I", @"W", @"E"]];
    _lvl.segmentedControlStyle = UISegmentedControlStyleBar; _lvl.selectedSegmentIndex = 3;
    [_lvl addTarget:self action:@selector(levelChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _lvl;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    _run = [[UIBarButtonItem alloc] initWithTitle:@"Pause" style:UIBarButtonItemStyleBordered target:self action:@selector(togglePause)];
    _autoItem = [[UIBarButtonItem alloc] initWithTitle:@"Scroll: on" style:UIBarButtonItemStyleBordered target:self action:@selector(toggleAuto)];
    self.toolbarItems = @[_run, flex, _autoItem, flex,
        [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStyleBordered target:self action:@selector(clearLog)], flex,
        [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleBordered target:self action:@selector(save)]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(targetChanged) name:ADBTargetChangedNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    if (!_s && !_paused) [self start];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}
- (void)targetChanged { [self stop]; if (self.isViewLoaded && self.view.window) [self start]; }

- (void)start {
    ADBManager *m = [ADBManager shared];
    if (![m hasTarget]) { _tv.text = @"No device selected. Open the Devices tab."; return; }
    static const char *letters = "VDIWE";
    NSString *cmd = [NSString stringWithFormat:@"logcat -v threadtime '*:%c'", letters[_lvl.selectedSegmentIndex]];
    ADBSession *s = [m newSessionForCommand:cmd];
    __weak LogcatViewController *me = self; __weak ADBSession *ws = s;
    s.onData = ^(NSString *t, int kind) { [me ingest:t]; };
    s.onClose = ^(int code, NSString *err) {
        LogcatViewController *l = me; if (!l) return;
        if (l->_s == ws) l->_s = nil;
        if (code < 0 && err.length) [l ingest:[NSString stringWithFormat:@"\n-- logcat connection failed: %@ --\n", err]];
    };
    _s = s; [s start];
    if (!_timer) _timer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)stop {
    ADBSession *s = _s; _s = nil;
    if (s) { s.onData = nil; s.onClose = nil; [s stop]; }
}
- (void)togglePause {
    _paused = !_paused; _run.title = _paused ? @"Resume" : @"Pause";
    if (_paused) [self stop]; else [self start];
}
- (void)toggleAuto { _auto = !_auto; _autoItem.title = _auto ? @"Scroll: on" : @"Scroll: off"; }
- (void)levelChanged { [self stop]; if (!_paused) [self start]; }
- (void)filterChanged { _dirty = YES; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)ingest:(NSString *)chunk {
    NSString *all = [_partial stringByAppendingString:chunk];
    NSMutableArray *parts = [[all componentsSeparatedByString:@"\n"] mutableCopy];
    _partial = [parts lastObject]; [parts removeLastObject];
    if (!parts.count) return;
    [_lines addObjectsFromArray:parts];
    if (_lines.count > MAX_LINES) [_lines removeObjectsInRange:NSMakeRange(0, _lines.count - MAX_LINES + 1000)];
    _dirty = YES;
}

- (void)tick {
    if (!_dirty || !self.view.window) return;
    _dirty = NO;
    NSString *q = [[_filter.text ?: @"" lowercaseString] adb_trimmed];
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = (NSInteger)_lines.count - 1; i >= 0 && out.count < 500; i--) {
        NSString *l = _lines[i];
        if (!q.length || [[l lowercaseString] rangeOfString:q].location != NSNotFound) [out addObject:l];
    }
    NSArray *rev = [[out reverseObjectEnumerator] allObjects];
    _tv.text = [rev componentsJoinedByString:@"\n"];
    if (_auto && _tv.text.length) [_tv scrollRangeToVisible:NSMakeRange(_tv.text.length - 1, 1)];
}

- (void)clearLog {
    [_lines removeAllObjects]; _partial = @""; _tv.text = @"";
    [[ADBManager shared] shell:@"logcat -c" completion:^(NSString *o, int c, NSString *e) {}];
}
- (void)save {
    NSString *dir = [ADBDocumentsDir() stringByAppendingPathComponent:@"Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"logcat_%d.txt", (int)[[NSDate date] timeIntervalSince1970]]];
    [[_lines componentsJoinedByString:@"\n"] writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [ADBAlert alert:@"Saved" message:p];
}
@end

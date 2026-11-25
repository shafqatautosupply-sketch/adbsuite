#import "TerminalViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"

@implementation TerminalViewController {
    UITextView *_out; UITextField *_in; UIView *_bar;
    ADBSession *_session;
    NSMutableString *_pending; NSTimer *_timer;
    NSMutableArray *_history; NSInteger _histPos;
    CGFloat _kb;
}

- (id)init {
    if ((self = [super init])) {
        self.title = @"Terminal";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Terminal" image:[UIImage imageNamed:@"tab_terminal"] tag:2];
        _pending = [NSMutableString string]; _history = [NSMutableArray array]; _histPos = 0;
    }
    return self;
}

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor blackColor];
    self.view = v;
    _out = ADBMakeConsole(CGRectZero); [v addSubview:_out];
    _bar = [[UIView alloc] initWithFrame:CGRectZero];
    _bar.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1]; [v addSubview:_bar];
    _in = [[UITextField alloc] initWithFrame:CGRectZero];
    _in.borderStyle = UITextBorderStyleRoundedRect; _in.placeholder = @"command";
    _in.font = ADBMonoFont(14); _in.delegate = self;
    _in.autocapitalizationType = UITextAutocapitalizationTypeNone; _in.autocorrectionType = UITextAutocorrectionTypeNo;
    _in.returnKeyType = UIReturnKeySend; _in.clearButtonMode = UITextFieldViewModeWhileEditing;
    [_bar addSubview:_in];
    UIButton *up = ADBMakeButton(@"\u25B2", CGRectZero, self, @selector(histUp)); up.tag = 1;
    UIButton *dn = ADBMakeButton(@"\u25BC", CGRectZero, self, @selector(histDown)); dn.tag = 2;
    UIButton *tab = ADBMakeButton(@"/", CGRectZero, self, @selector(insertSlash)); tab.tag = 3;
    [_bar addSubview:up]; [_bar addSubview:dn]; [_bar addSubview:tab];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; CGFloat barH = 44, w = b.size.width;
    CGFloat bottom = b.size.height - _kb;
    _bar.frame = CGRectMake(0, bottom - barH, w, barH);
    _out.frame = CGRectMake(0, 0, w, bottom - barH);
    _in.frame = CGRectMake(6, 7, w - 6 - 3 * 42 - 6, 30);
    CGFloat x = w - 3 * 42;
    for (UIView *v in _bar.subviews) if ([v isKindOfClass:[UIButton class]]) { v.frame = CGRectMake(x + (v.tag - 1) * 42, 6, 40, 32); }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStyleBordered target:self action:@selector(clear)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Restart" style:UIBarButtonItemStyleBordered target:self action:@selector(restart)];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(kbChange:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(kbChange:) name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(targetChanged) name:ADBTargetChangedNotification object:nil];
}

- (void)kbChange:(NSNotification *)n {
    CGRect end = [[n.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    end = [self.view convertRect:[self.view.window convertRect:end fromWindow:nil] fromView:nil];
    BOOL show = [n.name isEqualToString:UIKeyboardWillShowNotification];
    _kb = show ? MAX(0, CGRectGetMaxY(self.view.bounds) - end.origin.y) : 0;
    [UIView animateWithDuration:0.25 animations:^{ [self viewDidLayoutSubviews]; }];
    [self scrollEnd];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_session && [[ADBManager shared] hasTarget]) [self startSession];
    else if (![[ADBManager shared] hasTarget]) [self append:@"No device selected. Pick one in the Devices tab.\n"];
}
- (void)targetChanged { [self restart]; }

- (void)startSession {
    ADBManager *m = [ADBManager shared];
    if (![m hasTarget]) return;
    [self append:[NSString stringWithFormat:@"-- connecting to %@ --\n", [m targetString]]];
    ADBSession *s = [m newShellSession];
    __weak TerminalViewController *me = self; __weak ADBSession *ws = s;
    s.onData = ^(NSString *t, int kind) { [me append:t]; };
    s.onClose = ^(int code, NSString *err) {
        TerminalViewController *t = me; if (!t) return;
        [t append:(code < 0 ? [NSString stringWithFormat:@"\n-- connection failed: %@ --\n", err] : @"\n-- session closed --\n")];
        if (t->_session == ws) t->_session = nil;
    };
    _session = s; [s start];
}

- (void)restart {
    ADBSession *s = _session; _session = nil;
    if (s) { s.onData = nil; s.onClose = nil; [s stop]; }
    if (self.isViewLoaded && self.view.window) [self startSession];
}
- (void)clear { [_pending setString:@""]; _out.text = @""; }

- (void)append:(NSString *)t {
    [_pending appendString:t];
    if (!_timer) _timer = [NSTimer scheduledTimerWithTimeInterval:0.08 target:self selector:@selector(flush) userInfo:nil repeats:NO];
}
- (void)flush {
    _timer = nil;
    if (!_pending.length) return;
    NSString *cur = _out.text ?: @"";
    NSString *n = [cur stringByAppendingString:_pending];
    [_pending setString:@""];
    if (n.length > 120000) n = [n substringFromIndex:n.length - 80000];
    _out.text = n;
    [self scrollEnd];
}
- (void)scrollEnd { if (_out.text.length) [_out scrollRangeToVisible:NSMakeRange(_out.text.length - 1, 1)]; }

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    NSString *cmd = tf.text ?: @"";
    tf.text = @"";
    if ([[cmd adb_trimmed] isEqualToString:@"clear"]) { [self clear]; return NO; }
    if (cmd.length) { [_history addObject:cmd]; _histPos = _history.count; }
    [self append:[NSString stringWithFormat:@"$ %@\n", cmd]];
    if (!_session || !_session.running) { [self startSession]; }
    [_session sendString:[cmd stringByAppendingString:@"\n"]];
    return NO;
}
- (void)histUp { if (_histPos > 0) { _histPos--; _in.text = _history[_histPos]; } }
- (void)histDown {
    if (_histPos < (NSInteger)_history.count - 1) { _histPos++; _in.text = _history[_histPos]; }
    else { _histPos = _history.count; _in.text = @""; }
}
- (void)insertSlash { _in.text = [(_in.text ?: @"") stringByAppendingString:@"/"]; }
@end

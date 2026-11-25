#import "RemoteViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"

/* Touch surface: reports tap or swipe in view coordinates */
@interface ADBTouchPad : UIView
@property (nonatomic, copy) void (^onGesture)(CGPoint start, CGPoint end, NSTimeInterval duration);
@end
@implementation ADBTouchPad {
    CGPoint _start; NSTimeInterval _t0;
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)e {
    UITouch *t = [touches anyObject]; _start = [t locationInView:self]; _t0 = t.timestamp;
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)e {
    UITouch *t = [touches anyObject];
    if (self.onGesture) self.onGesture(_start, [t locationInView:self], t.timestamp - _t0);
}
@end

@implementation RemoteViewController {
    UIScrollView *_scroll; UILabel *_status; UITextField *_text; ADBTouchPad *_pad;
    NSMutableArray *_codes; CGSize _devSize; CGFloat _kb;
}

- (id)init {
    if ((self = [super init])) {
        self.title = @"Remote";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Remote" image:[UIImage imageNamed:@"tab_remote"] tag:1];
        _codes = [NSMutableArray array];
    }
    return self;
}

- (UIButton *)addKey:(NSString *)title code:(NSString *)code frame:(CGRect)f {
    UIButton *b = ADBMakeButton(title, f, self, @selector(keyTapped:));
    b.tag = (NSInteger)_codes.count; [_codes addObject:code];
    [_scroll addSubview:b];
    return b;
}

/* equally spaced row of keys; returns next y */
- (CGFloat)row:(NSArray *)items y:(CGFloat)y {
    CGFloat w = 320, pad = 6, n = items.count, bw = (w - pad * (n + 1)) / n;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSArray *it = items[i];
        [self addKey:it[0] code:it[1] frame:CGRectMake(pad + i * (bw + pad), y, bw, 40)];
    }
    return y + 46;
}

- (void)loadView {
    _scroll = [[UIScrollView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _scroll.backgroundColor = [UIColor groupTableViewBackgroundColor];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    self.view = _scroll;

    _status = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 304, 18)];
    _status.backgroundColor = [UIColor clearColor]; _status.font = [UIFont systemFontOfSize:12];
    _status.textColor = [UIColor darkGrayColor]; _status.textAlignment = NSTextAlignmentCenter;
    [_scroll addSubview:_status];

    CGFloat y = 26;
    y = [self row:@[@[@"Power", @"26"], @[@"Home", @"3"], @[@"Back", @"4"], @[@"Menu", @"82"]] y:y];
    /* D-pad */
    CGFloat cx = 160, bw = 84, bh = 50;
    [self addKey:@"\u25B2" code:@"19" frame:CGRectMake(cx - bw / 2, y, bw, bh)];
    [self addKey:@"\u25C0" code:@"21" frame:CGRectMake(cx - bw / 2 - bw - 6, y + bh + 4, bw, bh)];
    [self addKey:@"OK" code:@"23" frame:CGRectMake(cx - bw / 2, y + bh + 4, bw, bh)];
    [self addKey:@"\u25B6" code:@"22" frame:CGRectMake(cx + bw / 2 + 6, y + bh + 4, bw, bh)];
    [self addKey:@"\u25BC" code:@"20" frame:CGRectMake(cx - bw / 2, y + 2 * (bh + 4), bw, bh)];
    y += 3 * (bh + 4) + 6;
    y = [self row:@[@[@"\u23EE", @"88"], @[@"\u23EA", @"89"], @[@"\u23EF", @"85"], @[@"\u23E9", @"90"], @[@"\u23ED", @"87"]] y:y];
    y = [self row:@[@[@"Vol-", @"25"], @[@"Mute", @"164"], @[@"Vol+", @"24"], @[@"CH-", @"167"], @[@"CH+", @"166"]] y:y];
    y = [self row:@[@[@"TV", @"170"], @[@"Guide", @"172"], @[@"Info", @"165"], @[@"Settings", @"176"]] y:y];
    y = [self row:@[@[@"Search", @"84"], @[@"Recent", @"187"], @[@"Input", @"178"], @[@"Sleep", @"223"], @[@"Wake", @"224"]] y:y];
    y = [self row:@[@[@"1", @"8"], @[@"2", @"9"], @[@"3", @"10"], @[@"4", @"11"], @[@"5", @"12"]] y:y];
    y = [self row:@[@[@"6", @"13"], @[@"7", @"14"], @[@"8", @"15"], @[@"9", @"16"], @[@"0", @"7"]] y:y];
    y = [self row:@[@[@"Del", @"67"], @[@"Enter", @"66"], @[@"Tab", @"61"], @[@"Esc", @"111"]] y:y];

    _text = [[UITextField alloc] initWithFrame:CGRectMake(8, y + 4, 230, 32)];
    _text.borderStyle = UITextBorderStyleRoundedRect; _text.placeholder = @"Type text to send";
    _text.delegate = self; _text.returnKeyType = UIReturnKeySend;
    _text.autocapitalizationType = UITextAutocapitalizationTypeNone; _text.autocorrectionType = UITextAutocorrectionTypeNo;
    [_scroll addSubview:_text];
    UIButton *send = ADBMakeButton(@"Send", CGRectMake(244, y + 2, 68, 36), self, @selector(sendText));
    [_scroll addSubview:send];
    y += 46;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(8, y, 304, 16)];
    l.backgroundColor = [UIColor clearColor]; l.font = [UIFont systemFontOfSize:12]; l.textColor = [UIColor grayColor];
    l.text = @"Touchpad: tap = tap, drag = swipe (mapped to device screen)"; [_scroll addSubview:l];
    y += 18;
    _pad = [[ADBTouchPad alloc] initWithFrame:CGRectMake(8, y, 304, 190)];
    _pad.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1]; _pad.layer.cornerRadius = 8;
    __weak RemoteViewController *me = self;
    _pad.onGesture = ^(CGPoint s, CGPoint e, NSTimeInterval d) { [me padGestureFrom:s to:e duration:d]; };
    [_scroll addSubview:_pad];
    y += 200;
    _scroll.contentSize = CGSizeMake(320, y + 10);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusChanged) name:ADBControlStatusNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(targetChanged) name:ADBTargetChangedNotification object:nil];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];
}
- (void)kbShow:(NSNotification *)n {
    CGRect end = [[n.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    _scroll.contentInset = UIEdgeInsetsMake(0, 0, end.size.height, 0);
    [_scroll scrollRectToVisible:_text.frame animated:YES];
}
- (void)kbHide:(NSNotification *)n { _scroll.contentInset = UIEdgeInsetsZero; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self statusChanged];
    if (_devSize.width == 0) [self queryScreenSize];
}
- (void)statusChanged {
    ADBManager *m = [ADBManager shared];
    _status.text = [m hasTarget] ? [NSString stringWithFormat:@"%@  \u2022  %@", [m targetString], m.controlStatus ?: @"ready"] : @"No device selected";
}
- (void)targetChanged { _devSize = CGSizeZero; [self statusChanged]; }

- (void)queryScreenSize {
    if (![[ADBManager shared] hasTarget]) return;
    [[ADBManager shared] shell:@"wm size" completion:^(NSString *out, int code, NSString *err) {
        NSArray *lines = [out componentsSeparatedByString:@"\n"];
        for (NSString *ln in lines) {            /* last line wins (Override size) */
            NSRange r = [ln rangeOfString:@": "];
            if (r.location == NSNotFound) continue;
            NSArray *p = [[[ln substringFromIndex:r.location + 2] adb_trimmed] componentsSeparatedByString:@"x"];
            if (p.count == 2) _devSize = CGSizeMake([p[0] floatValue], [p[1] floatValue]);
        }
    }];
}

- (void)keyTapped:(UIButton *)b {
    [[ADBManager shared] sendControl:[NSString stringWithFormat:@"input keyevent %@", _codes[b.tag]]];
}

- (void)sendText {
    NSString *t = _text.text;
    if (!t.length) return;
    NSMutableString *e = [NSMutableString string];
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c == ' ') [e appendString:@"%s"]; else [e appendFormat:@"%C", c];
    }
    [[ADBManager shared] sendControl:[NSString stringWithFormat:@"input text %@", [e adb_shellQuoted]]];
    _text.text = @"";
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self sendText]; return NO; }

- (void)padGestureFrom:(CGPoint)s to:(CGPoint)e duration:(NSTimeInterval)d {
    if (_devSize.width <= 0) { [self queryScreenSize]; [ADBHUD toast:@"Reading screen size..."]; return; }
    CGSize ps = _pad.bounds.size;
    /* pad is landscape-shaped; map to the device's current orientation via aspect only */
    int x1 = (int)(s.x / ps.width * _devSize.width), y1 = (int)(s.y / ps.height * _devSize.height);
    int x2 = (int)(e.x / ps.width * _devSize.width), y2 = (int)(e.y / ps.height * _devSize.height);
    CGFloat dist = hypot(e.x - s.x, e.y - s.y);
    ADBManager *m = [ADBManager shared];
    if (dist < 10) [m sendControl:[NSString stringWithFormat:@"input tap %d %d", x1, y1]];
    else [m sendControl:[NSString stringWithFormat:@"input swipe %d %d %d %d %d", x1, y1, x2, y2, MAX(80, MIN(1200, (int)(d * 1000)))]];
}
@end

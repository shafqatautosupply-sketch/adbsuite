#import "DevicesViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"
#import "OutputViewController.h"

@implementation DevicesViewController {
    NSArray *_found;      /* discovered connect services */
    NSArray *_pairing;    /* discovered pairing services */
    BOOL _scanning;
    NSString *_status;    /* banner/model of the current device */
}

- (id)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = @"Devices";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Devices" image:[UIImage imageNamed:@"tab_devices"] tag:0];
        _found = @[]; _pairing = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                          target:self action:@selector(scan)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(targetChanged) name:ADBTargetChangedNotification object:nil];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_found.count && !_pairing.count && !_scanning) [self scan];
}
- (void)targetChanged { [self.tableView reloadData]; }

- (void)scan {
    if (_scanning) return;
    _scanning = YES; [self.tableView reloadData];
    [[ADBManager shared] discoverWithCompletion:^(NSArray *c, NSArray *p) {
        _found = c; _pairing = p; _scanning = NO;
        [self.tableView reloadData];
    }];
}

#pragma mark - actions

- (void)pairWithHost:(NSString *)host port:(int)port {
    NSString *addr = host.length ? [NSString stringWithFormat:@"%@:%d", host, port] : @"";
    [ADBAlert promptTwo:@"Pair device"
                message:@"On the device: Developer options > Wireless debugging > Pair device with pairing code. Enter the IP:PORT and 6-digit code shown there."
                 place1:@"192.168.1.50:37123" text1:addr place2:@"123456" text2:@""
                     ok:^(NSString *a, NSString *code) {
        NSString *h = nil; int p = 0;
        NSRange r = [a rangeOfString:@":" options:NSBackwardsSearch];
        if (r.location != NSNotFound) { h = [[a substringToIndex:r.location] adb_trimmed]; p = [[a substringFromIndex:r.location + 1] intValue]; }
        code = [code adb_trimmed];
        if (!h.length || p <= 0 || code.length < 4) { [ADBAlert alert:@"Pairing" message:@"Need IP:PORT of the pairing dialog and the pairing code."]; return; }
        [ADBHUD show:@"Pairing..."];
        [[ADBManager shared] pairHost:h port:p code:code completion:^(BOOL ok, NSString *msg) {
            [ADBHUD hide];
            [ADBAlert alert:ok ? @"Paired" : @"Pairing failed"
                    message:ok ? [msg stringByAppendingString:@"\n\nNow tap the device's 'connect' entry or add it with its connect port."] : msg];
            if (ok) [self scan];
        }];
    }];
}

- (void)addManually {
    [ADBAlert prompt:@"Connect to device" message:@"IP:PORT shown under Wireless debugging (or IP:5555 for adb tcpip). Leave the port off to auto-discover it."
         placeholder:@"192.168.1.50:41234" text:@"" keyboard:UIKeyboardTypeNumbersAndPunctuation ok:^(NSString *t) {
        NSString *h = [t adb_trimmed]; int p = 0;
        NSRange r = [h rangeOfString:@":" options:NSBackwardsSearch];
        if (r.location != NSNotFound) { p = [[h substringFromIndex:r.location + 1] intValue]; h = [h substringToIndex:r.location]; }
        if (!h.length) return;
        [self connectHost:h port:p name:nil];
    }];
}

- (void)connectHost:(NSString *)host port:(int)port name:(NSString *)name {
    ADBManager *m = [ADBManager shared];
    [ADBHUD show:@"Connecting..."];
    void (^tryPort)(int) = ^(int p) {
        [m probeHost:host port:p completion:^(BOOL ok, NSString *banner, NSString *err) {
            [ADBHUD hide];
            if (ok) {
                NSString *model = [self valueForKey:@"ro.product.model" inBanner:banner];
                NSString *nm = name.length ? name : (model.length ? model : host);
                [m setTargetHost:host port:p name:nm];
                [m saveCurrentTarget];
                _status = banner;
                [self.tableView reloadData];
                [ADBHUD toast:[NSString stringWithFormat:@"Connected to %@", nm]];
            } else {
                [ADBAlert alert:@"Connection failed" message:[NSString stringWithFormat:@"%@\n\nIf wireless debugging was toggled, the port changed: use Scan, or pair again if the key was forgotten.", err]];
            }
        }];
    };
    if (port > 0) {
        tryPort(port);
    } else {
        [m findPortForHost:host completion:^(int p) { tryPort(p > 0 ? p : 5555); }];
    }
}

- (NSString *)valueForKey:(NSString *)key inBanner:(NSString *)banner {
    for (NSString *part in [banner componentsSeparatedByString:@";"]) {
        NSString *x = part;
        NSRange r = [x rangeOfString:@"::"];
        if (r.location != NSNotFound) x = [x substringFromIndex:r.location + 2];
        if ([x hasPrefix:[key stringByAppendingString:@"="]]) return [x substringFromIndex:key.length + 1];
    }
    return nil;
}

- (void)showKey {
    [ADBHUD show:@"Preparing key..."];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *k = [[ADBManager shared] publicKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [ADBHUD hide];
            OutputViewController *o = [[OutputViewController alloc] initWithTitle:@"Public key"
                text:[NSString stringWithFormat:@"%@\n\nThis key is stored on the Android device when you pair. Private key: Library/ADBSuite/.adbi/adbkey", k]];
            [self.navigationController pushViewController:o animated:YES];
        });
    });
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case 0: return 4;
        case 1: return MAX((NSInteger)[ADBManager shared].saved.count, 1);
        case 2: return MAX((NSInteger)(_found.count + _pairing.count), 1);
        default: return 1;
    }
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return @"Current device";
        case 1: return @"Saved devices";
        case 2: return _scanning ? @"Scanning network..." : @"Found on network (mDNS)";
        default: return nil;
    }
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 3) return @"Android 11+: enable Developer options, then Wireless debugging. Pair once per key, then connect. The connect port changes every time wireless debugging is toggled.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.accessoryType = UITableViewCellAccessoryNone; c.selectionStyle = UITableViewCellSelectionStyleBlue;
    c.textLabel.textColor = [UIColor blackColor]; c.detailTextLabel.text = nil;
    ADBManager *m = [ADBManager shared];
    if (ip.section == 0) {
        switch (ip.row) {
            case 0:
                c.textLabel.text = [m hasTarget] ? (m.deviceName.length ? m.deviceName : m.host) : @"No device selected";
                c.detailTextLabel.text = [m hasTarget] ? [m targetString] : @"Pick or add one below";
                break;
            case 1: c.textLabel.text = @"Pair new device..."; c.detailTextLabel.text = @"Wireless debugging pairing code"; break;
            case 2: c.textLabel.text = @"Connect manually..."; c.detailTextLabel.text = @"IP[:PORT]"; break;
            default: c.textLabel.text = @"My public key"; c.detailTextLabel.text = @"Installed on devices during pairing"; break;
        }
        if (ip.row == 0) c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 1) {
        if (!m.saved.count) { c.textLabel.text = @"(none yet)"; c.textLabel.textColor = [UIColor grayColor]; c.selectionStyle = UITableViewCellSelectionStyleNone; }
        else {
            NSDictionary *d = m.saved[ip.row];
            c.textLabel.text = d[@"name"];
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@:%@", d[@"host"], d[@"port"]];
            if ([d[@"host"] isEqualToString:m.host]) c.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else if (ip.section == 2) {
        if (!_found.count && !_pairing.count) { c.textLabel.text = _scanning ? @"..." : @"Nothing found"; c.textLabel.textColor = [UIColor grayColor]; c.selectionStyle = UITableViewCellSelectionStyleNone; }
        else {
            BOOL isPair = ip.row < (NSInteger)_pairing.count;
            NSDictionary *d = isPair ? _pairing[ip.row] : _found[ip.row - _pairing.count];
            c.textLabel.text = d[@"name"];
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@:%@", isPair ? @"PAIR" : @"CONNECT", d[@"host"], d[@"port"]];
        }
    } else {
        c.textLabel.text = @"Device info"; c.detailTextLabel.text = _status.length ? _status : @"Connect to see the banner";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    ADBManager *m = [ADBManager shared];
    if (ip.section == 0) {
        if (ip.row == 1) [self pairWithHost:nil port:0];
        else if (ip.row == 2) [self addManually];
        else if (ip.row == 3) [self showKey];
    } else if (ip.section == 1 && m.saved.count) {
        NSDictionary *d = m.saved[ip.row];
        [self connectHost:d[@"host"] port:[d[@"port"] intValue] name:d[@"name"]];
    } else if (ip.section == 2 && (_found.count || _pairing.count)) {
        BOOL isPair = ip.row < (NSInteger)_pairing.count;
        NSDictionary *d = isPair ? _pairing[ip.row] : _found[ip.row - _pairing.count];
        if (isPair) [self pairWithHost:d[@"host"] port:[d[@"port"] intValue]];
        else [self connectHost:d[@"host"] port:[d[@"port"] intValue] name:nil];
    } else if (ip.section == 3 && _status.length) {
        NSString *t = [_status stringByReplacingOccurrencesOfString:@";" withString:@"\n"];
        [self.navigationController pushViewController:[[OutputViewController alloc] initWithTitle:@"Banner" text:t] animated:YES];
    }
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 1 && [ADBManager shared].saved.count > 0;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    [[ADBManager shared] removeSavedAtIndex:ip.row];
    [tv reloadData];
}
@end

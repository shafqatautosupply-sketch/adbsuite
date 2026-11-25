#import "AppsViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"
#import "OutputViewController.h"
#import "LocalFilesViewController.h"

@implementation AppsViewController {
    NSArray *_all, *_shown; UISegmentedControl *_seg; UISearchBar *_search; BOOL _loading;
}

- (id)init {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = @"Apps"; _all = @[]; _shown = @[];
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Apps" image:[UIImage imageNamed:@"tab_apps"] tag:4];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _seg = [[UISegmentedControl alloc] initWithItems:@[@"User", @"System", @"All"]];
    _seg.segmentedControlStyle = UISegmentedControlStyleBar; _seg.selectedSegmentIndex = 0;
    [_seg addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _seg;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Install" style:UIBarButtonItemStyleBordered target:self action:@selector(install)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    _search.delegate = self; _search.placeholder = @"Filter packages";
    _search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.tableView.tableHeaderView = _search;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:ADBTargetChangedNotification object:nil];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; if (!_all.count && !_loading) [self reload]; }

- (void)reload {
    if (![[ADBManager shared] hasTarget]) { _all = @[]; [self applyFilter]; return; }
    NSString *flag = _seg.selectedSegmentIndex == 0 ? @"-3" : (_seg.selectedSegmentIndex == 1 ? @"-s" : @"");
    _loading = YES;
    [[ADBManager shared] shell:[NSString stringWithFormat:@"pm list packages -f %@ 2>&1", flag] completion:^(NSString *out, int code, NSString *err) {
        _loading = NO;
        if (err) { [ADBAlert alert:@"Error" message:err]; return; }
        NSMutableArray *a = [NSMutableArray array];
        for (NSString *ln in [out componentsSeparatedByString:@"\n"]) {
            NSString *l = [ln adb_trimmed];
            if (![l hasPrefix:@"package:"]) continue;
            l = [l substringFromIndex:8];
            NSRange r = [l rangeOfString:@"=" options:NSBackwardsSearch];
            if (r.location == NSNotFound) continue;
            [a addObject:@{@"pkg": [l substringFromIndex:r.location + 1], @"apk": [l substringToIndex:r.location]}];
        }
        _all = [a sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) { return [x[@"pkg"] compare:y[@"pkg"]]; }];
        [self applyFilter];
    }];
}

- (void)applyFilter {
    NSString *q = [[_search.text ?: @"" lowercaseString] adb_trimmed];
    if (!q.length) _shown = _all;
    else {
        NSMutableArray *a = [NSMutableArray array];
        for (NSDictionary *d in _all) if ([[d[@"pkg"] lowercaseString] rangeOfString:q].location != NSNotFound) [a addObject:d];
        _shown = a;
    }
    self.title = [NSString stringWithFormat:@"Apps (%lu)", (unsigned long)_shown.count];
    [self.tableView reloadData];
}
- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)t { [self applyFilter]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _shown.count ?: 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"a"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"a"];
    if (!_shown.count) {
        c.textLabel.text = _loading ? @"Loading..." : ([[ADBManager shared] hasTarget] ? @"No packages" : @"No device selected");
        c.detailTextLabel.text = nil; return c;
    }
    NSDictionary *d = _shown[ip.row];
    c.textLabel.text = d[@"pkg"]; c.textLabel.font = [UIFont boldSystemFontOfSize:14];
    c.detailTextLabel.text = d[@"apk"];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_shown.count) return;
    [_search resignFirstResponder];
    NSDictionary *d = _shown[ip.row]; NSString *pkg = d[@"pkg"];
    NSArray *items = @[@"Launch", @"Force stop", @"App settings", @"Info (dumpsys)", @"Extract APK", @"Clear data", @"Disable", @"Enable", @"Uninstall"];
    [ADBAlert sheet:pkg buttons:items destructive:8 from:self handler:^(NSInteger i) {
        NSString *p = [pkg adb_shellQuoted];
        switch (i) {
            case 0: { [self run:[NSString stringWithFormat:@"out=$(monkey -p %@ -c android.intent.category.LAUNCHER 1 2>&1); case \"$out\" in *\"No activities\"*) monkey -p %@ -c android.intent.category.LEANBACK_LAUNCHER 1 2>&1;; *) echo \"$out\";; esac", p, p] ok:@"Launched" showOutput:NO]; break; }
            case 1: { [self run:[NSString stringWithFormat:@"am force-stop %@", p] ok:@"Stopped" showOutput:NO]; break; }
            case 2: { [self run:[NSString stringWithFormat:@"am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:%@", pkg] ok:@"Opened" showOutput:NO]; break; }
            case 3: { [self info:pkg]; break; }
            case 4: { [self extract:pkg]; break; }
            case 5: { [ADBAlert confirm:@"Clear data" message:[NSString stringWithFormat:@"Erase all data of %@?", pkg] button:@"Clear" yes:^{ [self run:[NSString stringWithFormat:@"pm clear %@", p] ok:@"Cleared" showOutput:NO]; }]; break; }
            case 6: { [self run:[NSString stringWithFormat:@"pm disable-user --user 0 %@ 2>&1 || pm disable %@ 2>&1", p, p] ok:@"Disabled" showOutput:NO]; break; }
            case 7: { [self run:[NSString stringWithFormat:@"pm enable %@", p] ok:@"Enabled" showOutput:NO]; break; }
            case 8: { [ADBAlert confirm:@"Uninstall" message:[NSString stringWithFormat:@"Uninstall %@?", pkg] button:@"Uninstall" yes:^{
                        [self run:[NSString stringWithFormat:@"pm uninstall %@ 2>&1 || pm uninstall --user 0 %@ 2>&1", p, p] ok:@"Uninstalled" showOutput:NO]; }]; break; }
        }
    }];
}

- (void)run:(NSString *)cmd ok:(NSString *)okText showOutput:(BOOL)show {
    [ADBHUD show:@"Working..."];
    [[ADBManager shared] shell:cmd completion:^(NSString *out, int code, NSString *err) {
        [ADBHUD hide];
        if (err) { [ADBAlert alert:@"Error" message:err]; return; }
        NSString *o = [out adb_trimmed];
        if (show) { [self.navigationController pushViewController:[[OutputViewController alloc] initWithTitle:@"Output" text:o] animated:YES]; return; }
        if (code != 0 || [o rangeOfString:@"Error"].location != NSNotFound || [o rangeOfString:@"Failure"].location != NSNotFound || [o rangeOfString:@"Exception"].location != NSNotFound)
            [ADBAlert alert:@"Result" message:o.length ? o : @"Command failed"];
        else { [ADBHUD toast:okText]; [self reload]; }
    }];
}

- (void)info:(NSString *)pkg {
    [ADBHUD show:@"Reading..."];
    [[ADBManager shared] shell:[NSString stringWithFormat:@"dumpsys package %@ | head -300", [pkg adb_shellQuoted]] completion:^(NSString *out, int code, NSString *err) {
        [ADBHUD hide];
        [self.navigationController pushViewController:[[OutputViewController alloc] initWithTitle:pkg text:err ?: out] animated:YES];
    }];
}

- (void)extract:(NSString *)pkg {
    [ADBHUD show:@"Locating APK..."];
    [[ADBManager shared] shell:[NSString stringWithFormat:@"pm path %@", [pkg adb_shellQuoted]] completion:^(NSString *out, int code, NSString *err) {
        NSMutableArray *paths = [NSMutableArray array];
        for (NSString *ln in [out componentsSeparatedByString:@"\n"]) {
            NSString *l = [ln adb_trimmed];
            if ([l hasPrefix:@"package:"]) [paths addObject:[l substringFromIndex:8]];
        }
        if (!paths.count) { [ADBHUD hide]; [ADBAlert alert:@"Extract APK" message:err ?: @"No APK path found"]; return; }
        NSString *dir = [[ADBDocumentsDir() stringByAppendingPathComponent:@"APKs"] stringByAppendingPathComponent:pkg];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [self pullPaths:paths index:0 dir:dir];
    }];
}
- (void)pullPaths:(NSArray *)paths index:(NSUInteger)i dir:(NSString *)dir {
    if (i >= paths.count) { [ADBHUD hide]; [ADBAlert alert:@"APK saved" message:dir]; return; }
    NSString *rp = paths[i];
    [ADBHUD showProgress:[NSString stringWithFormat:@"Pulling %@ (%lu/%lu)", [rp lastPathComponent], (unsigned long)i + 1, (unsigned long)paths.count]];
    [[ADBManager shared] pull:rp to:[dir stringByAppendingPathComponent:[rp lastPathComponent]] total:0
        progress:^(double f, unsigned long long done) { [ADBHUD setProgress:0 text:[NSString stringWithFormat:@"%@ downloaded", ADBHumanSize(done)]]; }
        completion:^(BOOL ok, NSString *err) {
            if (!ok) { [ADBHUD hide]; [ADBAlert alert:@"Pull failed" message:err]; return; }
            [self pullPaths:paths index:i + 1 dir:dir];
        }];
}

- (void)install {
    [ADBAlert sheet:@"Install APK" buttons:@[@"Install", @"Replace existing (-r)", @"Replace + downgrade + grant perms (-r -d -g)"] destructive:-1 from:self handler:^(NSInteger i) {
        NSString *flags = i == 0 ? @"" : (i == 1 ? @"-r" : @"-r -d -g");
        UINavigationController *nav = [LocalFilesViewController pickerWithStart:ADBDocumentsDir() filter:@"apk" onPick:^(NSString *local) {
            NSString *remote = @"/data/local/tmp/adbsuite_install.apk";
            [ADBHUD showProgress:@"Uploading APK..."];
            [[ADBManager shared] push:local to:remote progress:^(double f) { [ADBHUD setProgress:f text:nil]; } completion:^(BOOL ok, NSString *err) {
                if (!ok) { [ADBHUD hide]; [ADBAlert alert:@"Upload failed" message:err]; return; }
                [ADBHUD show:@"Installing..."];
                [[ADBManager shared] shell:[NSString stringWithFormat:@"pm install %@ %@ 2>&1; rm -f %@", flags, remote, remote] completion:^(NSString *out, int code, NSString *e2) {
                    [ADBHUD hide];
                    [ADBAlert alert:@"Install result" message:e2 ?: [out adb_trimmed]];
                    [self reload];
                }];
            }];
        }];
        [self presentViewController:nav animated:YES completion:nil];
    }];
}
@end

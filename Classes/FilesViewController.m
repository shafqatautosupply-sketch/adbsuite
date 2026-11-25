#import "FilesViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"
#import "OutputViewController.h"
#import "LocalFilesViewController.h"

/* ---- minimal zoomable image viewer ---- */
@interface ImageViewerController : UIViewController <UIScrollViewDelegate>
- (id)initWithImage:(UIImage *)img title:(NSString *)t;
@end
@implementation ImageViewerController {
    UIImage *_img; UIImageView *_iv; UIScrollView *_sv;
}
- (id)initWithImage:(UIImage *)img title:(NSString *)t { if ((self = [super init])) { _img = img; self.title = t; } return self; }
- (void)loadView {
    _sv = [[UIScrollView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _sv.backgroundColor = [UIColor blackColor]; _sv.delegate = self;
    _sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _iv = [[UIImageView alloc] initWithImage:_img]; [_sv addSubview:_iv];
    _sv.contentSize = _img.size; _sv.maximumZoomScale = 4;
    self.view = _sv;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_img.size.width <= 0) return;
    CGFloat s = MIN(_sv.bounds.size.width / _img.size.width, _sv.bounds.size.height / _img.size.height);
    _sv.minimumZoomScale = s; if (_sv.zoomScale < s) _sv.zoomScale = s;
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)s { return _iv; }
@end

/* ---- file manager ---- */
@implementation FilesViewController {
    NSString *_path; NSArray *_items; NSString *_error; BOOL _loading;
}

- (id)initWithPath:(NSString *)path {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        if (![path hasSuffix:@"/"]) path = [path stringByAppendingString:@"/"];
        _path = [path copy]; _items = @[];
        self.title = [path isEqualToString:@"/"] ? @"/" : [[path substringToIndex:path.length - 1] lastPathComponent];
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Files" image:[UIImage imageNamed:@"tab_files"] tag:3];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Upload" style:UIBarButtonItemStyleBordered target:self action:@selector(upload)], flex,
        [[UIBarButtonItem alloc] initWithTitle:@"New Folder" style:UIBarButtonItemStyleBordered target:self action:@selector(newFolder)], flex,
        [[UIBarButtonItem alloc] initWithTitle:@"Go to..." style:UIBarButtonItemStyleBordered target:self action:@selector(goTo)]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:ADBTargetChangedNotification object:nil];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    if (!_items.count && !_loading) [self reload];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.navigationController.viewControllers.count <= 1) [self.navigationController setToolbarHidden:YES animated:animated];
}

#pragma mark - listing

- (void)reload {
    if (![[ADBManager shared] hasTarget]) { _error = @"No device selected. Open the Devices tab."; _items = @[]; [self.tableView reloadData]; return; }
    _loading = YES; _error = nil;
    [[ADBManager shared] shell:[NSString stringWithFormat:@"ls -lAp %@ 2>&1", [_path adb_shellQuoted]] completion:^(NSString *out, int code, NSString *err) {
        _loading = NO;
        if (err) { _error = err; _items = @[]; }
        else { _items = [self parse:out]; if (!_items.count && out.length > 1) _error = [out adb_trimmed]; }
        [self.tableView reloadData];
    }];
}

- (NSArray *)parse:(NSString *)out {
    NSMutableArray *res = [NSMutableArray array];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{4}-\\d\\d-\\d\\d)\\s+(\\d\\d:\\d\\d)\\S*\\s+(.+)$" options:0 error:NULL];
    BOOL sawError = NO;
    for (NSString *raw in [out componentsSeparatedByString:@"\n"]) {
        NSString *ln = [raw adb_trimmed];
        if (!ln.length || [ln hasPrefix:@"total "]) continue;
        NSTextCheckingResult *m = [re firstMatchInString:ln options:0 range:NSMakeRange(0, ln.length)];
        if (!m) { sawError = YES; continue; }
        NSString *perms = ADBFirst([ln componentsSeparatedByString:@" "]);
        NSString *name = [ln substringWithRange:[m rangeAtIndex:3]];
        NSString *date = [NSString stringWithFormat:@"%@ %@", [ln substringWithRange:[m rangeAtIndex:1]], [ln substringWithRange:[m rangeAtIndex:2]]];
        /* size = numeric token just before the date */
        NSString *before = [[ln substringToIndex:[m rangeAtIndex:1].location] adb_trimmed];
        NSString *sizeTok = [[before componentsSeparatedByString:@" "] lastObject];
        unsigned long long size = [sizeTok rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound ? strtoull([sizeTok UTF8String], NULL, 10) : 0;
        BOOL link = [perms hasPrefix:@"l"];
        if (link) { NSRange a = [name rangeOfString:@" -> "]; if (a.location != NSNotFound) name = [name substringToIndex:a.location]; }
        BOOL dir = [perms hasPrefix:@"d"] || link || [name hasSuffix:@"/"];
        if ([name hasSuffix:@"/"]) name = [name substringToIndex:name.length - 1];
        [res addObject:@{@"name": name, @"dir": @(dir), @"size": @(size), @"perms": perms ?: @"", @"date": date}];
    }
    (void)sawError;
    return [res sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL da = [a[@"dir"] boolValue], db = [b[@"dir"] boolValue];
        if (da != db) return da ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
}

#pragma mark - table

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _path; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _items.count ?: 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"f"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
    if (!_items.count) {
        c.textLabel.text = _loading ? @"Loading..." : (_error ?: @"(empty)");
        c.textLabel.numberOfLines = 0; c.detailTextLabel.text = nil; c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }
    c.textLabel.numberOfLines = 1;
    NSDictionary *d = _items[ip.row]; BOOL dir = [d[@"dir"] boolValue];
    c.textLabel.text = d[@"name"];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@%@  %@", dir ? @"" : [ADBHumanSize([d[@"size"] unsignedLongLongValue]) stringByAppendingString:@"  "], d[@"date"], d[@"perms"]];
    c.accessoryType = dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return (!_items.count && _error.length > 40) ? 90 : 52;
}

- (NSString *)remotePathFor:(NSDictionary *)d { return [_path stringByAppendingString:d[@"name"]]; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_items.count) return;
    NSDictionary *d = _items[ip.row];
    if ([d[@"dir"] boolValue]) {
        [self.navigationController pushViewController:[[FilesViewController alloc] initWithPath:[[self remotePathFor:d] stringByAppendingString:@"/"]] animated:YES];
        return;
    }
    [ADBAlert sheet:d[@"name"] buttons:@[@"Open / View", @"Download", @"Rename", @"Properties", @"Delete"] destructive:4 from:self handler:^(NSInteger i) {
        switch (i) {
            case 0: [self downloadAndOpen:d]; break;
            case 1: [self download:d open:NO]; break;
            case 2: [self rename:d]; break;
            case 3: [self properties:d]; break;
            case 4: [self deleteItem:d]; break;
        }
    }];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return _items.count > 0; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st == UITableViewCellEditingStyleDelete) [self deleteItem:_items[ip.row]];
}

#pragma mark - operations

- (void)runShell:(NSString *)cmd then:(void (^)(NSString *out))then {
    [ADBHUD show:@"Working..."];
    [[ADBManager shared] shell:cmd completion:^(NSString *out, int code, NSString *err) {
        [ADBHUD hide];
        if (err) { [ADBAlert alert:@"Error" message:err]; return; }
        if (code != 0 && out.length) { [ADBAlert alert:@"Failed" message:out]; return; }
        if (then) then(out);
        [self reload];
    }];
}

- (void)deleteItem:(NSDictionary *)d {
    BOOL dir = [d[@"dir"] boolValue];
    [ADBAlert confirm:@"Delete" message:[NSString stringWithFormat:@"Delete %@ \"%@\" from the device?", dir ? @"folder" : @"file", d[@"name"]] button:@"Delete" yes:^{
        [self runShell:[NSString stringWithFormat:@"rm -rf %@ 2>&1", [[self remotePathFor:d] adb_shellQuoted]] then:nil];
    }];
}
- (void)rename:(NSDictionary *)d {
    [ADBAlert prompt:@"Rename" message:nil placeholder:@"new name" text:d[@"name"] keyboard:UIKeyboardTypeDefault ok:^(NSString *t) {
        t = [t adb_trimmed]; if (!t.length || [t isEqualToString:d[@"name"]]) return;
        [self runShell:[NSString stringWithFormat:@"mv %@ %@ 2>&1", [[self remotePathFor:d] adb_shellQuoted], [[_path stringByAppendingString:t] adb_shellQuoted]] then:nil];
    }];
}
- (void)newFolder {
    [ADBAlert prompt:@"New folder" message:nil placeholder:@"name" text:@"" keyboard:UIKeyboardTypeDefault ok:^(NSString *t) {
        t = [t adb_trimmed]; if (!t.length) return;
        [self runShell:[NSString stringWithFormat:@"mkdir -p %@ 2>&1", [[_path stringByAppendingString:t] adb_shellQuoted]] then:nil];
    }];
}
- (void)goTo {
    NSArray *locs = @[@"/sdcard/", @"/sdcard/Download/", @"/sdcard/DCIM/", @"/storage/", @"/data/local/tmp/", @"/system/", @"/", @"Type a path..."];
    [ADBAlert sheet:@"Go to" buttons:locs destructive:-1 from:self handler:^(NSInteger i) {
        if (i == (NSInteger)locs.count - 1) {
            [ADBAlert prompt:@"Go to path" message:nil placeholder:@"/sdcard/Movies" text:_path keyboard:UIKeyboardTypeURL ok:^(NSString *t) {
                [self.navigationController pushViewController:[[FilesViewController alloc] initWithPath:[t adb_trimmed]] animated:YES];
            }];
        } else [self.navigationController pushViewController:[[FilesViewController alloc] initWithPath:locs[i]] animated:YES];
    }];
}
- (void)properties:(NSDictionary *)d {
    NSString *p = [[self remotePathFor:d] adb_shellQuoted];
    [self runShell:[NSString stringWithFormat:@"ls -ld %@; stat %@ 2>&1; echo; file %@ 2>&1; echo; md5sum %@ 2>&1", p, p, p, p] then:^(NSString *out) {
        [self.navigationController pushViewController:[[OutputViewController alloc] initWithTitle:d[@"name"] text:out] animated:YES];
    }];
}

- (void)upload {
    UINavigationController *nav = [LocalFilesViewController pickerWithStart:ADBDocumentsDir() filter:nil onPick:^(NSString *local) {
        NSString *remote = [_path stringByAppendingString:[local lastPathComponent]];
        [ADBHUD showProgress:[NSString stringWithFormat:@"Uploading %@", [local lastPathComponent]]];
        [[ADBManager shared] push:local to:remote progress:^(double f) { [ADBHUD setProgress:f text:nil]; }
                       completion:^(BOOL ok, NSString *err) {
            [ADBHUD hide];
            if (!ok) [ADBAlert alert:@"Upload failed" message:err]; else [self reload];
        }];
    }];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)download:(NSDictionary *)d open:(BOOL)open {
    NSString *dir = [ADBDocumentsDir() stringByAppendingPathComponent:@"Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *local = [dir stringByAppendingPathComponent:d[@"name"]];
    unsigned long long total = [d[@"size"] unsignedLongLongValue];
    [ADBHUD showProgress:[NSString stringWithFormat:@"Downloading %@", d[@"name"]]];
    [[ADBManager shared] pull:[self remotePathFor:d] to:local total:total
        progress:^(double f, unsigned long long done) {
            [ADBHUD setProgress:f text:total ? nil : [NSString stringWithFormat:@"%@ downloaded", ADBHumanSize(done)]];
        } completion:^(BOOL ok, NSString *err) {
            [ADBHUD hide];
            if (!ok) { [ADBAlert alert:@"Download failed" message:err]; return; }
            if (open) [self openLocal:local name:d[@"name"]];
            else [ADBAlert alert:@"Saved" message:local];
        }];
}
- (void)downloadAndOpen:(NSDictionary *)d { [self download:d open:YES]; }

- (void)openLocal:(NSString *)path name:(NSString *)name {
    NSString *ext = [[path pathExtension] lowercaseString];
    if ([@[@"png", @"jpg", @"jpeg", @"gif", @"bmp", @"tif", @"tiff"] containsObject:ext]) {
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img) { [self.navigationController pushViewController:[[ImageViewerController alloc] initWithImage:img title:name] animated:YES]; return; }
    }
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if ([at[NSFileSize] unsignedLongLongValue] < 600 * 1024) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSString *t = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (t) { [self.navigationController pushViewController:[[OutputViewController alloc] initWithTitle:name text:t] animated:YES]; return; }
    }
    [ADBAlert alert:@"Saved" message:[NSString stringWithFormat:@"Binary file saved to\n%@", path]];
}
@end

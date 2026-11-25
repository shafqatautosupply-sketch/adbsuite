#import "LocalFilesViewController.h"
#import "ADBKit.h"

@implementation LocalFilesViewController {
    NSString *_path; NSArray *_items;
}

+ (UINavigationController *)pickerWithStart:(NSString *)start filter:(NSString *)ext onPick:(void (^)(NSString *))pick {
    LocalFilesViewController *vc = [[LocalFilesViewController alloc] initWithPath:start];
    vc.onPick = pick; vc.extensionFilter = ext;
    return [[UINavigationController alloc] initWithRootViewController:vc];
}

- (id)initWithPath:(NSString *)path {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        self.title = [path lastPathComponent].length ? [path lastPathComponent] : @"/";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStyleBordered target:self action:@selector(cancel)];
    self.toolbarItems = @[[[UIBarButtonItem alloc] initWithTitle:@"Locations" style:UIBarButtonItemStyleBordered target:self action:@selector(locations)]];
    [self reload];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.navigationController setToolbarHidden:NO animated:NO]; }
- (void)cancel { [self.presentingViewController dismissViewControllerAnimated:YES completion:nil]; }

- (void)reload {
    NSError *err = nil;
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_path error:&err];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in [names sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        if ([n hasPrefix:@"."]) continue;
        NSString *full = [_path stringByAppendingPathComponent:n];
        BOOL dir = NO; [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&dir];
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
        if (!dir && self.extensionFilter && ![[[n pathExtension] lowercaseString] isEqualToString:self.extensionFilter]) continue;
        [out addObject:@{@"name": n, @"dir": @(dir), @"size": at[NSFileSize] ?: @0, @"path": full}];
    }
    _items = out;
    [self.tableView reloadData];
}

- (void)locations {
    NSArray *locs = @[ADBDocumentsDir(), @"/var/mobile/Documents", @"/var/mobile/Media", @"/var/mobile/Media/DCIM", @"/var/mobile", @"/private/var/tmp", @"/"];
    [ADBAlert sheet:@"Go to" buttons:locs destructive:-1 from:self handler:^(NSInteger i) {
        LocalFilesViewController *vc = [[LocalFilesViewController alloc] initWithPath:locs[i]];
        vc.onPick = self.onPick; vc.extensionFilter = self.extensionFilter;
        [self.navigationController pushViewController:vc animated:YES];
    }];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX((NSInteger)_items.count, 1); }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"l"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"l"];
    if (!_items.count) { c.textLabel.text = @"(empty)"; c.detailTextLabel.text = _path; c.accessoryType = UITableViewCellAccessoryNone; return c; }
    NSDictionary *d = _items[ip.row];
    c.textLabel.text = d[@"name"];
    BOOL dir = [d[@"dir"] boolValue];
    c.detailTextLabel.text = dir ? @"Folder" : ADBHumanSize([d[@"size"] unsignedLongLongValue]);
    c.accessoryType = dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_items.count) return;
    NSDictionary *d = _items[ip.row];
    if ([d[@"dir"] boolValue]) {
        LocalFilesViewController *vc = [[LocalFilesViewController alloc] initWithPath:d[@"path"]];
        vc.onPick = self.onPick; vc.extensionFilter = self.extensionFilter;
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        NSString *p = d[@"path"]; void (^cb)(NSString *) = self.onPick;
        [self.presentingViewController dismissViewControllerAnimated:YES completion:^{ if (cb) cb(p); }];
    }
}
@end

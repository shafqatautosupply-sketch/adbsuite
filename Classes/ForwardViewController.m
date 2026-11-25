#import "ForwardViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"

@implementation ForwardViewController
- (id)init { if ((self = [super initWithStyle:UITableViewStyleGrouped])) { self.title = @"Port forwarding"; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(add)];
}
- (void)add {
    [ADBAlert promptTwo:@"Forward port" message:@"Local port on this iPhone  ->  device port (e.g. tcp:8080, localabstract:name)"
                 place1:@"8080" text1:@"" place2:@"tcp:8080" text2:@"" ok:^(NSString *a, NSString *b) {
        int lp = [[a adb_trimmed] intValue]; NSString *svc = [b adb_trimmed];
        if (lp <= 0 || !svc.length) return;
        if ([svc rangeOfString:@":"].location == NSNotFound) svc = [@"tcp:" stringByAppendingString:svc];
        [ADBAlert sheet:@"Listen on" buttons:@[@"This iPhone only (127.0.0.1)", @"All interfaces (other devices can connect)"] destructive:-1 from:self handler:^(NSInteger i) {
            NSString *err = [[ADBManager shared] startForwardLocalPort:lp remoteService:svc bindAll:i == 1];
            if (err) [ADBAlert alert:@"Cannot forward" message:err];
            [self.tableView reloadData];
        }];
    }];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX((NSInteger)[ADBManager shared].forwards.count, 1); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"Each connection opens its own ADB stream. Forwards stop when the app quits; they do not follow a changed wireless-debugging port.";
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"w"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"w"];
    NSArray *f = [ADBManager shared].forwards;
    if (!f.count) { c.textLabel.text = @"No forwards - tap +"; c.detailTextLabel.text = nil; return c; }
    NSDictionary *d = f[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@:%@  \u2192  %@", [d[@"all"] boolValue] ? @"*" : @"127.0.0.1", d[@"local"], d[@"service"]];
    c.detailTextLabel.text = @"Swipe to remove";
    return c;
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return [ADBManager shared].forwards.count > 0; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    if (st == UITableViewCellEditingStyleDelete) { [[ADBManager shared] stopForwardAtIndex:ip.row]; [tv reloadData]; }
}
@end

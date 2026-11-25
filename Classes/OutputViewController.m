#import "OutputViewController.h"
#import "ADBKit.h"

@implementation OutputViewController {
    UITextView *_tv; NSString *_text;
}
- (id)initWithTitle:(NSString *)title text:(NSString *)text {
    if ((self = [super init])) { self.title = title; _text = [text copy]; }
    return self;
}
- (void)loadView {
    _tv = ADBMakeConsole([UIScreen mainScreen].bounds);
    self.view = _tv;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    _tv.text = _text;
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share)];
    if (self.reload) {
        UIBarButtonItem *r = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(doReload)];
        self.navigationItem.rightBarButtonItems = @[share, r];
    } else self.navigationItem.rightBarButtonItem = share;
}
- (void)setText:(NSString *)text { _text = [text copy]; _tv.text = text; }
- (void)doReload {
    if (!self.reload) return;
    [ADBHUD show:@"Refreshing..."];
    self.reload(^(NSString *t) { [ADBHUD hide]; [self setText:t]; });
}
- (void)share {
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[_text ?: @""] applicationActivities:nil];
    [self presentViewController:a animated:YES completion:nil];
}
@end

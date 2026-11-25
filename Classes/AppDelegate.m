#import "AppDelegate.h"
#import "ADBManager.h"
#import "DevicesViewController.h"
#import "RemoteViewController.h"
#import "TerminalViewController.h"
#import "FilesViewController.h"
#import "AppsViewController.h"
#import "ScreenViewController.h"
#import "LogcatViewController.h"
#import "ToolsViewController.h"

@implementation AppDelegate

- (UINavigationController *)nav:(UIViewController *)vc {
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:vc];
    n.navigationBar.tintColor = [UIColor colorWithRed:0.12 green:0.38 blue:0.26 alpha:1];
    n.toolbar.tintColor = n.navigationBar.tintColor;
    n.tabBarItem = vc.tabBarItem;
    return n;
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    [ADBManager shared];
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UITabBarController *tabs = [[UITabBarController alloc] init];
    tabs.viewControllers = @[
        [self nav:[DevicesViewController new]],
        [self nav:[RemoteViewController new]],
        [self nav:[TerminalViewController new]],
        [self nav:[[FilesViewController alloc] initWithPath:@"/sdcard/"]],
        [self nav:[AppsViewController new]],
        [self nav:[ScreenViewController new]],
        [self nav:[LogcatViewController new]],
        [self nav:[ToolsViewController new]],
    ];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

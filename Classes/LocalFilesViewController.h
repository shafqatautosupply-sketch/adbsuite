#import <UIKit/UIKit.h>
/* Picks a file from the iPhone's file system (used for uploads / APK install). */
@interface LocalFilesViewController : UITableViewController
@property (nonatomic, copy) void (^onPick)(NSString *path);
@property (nonatomic, copy) NSString *extensionFilter;   /* e.g. @"apk" or nil */
+ (UINavigationController *)pickerWithStart:(NSString *)start filter:(NSString *)ext onPick:(void (^)(NSString *path))pick;
- (id)initWithPath:(NSString *)path;
@end

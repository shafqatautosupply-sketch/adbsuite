#import <UIKit/UIKit.h>
/* Scrollable monospace text with Copy / Share. Optional reload block for live data. */
@interface OutputViewController : UIViewController
@property (nonatomic, copy) void (^reload)(void (^done)(NSString *newText));
- (id)initWithTitle:(NSString *)title text:(NSString *)text;
- (void)setText:(NSString *)text;
@end

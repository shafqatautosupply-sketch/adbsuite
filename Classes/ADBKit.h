#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

/* ---- small UI helpers (block based alerts / sheets / HUD) ---- */
@interface ADBAlert : NSObject
+ (void)alert:(NSString *)title message:(NSString *)message;
+ (void)confirm:(NSString *)title message:(NSString *)message button:(NSString *)button yes:(void (^)(void))yes;
+ (void)prompt:(NSString *)title message:(NSString *)message placeholder:(NSString *)ph text:(NSString *)text
      keyboard:(UIKeyboardType)kb ok:(void (^)(NSString *text))ok;
+ (void)promptTwo:(NSString *)title message:(NSString *)message
         place1:(NSString *)p1 text1:(NSString *)t1 place2:(NSString *)p2 text2:(NSString *)t2
         ok:(void (^)(NSString *a, NSString *b))ok;
+ (void)sheet:(NSString *)title buttons:(NSArray *)buttons destructive:(NSInteger)destructive
         from:(UIViewController *)vc handler:(void (^)(NSInteger index))handler;
@end

@interface ADBHUD : NSObject
+ (void)show:(NSString *)text;                       /* spinner */
+ (void)showProgress:(NSString *)text;               /* spinner + progress bar */
+ (void)setProgress:(double)fraction text:(NSString *)text;
+ (void)hide;
+ (void)toast:(NSString *)text;                      /* auto-hiding message */
@end

/* Incremental UTF-8 decoder (handles multibyte chars split across packets) */
@interface ADBUTF8Decoder : NSObject
- (NSString *)feed:(const uint8_t *)bytes length:(size_t)n;
@end

@interface NSString (ADB)
- (NSString *)adb_shellQuoted;                       /* 'single quoted' for sh */
- (NSString *)adb_trimmed;
@end

UIFont *ADBMonoFont(CGFloat size);
UIColor *ADBGreen(void);
id ADBFirst(NSArray *a);                             /* safe replacement for -firstObject (iOS 7+) */
NSString *ADBDocumentsDir(void);                     /* ~/Documents/ADBSuite (created) */
NSString *ADBHumanSize(unsigned long long bytes);
UITextView *ADBMakeConsole(CGRect frame);            /* black, green, monospace, read-only */
UIButton *ADBMakeButton(NSString *title, CGRect frame, id target, SEL action);

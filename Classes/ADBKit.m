#import "ADBKit.h"
#import <objc/runtime.h>

static char kHandlerKey;

@interface ADBAlertHandler : NSObject <UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, copy) void (^alertBlock)(UIAlertView *av, NSInteger idx);
@property (nonatomic, copy) void (^sheetBlock)(NSInteger idx);
@end
@implementation ADBAlertHandler
- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)idx {
    if (self.alertBlock) self.alertBlock(av, idx);
}
- (void)actionSheet:(UIActionSheet *)as clickedButtonAtIndex:(NSInteger)idx {
    if (idx == as.cancelButtonIndex) return;
    if (self.sheetBlock) self.sheetBlock(idx);
}
@end

@implementation ADBAlert
+ (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:title message:message delegate:nil
                                       cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [av show];
}
+ (void)confirm:(NSString *)title message:(NSString *)message button:(NSString *)button yes:(void (^)(void))yes {
    ADBAlertHandler *h = [ADBAlertHandler new];
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:title message:message delegate:h
                                       cancelButtonTitle:@"Cancel" otherButtonTitles:button, nil];
    h.alertBlock = ^(UIAlertView *a, NSInteger idx) { if (idx != a.cancelButtonIndex && yes) yes(); };
    objc_setAssociatedObject(av, &kHandlerKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [av show];
}
+ (void)prompt:(NSString *)title message:(NSString *)message placeholder:(NSString *)ph text:(NSString *)text
      keyboard:(UIKeyboardType)kb ok:(void (^)(NSString *))ok {
    ADBAlertHandler *h = [ADBAlertHandler new];
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:title message:message delegate:h
                                       cancelButtonTitle:@"Cancel" otherButtonTitles:@"OK", nil];
    av.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *tf = [av textFieldAtIndex:0];
    tf.placeholder = ph; tf.text = text; tf.keyboardType = kb;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    h.alertBlock = ^(UIAlertView *a, NSInteger idx) {
        if (idx != a.cancelButtonIndex && ok) ok([[a textFieldAtIndex:0] text] ?: @"");
    };
    objc_setAssociatedObject(av, &kHandlerKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [av show];
}
+ (void)promptTwo:(NSString *)title message:(NSString *)message
           place1:(NSString *)p1 text1:(NSString *)t1 place2:(NSString *)p2 text2:(NSString *)t2
               ok:(void (^)(NSString *, NSString *))ok {
    ADBAlertHandler *h = [ADBAlertHandler new];
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:title message:message delegate:h
                                       cancelButtonTitle:@"Cancel" otherButtonTitles:@"OK", nil];
    av.alertViewStyle = UIAlertViewStyleLoginAndPasswordInput;
    UITextField *a = [av textFieldAtIndex:0], *b = [av textFieldAtIndex:1];
    a.placeholder = p1; a.text = t1; b.placeholder = p2; b.text = t2; b.secureTextEntry = NO;
    a.autocapitalizationType = b.autocapitalizationType = UITextAutocapitalizationTypeNone;
    a.autocorrectionType = b.autocorrectionType = UITextAutocorrectionTypeNo;
    a.keyboardType = UIKeyboardTypeNumbersAndPunctuation; b.keyboardType = UIKeyboardTypeNumberPad;
    h.alertBlock = ^(UIAlertView *v, NSInteger idx) {
        if (idx != v.cancelButtonIndex && ok) ok([[v textFieldAtIndex:0] text] ?: @"", [[v textFieldAtIndex:1] text] ?: @"");
    };
    objc_setAssociatedObject(av, &kHandlerKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [av show];
}
+ (void)sheet:(NSString *)title buttons:(NSArray *)buttons destructive:(NSInteger)destructive
         from:(UIViewController *)vc handler:(void (^)(NSInteger))handler {
    ADBAlertHandler *h = [ADBAlertHandler new];
    UIActionSheet *as = [[UIActionSheet alloc] initWithTitle:title delegate:h cancelButtonTitle:nil
                                      destructiveButtonTitle:nil otherButtonTitles:nil];
    for (NSString *b in buttons) [as addButtonWithTitle:b];
    if (destructive >= 0) as.destructiveButtonIndex = destructive;
    as.cancelButtonIndex = [as addButtonWithTitle:@"Cancel"];
    h.sheetBlock = handler;
    objc_setAssociatedObject(as, &kHandlerKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *host = vc.view.window ?: vc.view;
    [as showInView:host];
}
@end

/* ------------------------------------------------------------------ */
static UIView *gHud; static UILabel *gHudLabel; static UIProgressView *gHudBar;

@implementation ADBHUD
+ (void)build:(BOOL)withBar text:(NSString *)text {
    [self hide];
    UIWindow *w = [[UIApplication sharedApplication] keyWindow];
    if (!w) return;
    UIView *dim = [[UIView alloc] initWithFrame:w.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, withBar ? 130 : 110)];
    box.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height / 2);
    box.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                           UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    box.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    box.layer.cornerRadius = 12;
    UIActivityIndicatorView *ai = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    ai.center = CGPointMake(110, 32); [ai startAnimating]; [box addSubview:ai];
    gHudLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 58, 200, 40)];
    gHudLabel.backgroundColor = [UIColor clearColor]; gHudLabel.textColor = [UIColor whiteColor];
    gHudLabel.textAlignment = NSTextAlignmentCenter; gHudLabel.font = [UIFont systemFontOfSize:14];
    gHudLabel.numberOfLines = 2; gHudLabel.text = text; [box addSubview:gHudLabel];
    if (withBar) {
        gHudBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        gHudBar.frame = CGRectMake(20, 106, 180, 10); [box addSubview:gHudBar];
    }
    [dim addSubview:box]; [w addSubview:dim]; gHud = dim;
}
+ (void)show:(NSString *)text { [self build:NO text:text]; }
+ (void)showProgress:(NSString *)text { [self build:YES text:text]; }
+ (void)setProgress:(double)f text:(NSString *)t {
    if (gHudBar) gHudBar.progress = (float)(f < 0 ? 0 : (f > 1 ? 1 : f));
    if (t && gHudLabel) gHudLabel.text = t;
}
+ (void)hide { [gHud removeFromSuperview]; gHud = nil; gHudLabel = nil; gHudBar = nil; }
+ (void)toast:(NSString *)text {
    [self build:NO text:text];
    UIView *mine = gHud;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gHud == mine) [ADBHUD hide];
    });
}
@end

/* ------------------------------------------------------------------ */
@implementation ADBUTF8Decoder {
    NSMutableData *_pend;
}
- (NSString *)feed:(const uint8_t *)bytes length:(size_t)n {
    if (!_pend) _pend = [NSMutableData data];
    [_pend appendBytes:bytes length:n];
    NSUInteger len = _pend.length, cut = 0;
    for (; cut <= 3 && cut <= len; cut++) {
        NSData *d = [_pend subdataWithRange:NSMakeRange(0, len - cut)];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s) {
            [_pend replaceBytesInRange:NSMakeRange(0, len - cut) withBytes:NULL length:0];
            return s;
        }
    }
    NSString *s = [[NSString alloc] initWithData:_pend encoding:NSISOLatin1StringEncoding];
    _pend = [NSMutableData data];
    return s ?: @"";
}
@end

@implementation NSString (ADB)
- (NSString *)adb_shellQuoted {
    return [NSString stringWithFormat:@"'%@'", [self stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
- (NSString *)adb_trimmed {
    return [self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
@end

UIFont *ADBMonoFont(CGFloat size) {
    UIFont *f = [UIFont fontWithName:@"Courier" size:size];
    return f ?: [UIFont systemFontOfSize:size];
}
UIColor *ADBGreen(void) { return [UIColor colorWithRed:0.35 green:0.95 blue:0.45 alpha:1]; }

id ADBFirst(NSArray *a) { return a.count ? [a objectAtIndex:0] : nil; }

NSString *ADBDocumentsDir(void) {
    NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *d = [ADBFirst(p) stringByAppendingPathComponent:@"ADBSuite"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
    return d;
}
NSString *ADBHumanSize(unsigned long long b) {
    if (b < 1024) return [NSString stringWithFormat:@"%llu B", b];
    double v = b / 1024.0; const char *u[] = {"KB", "MB", "GB", "TB"}; int i = 0;
    while (v >= 1024 && i < 3) { v /= 1024; i++; }
    return [NSString stringWithFormat:@"%.1f %s", v, u[i]];
}
UITextView *ADBMakeConsole(CGRect frame) {
    UITextView *t = [[UITextView alloc] initWithFrame:frame];
    t.backgroundColor = [UIColor blackColor]; t.textColor = ADBGreen();
    t.font = ADBMonoFont(11); t.editable = NO;
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    t.autocorrectionType = UITextAutocorrectionTypeNo;
    return t;
}
UIButton *ADBMakeButton(NSString *title, CGRect frame, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    b.frame = frame; [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

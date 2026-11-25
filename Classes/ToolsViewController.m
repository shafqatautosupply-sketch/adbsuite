#import "ToolsViewController.h"
#import "ADBManager.h"
#import "ADBKit.h"
#import "OutputViewController.h"
#import "ForwardViewController.h"

typedef void (^ToolAction)(void);

@implementation ToolsViewController {
    NSArray *_sections;   /* @[@{@"title":..,@"rows":@[@{@"t":..,@"s":..,@"a":block}]}] */
}

- (id)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = @"Tools";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Tools" image:[UIImage imageNamed:@"tab_tools"] tag:7];
    }
    return self;
}

#pragma mark - building blocks

- (NSDictionary *)row:(NSString *)t sub:(NSString *)s action:(ToolAction)a { return @{@"t": t, @"s": s ?: @"", @"a": [a copy]}; }

/* run a command and show its output in a viewer; optionally refreshable */
- (ToolAction)show:(NSString *)title cmd:(NSString *)cmd live:(BOOL)live {
    __weak ToolsViewController *me = self;
    return ^{
        ToolsViewController *s = me; if (!s) return;
        [ADBHUD show:@"Reading..."];
        [[ADBManager shared] shell:cmd completion:^(NSString *out, int code, NSString *err) {
            [ADBHUD hide];
            OutputViewController *o = [[OutputViewController alloc] initWithTitle:title text:err ?: out];
            if (live) o.reload = ^(void (^done)(NSString *)) {
                [[ADBManager shared] shell:cmd completion:^(NSString *o2, int c2, NSString *e2) { done(e2 ?: o2); }];
            };
            [s.navigationController pushViewController:o animated:YES];
        }];
    };
}

/* run a command quietly; toast on success, alert on any output/failure */
- (void)quick:(NSString *)cmd done:(NSString *)msg {
    [ADBHUD show:@"Working..."];
    [[ADBManager shared] shell:cmd completion:^(NSString *out, int code, NSString *err) {
        [ADBHUD hide];
        NSString *o = [out adb_trimmed];
        if (err) { [ADBAlert alert:@"Error" message:err]; return; }
        if (code != 0 || [o rangeOfString:@"Exception"].location != NSNotFound || [o rangeOfString:@"Error"].location != NSNotFound || [o rangeOfString:@"not found"].location != NSNotFound)
            [ADBAlert alert:@"Result" message:o.length ? o : @"Command failed"];
        else [ADBHUD toast:msg ?: @"Done"];
    }];
}
- (ToolAction)quickAction:(NSString *)cmd done:(NSString *)msg {
    __weak ToolsViewController *me = self;
    return ^{ [me quick:cmd done:msg]; };
}
- (ToolAction)confirm:(NSString *)title cmd:(NSString *)cmd {
    __weak ToolsViewController *me = self;
    return ^{ [ADBAlert confirm:title message:@"Are you sure?" button:title yes:^{ [me quick:cmd done:@"Sent"]; }]; };
}
/* On / Off pair */
- (ToolAction)toggle:(NSString *)title on:(NSString *)on off:(NSString *)off {
    __weak ToolsViewController *me = self;
    return ^{
        ToolsViewController *s = me; if (!s) return;
        [ADBAlert sheet:title buttons:@[@"Turn on", @"Turn off"] destructive:-1 from:s handler:^(NSInteger i) {
            [me quick:i == 0 ? on : off done:i == 0 ? @"On" : @"Off"];
        }];
    };
}
/* numeric/text prompt -> command with %@ */
- (ToolAction)prompt:(NSString *)title msg:(NSString *)msg ph:(NSString *)ph fmt:(NSString *)fmt quote:(BOOL)quote show:(BOOL)show {
    __weak ToolsViewController *me = self;
    return ^{
        [ADBAlert prompt:title message:msg placeholder:ph text:@"" keyboard:UIKeyboardTypeDefault ok:^(NSString *t) {
            t = [t adb_trimmed]; if (!t.length) return;
            NSString *cmd = [NSString stringWithFormat:fmt, quote ? [t adb_shellQuoted] : t];
            if (show) { ToolAction a = [me show:title cmd:cmd live:NO]; a(); }
            else [me quick:cmd done:@"Done"];
        }];
    };
}

- (void)buildSections {
    __weak ToolsViewController *me = self;
    NSString *overview = @"echo \"Model:        $(getprop ro.product.model)\"; echo \"Manufacturer: $(getprop ro.product.manufacturer)\"; "
        "echo \"Device:       $(getprop ro.product.device)\"; echo \"Android:      $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))\"; "
        "echo \"Build:        $(getprop ro.build.display.id)\"; echo \"Patch:        $(getprop ro.build.version.security_patch)\"; "
        "echo \"ABI:          $(getprop ro.product.cpu.abi)\"; echo \"Serial:       $(getprop ro.serialno)\"; echo \"Uptime:      $(uptime)\"; "
        "echo; echo '--- Battery ---'; dumpsys battery | head -20; echo; echo '--- Storage ---'; df -h /data /sdcard 2>&1; "
        "echo; echo '--- Memory ---'; head -5 /proc/meminfo; echo; echo '--- Network ---'; ip -4 addr 2>&1 | grep -E 'inet |^[0-9]'";
    _sections = @[
      @{@"title": @"Device information", @"rows": @[
        [self row:@"Overview" sub:@"model, Android, battery, storage, network" action:[self show:@"Overview" cmd:overview live:YES]],
        [self row:@"Current app / activity" sub:@"what is in the foreground" action:[self show:@"Foreground" cmd:@"dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity|mFocusedApp' | head -10" live:YES]],
        [self row:@"All properties" sub:@"getprop" action:[self show:@"Properties" cmd:@"getprop | sort" live:NO]],
        [self row:@"Battery" sub:@"dumpsys battery" action:[self show:@"Battery" cmd:@"dumpsys battery" live:YES]],
        [self row:@"Memory" sub:@"/proc/meminfo" action:[self show:@"Memory" cmd:@"cat /proc/meminfo" live:YES]],
        [self row:@"Storage" sub:@"df -h" action:[self show:@"Storage" cmd:@"df -h 2>&1" live:YES]],
        [self row:@"Network" sub:@"interfaces, routes, Wi-Fi" action:[self show:@"Network" cmd:@"ip addr; echo; ip route; echo; dumpsys wifi | grep -E 'mWifiInfo|SSID|Supplicant state' | head -6" live:YES]],
        [self row:@"Processes" sub:@"top" action:[self show:@"Processes" cmd:@"top -b -n 1 2>&1 | head -45" live:YES]],
        [self row:@"Display" sub:@"size, density, refresh" action:[self show:@"Display" cmd:@"wm size; wm density; dumpsys display | grep -E 'mBaseDisplayInfo|fps' | head -6" live:NO]],
        [self row:@"Dumpsys service..." sub:@"any system service" action:[self prompt:@"dumpsys" msg:@"Service name (see: dumpsys -l)" ph:@"battery" fmt:@"dumpsys %@ | head -500" quote:YES show:YES]],
        [self row:@"Run command..." sub:@"one-shot shell command" action:[self prompt:@"Command" msg:nil ph:@"ls /sdcard" fmt:@"%@ 2>&1" quote:NO show:YES]],
      ]},
      @{@"title": @"Power", @"rows": @[
        [self row:@"Sleep screen" sub:@"" action:[self quickAction:@"input keyevent 223" done:@"Sleep"]],
        [self row:@"Wake screen" sub:@"" action:[self quickAction:@"input keyevent 224" done:@"Wake"]],
        [self row:@"Reboot" sub:@"" action:[self confirm:@"Reboot" cmd:@"reboot"]],
        [self row:@"Reboot to recovery" sub:@"" action:[self confirm:@"Reboot to recovery" cmd:@"reboot recovery"]],
        [self row:@"Reboot to bootloader" sub:@"" action:[self confirm:@"Reboot to bootloader" cmd:@"reboot bootloader"]],
        [self row:@"Power off" sub:@"" action:[self confirm:@"Power off" cmd:@"reboot -p"]],
      ]},
      @{@"title": @"Quick settings", @"rows": @[
        [self row:@"Wi-Fi" sub:@"svc wifi" action:[self toggle:@"Wi-Fi" on:@"svc wifi enable" off:@"svc wifi disable"]],
        [self row:@"Mobile data" sub:@"svc data" action:[self toggle:@"Mobile data" on:@"svc data enable" off:@"svc data disable"]],
        [self row:@"Bluetooth" sub:@"may need Android 8+" action:[self toggle:@"Bluetooth" on:@"svc bluetooth enable 2>&1 || cmd bluetooth_manager enable 2>&1" off:@"svc bluetooth disable 2>&1 || cmd bluetooth_manager disable 2>&1"]],
        [self row:@"Airplane mode" sub:@"" action:[self toggle:@"Airplane mode" on:@"cmd connectivity airplane-mode enable 2>&1 || (settings put global airplane_mode_on 1; am broadcast -a android.intent.action.AIRPLANE_MODE)" off:@"cmd connectivity airplane-mode disable 2>&1 || (settings put global airplane_mode_on 0; am broadcast -a android.intent.action.AIRPLANE_MODE)"]],
        [self row:@"Stay awake while charging" sub:@"" action:[self toggle:@"Stay awake" on:@"svc power stayon true" off:@"svc power stayon false"]],
        [self row:@"Animations" sub:@"window/transition/animator scale" action:[self toggle:@"Animations" on:@"settings put global window_animation_scale 1; settings put global transition_animation_scale 1; settings put global animator_duration_scale 1" off:@"settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0"]],
        [self row:@"Show touches" sub:@"developer option" action:[self toggle:@"Show touches" on:@"settings put system show_touches 1" off:@"settings put system show_touches 0"]],
        [self row:@"Auto-rotate" sub:@"" action:[self toggle:@"Auto-rotate" on:@"settings put system accelerometer_rotation 1" off:@"settings put system accelerometer_rotation 0"]],
        [self row:@"Brightness..." sub:@"0-255" action:[self prompt:@"Brightness" msg:@"0 - 255" ph:@"128" fmt:@"settings put system screen_brightness_mode 0; settings put system screen_brightness %@" quote:NO show:NO]],
        [self row:@"Media volume..." sub:@"stream 3" action:[self prompt:@"Volume" msg:@"Level (device specific, usually 0-15)" ph:@"7" fmt:@"media volume --show --stream 3 --set %1$@ 2>&1 || cmd media_session volume --stream 3 --set %1$@ 2>&1" quote:NO show:NO]],
        [self row:@"Screen timeout..." sub:@"milliseconds" action:[self prompt:@"Screen timeout" msg:@"Milliseconds, e.g. 600000" ph:@"600000" fmt:@"settings put system screen_off_timeout %@" quote:NO show:NO]],
        [self row:@"Display size..." sub:@"wm size WxH" action:[self prompt:@"Display size" msg:@"e.g. 1280x720" ph:@"1280x720" fmt:@"wm size %@" quote:YES show:NO]],
        [self row:@"Reset display size" sub:@"" action:[self quickAction:@"wm size reset" done:@"Reset"]],
        [self row:@"Display density..." sub:@"wm density" action:[self prompt:@"Density" msg:@"dpi, e.g. 320" ph:@"320" fmt:@"wm density %@" quote:YES show:NO]],
        [self row:@"Reset density" sub:@"" action:[self quickAction:@"wm density reset" done:@"Reset"]],
      ]},
      @{@"title": @"Launch", @"rows": @[
        [self row:@"Open URL on device" sub:@"am start VIEW" action:[self prompt:@"Open URL" msg:nil ph:@"https://example.com" fmt:@"am start -a android.intent.action.VIEW -d %@" quote:YES show:NO]],
        [self row:@"Android settings" sub:@"" action:[self quickAction:@"am start -a android.settings.SETTINGS" done:@"Opened"]],
        [self row:@"Developer options" sub:@"" action:[self quickAction:@"am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS" done:@"Opened"]],
        [self row:@"am start ..." sub:@"raw arguments" action:[self prompt:@"am start" msg:@"Arguments, e.g. -n com.pkg/.Activity" ph:@"-a android.intent.action.MAIN" fmt:@"am start %@ 2>&1" quote:NO show:YES]],
        [self row:@"am broadcast ..." sub:@"raw arguments" action:[self prompt:@"am broadcast" msg:nil ph:@"-a android.intent.action.BOOT_COMPLETED" fmt:@"am broadcast %@ 2>&1" quote:NO show:YES]],
      ]},
      @{@"title": @"ADB / network", @"rows": @[
        [self row:@"Port forwarding" sub:@"iPhone port -> device port" action:^{ [me.navigationController pushViewController:[ForwardViewController new] animated:YES]; }],
        [self row:@"Enable ADB over TCP 5555" sub:@"adb tcpip 5555" action:^{
            [[ADBManager shared] service:@"tcpip:5555" completion:^(NSData *d, NSString *err) {
                NSString *t = err ?: [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                [ADBAlert alert:@"tcpip" message:t.length ? t : @"Requested"];
            }]; }],
        [self row:@"Back to USB mode" sub:@"adb usb" action:^{
            [[ADBManager shared] service:@"usb:" completion:^(NSData *d, NSString *err) {
                NSString *t = err ?: [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                [ADBAlert alert:@"usb" message:t.length ? t : @"Requested"];
            }]; }],
        [self row:@"Reset control channel" sub:@"reconnect remote/touch channel" action:^{ [[ADBManager shared] resetControl]; [ADBHUD toast:@"Reset"]; }],
        [self row:@"Disconnect device" sub:@"forget current target" action:^{
            [[ADBManager shared] setTargetHost:nil port:0 name:nil]; [ADBHUD toast:@"Disconnected"]; }],
      ]},
    ];
}

- (void)viewDidLoad { [super viewDidLoad]; [self buildSections]; }

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [_sections[s][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _sections[s][@"title"]; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"t"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"t"];
    NSDictionary *r = _sections[ip.section][@"rows"][ip.row];
    c.textLabel.text = r[@"t"]; c.detailTextLabel.text = [r[@"s"] length] ? r[@"s"] : nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    ToolAction a = _sections[ip.section][@"rows"][ip.row][@"a"];
    if (![[ADBManager shared] hasTarget] && ip.section != 4) { [ADBAlert alert:@"No device" message:@"Pick or pair a device in the Devices tab first."]; return; }
    if (a) a();
}
@end

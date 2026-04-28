//
//  ViewController.m
//  DJIStreamDemo
//

#import "ViewController.h"
#import "TVUIRLDJIStreamManager.h"
#import "RTMPIngestController.h"
#include <ifaddrs.h>
#include <arpa/inet.h>

// Resolution presets — maps 1:1 to segmentedControl.selectedSegmentIndex.
static const TVUIRLDJIStreamResolution kResolutionOptions[] = {
    TVUIRLDJIStreamResolution480p,
    TVUIRLDJIStreamResolution720p,
    TVUIRLDJIStreamResolution1080p,
};

// Bitrate presets in bits/sec — maps 1:1 to segmentedControl.selectedSegmentIndex.
static const uint32_t kBitrateOptions[] = {
    2000000, 4000000, 6000000, 8000000,
    10000000, 12000000, 16000000, 20000000,
};

// RTMP URL template — %@ is replaced with the device's current Wi-Fi IP at runtime.
// Fallback IP (172.20.10.1) is used when the iPhone acts as a Personal Hotspot.
static NSString * const kRtmpUrlTemplate = @"rtmp://%@:1935/live/dji";

@interface ViewController () <TVUIRLDJIStreamManagerDelegate, RTMPIngestControllerDelegate,
                              UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UIView *previewContainer;
@property (nonatomic, strong) UITableView *deviceTable;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *startStreamButton;
@property (nonatomic, strong) UIButton *stopStreamButton;
@property (nonatomic, strong) UIButton *startServerButton;
@property (nonatomic, strong) UIButton *stopServerButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *ssidField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UITextField *rtmpField;
@property (nonatomic, strong) UITextField *latencyField;
@property (nonatomic, strong) UISwitch *noDelaySwitch;
@property (nonatomic, strong) UISegmentedControl *resolutionControl;
@property (nonatomic, strong) UISegmentedControl *bitrateControl;
@property (nonatomic, strong) UIView *batteryContainer;
@property (nonatomic, strong) UIView *batteryBody;
@property (nonatomic, strong) UIView *batteryLevel;
@property (nonatomic, strong) UILabel *batteryLabel;
@property (nonatomic, strong) NSTimer *batteryTimer;
@property (nonatomic, strong) UILabel *bitrateStatsLabel;
@property (nonatomic, strong) NSTimer *bitrateStatsTimer;

@property (nonatomic, strong) NSMutableArray<TVUIRLDJIDiscoveredPeripheral *> *devices;
@property (nonatomic, strong) TVUIRLDJIDiscoveredPeripheral *selected;
@property (nonatomic, assign) TVUIRLDJIStreamState currentState;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DJI Osmo Action Stream Demo";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.devices = [NSMutableArray array];
    self.currentState = TVUIRLDJIStreamStateIdle;

    TVUIRLDJIStreamManager.manager.delegate = self;
    RTMPIngestController.shared.delegate = self;

    [self buildUI];
    [self refreshRtmpUrlSuggestion];
    [self refreshControlState];

    // Tap anywhere outside a text field to dismiss the keyboard.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (NSString *)currentLocalIP {
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *iface = interfaces; iface != NULL; iface = iface->ifa_next) {
            if (iface->ifa_addr && iface->ifa_addr->sa_family == AF_INET
                && strcmp(iface->ifa_name, "en0") == 0) {
                address = [NSString stringWithUTF8String:
                    inet_ntoa(((struct sockaddr_in *)iface->ifa_addr)->sin_addr)];
                break;
            }
        }
    }
    freeifaddrs(interfaces);
    return address ?: @"172.20.10.1";   // fallback: Personal Hotspot IP
}

- (void)refreshRtmpUrlSuggestion {
    if (self.rtmpField.text.length == 0) {
        self.rtmpField.text = [NSString stringWithFormat:kRtmpUrlTemplate, [self currentLocalIP]];
    }
}

// Returns YES for `srt://…`. Case-insensitive.
- (BOOL)isSrtUrl:(NSString *)url {
    return [url rangeOfString:@"srt://" options:NSCaseInsensitiveSearch].location == 0;
}

- (void)buildUI {
    CGFloat margin = 16;
    CGFloat w = self.view.bounds.size.width;
    CGFloat y = [UIApplication sharedApplication].statusBarFrame.size.height + 44;

    // Preview — 16:9 on top, capped at 200pt tall so small phones don't run out of room.
    CGFloat previewHeight = MIN(floor((w - margin * 2) * 9.0 / 16.0), 200);
    self.previewContainer = [[UIView alloc] initWithFrame:CGRectMake(margin, y,
                                                                      w - margin * 2,
                                                                      previewHeight)];
    self.previewContainer.backgroundColor = [UIColor blackColor];
    self.previewContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.previewContainer.layer.cornerRadius = 8;
    self.previewContainer.layer.masksToBounds = YES;
    [self.view addSubview:self.previewContainer];

    UIView *preview = RTMPIngestController.shared.previewView;
    preview.frame = self.previewContainer.bounds;
    preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.previewContainer addSubview:preview];

    self.batteryContainer = [[UIView alloc] init];
    self.batteryContainer.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.8];
    self.batteryContainer.layer.cornerRadius = 5;
    [self.previewContainer addSubview:self.batteryContainer];

    self.batteryBody = [[UIView alloc] init];
    self.batteryBody.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.0];
    self.batteryBody.layer.cornerRadius = 2;
    self.batteryBody.layer.borderWidth = 1;
    self.batteryBody.layer.borderColor = [UIColor whiteColor].CGColor;
    [self.batteryContainer addSubview:self.batteryBody];

    self.batteryLevel = [[UIView alloc] init];
    self.batteryLevel.backgroundColor = [UIColor systemGreenColor];
    self.batteryLevel.layer.cornerRadius = 1;
    [self.batteryBody addSubview:self.batteryLevel];

    UIView *batteryTip = [[UIView alloc] init];
    batteryTip.backgroundColor = [UIColor whiteColor];
    batteryTip.layer.cornerRadius = 1.5;
    [self.previewContainer addSubview:batteryTip];

    self.batteryLabel = [[UILabel alloc] init];
    self.batteryLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    self.batteryLabel.textColor = [UIColor whiteColor];
    self.batteryLabel.textAlignment = NSTextAlignmentCenter;
    [self.previewContainer addSubview:self.batteryLabel];

    [self layoutBatteryUI];

    y += previewHeight + 8;

    self.statusLabel = [self makeLabel:@"Status: idle" y:y];
    y += 28;

    self.bitrateStatsLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, self.view.bounds.size.width - margin * 2, 22)];
    self.bitrateStatsLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.bitrateStatsLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.bitrateStatsLabel.textColor = [UIColor secondaryLabelColor];
    self.bitrateStatsLabel.text = @"Bitrate: -- Mbps";
    [self.view addSubview:self.bitrateStatsLabel];
    y += 26;

    self.ssidField = [self makeField:@"iPhone Personal Hotspot SSID" y:y];
    y += 40;
    self.passwordField = [self makeField:@"Hotspot password" y:y];
    self.passwordField.secureTextEntry = YES;
    y += 40;
    self.rtmpField = [self makeField:@"rtmp://172.20.10.1:1935/live/dji  OR  srt://…" y:y];
    y += 44;

    // Buffer latency (left) + TCP No-Delay switch (right) — same row
    UILabel *latLbl = [[UILabel alloc] initWithFrame:CGRectMake(margin, y + 6, 84, 22)];
    latLbl.text = @"Buffer (ms)";
    latLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    latLbl.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:latLbl];

    self.latencyField = [[UITextField alloc] initWithFrame:CGRectMake(margin + 88, y, 70, 34)];
    self.latencyField.borderStyle = UITextBorderStyleRoundedRect;
    self.latencyField.text = @"1000";
    self.latencyField.keyboardType = UIKeyboardTypeNumberPad;
    self.latencyField.font = [UIFont systemFontOfSize:14];
    self.latencyField.textAlignment = NSTextAlignmentCenter;
    self.latencyField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.latencyField.inputAccessoryView = [self makeDoneToolbar];
    [self.view addSubview:self.latencyField];

    self.noDelaySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - margin - 51, y + 2, 51, 31)];
    self.noDelaySwitch.on = NO;
    [self.view addSubview:self.noDelaySwitch];

    UILabel *ndLbl = [[UILabel alloc] initWithFrame:CGRectMake(w - margin - 51 - 90, y + 6, 88, 22)];
    ndLbl.text = @"TCP No-Delay";
    ndLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    ndLbl.textColor = [UIColor secondaryLabelColor];
    ndLbl.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:ndLbl];

    y += 44;

    self.ssidField.text = @"TVU-U6-2";
    self.passwordField.text = @"tvu@2026-->CNY";
    self.rtmpField.text = [NSString stringWithFormat:kRtmpUrlTemplate, [self currentLocalIP]];

    // SRT hint label
    UILabel *srtHint = [[UILabel alloc] initWithFrame:self.previewContainer.bounds];
    srtHint.tag = 9001;
    srtHint.text = @"SRT mode\nstream is on the PC";
    srtHint.numberOfLines = 0;
    srtHint.textAlignment = NSTextAlignmentCenter;
    srtHint.textColor = [UIColor whiteColor];
    srtHint.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    srtHint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    srtHint.hidden = YES;
    [self.previewContainer addSubview:srtHint];

    // Resolution picker
    [self makeLabel:@"Resolution" y:y];
    y += 22;
    self.resolutionControl = [self makeSegmented:@[@"480p", @"720p", @"1080p"] y:y];
    self.resolutionControl.selectedSegmentIndex = 1;  // default 720p
    y += 40;

    // Bitrate picker
    [self makeLabel:@"Bitrate (Mbps)" y:y];
    y += 22;
    self.bitrateControl = [self makeSegmented:@[@"2", @"4", @"6", @"8", @"10", @"12", @"16", @"20"] y:y];
    self.bitrateControl.selectedSegmentIndex = 1;  // default 4 Mbps
    y += 44;

    // RTMP Server controls — row 1
    CGFloat btnW = (w - margin * 3) / 2.0;
    self.startServerButton = [self makeButton:@"Start Server"
                                            x:margin y:y w:btnW
                                        action:@selector(onStartServerTap)];
    self.startServerButton.backgroundColor = [UIColor systemTealColor];
    self.stopServerButton = [self makeButton:@"Stop Server"
                                           x:margin * 2 + btnW y:y w:btnW
                                       action:@selector(onStopServerTap)];
    y += 44;

    // DJI Stream controls — row 2
    CGFloat btnW3 = (w - margin * 4) / 3.0;
    self.scanButton = [self makeButton:@"Scan" x:margin y:y w:btnW3 action:@selector(onScanTap)];
    self.startStreamButton = [self makeButton:@"Start DJI" x:margin * 2 + btnW3 y:y w:btnW3
                                        action:@selector(onStartStreamTap)];
    self.stopStreamButton = [self makeButton:@"Stop DJI" x:margin * 3 + btnW3 * 2 y:y w:btnW3
                                       action:@selector(onStopStreamTap)];
    y += 48;

    CGRect tableRect = CGRectMake(margin, y, w - margin * 2,
                                  self.view.bounds.size.height - y - margin);
    self.deviceTable = [[UITableView alloc] initWithFrame:tableRect style:UITableViewStylePlain];
    self.deviceTable.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.deviceTable.dataSource = self;
    self.deviceTable.delegate = self;
    self.deviceTable.rowHeight = 44;
    [self.deviceTable registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    [self.view addSubview:self.deviceTable];
}

- (UILabel *)makeLabel:(NSString *)text y:(CGFloat)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, self.view.bounds.size.width - 32, 22)];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = text;
    [self.view addSubview:l];
    return l;
}

- (UITextField *)makeField:(NSString *)placeholder y:(CGFloat)y {
    UITextField *tf = [[UITextField alloc]
        initWithFrame:CGRectMake(16, y, self.view.bounds.size.width - 32, 34)];
    tf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.placeholder = placeholder;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:tf];
    return tf;
}

- (UISegmentedControl *)makeSegmented:(NSArray<NSString *> *)titles y:(CGFloat)y {
    UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:titles];
    sc.frame = CGRectMake(16, y, self.view.bounds.size.width - 32, 32);
    sc.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:sc];
    return sc;
}

- (UIButton *)makeButton:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(x, y, w, 36);
    b.backgroundColor = [UIColor systemBlueColor];
    b.layer.cornerRadius = 8;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

// Updates button/control enabled-state from `currentState` and RTMP server state.
// Call after every state change.
- (void)refreshControlState {
    BOOL djiIdle = self.currentState == TVUIRLDJIStreamStateIdle
                || self.currentState == TVUIRLDJIStreamStateWifiSetupFailed;
    BOOL djiStreaming = self.currentState == TVUIRLDJIStreamStateStreaming;
    BOOL serverRunning = [RTMPIngestController.shared isRunning];

    // Server buttons: can start when not running, can stop when running
    self.startServerButton.enabled = !serverRunning;
    self.startServerButton.alpha = self.startServerButton.enabled ? 1.0 : 0.4;
    self.stopServerButton.enabled = serverRunning;
    self.stopServerButton.alpha = self.stopServerButton.enabled ? 1.0 : 0.4;

    // DJI stream buttons: Start requires a selected device + idle state
    self.startStreamButton.enabled = djiIdle && self.selected != nil;
    self.startStreamButton.alpha = self.startStreamButton.enabled ? 1.0 : 0.4;
    self.stopStreamButton.enabled = !djiIdle;
    self.stopStreamButton.alpha = self.stopStreamButton.enabled ? 1.0 : 0.4;

    // Scan button
    self.scanButton.enabled = djiIdle;
    self.scanButton.alpha = djiIdle ? 1.0 : 0.4;

    // Lock DJI configuration while a stream session is in-flight
    self.resolutionControl.enabled = djiIdle;
    self.bitrateControl.enabled = djiIdle;
    self.ssidField.enabled = djiIdle;
    self.passwordField.enabled = djiIdle;
    self.rtmpField.enabled = djiIdle && !serverRunning;
    self.latencyField.enabled = djiIdle && !serverRunning;
    self.noDelaySwitch.enabled = djiIdle && !serverRunning;

    if (djiStreaming || serverRunning) {
        self.statusLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.statusLabel.textColor = [UIColor secondaryLabelColor];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutBatteryUI];
}

- (void)layoutBatteryUI {
    CGFloat containerW = 52;
    CGFloat containerH = 20;
    CGFloat bodyW = 42;
    CGFloat bodyH = 14;
    CGFloat tipW = 3;
    CGFloat tipH = 6;
    CGFloat padding = 3;

    CGFloat containerX = self.previewContainer.bounds.size.width - containerW - 8;
    CGFloat containerY = 8;
    self.batteryContainer.frame = CGRectMake(containerX, containerY, containerW, containerH);

    CGFloat bodyX = (containerW - bodyW) / 2.0;
    CGFloat bodyY = (containerH - bodyH) / 2.0;
    self.batteryBody.frame = CGRectMake(bodyX, bodyY, bodyW, bodyH);

    UIView *batteryTip = self.batteryContainer.superview.subviews.lastObject;
    if (batteryTip && batteryTip != self.batteryLabel) {
        batteryTip.frame = CGRectMake(containerX + containerW, containerY + (containerH - tipH) / 2.0, tipW, tipH);
    }

    self.batteryLabel.frame = CGRectMake(containerX, containerY + containerH + 2, containerW, 12);

    [self updateBatteryDisplay];
}

- (void)updateBatteryDisplay {
    NSNumber *battery = [TVUIRLDJIStreamManager.manager batteryPercentage];
    if (battery) {
        NSInteger percentage = battery.integerValue;
        self.batteryLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percentage];

        CGFloat fillWidth = (percentage / 100.0) * (self.batteryBody.bounds.size.width - 4);
        if (fillWidth < 0) fillWidth = 0;

        self.batteryLevel.frame = CGRectMake(2, 2, fillWidth, self.batteryBody.bounds.size.height - 4);

        if (percentage <= 20) {
            self.batteryLevel.backgroundColor = [UIColor systemRedColor];
        } else if (percentage <= 50) {
            self.batteryLevel.backgroundColor = [UIColor systemOrangeColor];
        } else {
            self.batteryLevel.backgroundColor = [UIColor systemGreenColor];
        }

        self.batteryContainer.hidden = NO;
        self.batteryLabel.hidden = NO;
    } else {
        self.batteryContainer.hidden = YES;
        self.batteryLabel.hidden = YES;
    }
}

#pragma mark - RTMP Server Actions

- (void)onStartServerTap {
    NSString *url = self.rtmpField.text ?: @"";
    if ([self isSrtUrl:url]) {
        self.statusLabel.text = @"Status: SRT URL — server not needed";
        return;
    }
    uint16_t port = 1935;
    NSString *streamKey = @"dji";
    [self parseRtmpUrl:url port:&port streamKey:&streamKey];
    RTMPIngestController.shared.latency = (int32_t)[self.latencyField.text integerValue];
    RTMPIngestController.shared.noDelay = self.noDelaySwitch.isOn;
    [RTMPIngestController.shared startWithPort:port streamKey:streamKey];
    self.statusLabel.text = @"Status: RTMP server listening";
    [self refreshControlState];
}

- (void)onStopServerTap {
    [RTMPIngestController.shared stop];
    self.statusLabel.text = @"Status: RTMP server stopped";
    [self refreshControlState];
}

#pragma mark - DJI Stream Actions

- (void)onScanTap {
    [self refreshRtmpUrlSuggestion];
    [self.devices removeAllObjects];
    self.selected = nil;
    [self.deviceTable reloadData];
    [TVUIRLDJIStreamManager.manager startScan];
    self.statusLabel.text = @"Status: scanning…";
    [self refreshControlState];
}

- (void)onStartStreamTap {
    if (!self.selected) {
        self.statusLabel.text = @"Status: pick a device first";
        return;
    }
    NSString *ssid = self.ssidField.text ?: @"";
    NSString *pwd = self.passwordField.text ?: @"";
    NSString *url = self.rtmpField.text ?: @"";
    if (ssid.length == 0 || url.length == 0) {
        self.statusLabel.text = @"Status: SSID and stream URL are required";
        return;
    }

    NSInteger resIdx = self.resolutionControl.selectedSegmentIndex;
    TVUIRLDJIStreamResolution resolution = (resIdx >= 0 && resIdx < 3)
        ? kResolutionOptions[resIdx]
        : TVUIRLDJIStreamResolution720p;

    NSInteger brIdx = self.bitrateControl.selectedSegmentIndex;
    uint32_t bitrate = (brIdx >= 0 && brIdx < 8) ? kBitrateOptions[brIdx] : 4000000;

    BOOL srtMode = [self isSrtUrl:url];
    if (srtMode) {
        // SRT: camera streams directly to the PC. No local ingest on the phone.
        [self setSrtHintHidden:NO];
    } else {
        // RTMP: auto-start the server if not already running.
        [self setSrtHintHidden:YES];
        if (![RTMPIngestController.shared isRunning]) {
            uint16_t port = 1935;
            NSString *streamKey = @"dji";
            [self parseRtmpUrl:url port:&port streamKey:&streamKey];
            RTMPIngestController.shared.latency = (int32_t)[self.latencyField.text integerValue];
            RTMPIngestController.shared.noDelay = self.noDelaySwitch.isOn;
            [RTMPIngestController.shared startWithPort:port streamKey:streamKey];
        }
    }

    BOOL ok = [TVUIRLDJIStreamManager.manager startLiveStreamWithPeripheralId:self.selected.peripheralId
                                                                 wifiSsid:ssid
                                                             wifiPassword:pwd
                                                                  rtmpUrl:url
                                                               resolution:resolution
                                                                      fps:30
                                                                  bitrate:bitrate
                                                       imageStabilization:TVUIRLDJIStreamImageStabilizationRockSteady];
    if (!ok) {
        self.statusLabel.text = @"Status: start rejected";
    }
    [self refreshControlState];
}

- (void)onStopStreamTap {
    [TVUIRLDJIStreamManager.manager stopLiveStream];
    [self setSrtHintHidden:YES];
}

- (void)setSrtHintHidden:(BOOL)hidden {
    UIView *hint = [self.previewContainer viewWithTag:9001];
    hint.hidden = hidden;
}

// Parses `rtmp://host:port/app/streamKey` — pulls out port (default 1935) and
// the last path component as streamKey (default "dji").
- (void)parseRtmpUrl:(NSString *)urlString port:(uint16_t *)outPort streamKey:(NSString **)outKey {
    NSURLComponents *c = [NSURLComponents componentsWithString:urlString];
    if (c.port != nil) {
        *outPort = (uint16_t)c.port.unsignedShortValue;
    }
    NSArray<NSString *> *parts = [c.path componentsSeparatedByString:@"/"];
    NSString *last = nil;
    for (NSString *p in parts) {
        if (p.length > 0) last = p;
    }
    if (last.length > 0) {
        *outKey = last;
    }
}

#pragma mark - TVUIRLDJIStreamManagerDelegate

- (void)djiStreamManager:(TVUIRLDJIStreamManager *)manager
            didDiscover:(TVUIRLDJIDiscoveredPeripheral *)peripheral {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (TVUIRLDJIDiscoveredPeripheral *d in self.devices) {
            if ([d.peripheralId isEqualToString:peripheral.peripheralId]) return;
        }
        [self.devices addObject:peripheral];
        [self.deviceTable reloadData];
    });
}

- (void)djiStreamManager:(TVUIRLDJIStreamManager *)manager
          didChangeState:(TVUIRLDJIStreamState)state
               stateName:(NSString *)stateName {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentState = state;
        self.statusLabel.text = [NSString stringWithFormat:@"Status: %@", stateName];
        [self refreshControlState];
        [self updateBatteryDisplay];

        if (state == TVUIRLDJIStreamStateStreaming) {
            [self.batteryTimer invalidate];
            self.batteryTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                                 target:self
                                                               selector:@selector(updateBatteryDisplay)
                                                               userInfo:nil
                                                                repeats:YES];
        } else {
            [self.batteryTimer invalidate];
            self.batteryTimer = nil;
        }
    });
}

#pragma mark - RTMPIngestControllerDelegate

- (void)rtmpIngestDidStartPublishWithStreamKey:(NSString *)streamKey {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"Status: publishing (%@)", streamKey];
        self.statusLabel.textColor = [UIColor systemGreenColor];
        [self.bitrateStatsTimer invalidate];
        self.bitrateStatsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                  target:self
                                                                selector:@selector(updateBitrateStatsDisplay)
                                                                userInfo:nil
                                                                 repeats:YES];
    });
}

- (void)rtmpIngestDidStopPublishWithStreamKey:(NSString *)streamKey reason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"Status: publish stopped (%@)", reason];
        self.statusLabel.textColor = [UIColor secondaryLabelColor];
        [self.bitrateStatsTimer invalidate];
        self.bitrateStatsTimer = nil;
        self.bitrateStatsLabel.text = @"Bitrate: -- Mbps";
        [self refreshControlState];
    });
}

- (void)updateBitrateStatsDisplay {
    if (![RTMPIngestController.shared isRunning]) {
        self.bitrateStatsLabel.text = @"Bitrate: -- Mbps";
        return;
    }
    TVUIRLBandwidthSnapshot snap = [RTMPIngestController.shared updateStats];
    double mbps = (snap.speed * 8.0) / 1000000.0;
    self.bitrateStatsLabel.text = [NSString stringWithFormat:@"Bitrate: %.2f Mbps", mbps];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.devices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    TVUIRLDJIDiscoveredPeripheral *d = self.devices[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)", d.name, d.modelName];
    cell.detailTextLabel.text = d.peripheralId;
    cell.accessoryType = (self.selected == d) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    self.selected = self.devices[indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [tableView reloadData];
    [TVUIRLDJIStreamManager.manager stopScan];
    [self refreshControlState];
}

- (UIToolbar *)makeDoneToolbar {
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(dismissKeyboard)];
    bar.items = @[flex, done];
    return bar;
}

@end

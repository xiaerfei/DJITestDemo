//
//  ViewController.m
//  DJIStreamDemo
//

#import "ViewController.h"
#import "DJIStreamDemo-Swift.h"
#include <ifaddrs.h>
#include <arpa/inet.h>

// Resolution presets — maps 1:1 to segmentedControl.selectedSegmentIndex.
static const DJIStreamResolution kResolutionOptions[] = {
    DJIStreamResolutionR480p,
    DJIStreamResolutionR720p,
    DJIStreamResolutionR1080p,
};

// Bitrate presets in bits/sec — maps 1:1 to segmentedControl.selectedSegmentIndex.
static const uint32_t kBitrateOptions[] = {
    2000000, 4000000, 6000000, 8000000,
    10000000, 12000000, 16000000, 20000000,
};

// RTMP URL template — %@ is replaced with the device's current Wi-Fi IP at runtime.
// Fallback IP (172.20.10.1) is used when the iPhone acts as a Personal Hotspot.
static NSString * const kRtmpUrlTemplate = @"rtmp://%@:1935/live/dji";

@interface ViewController () <DJIStreamControllerDelegate, RTMPIngestControllerDelegate,
                              UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UIView *previewContainer;
@property (nonatomic, strong) UITableView *deviceTable;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *ssidField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UITextField *rtmpField;
@property (nonatomic, strong) UITextField *latencyField;
@property (nonatomic, strong) UISwitch *noDelaySwitch;
@property (nonatomic, strong) UITextField *queueSizeField;
@property (nonatomic, strong) UISegmentedControl *resolutionControl;
@property (nonatomic, strong) UISegmentedControl *bitrateControl;

@property (nonatomic, strong) NSMutableArray<DJIDiscoveredPeripheral *> *devices;
@property (nonatomic, strong) DJIDiscoveredPeripheral *selected;
@property (nonatomic, assign) enum DJIStreamState currentState;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DJI Osmo Action Stream Demo";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.devices = [NSMutableArray array];
    self.currentState = DJIStreamStateIdle;

    DJIStreamController.shared.delegate = self;
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
    y += previewHeight + 8;

    self.statusLabel = [self makeLabel:@"Status: idle" y:y];
    y += 28;

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
    self.latencyField.text = @"0";
    self.latencyField.keyboardType = UIKeyboardTypeNumberPad;
    self.latencyField.font = [UIFont systemFontOfSize:14];
    self.latencyField.textAlignment = NSTextAlignmentCenter;
    self.latencyField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.latencyField.inputAccessoryView = [self makeDoneToolbar];
    [self.view addSubview:self.latencyField];

    self.noDelaySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - margin - 51, y + 2, 51, 31)];
    self.noDelaySwitch.on = YES;
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

    // In SRT mode the stream goes directly to the PC, so the iPhone has no
    // frames to render. Show a hint on top of the preview area.
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

    // Queue size (free input, frames to buffer before display)
    UILabel *qsLbl = [[UILabel alloc] initWithFrame:CGRectMake(margin, y + 6, 140, 22)];
    qsLbl.text = @"Smooth Queue (frames)";
    qsLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    qsLbl.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:qsLbl];

    self.queueSizeField = [[UITextField alloc] initWithFrame:CGRectMake(margin + 144, y, 70, 34)];
    self.queueSizeField.borderStyle = UITextBorderStyleRoundedRect;
    self.queueSizeField.text = @"3";
    self.queueSizeField.keyboardType = UIKeyboardTypeNumberPad;
    self.queueSizeField.font = [UIFont systemFontOfSize:14];
    self.queueSizeField.textAlignment = NSTextAlignmentCenter;
    self.queueSizeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.queueSizeField.inputAccessoryView = [self makeDoneToolbar];
    [self.view addSubview:self.queueSizeField];
    y += 44;

    // Resolution picker
    [self makeLabel:@"Resolution" y:y];
    y += 22;
    self.resolutionControl = [self makeSegmented:@[@"480p", @"720p", @"1080p"] y:y];
    self.resolutionControl.selectedSegmentIndex = 2;  // default 1080p
    y += 40;

    // Bitrate picker
    [self makeLabel:@"Bitrate (Mbps)" y:y];
    y += 22;
    self.bitrateControl = [self makeSegmented:@[@"2", @"4", @"6", @"8", @"10", @"12", @"16", @"20"] y:y];
    self.bitrateControl.selectedSegmentIndex = 2;  // default 6 Mbps
    y += 44;

    CGFloat btnW = (w - margin * 4) / 3.0;
    self.scanButton = [self makeButton:@"Scan" x:margin y:y w:btnW action:@selector(onScanTap)];
    self.startButton = [self makeButton:@"Start" x:margin * 2 + btnW y:y w:btnW action:@selector(onStartTap)];
    self.stopButton = [self makeButton:@"Stop" x:margin * 3 + btnW * 2 y:y w:btnW action:@selector(onStopTap)];
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

// Updates button/control enabled-state from `currentState`. Call after every state change.
- (void)refreshControlState {
    BOOL idle = self.currentState == DJIStreamStateIdle
             || self.currentState == DJIStreamStateWifiSetupFailed;
    BOOL streaming = self.currentState == DJIStreamStateStreaming;

    self.startButton.enabled = idle && self.selected != nil;
    self.startButton.alpha = self.startButton.enabled ? 1.0 : 0.4;
    self.stopButton.enabled = !idle;
    self.stopButton.alpha = self.stopButton.enabled ? 1.0 : 0.4;

    // Lock configuration while a session is in-flight.
    self.resolutionControl.enabled = idle;
    self.bitrateControl.enabled = idle;
    self.ssidField.enabled = idle;
    self.passwordField.enabled = idle;
    self.rtmpField.enabled = idle;
    self.latencyField.enabled = idle;
    self.noDelaySwitch.enabled = idle;
    self.queueSizeField.enabled = idle;
    self.scanButton.enabled = idle;
    self.scanButton.alpha = idle ? 1.0 : 0.4;

    if (streaming) {
        self.statusLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.statusLabel.textColor = [UIColor secondaryLabelColor];
    }
}

#pragma mark - Actions

- (void)onScanTap {
    [self refreshRtmpUrlSuggestion];
    [self.devices removeAllObjects];
    self.selected = nil;
    [self.deviceTable reloadData];
    [DJIStreamController.shared startScan];
    self.statusLabel.text = @"Status: scanning…";
    [self refreshControlState];
}

- (void)onStartTap {
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
    DJIStreamResolution resolution = (resIdx >= 0 && resIdx < 3)
        ? kResolutionOptions[resIdx]
        : DJIStreamResolutionR1080p;

    NSInteger brIdx = self.bitrateControl.selectedSegmentIndex;
    uint32_t bitrate = (brIdx >= 0 && brIdx < 8) ? kBitrateOptions[brIdx] : 6000000;

    BOOL srtMode = [self isSrtUrl:url];
    if (srtMode) {
        // SRT: camera streams directly to the PC. No local ingest on the phone.
        [self setSrtHintHidden:NO];
    } else {
        // RTMP: iPhone hosts the ingest server and renders frames locally.
        [self setSrtHintHidden:YES];
        uint16_t port = 1935;
        NSString *streamKey = @"dji";
        [self parseRtmpUrl:url port:&port streamKey:&streamKey];
        RTMPIngestController.shared.latency = (int32_t)[self.latencyField.text integerValue];
        RTMPIngestController.shared.noDelay = self.noDelaySwitch.isOn;
        NSInteger queueSize = [self.queueSizeField.text integerValue];
        RTMPIngestController.shared.frameQueueSize = queueSize > 0 ? queueSize : 1;
        [RTMPIngestController.shared startWithPort:port streamKey:streamKey];
    }

    BOOL ok = [DJIStreamController.shared startLiveStreamWithPeripheralId:self.selected.peripheralId
                                                                 wifiSsid:ssid
                                                             wifiPassword:pwd
                                                                  rtmpUrl:url
                                                               resolution:resolution
                                                                      fps:30
                                                                  bitrate:bitrate
                                                       imageStabilization:DJIStreamImageStabilizationRockSteady];
    if (!ok) {
        if (!srtMode) [RTMPIngestController.shared stop];
        self.statusLabel.text = @"Status: start rejected";
    }
    [self refreshControlState];
}

- (void)onStopTap {
    [DJIStreamController.shared stopLiveStream];
    [RTMPIngestController.shared stop];
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

#pragma mark - DJIStreamControllerDelegate

- (void)djiStreamController:(DJIStreamController *)controller
                didDiscover:(DJIDiscoveredPeripheral *)peripheral {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (DJIDiscoveredPeripheral *d in self.devices) {
            if ([d.peripheralId isEqualToString:peripheral.peripheralId]) return;
        }
        [self.devices addObject:peripheral];
        [self.deviceTable reloadData];
    });
}

- (void)djiStreamController:(DJIStreamController *)controller
             didChangeState:(enum DJIStreamState)state
                  stateName:(NSString *)stateName {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentState = state;
        self.statusLabel.text = [NSString stringWithFormat:@"Status: %@", stateName];
        [self refreshControlState];
    });
}

#pragma mark - RTMPIngestControllerDelegate

- (void)rtmpIngestDidStartPublishWithStreamKey:(NSString *)streamKey {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"Status: publishing (%@)", streamKey];
        self.statusLabel.textColor = [UIColor systemGreenColor];
    });
}

- (void)rtmpIngestDidStopPublishWithStreamKey:(NSString *)streamKey reason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = [NSString stringWithFormat:@"Status: publish stopped (%@)", reason];
        self.statusLabel.textColor = [UIColor secondaryLabelColor];
    });
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.devices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    DJIDiscoveredPeripheral *d = self.devices[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)", d.name, d.modelName];
    cell.detailTextLabel.text = d.peripheralId;
    cell.accessoryType = (self.selected == d) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    self.selected = self.devices[indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [tableView reloadData];
    [DJIStreamController.shared stopScan];
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

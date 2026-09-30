#import <Cocoa/Cocoa.h>
#import <CoreWLAN/CoreWLAN.h>
#import <UserNotifications/UserNotifications.h>

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr const char *AppName = "NetWatch";
constexpr const char *Version = "1.2.0-cpp";
constexpr NSTimeInterval CheckInterval = 30.0;
constexpr int ProbeTimeoutSeconds = 1;
constexpr int FailThreshold = 2;
constexpr int OkThreshold = 1;
constexpr double LatencyWarnMs = 300.0;
constexpr int LatencyWarnCount = 2;
constexpr double FlapWindowSeconds = 60.0;
constexpr int FlapThreshold = 3;

struct IntervalChoice {
    const char *label;
    int seconds;  // 0 = never
};

// Sentinels: Fastest probes back-to-back, ReconnectOnly freezes the menubar
// reading until the link comes back, Never stops the timer entirely.
constexpr int IntervalFastest = -1;
constexpr int IntervalReconnectOnly = -2;
constexpr int IntervalNever = 0;
// Fastest chains probes: the next one starts as soon as the previous reply lands,
// so the reading updates per reply like `ping` does. The floor keeps a fast link
// from turning into hundreds of connects per second.
constexpr NSTimeInterval FastestFloor = 0.2;

const std::vector<IntervalChoice> IntervalChoices = {
    {"Fastest", IntervalFastest},
    {"1 sec (unstable)", 1},
    {"10 sec", 10},
    {"30 sec", 30},
    {"1 min", 60},
    {"5 min", 300},
    {"10 min", 600},
    {"Only when reconnect", IntervalReconnectOnly},
    {"Never", IntervalNever},
};

struct ProbeTarget {
    const char *host;
    uint16_t port;
};

const std::vector<ProbeTarget> ProbeTargets = {
    {"1.1.1.1", 53},
    {"8.8.8.8", 53},
    {"9.9.9.9", 53},
};

struct WifiReading {
    bool connected = false;
    int rssiDbm = 0;
    int noiseDbm = 0;
    int txRateMbps = 0;
    long channel = 0;
    std::string band;
    std::string width;
};

struct ProbeResult {
    bool online = false;
    std::optional<double> latencyMs;
    WifiReading wifi;
};

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

std::string homePath() {
    return std::string([NSHomeDirectory() UTF8String]);
}

std::string logPath() {
    return homePath() + "/Library/Logs/NetWatch.log";
}

std::string timestamp() {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return std::string([[formatter stringFromDate:[NSDate date]] UTF8String]);
}

void logEvent(const std::string &message) {
    try {
        auto path = std::filesystem::path(logPath());
        std::filesystem::create_directories(path.parent_path());
        std::ofstream log(path, std::ios::app);
        if (log) {
            log << timestamp() << "  " << message << '\n';
        }
    } catch (...) {
    }
}

std::string formatDuration(double secondsValue) {
    auto seconds = static_cast<int>(std::llround(secondsValue));
    if (seconds < 60) {
        return std::to_string(seconds) + "s";
    }

    int minutes = seconds / 60;
    int remainingSeconds = seconds % 60;
    if (minutes < 60) {
        return std::to_string(minutes) + "m " + std::to_string(remainingSeconds) + "s";
    }

    int hours = minutes / 60;
    int remainingMinutes = minutes % 60;
    return std::to_string(hours) + "h " + std::to_string(remainingMinutes) + "m";
}

bool connectWithTimeout(const ProbeTarget &target) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return false;
    }

    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_port = htons(target.port);
    if (inet_pton(AF_INET, target.host, &address.sin_addr) != 1) {
        close(fd);
        return false;
    }

    int result = connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address));
    if (result == 0) {
        close(fd);
        return true;
    }

    if (errno != EINPROGRESS) {
        close(fd);
        return false;
    }

    fd_set writeSet;
    FD_ZERO(&writeSet);
    FD_SET(fd, &writeSet);

    timeval timeout {};
    timeout.tv_sec = ProbeTimeoutSeconds;
    timeout.tv_usec = 0;

    result = select(fd + 1, nullptr, &writeSet, nullptr, &timeout);
    if (result <= 0) {
        close(fd);
        return false;
    }

    int socketError = 0;
    socklen_t socketErrorLength = sizeof(socketError);
    bool connected = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 && socketError == 0;
    close(fd);
    return connected;
}

ProbeResult probe() {
    for (const auto &target : ProbeTargets) {
        auto start = Clock::now();
        if (connectWithTimeout(target)) {
            auto elapsed = Clock::now() - start;
            double ms = std::chrono::duration<double, std::milli>(elapsed).count();
            return {true, ms, {}};
        }
    }

    return {false, std::nullopt, {}};
}

// Signal, noise, rate and channel need no Location permission; the SSID does,
// so it is deliberately not read.
WifiReading readWifi() {
    WifiReading reading;
    CWInterface *wifi = [[CWWiFiClient sharedWiFiClient] interface];
    if (wifi == nil) {
        return reading;
    }

    NSInteger rssi = wifi.rssiValue;
    if (rssi == 0) {  // not associated with a network
        return reading;
    }

    reading.connected = true;
    reading.rssiDbm = static_cast<int>(rssi);
    reading.noiseDbm = static_cast<int>(wifi.noiseMeasurement);
    reading.txRateMbps = static_cast<int>(std::lround(wifi.transmitRate));

    CWChannel *channel = wifi.wlanChannel;
    if (channel != nil) {
        reading.channel = static_cast<long>(channel.channelNumber);
        switch (channel.channelBand) {
            case kCWChannelBand2GHz: reading.band = "2.4GHz"; break;
            case kCWChannelBand5GHz: reading.band = "5GHz"; break;
            case kCWChannelBand6GHz: reading.band = "6GHz"; break;
            default: break;
        }
        switch (channel.channelWidth) {
            case kCWChannelWidth20MHz: reading.width = "20MHz"; break;
            case kCWChannelWidth40MHz: reading.width = "40MHz"; break;
            case kCWChannelWidth80MHz: reading.width = "80MHz"; break;
            case kCWChannelWidth160MHz: reading.width = "160MHz"; break;
            default: break;
        }
    }
    return reading;
}

// dBm is negative; closer to 0 is stronger.
const char *signalQuality(int rssiDbm) {
    if (rssiDbm >= -50) return "Excellent";
    if (rssiDbm >= -60) return "Good";
    if (rssiDbm >= -67) return "Fair";
    if (rssiDbm >= -75) return "Weak";
    return "Bad";
}

NSColor *signalColor(int rssiDbm) {
    if (rssiDbm >= -60) return [NSColor systemGreenColor];
    if (rssiDbm >= -67) return [NSColor systemYellowColor];
    if (rssiDbm >= -75) return [NSColor systemOrangeColor];
    return [NSColor systemRedColor];
}

// Emoji keep their color in the menu even though info rows are disabled (greyed).
NSString *signalIcon(int rssiDbm) {
    if (rssiDbm >= -60) return @"\U0001F7E2";
    if (rssiDbm >= -67) return @"\U0001F7E1";
    if (rssiDbm >= -75) return @"\U0001F7E0";
    return @"\U0001F534";
}

std::string wifiSummary(const WifiReading &wifi) {
    if (!wifi.connected) {
        return "Wi-Fi not connected";
    }
    return "Wi-Fi " + std::to_string(wifi.rssiDbm) + " dBm, " + signalQuality(wifi.rssiDbm);
}

NSString *ns(const std::string &value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

NSString *soundPath() {
    NSString *bundledPath = [[NSBundle mainBundle] pathForResource:@"ping" ofType:@"mp3" inDirectory:@"assets"];
    if (bundledPath != nil) {
        return bundledPath;
    }

    NSString *workingPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"assets/ping.mp3"];
    return workingPath;
}

void playSound() {
    NSString *path = soundPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return;
    }

    [[NSTask launchedTaskWithLaunchPath:@"/usr/bin/afplay" arguments:@[path]] waitUntilExit];
}

} // namespace

@interface NetWatchController : NSObject <UNUserNotificationCenterDelegate, NSMenuDelegate> {
    NSStatusItem *_statusItem;
    NSMenuItem *_statusMenuItem;
    NSMenuItem *_latencyMenuItem;
    NSMenuItem *_lastOutageMenuItem;
    NSMenuItem *_wifiMenuItem;
    NSMenuItem *_wifiLinkMenuItem;
    NSMenuItem *_muteMenuItem;
    NSMenu *_intervalSubmenu;
    NSMenuItem *_viewMenuItem;
    NSMenuItem *_signalColorMenuItem;
    NSTimer *_timer;

    std::optional<bool> _online;
    std::optional<double> _latencyMs;
    std::optional<double> _displayLatencyMs;  // what the menubar shows
    bool _muted;
    bool _emojiOnly;
    bool _colorBySignal;  // menubar color follows Wi-Fi RSSI instead of link status
    NSTimeInterval _interval;  // 0 = never refresh automatically
    bool _checking;
    NSColor *_statusColor;
    NSString *_statusIcon;
    int _failCount;
    int _okCount;
    int _slowCount;
    std::vector<TimePoint> _transitions;
    std::optional<TimePoint> _offlineSince;
    std::optional<double> _lastOutage;
    WifiReading _wifi;
}
@end

@implementation NetWatchController

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _muted = false;
    _emojiOnly = false;
    _colorBySignal = false;
    _interval = CheckInterval;
    _checking = false;
    _statusColor = [NSColor labelColor];
    _statusIcon = @"\U0001F310";
    _failCount = 0;
    _okCount = 0;
    _slowCount = 0;

    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    notificationCenter.delegate = self;
    [notificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(__unused BOOL granted, __unused NSError *error) {
    }];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.title = @"-";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:ns(AppName)];
    _statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Status: starting..." action:nil keyEquivalent:@""];
    _latencyMenuItem = [[NSMenuItem alloc] initWithTitle:@"Latency: -" action:nil keyEquivalent:@""];
    _lastOutageMenuItem = [[NSMenuItem alloc] initWithTitle:@"Last outage: -" action:nil keyEquivalent:@""];
    _wifiMenuItem = [[NSMenuItem alloc] initWithTitle:@"Wi-Fi: -" action:nil keyEquivalent:@""];
    _wifiLinkMenuItem = [[NSMenuItem alloc] initWithTitle:@"Link: -" action:nil keyEquivalent:@""];
    _muteMenuItem = [[NSMenuItem alloc] initWithTitle:@"Mute sound" action:@selector(toggleMute:) keyEquivalent:@""];
    _muteMenuItem.target = self;

    _viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"Show emoji only" action:@selector(toggleView:) keyEquivalent:@""];
    _viewMenuItem.target = self;

    _signalColorMenuItem = [[NSMenuItem alloc] initWithTitle:@"Color by Wi-Fi signal" action:@selector(toggleSignalColor:) keyEquivalent:@""];
    _signalColorMenuItem.target = self;

    NSMenuItem *intervalMenuItem = [[NSMenuItem alloc] initWithTitle:@"Update interval" action:nil keyEquivalent:@""];
    _intervalSubmenu = [[NSMenu alloc] initWithTitle:@"Update interval"];
    for (const auto &choice : IntervalChoices) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:ns(choice.label) action:@selector(selectInterval:) keyEquivalent:@""];
        item.target = self;
        item.tag = static_cast<NSInteger>(choice.seconds);
        [_intervalSubmenu addItem:item];
    }
    intervalMenuItem.submenu = _intervalSubmenu;

    NSMenuItem *openLogItem = [[NSMenuItem alloc] initWithTitle:@"Open log" action:@selector(openLog:) keyEquivalent:@""];
    openLogItem.target = self;

    NSMenuItem *clearLogItem = [[NSMenuItem alloc] initWithTitle:@"Clear log" action:@selector(clearLog:) keyEquivalent:@""];
    clearLogItem.target = self;

    NSMenuItem *versionItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%s v%s", AppName, Version] action:nil keyEquivalent:@""];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;

    [menu addItem:_statusMenuItem];
    [menu addItem:_latencyMenuItem];
    [menu addItem:_lastOutageMenuItem];
    [menu addItem:_wifiMenuItem];
    [menu addItem:_wifiLinkMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:_muteMenuItem];
    [menu addItem:_viewMenuItem];
    [menu addItem:_signalColorMenuItem];
    [menu addItem:intervalMenuItem];
    [menu addItem:openLogItem];
    [menu addItem:clearLogItem];
    [menu addItem:versionItem];
    [menu addItem:quitItem];
    menu.delegate = self;
    _statusItem.menu = menu;

    [self scheduleTimer];
    [self check:nil];

    return self;
}

- (void)scheduleTimer {
    [_timer invalidate];
    _timer = nil;
    [self updateIntervalMenu];

    NSTimeInterval tick = _interval;
    if (_interval == IntervalNever) {
        return;
    }
    if (_interval == IntervalFastest) {
        // Self-chaining from consumeProbeResult: no repeating timer needed.
        return;
    }
    if (_interval == IntervalReconnectOnly) {
        // Still has to probe to notice a reconnect; only the display is frozen.
        tick = CheckInterval;
    }

    _timer = [NSTimer scheduledTimerWithTimeInterval:tick target:self selector:@selector(check:) userInfo:nil repeats:YES];
}

- (void)updateIntervalMenu {
    for (NSMenuItem *item in _intervalSubmenu.itemArray) {
        item.state = (static_cast<NSTimeInterval>(item.tag) == _interval) ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)selectInterval:(NSMenuItem *)sender {
    _interval = static_cast<NSTimeInterval>(sender.tag);
    if (_interval == IntervalReconnectOnly) {
        _displayLatencyMs = _latencyMs;
    }
    [self updateIntervalMenu];
    [self scheduleTimer];
    if (_interval != IntervalNever) {
        [self check:nil];
    }
}

// Clicking the status item refreshes immediately and restarts the 30s cycle.
- (void)menuWillOpen:(__unused NSMenu *)menu {
    [self updateIntervalMenu];
    if (_interval == IntervalNever) {
        return;
    }
    [self check:nil];
    [self scheduleTimer];
}

- (void)toggleMute:(id)sender {
    _muted = !_muted;
    _muteMenuItem.state = _muted ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)openLog:(id)sender {
    std::string path = logPath();
    if (!std::filesystem::exists(path)) {
        logEvent("(log created)");
    }

    NSURL *url = [NSURL fileURLWithPath:ns(path)];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)clearLog:(id)sender {
    std::error_code error;
    bool removed = std::filesystem::remove(logPath(), error);

    if (error) {
        [self notifyWithTitle:@"Error" message:@"Could not clear the log file."];
    } else if (removed) {
        [self notifyWithTitle:@"Log cleared" message:@"The network log history has been wiped."];
    } else {
        [self notifyWithTitle:@"Log empty" message:@"There is no log file to clear."];
    }
}

- (void)check:(id)sender {
    if (_checking) {
        return;
    }

    _checking = true;
    __weak NetWatchController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ProbeResult result = probe();
        result.wifi = readWifi();
        dispatch_async(dispatch_get_main_queue(), ^{
            NetWatchController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf consumeProbeResult:result];
            }
        });
    });
}

- (void)continueFastest {
    if (_interval == IntervalFastest) {
        [self check:nil];
    }
}

- (void)consumeProbeResult:(ProbeResult)result {
    _checking = false;
    _latencyMs = result.latencyMs;
    _wifi = result.wifi;
    if (_interval != IntervalReconnectOnly) {
        _displayLatencyMs = _latencyMs;
    }

    if (_interval == IntervalFastest) {
        __weak NetWatchController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FastestFloor * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NetWatchController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf continueFastest];
            }
        });
    }

    if (result.online && _latencyMs.has_value() && *_latencyMs > LatencyWarnMs) {
        _slowCount += 1;
    } else {
        _slowCount = 0;
    }

    if (result.online) {
        _okCount += 1;
        _failCount = 0;
        if (!_online.has_value() || *_online != true) {
            if (_okCount >= OkThreshold) {
                [self setOnline:true];
            }
        }
    } else {
        _failCount += 1;
        _okCount = 0;
        if (!_online.has_value() || *_online != false) {
            if (_failCount >= FailThreshold) {
                [self setOnline:false];
            }
        }
    }

    [self updateDisplay];
}

- (void)setOnline:(bool)online {
    std::optional<bool> was = _online;
    _online = online;

    // "Only when reconnect" refreshes the menubar reading at the moment the link
    // comes back, and blanks it to the state emoji while it is down.
    if (_interval == IntervalReconnectOnly) {
        _displayLatencyMs = online ? _latencyMs : std::nullopt;
    }

    if (!was.has_value()) {
        if (!online) {
            _offlineSince = Clock::now();
        }
        return;
    }

    _transitions.push_back(Clock::now());

    if (online) {
        std::optional<double> duration;
        if (_offlineSince.has_value()) {
            duration = std::chrono::duration<double>(Clock::now() - *_offlineSince).count();
            _lastOutage = duration;
            _offlineSince.reset();
        }

        std::string message = "You are back online.";
        if (duration.has_value()) {
            message = "Offline for " + formatDuration(*duration) + ".";
        }
        logEvent("RECONNECTED (" + message + ")");
        [self alertWithTitle:@"Network restored" message:ns(message)];
    } else {
        _offlineSince = Clock::now();
        logEvent("DISCONNECTED (" + wifiSummary(_wifi) + ")");
        [self alertWithTitle:@"Network disconnected" message:@"Your connection just dropped."];
    }
}

- (void)updateDisplay {
    auto now = Clock::now();
    std::vector<TimePoint> recentTransitions;
    for (auto transition : _transitions) {
        double age = std::chrono::duration<double>(now - transition).count();
        if (age <= FlapWindowSeconds) {
            recentTransitions.push_back(transition);
        }
    }
    _transitions = recentTransitions;

    int flaps = static_cast<int>(_transitions.size());
    bool unstable = flaps >= FlapThreshold;
    bool highLatency = _slowCount >= LatencyWarnCount;

    NSString *status = @"starting...";
    NSColor *color = [NSColor labelColor];
    NSString *icon = @"\U0001F310";
    if (_online.has_value() && *_online == false) {
        color = [NSColor systemRedColor];
        icon = @"\U0001F534";
        status = @"Disconnected";
    } else if (unstable) {
        color = [NSColor systemOrangeColor];
        icon = @"\U0001F7E0";
        status = [NSString stringWithFormat:@"Unstable (%d flaps/min)", flaps];
    } else if (highLatency && _latencyMs.has_value()) {
        color = [NSColor systemYellowColor];
        icon = @"\U0001F7E1";
        status = [NSString stringWithFormat:@"High latency (%d ms)", static_cast<int>(*_latencyMs)];
    } else if (_online.has_value() && *_online == true) {
        color = [NSColor systemGreenColor];
        icon = @"\U0001F7E2";
        status = @"Connected";
    }
    _statusColor = color;
    _statusIcon = icon;
    [self applyStatusTitle];

    _statusMenuItem.title = [NSString stringWithFormat:@"Status: %@", status];
    if (_latencyMs.has_value()) {
        _latencyMenuItem.title = [NSString stringWithFormat:@"Latency: %d ms", static_cast<int>(*_latencyMs)];
    } else {
        _latencyMenuItem.title = @"Latency: -";
    }

    if (_wifi.connected) {
        _wifiMenuItem.title = [NSString stringWithFormat:@"%@ Wi-Fi: %d dBm (%s) · SNR %d dB",
                               signalIcon(_wifi.rssiDbm), _wifi.rssiDbm, signalQuality(_wifi.rssiDbm), _wifi.rssiDbm - _wifi.noiseDbm];
        std::string channel = "ch " + std::to_string(_wifi.channel);
        if (!_wifi.band.empty() || !_wifi.width.empty()) {
            channel += " (" + _wifi.band + (_wifi.band.empty() || _wifi.width.empty() ? "" : ", ") + _wifi.width + ")";
        }
        _wifiLinkMenuItem.title = [NSString stringWithFormat:@"Link: %d Mbps · %@", _wifi.txRateMbps, ns(channel)];
        _wifiLinkMenuItem.hidden = NO;
    } else {
        _wifiMenuItem.title = @"Wi-Fi: not connected";
        _wifiLinkMenuItem.hidden = YES;
    }

    if (_lastOutage.has_value()) {
        _lastOutageMenuItem.title = [NSString stringWithFormat:@"Last outage: %@", ns(formatDuration(*_lastOutage))];
    } else {
        _lastOutageMenuItem.title = @"Last outage: -";
    }
}

- (void)applyStatusTitle {
    NSButton *button = _statusItem.button;
    if (_emojiOnly) {
        button.attributedTitle = [[NSAttributedString alloc] initWithString:_statusIcon];
        return;
    }

    // No latency to show means the link is down (or has not been probed yet) —
    // fall back to the state emoji rather than a bare dash.
    if (!_displayLatencyMs.has_value()) {
        button.attributedTitle = [[NSAttributedString alloc] initWithString:_statusIcon];
        return;
    }

    NSString *text = [NSString stringWithFormat:@"%dms", static_cast<int>(*_displayLatencyMs)];

    NSDictionary *attributes = @{
        NSForegroundColorAttributeName: (_colorBySignal && _wifi.connected) ? signalColor(_wifi.rssiDbm) : _statusColor,
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:[NSFont systemFontSize]
                                                              weight:NSFontWeightRegular],
    };
    button.attributedTitle = [[NSAttributedString alloc] initWithString:text attributes:attributes];
}

- (void)toggleSignalColor:(__unused id)sender {
    _colorBySignal = !_colorBySignal;
    _signalColorMenuItem.state = _colorBySignal ? NSControlStateValueOn : NSControlStateValueOff;
    [self applyStatusTitle];
}

- (void)toggleView:(__unused id)sender {
    _emojiOnly = !_emojiOnly;
    _viewMenuItem.title = _emojiOnly ? @"Show latency (ms)" : @"Show emoji only";
    [self applyStatusTitle];
}

- (void)alertWithTitle:(NSString *)title message:(NSString *)message {
    if (!_muted) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            playSound();
        });
    }

    [self notifyWithTitle:title message:message];
}

- (void)notifyWithTitle:(NSString *)title message:(NSString *)message {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = message;
    content.sound = nil;

    NSString *identifier = [NSString stringWithFormat:@"dev.yu.NetWatch.%@", [[NSUUID UUID] UUIDString]];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NetWatchController *controller = [[NetWatchController alloc] init];
        (void)controller;
        [app run];
    }
    return 0;
}

#import <Cocoa/Cocoa.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreWLAN/CoreWLAN.h>
#import <UserNotifications/UserNotifications.h>

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <ifaddrs.h>
#include <net/if.h>
#include <optional>
#include <sstream>
#include <string>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr const char *AppName = "NetWatch";
constexpr const char *Version = "2.0.0";
constexpr int DefaultIntervalSeconds = 5;
constexpr int ProbeTimeoutSeconds = 1;
constexpr int FailThreshold = 2;
constexpr int OkThreshold = 1;
constexpr double FlapWindowSeconds = 60.0;
constexpr int FlapThreshold = 3;
constexpr double OutageWindowSeconds = 600.0;  // drops counted for Outage color
constexpr double PublicIpMinRefreshSeconds = 30.0;
constexpr int SpeedTestMaxSeconds = 20;

// Color thresholds. Red is reserved for "disconnected", so the worst level is orange.
constexpr double PingGoodMs = 40.0;
constexpr double PingWarnMs = 90.0;
constexpr int RssiGoodDbm = -50;
constexpr int RssiWarnDbm = -67;
constexpr int OutageGoodCount = 1;
constexpr int OutageWarnCount = 4;

// Speed labels, by download throughput.
constexpr double SpeedFastBps = 100e6;
constexpr double SpeedNormalBps = 25e6;

const std::vector<int> IntervalChoices = {1, 3, 5, 10, 20, 30, 60, 90};

enum class Level { Good, Warn, Bad };
enum class HudMode : NSInteger { Emoji = 0, Ping = 1, Rssi = 2 };
enum class ColorMode : NSInteger { Ping = 0, Outage = 1, Rssi = 2 };

NSString *const DefaultsMuted = @"muted";
NSString *const DefaultsHud = @"hudMode";
NSString *const DefaultsColor = @"colorMode";
NSString *const DefaultsInterval = @"intervalSeconds";

NSString *const IconGlobe = @"\U0001F310";
NSString *const IconGreen = @"\U0001F7E2";
NSString *const IconYellow = @"\U0001F7E1";
NSString *const IconOrange = @"\U0001F7E0";
NSString *const IconRed = @"\U0001F534";

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
    std::string ssid;  // empty without Location permission
    std::string security;
};

struct ProbeResult {
    bool online = false;
    std::optional<double> latencyMs;
    WifiReading wifi;
    std::string localIp;
};

struct SpeedResult {
    double downBps = 0;
    double upBps = 0;
};

struct OutageRecord {
    NSDate *start = nil;
    std::optional<double> duration;  // empty while still offline
};

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

NSString *ns(const std::string &value) {
    NSString *string = [NSString stringWithUTF8String:value.c_str()];
    return string != nil ? string : @"";
}

std::string str(NSString *value) {
    return value != nil ? std::string([value UTF8String]) : std::string();
}

std::string homePath() {
    return str(NSHomeDirectory());
}

std::string logPath() {
    return homePath() + "/Library/Logs/NetWatch.log";
}

NSDateFormatter *makeFormatter(NSString *format) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = format;
    return formatter;
}

std::string formatDate(NSDate *date, NSString *format) {
    return str([makeFormatter(format) stringFromDate:date]);
}

std::string timestamp() {
    return formatDate([NSDate date], @"yyyy-MM-dd HH:mm:ss");
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

// Seeds "Last outage" at launch: the newest DISCONNECTED line that has a
// RECONNECTED after it. Log lines are "yyyy-MM-dd HH:mm:ss  MESSAGE".
std::optional<OutageRecord> lastOutageFromLog(const std::string &contents) {
    NSDateFormatter *formatter = makeFormatter(@"yyyy-MM-dd HH:mm:ss");
    std::istringstream in(contents);
    std::string line;
    NSDate *pendingStart = nil;
    std::optional<OutageRecord> last;
    while (std::getline(in, line)) {
        if (line.size() < 21) {
            continue;
        }
        NSDate *when = [formatter dateFromString:ns(line.substr(0, 19))];
        if (when == nil) {
            continue;
        }
        std::string message = line.substr(21);
        if (message.rfind("DISCONNECTED", 0) == 0) {
            pendingStart = when;
        } else if (message.rfind("RECONNECTED", 0) == 0 && pendingStart != nil) {
            last = OutageRecord{pendingStart, [when timeIntervalSinceDate:pendingStart]};
            pendingStart = nil;
        }
    }
    return last;
}

Level levelForPing(double ms) {
    if (ms < PingGoodMs) return Level::Good;
    if (ms <= PingWarnMs) return Level::Warn;
    return Level::Bad;
}

Level levelForRssi(int rssiDbm) {
    if (rssiDbm >= RssiGoodDbm) return Level::Good;
    if (rssiDbm >= RssiWarnDbm) return Level::Warn;
    return Level::Bad;
}

Level levelForOutages(int drops) {
    if (drops <= OutageGoodCount) return Level::Good;
    if (drops <= OutageWarnCount) return Level::Warn;
    return Level::Bad;
}

NSColor *colorForLevel(Level level) {
    switch (level) {
        case Level::Good: return [NSColor systemGreenColor];
        case Level::Warn: return [NSColor systemYellowColor];
        case Level::Bad: return [NSColor systemOrangeColor];
    }
    return [NSColor labelColor];
}

NSString *iconForLevel(Level level) {
    switch (level) {
        case Level::Good: return IconGreen;
        case Level::Warn: return IconYellow;
        case Level::Bad: return IconOrange;
    }
    return IconGlobe;
}

// dBm is negative; closer to 0 is stronger.
const char *signalQuality(int rssiDbm) {
    if (rssiDbm >= -50) return "Excellent";
    if (rssiDbm >= -60) return "Good";
    if (rssiDbm >= -67) return "Fair";
    if (rssiDbm >= -75) return "Weak";
    return "Bad";
}

std::string securityName(CWSecurity security) {
    switch (security) {
        case kCWSecurityNone: return "Open";
        case kCWSecurityWEP: return "WEP";
        case kCWSecurityDynamicWEP: return "Dynamic WEP";
        case kCWSecurityWPAPersonal: return "WPA Personal";
        case kCWSecurityWPAPersonalMixed: return "WPA/WPA2 Personal";
        case kCWSecurityWPA2Personal: return "WPA2 Personal";
        case kCWSecurityPersonal: return "Personal";
        case kCWSecurityWPA3Personal: return "WPA3 Personal";
        case kCWSecurityWPA3Transition: return "WPA2/WPA3 Personal";
        case kCWSecurityWPAEnterprise: return "WPA Enterprise";
        case kCWSecurityWPAEnterpriseMixed: return "WPA/WPA2 Enterprise";
        case kCWSecurityWPA2Enterprise: return "WPA2 Enterprise";
        case kCWSecurityEnterprise: return "Enterprise";
        case kCWSecurityWPA3Enterprise: return "WPA3 Enterprise";
        case kCWSecurityOWE: return "Enhanced Open";
        case kCWSecurityOWETransition: return "Enhanced Open (transition)";
        default: return "Unknown";
    }
}

// Signal, noise, rate, channel and security need no permission; the SSID
// needs Location, so it comes back empty until that is granted.
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
    reading.ssid = str(wifi.ssid);
    reading.security = securityName(wifi.security);

    CWChannel *channel = wifi.wlanChannel;
    if (channel != nil) {
        reading.channel = static_cast<long>(channel.channelNumber);
        switch (channel.channelBand) {
            case kCWChannelBand2GHz: reading.band = "2.4 GHz"; break;
            case kCWChannelBand5GHz: reading.band = "5 GHz"; break;
            case kCWChannelBand6GHz: reading.band = "6 GHz"; break;
            default: break;
        }
        switch (channel.channelWidth) {
            case kCWChannelWidth20MHz: reading.width = "20 MHz"; break;
            case kCWChannelWidth40MHz: reading.width = "40 MHz"; break;
            case kCWChannelWidth80MHz: reading.width = "80 MHz"; break;
            case kCWChannelWidth160MHz: reading.width = "160 MHz"; break;
            default: break;
        }
    }
    return reading;
}

std::string wifiSummary(const WifiReading &wifi) {
    if (!wifi.connected) {
        return "Wi-Fi not connected";
    }
    return "Wi-Fi " + std::to_string(wifi.rssiDbm) + " dBm, " + signalQuality(wifi.rssiDbm);
}

// IPv4 of en0 (Wi-Fi), else the first other active non-VPN interface.
std::string localIPv4() {
    ifaddrs *list = nullptr;
    if (getifaddrs(&list) != 0) {
        return "";
    }

    std::string en0;
    std::string fallback;
    for (ifaddrs *entry = list; entry != nullptr; entry = entry->ifa_next) {
        if (entry->ifa_addr == nullptr || entry->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if (!(entry->ifa_flags & IFF_UP) || (entry->ifa_flags & IFF_LOOPBACK)) {
            continue;
        }
        std::string name = entry->ifa_name;
        if (name.rfind("utun", 0) == 0) {
            continue;
        }
        char buffer[INET_ADDRSTRLEN];
        auto *address = reinterpret_cast<sockaddr_in *>(entry->ifa_addr);
        if (inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer)) == nullptr) {
            continue;
        }
        if (name == "en0") {
            en0 = buffer;
        } else if (fallback.empty()) {
            fallback = buffer;
        }
    }
    freeifaddrs(list);
    return en0.empty() ? fallback : en0;
}

// Cloudflare's /cdn-cgi/trace body is "key=value" lines; we want "ip=".
std::string parseTraceIp(const std::string &body) {
    std::istringstream in(body);
    std::string line;
    while (std::getline(in, line)) {
        if (line.rfind("ip=", 0) == 0) {
            return line.substr(3);
        }
    }
    return "";
}

// `networkQuality -c` JSON; throughputs are bits per second.
std::optional<SpeedResult> parseSpeedTest(NSData *data) {
    if (data.length == 0) {
        return std::nullopt;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return std::nullopt;
    }
    NSDictionary *result = json;
    id down = result[@"dl_throughput"];
    id up = result[@"ul_throughput"];
    if (![down isKindOfClass:[NSNumber class]]) {
        return std::nullopt;
    }
    SpeedResult speed;
    speed.downBps = [down doubleValue];
    speed.upBps = [up isKindOfClass:[NSNumber class]] ? [up doubleValue] : 0;
    return speed;
}

std::string formatBitrate(double bitsPerSecond) {
    char buffer[32];
    if (bitsPerSecond >= 1e9) {
        std::snprintf(buffer, sizeof(buffer), "%.1f Gbps", bitsPerSecond / 1e9);
    } else {
        std::snprintf(buffer, sizeof(buffer), "%.0f Mbps", bitsPerSecond / 1e6);
    }
    return buffer;
}

const char *speedLabel(double downBps) {
    if (downBps >= SpeedFastBps) return "Fast";
    if (downBps >= SpeedNormalBps) return "Normal";
    return "Slow";
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
    ProbeResult result;
    for (const auto &target : ProbeTargets) {
        auto start = Clock::now();
        if (connectWithTimeout(target)) {
            auto elapsed = Clock::now() - start;
            result.online = true;
            result.latencyMs = std::chrono::duration<double, std::milli>(elapsed).count();
            return result;
        }
    }
    return result;
}

void pruneOlderThan(std::vector<TimePoint> &points, double seconds) {
    auto now = Clock::now();
    std::vector<TimePoint> kept;
    for (auto point : points) {
        if (std::chrono::duration<double>(now - point).count() <= seconds) {
            kept.push_back(point);
        }
    }
    points = kept;
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

@interface NetWatchController : NSObject <UNUserNotificationCenterDelegate, NSMenuDelegate, CLLocationManagerDelegate> {
    NSStatusItem *_statusItem;
    NSMenuItem *_statusRow;
    NSMenuItem *_speedRow;
    NSMenuItem *_wifiNameRow;
    NSMenuItem *_rssiRow;
    NSMenuItem *_snrRow;
    NSMenuItem *_linkRow;
    NSMenuItem *_channelRow;
    NSMenuItem *_securityRow;
    NSMenuItem *_ipRow;
    NSMenuItem *_publicIpRow;
    NSMenuItem *_lastOutageRow;
    NSMenuItem *_muteItem;
    NSMenu *_hudMenu;
    NSMenu *_colorMenu;
    NSMenu *_intervalMenu;
    NSTimer *_timer;
    CLLocationManager *_locationManager;

    std::optional<bool> _online;
    std::optional<double> _latencyMs;
    WifiReading _wifi;
    std::string _localIp;
    std::string _publicIp;
    std::optional<TimePoint> _publicIpFetchedAt;
    bool _fetchingPublicIp;
    bool _muted;
    HudMode _hud;
    ColorMode _colorMode;
    int _interval;
    bool _checking;
    int _failCount;
    int _okCount;
    std::vector<TimePoint> _transitions;
    std::vector<TimePoint> _disconnects;
    std::optional<TimePoint> _offlineSince;
    std::optional<OutageRecord> _lastOutage;
    bool _speedTesting;
    std::optional<SpeedResult> _speed;
    NSDate *_speedTestedAt;
}
@end

@implementation NetWatchController

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:@{
        DefaultsMuted: @NO,
        DefaultsHud: @(static_cast<NSInteger>(HudMode::Ping)),
        DefaultsColor: @(static_cast<NSInteger>(ColorMode::Ping)),
        DefaultsInterval: @(DefaultIntervalSeconds),
    }];
    _muted = [defaults boolForKey:DefaultsMuted];
    _hud = static_cast<HudMode>([defaults integerForKey:DefaultsHud]);
    _colorMode = static_cast<ColorMode>([defaults integerForKey:DefaultsColor]);
    _interval = static_cast<int>([defaults integerForKey:DefaultsInterval]);
    if (std::find(IntervalChoices.begin(), IntervalChoices.end(), _interval) == IntervalChoices.end()) {
        _interval = DefaultIntervalSeconds;
    }

    _checking = false;
    _fetchingPublicIp = false;
    _speedTesting = false;
    _failCount = 0;
    _okCount = 0;

    std::ifstream logFile(logPath());
    if (logFile) {
        std::stringstream contents;
        contents << logFile.rdbuf();
        _lastOutage = lastOutageFromLog(contents.str());
    }

    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    notificationCenter.delegate = self;
    [notificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(__unused BOOL granted, __unused NSError *error) {
    }];

    // Location is only used so macOS reveals the Wi-Fi name (SSID).
    _locationManager = [[CLLocationManager alloc] init];
    _locationManager.delegate = self;
    [_locationManager requestWhenInUseAuthorization];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.title = IconGlobe;
    _statusItem.menu = [self buildMenu];

    [self updateMenuStates];
    [self scheduleTimer];
    [self check:nil];
    [self refreshPublicIp:YES];

    return self;
}

- (NSMenuItem *)infoRow {
    return [[NSMenuItem alloc] initWithTitle:@"-" action:nil keyEquivalent:@""];
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action tag:(NSInteger)tag {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.tag = tag;
    return item;
}

- (NSMenuItem *)submenuItem:(NSString *)title submenu:(NSMenu *)submenu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.submenu = submenu;
    return item;
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:ns(AppName)];
    menu.delegate = self;

    _statusRow = [self infoRow];
    _speedRow = [self item:@"Speed: Click to test" action:@selector(runSpeedTest:) tag:0];
    _wifiNameRow = [self infoRow];
    _rssiRow = [self infoRow];
    _snrRow = [self infoRow];
    _linkRow = [self infoRow];
    _channelRow = [self infoRow];
    _securityRow = [self infoRow];
    _ipRow = [self infoRow];
    _publicIpRow = [self infoRow];
    _lastOutageRow = [self infoRow];

    for (NSMenuItem *row in @[_statusRow, _speedRow, _wifiNameRow]) {
        [menu addItem:row];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    for (NSMenuItem *row in @[_rssiRow, _snrRow, _linkRow, _channelRow, _securityRow, _ipRow, _publicIpRow, _lastOutageRow]) {
        [menu addItem:row];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    _muteItem = [self item:@"Mute sound" action:@selector(toggleMute:) tag:0];
    [menu addItem:_muteItem];

    _hudMenu = [[NSMenu alloc] initWithTitle:@"HUD"];
    [_hudMenu addItem:[self item:@"Emoji" action:@selector(selectHud:) tag:static_cast<NSInteger>(HudMode::Emoji)]];
    [_hudMenu addItem:[self item:@"Ping" action:@selector(selectHud:) tag:static_cast<NSInteger>(HudMode::Ping)]];
    [_hudMenu addItem:[self item:@"RSSI" action:@selector(selectHud:) tag:static_cast<NSInteger>(HudMode::Rssi)]];
    [menu addItem:[self submenuItem:@"HUD" submenu:_hudMenu]];

    _colorMenu = [[NSMenu alloc] initWithTitle:@"Color"];
    [_colorMenu addItem:[self item:@"Ping" action:@selector(selectColor:) tag:static_cast<NSInteger>(ColorMode::Ping)]];
    [_colorMenu addItem:[self item:@"Outage" action:@selector(selectColor:) tag:static_cast<NSInteger>(ColorMode::Outage)]];
    [_colorMenu addItem:[self item:@"RSSI" action:@selector(selectColor:) tag:static_cast<NSInteger>(ColorMode::Rssi)]];
    [menu addItem:[self submenuItem:@"Color" submenu:_colorMenu]];

    _intervalMenu = [[NSMenu alloc] initWithTitle:@"Update interval"];
    for (int seconds : IntervalChoices) {
        [_intervalMenu addItem:[self item:[NSString stringWithFormat:@"%d sec", seconds] action:@selector(selectInterval:) tag:seconds]];
    }
    [menu addItem:[self submenuItem:@"Update interval" submenu:_intervalMenu]];

    [menu addItem:[self item:@"Open log" action:@selector(openLog:) tag:0]];
    NSMenu *clearMenu = [[NSMenu alloc] initWithTitle:@"Clear log"];
    [clearMenu addItem:[self item:@"Sure?" action:@selector(clearLog:) tag:0]];
    [menu addItem:[self submenuItem:@"Clear log" submenu:clearMenu]];

    [menu addItem:[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%s v%s", AppName, Version] action:nil keyEquivalent:@""]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [menu addItem:quitItem];
    return menu;
}

- (void)updateMenuStates {
    _muteItem.state = _muted ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSMenuItem *item in _hudMenu.itemArray) {
        item.state = item.tag == static_cast<NSInteger>(_hud) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    for (NSMenuItem *item in _colorMenu.itemArray) {
        item.state = item.tag == static_cast<NSInteger>(_colorMode) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    for (NSMenuItem *item in _intervalMenu.itemArray) {
        item.state = item.tag == _interval ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)scheduleTimer {
    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:_interval target:self selector:@selector(check:) userInfo:nil repeats:YES];
}

// Opening the menu refreshes immediately so the rows are current.
- (void)menuWillOpen:(__unused NSMenu *)menu {
    [self check:nil];
    [self refreshPublicIp:NO];
}

- (void)locationManagerDidChangeAuthorization:(__unused CLLocationManager *)manager {
    [self check:nil];
}

- (void)toggleMute:(id)sender {
    _muted = !_muted;
    [[NSUserDefaults standardUserDefaults] setBool:_muted forKey:DefaultsMuted];
    [self updateMenuStates];
}

- (void)selectHud:(NSMenuItem *)sender {
    _hud = static_cast<HudMode>(sender.tag);
    [[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:DefaultsHud];
    [self updateMenuStates];
    [self applyStatusTitle];
}

- (void)selectColor:(NSMenuItem *)sender {
    _colorMode = static_cast<ColorMode>(sender.tag);
    [[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:DefaultsColor];
    [self updateMenuStates];
    [self applyStatusTitle];
}

- (void)selectInterval:(NSMenuItem *)sender {
    _interval = static_cast<int>(sender.tag);
    [[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:DefaultsInterval];
    [self updateMenuStates];
    [self scheduleTimer];
    [self check:nil];
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
        result.localIp = localIPv4();
        dispatch_async(dispatch_get_main_queue(), ^{
            NetWatchController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf consumeProbeResult:result];
            }
        });
    });
}

- (void)consumeProbeResult:(ProbeResult)result {
    _checking = false;
    _latencyMs = result.latencyMs;
    _wifi = result.wifi;
    _localIp = result.localIp;

    if (result.online) {
        _okCount += 1;
        _failCount = 0;
        if ((!_online.has_value() || *_online != true) && _okCount >= OkThreshold) {
            [self setOnline:true];
        }
    } else {
        _failCount += 1;
        _okCount = 0;
        if ((!_online.has_value() || *_online != false) && _failCount >= FailThreshold) {
            [self setOnline:false];
        }
    }

    [self updateDisplay];
}

- (void)setOnline:(bool)online {
    std::optional<bool> was = _online;
    _online = online;

    if (!online) {
        _offlineSince = Clock::now();
        _lastOutage = OutageRecord{[NSDate date], std::nullopt};
    }

    if (!was.has_value()) {
        return;
    }

    _transitions.push_back(Clock::now());

    if (online) {
        std::string message = "You are back online.";
        if (_offlineSince.has_value()) {
            double duration = std::chrono::duration<double>(Clock::now() - *_offlineSince).count();
            if (_lastOutage.has_value()) {
                _lastOutage->duration = duration;
            }
            _offlineSince.reset();
            message = "Offline for " + formatDuration(duration) + ".";
        }
        logEvent("RECONNECTED (" + message + ")");
        [self alertWithTitle:@"Network restored" message:ns(message)];
        [self refreshPublicIp:YES];
    } else {
        _disconnects.push_back(Clock::now());
        // Wi-Fi state at the drop: a strong signal while offline points at the
        // router or ISP, a lost or weak one points at Wi-Fi.
        logEvent("DISCONNECTED (" + wifiSummary(_wifi) + ")");
        [self alertWithTitle:@"Network disconnected" message:@"Your connection just dropped."];
    }
}

- (Level)currentLevel {
    switch (_colorMode) {
        case ColorMode::Ping:
            return _latencyMs.has_value() ? levelForPing(*_latencyMs) : Level::Good;
        case ColorMode::Outage:
            return levelForOutages(static_cast<int>(_disconnects.size()));
        case ColorMode::Rssi:
            return _wifi.connected ? levelForRssi(_wifi.rssiDbm) : Level::Good;
    }
    return Level::Good;
}

- (void)updateDisplay {
    pruneOlderThan(_transitions, FlapWindowSeconds);
    pruneOlderThan(_disconnects, OutageWindowSeconds);

    int flaps = static_cast<int>(_transitions.size());
    int drops = static_cast<int>(_disconnects.size());

    NSString *icon = IconGlobe;
    NSString *status = @"Starting...";
    if (_online.has_value() && *_online == false) {
        icon = IconRed;
        status = @"Disconnected";
    } else if (_online.has_value() && flaps >= FlapThreshold) {
        icon = IconOrange;
        status = [NSString stringWithFormat:@"Unstable (%d drops / 10 min)", drops];
    } else if (_online.has_value()) {
        icon = IconGreen;
        status = @"Connected";
    }
    _statusRow.title = [NSString stringWithFormat:@"%@ Status: %@", icon, status];

    [self updateSpeedRow];

    if (_wifi.connected) {
        NSString *name = nil;
        if (!_wifi.ssid.empty()) {
            name = ns(_wifi.ssid);
        } else {
            CLAuthorizationStatus access = _locationManager.authorizationStatus;
            bool allowed = access == kCLAuthorizationStatusAuthorizedAlways;
            name = allowed ? @"(name unavailable)" : @"Allow Location to show name";
        }
        _wifiNameRow.title = [NSString stringWithFormat:@"Wi-Fi: %@", name];
        _rssiRow.title = [NSString stringWithFormat:@"RSSI: %d dBm (%s)", _wifi.rssiDbm, signalQuality(_wifi.rssiDbm)];
        _snrRow.title = [NSString stringWithFormat:@"SNR: %d dB", _wifi.rssiDbm - _wifi.noiseDbm];
        _linkRow.title = [NSString stringWithFormat:@"Link: %d Mbps", _wifi.txRateMbps];

        std::string channel = std::to_string(_wifi.channel);
        std::string detail = _wifi.band;
        if (!_wifi.width.empty()) {
            detail += (detail.empty() ? "" : ", ") + _wifi.width;
        }
        if (!detail.empty()) {
            channel += " (" + detail + ")";
        }
        _channelRow.title = [NSString stringWithFormat:@"Channel: %@", ns(channel)];
        _securityRow.title = [NSString stringWithFormat:@"Security: %@", ns(_wifi.security)];
    } else {
        _wifiNameRow.title = @"Wi-Fi: Not connected";
        _rssiRow.title = @"RSSI: -";
        _snrRow.title = @"SNR: -";
        _linkRow.title = @"Link: -";
        _channelRow.title = @"Channel: -";
        _securityRow.title = @"Security: -";
    }

    _ipRow.title = [NSString stringWithFormat:@"IP: %@", _localIp.empty() ? @"-" : ns(_localIp)];
    _publicIpRow.title = [NSString stringWithFormat:@"Public IP: %@", _publicIp.empty() ? @"-" : ns(_publicIp)];

    if (!_lastOutage.has_value()) {
        _lastOutageRow.title = @"Last outage: -";
    } else {
        std::string when = formatDate(_lastOutage->start, @"MM/dd HH:mm:ss");
        std::string length = _lastOutage->duration.has_value() ? formatDuration(*_lastOutage->duration) : "ongoing";
        _lastOutageRow.title = [NSString stringWithFormat:@"Last outage: %@ (%@)", ns(when), ns(length)];
    }

    [self applyStatusTitle];
}

- (void)updateSpeedRow {
    if (_speedTesting) {
        _speedRow.title = [NSString stringWithFormat:@"Speed: Testing... (up to %ds)", SpeedTestMaxSeconds];
    } else if (_speed.has_value()) {
        _speedRow.title = [NSString stringWithFormat:@"Speed: %s · %@ ↓ / %@ ↑ (tested %@)",
                           speedLabel(_speed->downBps), ns(formatBitrate(_speed->downBps)),
                           ns(formatBitrate(_speed->upBps)), ns(formatDate(_speedTestedAt, @"HH:mm"))];
    } else {
        _speedRow.title = @"Speed: Click to test";
    }
}

// Runs macOS's built-in speed test. It downloads real data, so only on click.
- (void)runSpeedTest:(id)sender {
    if (_speedTesting) {
        return;
    }
    _speedTesting = true;
    [self updateSpeedRow];

    __weak NetWatchController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/networkQuality"];
        task.arguments = @[@"-c", @"-s", @"-M", [NSString stringWithFormat:@"%d", SpeedTestMaxSeconds]];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];

        std::optional<SpeedResult> result;
        if ([task launchAndReturnError:nil]) {
            NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            result = parseSpeedTest(data);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NetWatchController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_speedTesting = false;
            if (result.has_value()) {
                strongSelf->_speed = result;
                strongSelf->_speedTestedAt = [NSDate date];
            } else {
                [strongSelf notifyWithTitle:@"Speed test failed" message:@"Could not measure speed. Try again when online."];
            }
            [strongSelf updateSpeedRow];
        });
    });
}

- (void)refreshPublicIp:(BOOL)force {
    if (_fetchingPublicIp) {
        return;
    }
    if (!force && _publicIpFetchedAt.has_value() &&
        std::chrono::duration<double>(Clock::now() - *_publicIpFetchedAt).count() < PublicIpMinRefreshSeconds) {
        return;
    }
    _fetchingPublicIp = true;

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 5;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    __weak NetWatchController *weakSelf = self;
    NSURL *url = [NSURL URLWithString:@"https://1.1.1.1/cdn-cgi/trace"];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        std::string ip;
        if (data.length > 0) {
            ip = parseTraceIp(std::string(static_cast<const char *>(data.bytes), data.length));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NetWatchController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_fetchingPublicIp = false;
            strongSelf->_publicIpFetchedAt = Clock::now();
            if (!ip.empty()) {
                strongSelf->_publicIp = ip;
            }
            [strongSelf updateDisplay];
        });
    }];
    [task resume];
    [session finishTasksAndInvalidate];
}

// HUD: disconnected is always 🔴; otherwise the selected Color metric picks
// the dot color (Emoji) or tints the number (Ping / RSSI).
- (void)applyStatusTitle {
    NSButton *button = _statusItem.button;
    if (!_online.has_value()) {
        button.attributedTitle = [[NSAttributedString alloc] initWithString:IconGlobe];
        return;
    }
    if (*_online == false) {
        button.attributedTitle = [[NSAttributedString alloc] initWithString:IconRed];
        return;
    }

    Level level = [self currentLevel];
    NSString *text = nil;
    if (_hud == HudMode::Ping && _latencyMs.has_value()) {
        text = [NSString stringWithFormat:@"%dms", static_cast<int>(*_latencyMs)];
    } else if (_hud == HudMode::Rssi && _wifi.connected) {
        text = [NSString stringWithFormat:@"%ddBm", _wifi.rssiDbm];
    }

    if (text == nil) {
        button.attributedTitle = [[NSAttributedString alloc] initWithString:iconForLevel(level)];
        return;
    }

    NSDictionary *attributes = @{
        NSForegroundColorAttributeName: colorForLevel(level),
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:[NSFont systemFontSize]
                                                              weight:NSFontWeightRegular],
    };
    button.attributedTitle = [[NSAttributedString alloc] initWithString:text attributes:attributes];
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

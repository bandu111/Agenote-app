#import "SoniNoteBridge.h"
#import "PNode.h"
#import <CoreBluetooth/CoreBluetooth.h>

@interface SoniNoteAudioHandler : NSObject <FlutterStreamHandler>
@property(nonatomic, copy) FlutterEventSink sink;
@property(nonatomic) NSUInteger sequence;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) void (^onSubscriptionChanged)(void);
@end
@implementation SoniNoteAudioHandler
- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events { self.generation++; self.sequence = 0; self.sink = events; if (self.onSubscriptionChanged) self.onSubscriptionChanged(); return nil; }
- (FlutterError *)onCancelWithArguments:(id)arguments { self.generation++; self.sink = nil; if (self.onSubscriptionChanged) self.onSubscriptionChanged(); return nil; }
@end

@interface SoniNoteBridge () <FlutterStreamHandler, CBCentralManagerDelegate, WindBleDelegate>
@property(nonatomic, strong) FlutterMethodChannel *methods;
@property(nonatomic, strong) FlutterEventChannel *events;
@property(nonatomic, strong) FlutterEventChannel *audioEvents;
@property(nonatomic, strong) SoniNoteAudioHandler *audioHandler;
@property(nonatomic) NSInteger audioQueued;
@property(nonatomic, copy) FlutterEventSink sink;
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *discovered;
@property(nonatomic, copy) NSString *deviceId;
@property(nonatomic, copy) NSString *lastButton;
@property(nonatomic, copy) NSString *lastRecordingState;
@property(nonatomic) NSTimeInterval lastButtonAt;
@property(nonatomic) NSInteger epoch;
@property(nonatomic) BOOL connected;
@property(nonatomic) BOOL recovering;
@property(nonatomic) BOOL scanning;
@property(nonatomic) NSInteger scanRevision;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL initialized;
@property(nonatomic) BOOL appForeground;
@end

@implementation SoniNoteBridge
- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
    if ((self = [super init])) {
        _discovered = [NSMutableDictionary dictionary];
        _lastRecordingState = @"unknown";
        _appForeground = YES;
        _methods = [FlutterMethodChannel methodChannelWithName:@"yanshu/soninote" binaryMessenger:messenger];
        _events = [FlutterEventChannel eventChannelWithName:@"yanshu/soninote/events" binaryMessenger:messenger];
        [_events setStreamHandler:self];
        _audioHandler = [SoniNoteAudioHandler new];
        _audioEvents = [FlutterEventChannel eventChannelWithName:@"yanshu/soninote/audio" binaryMessenger:messenger];
        [_audioEvents setStreamHandler:_audioHandler];
        __weak SoniNoteBridge *weakSelf = self;
        _audioHandler.onSubscriptionChanged = ^{ [weakSelf reportAppState]; };
        [_methods setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
            [weakSelf handle:call result:result];
        }];
    }
    return self;
}
- (void)ensureCentral {
    if (!self.central) self.central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()
        options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
}
- (void)ensureSDK {
    if (!self.initialized) {
        [PNode setShowLog:NO];
        [PNode Shared].delegate = self;
        self.initialized = YES;
    }
}
- (BOOL)authorized { return CBCentralManager.authorization == CBManagerAuthorizationAllowedAlways; }
- (void)reportAppState {
    if (self.initialized && self.connected && !self.closed)
        [[PNode Shared] sendAppShowState:(self.appForeground || self.audioHandler.sink) ? 1 : 2];
}
- (NSString *)authorizationStatus {
    switch (CBCentralManager.authorization) {
        case CBManagerAuthorizationAllowedAlways: return @"authorized";
        case CBManagerAuthorizationDenied: return @"denied";
        case CBManagerAuthorizationRestricted: return @"restricted";
        default: return @"not_determined";
    }
}
- (NSString *)bluetoothState {
    if (!self.central) return @"unknown";
    switch (self.central.state) {
        case CBManagerStatePoweredOn: return @"powered_on";
        case CBManagerStatePoweredOff: return @"powered_off";
        case CBManagerStateUnauthorized: return @"unauthorized";
        case CBManagerStateUnsupported: return @"unsupported";
        case CBManagerStateResetting: return @"resetting";
        default: return @"unknown";
    }
}
- (void)status {
    if ([self authorized]) [self ensureCentral];
    [self emit:@"bluetooth" data:@{@"authorized": @([self authorized]),
        @"enabled": @( (BOOL)(self.central != nil && self.central.state == CBManagerStatePoweredOn) ),
        @"state": [self bluetoothState], @"authorization": [self authorizationStatus]} global:YES id:nil];
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self status];
    // Warm the SDK's own central manager before the user opens the scan sheet.
    if (central.state == CBManagerStatePoweredOn && [self authorized]) [self ensureSDK];
    if (central.state == CBManagerStatePoweredOff || central.state == CBManagerStateUnauthorized ||
        central.state == CBManagerStateUnsupported || central.state == CBManagerStateResetting) {
        self.scanning = NO;
        if (self.deviceId) [self emit:@"connection" data:@{@"connected": @NO} global:NO id:self.deviceId];
        self.connected = NO; self.recovering = NO; self.deviceId = nil;
    }
}
- (FlutterError *)failure:(NSString *)code message:(NSString *)message {
    return [FlutterError errorWithCode:code message:message details:nil];
}
- (void)handle:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (self.closed) { result([self failure:@"sdk_closed" message:@"设备服务已关闭"]); return; }
    if ([call.method isEqualToString:@"requestPermissions"]) {
        if (CBCentralManager.authorization == CBManagerAuthorizationDenied ||
            CBCentralManager.authorization == CBManagerAuthorizationRestricted) {
            result([self failure:@"permission_denied" message:@"请在系统设置中允许蓝牙权限后重试"]); return;
        }
        [self ensureCentral]; [self status]; result(nil); return;
    }
    if ([call.method isEqualToString:@"status"]) { [self status]; result(nil); return; }
    if (![self authorized]) { result([self failure:@"permission_denied" message:@"请允许蓝牙权限"]); return; }
    [self ensureCentral];
    if (self.central.state != CBManagerStatePoweredOn) {
        [self status];
        NSString *code = @"bluetooth_initializing", *message = @"蓝牙状态确认中，请稍候重试";
        switch (self.central.state) {
            case CBManagerStatePoweredOff: code = @"bluetooth_off"; message = @"请开启系统蓝牙"; break;
            case CBManagerStateUnauthorized: code = @"permission_denied"; message = @"请在系统设置中允许蓝牙权限后重试"; break;
            case CBManagerStateUnsupported: code = @"bluetooth_unsupported"; message = @"当前设备不支持蓝牙连接"; break;
            default: break;
        }
        result([self failure:code message:message]); return;
    }
    [self ensureSDK];
    PNode *sdk = [PNode Shared];
    NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
    NSString *method = call.method;
    if ([method isEqualToString:@"startScan"]) {
        if (self.deviceId || self.recovering) { result([self failure:@"connection_busy" message:@"请等待连接操作完成"]); return; }
        self.scanRevision++; [self.discovered removeAllObjects]; self.scanning = YES; [sdk startSearch];
    } else if ([method isEqualToString:@"stopScan"]) { self.scanRevision++; self.scanning = NO; [sdk stopSearch];
    } else if ([method isEqualToString:@"connect"]) {
        NSString *identifier = args[@"device_id"];
        NSString *name = self.discovered[identifier ?: @""];
        if (self.deviceId || self.recovering || !name) { result([self failure:@"connection_busy" message:@"请重新扫描并等待连接操作完成"]); return; }
        self.epoch = [args[@"epoch"] integerValue]; self.deviceId = identifier;
        self.connected = NO; self.scanning = NO; self.lastButton = nil; self.lastRecordingState = @"unknown";
        [sdk stopSearch]; [sdk connectDeviceAndAddress:name :identifier];
    } else if ([method isEqualToString:@"disconnect"]) {
        self.recovering = YES; self.scanning = NO; [sdk stopSearch]; [sdk closeConnect];
    } else {
        if (!self.connected || self.recovering) { result([self failure:@"device_disconnected" message:@"设备未连接"]); return; }
        if ([method isEqualToString:@"syncTime"]) [sdk syncTime];
        else if ([method isEqualToString:@"battery"]) [sdk getCBC];
        else if ([method isEqualToString:@"capacity"]) [sdk getDeviceCapacity];
        else if ([method isEqualToString:@"firmware"]) [sdk getDeviceVersion];
        else if ([method isEqualToString:@"firmwareCode"]) [sdk getDeviceVersionCode];
        else if ([method isEqualToString:@"listFiles"]) [sdk getRecordFileList];
        else if ([method isEqualToString:@"downloadFile"]) {
            NSDictionary *args = call.arguments;
            NSString *name = args[@"name"];
            NSInteger offset = [args[@"offset"] integerValue];
            if (![self.lastRecordingState isEqualToString:@"idle"] || ![name isKindOfClass:NSString.class] || name.length == 0 || offset < 0) {
                result([FlutterError errorWithCode:@"file_unavailable" message:@"请先停止录音并检查文件" details:nil]); return;
            }
            [sdk startGetFile:name :[NSString stringWithFormat:@"%ld", (long)offset]];
        }
        else if ([method isEqualToString:@"stopDownload"]) [sdk stopGetFile:call.arguments[@"name"]];
        else if ([method isEqualToString:@"serial"]) [sdk getSn];
        else if ([method isEqualToString:@"recording"]) [sdk getRecordState];
        else if ([method isEqualToString:@"duration"]) [sdk getTimeOnlyRecording];
        else if ([method isEqualToString:@"startRecording"]) [sdk startRecord];
        else if ([method isEqualToString:@"pauseRecording"]) [sdk pauseRecord];
        else if ([method isEqualToString:@"resumeRecording"]) [sdk continueRecord];
        else if ([method isEqualToString:@"stopRecording"]) [sdk stopRecord];
        else if ([method isEqualToString:@"foreground"]) { self.appForeground = [call.arguments boolValue]; [self reportAppState]; }
        else { result(FlutterMethodNotImplemented); return; }
    }
    result(nil); // Submitted only; all state confirmation arrives via delegate.
}
- (void)emit:(NSString *)type data:(NSDictionary *)data global:(BOOL)global id:(NSString *)identifier {
    if (self.closed || !self.sink) return;
    self.sink(@{@"event_type": type, @"epoch": global ? @0 : @(self.epoch),
        @"device_id": identifier ?: NSNull.null, @"data": data,
        @"timestamp": [[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date]});
}
- (void)deviceDataEvent:(NSString *)text {
    NSInteger generation = self.epoch;
    NSInteger scanGeneration = self.scanRevision;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed || generation != self.epoch || text.length > 4096) return;
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![root isKindOfClass:NSDictionary.class]) return;
        NSString *cmd = [root[@"cmd"] description];
        if (![@[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"10", @"13", @"17", @"18"] containsObject:cmd]) {
            if (self.connected && cmd.length > 0 && cmd.length <= 3 &&
                [cmd rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound)
                [self emit:@"diagnostic" data:@{@"code": [@"unsupported_sdk_event_" stringByAppendingString:cmd]} global:NO id:self.deviceId];
            return;
        }
        NSDictionary *data = [root[@"data"] isKindOfClass:NSDictionary.class] ? root[@"data"] : @{};
        if (root[@"state"] && ![[root[@"state"] description] isEqualToString:@"0"]) {
            if ([cmd isEqualToString:@"2"]) {
                [self emit:@"connection" data:@{@"connected": @NO} global:NO id:self.deviceId];
                self.connected = NO; self.deviceId = nil; self.recovering = NO;
            } else [self emit:@"error" data:@{@"code": [@"sdk_response_" stringByAppendingString:cmd], @"message": @"设备响应失败，请刷新状态"} global:[cmd isEqualToString:@"1"] id:self.deviceId];
            return;
        }
        if ([cmd isEqualToString:@"4"]) {
            NSArray *items = [root[@"data"] isKindOfClass:NSArray.class] ? root[@"data"] : @[];
            NSData *json = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
            [self emit:@"files" data:@{@"items": [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding], @"finish": [root[@"finish"] description] ?: @""} global:NO id:self.deviceId];
            return;
        }
        if ([cmd isEqualToString:@"5"]) {
            [self emit:@"file_state" data:@{@"state": [data[@"record_file_state"] description] ?: @"", @"name": [data[@"name"] description] ?: @""} global:NO id:self.deviceId];
            return;
        }
        if ([cmd isEqualToString:@"1"]) {
            if (scanGeneration != self.scanRevision) return;
            NSString *name = [data[@"name"] isKindOfClass:NSString.class] ? data[@"name"] : @"";
            // Use the SDK address/identifier as-is. Never invent an iOS MAC address.
            NSString *identifier = [data[@"address"] isKindOfClass:NSString.class] ? data[@"address"] : @"";
            NSString *upper = [[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
            NSString *product = [[data[@"productType"] description] uppercaseString];
            BOOL compatible = [upper hasPrefix:@"CB08"] || [upper hasPrefix:@"SONINOTE"] ||
                [upper hasPrefix:@"V544"] || [upper hasPrefix:@"AI VOICE"] ||
                [product isEqualToString:@"CB08"] || [product isEqualToString:@"V544"];
            if (!self.scanning) return;
            if (!compatible || identifier.length == 0 || [@[@"null", @"<null>"] containsObject:identifier]) {
                [self emit:@"diagnostic" data:@{@"code": compatible ? @"scan_missing_identifier" : @"scan_filtered_product"} global:YES id:nil];
                return;
            }
            self.discovered[identifier] = name;
            [self emit:@"discovered" data:@{@"name": name, @"productType": [data[@"productType"] description] ?: @""} global:YES id:identifier];
            return;
        }
        if (!self.deviceId) return;
        if ([cmd isEqualToString:@"2"]) {
            NSString *identifier = [data[@"address"] description];
            if (identifier.length && ![@[@"null", @"<null>", self.deviceId] containsObject:identifier]) return;
            BOOL yes = [@[@"1", @"true"] containsObject:[data[@"connect_state"] description]];
            if (yes && self.recovering) { [[PNode Shared] closeConnect]; return; }
            self.connected = yes;
            [self emit:@"connection" data:@{@"connected": @(yes)} global:NO id:self.deviceId];
            if (!yes) { self.recovering = NO; self.deviceId = nil; }
            return;
        }
        if (!self.connected || self.recovering) return;
        if ([cmd isEqualToString:@"3"] || [cmd isEqualToString:@"9"]) {
            BOOL query = [cmd isEqualToString:@"9"];
            NSString *number = [data[query ? @"recordState" : @"record_state"] description];
            NSString *state = @"unknown";
            if (query) {
                if ([number isEqualToString:@"1"]) state = @"recording";
                else if ([number isEqualToString:@"2"]) state = [self.lastRecordingState isEqualToString:@"paused"] ? @"paused" : @"idle";
            } else {
                state = @{@"0": @"idle", @"1": @"recording", @"2": @"paused"}[number] ?: @"unknown";
                self.lastRecordingState = state; self.lastButton = nil;
            }
            if (query && [self.lastRecordingState isEqualToString:@"unknown"]) self.lastRecordingState = state;
            [self emit:@"recording" data:@{@"state": state, @"query": @(query),
                @"saved": @((BOOL)(!query && [state isEqualToString:@"idle"])), @"fileName": [data[@"fileName"] description] ?: @""} global:NO id:self.deviceId];
        } else if ([cmd isEqualToString:@"8"]) {
            NSString *button = [data[@"event"] description];
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            // Diagnostic observation only: repeated SDK messages are not proof
            // of two physical presses. Preserve the existing ACK/state flow.
            [self emit:@"button_observed" data:@{@"button": button,
                @"atMs": @((long long)(now * 1000))} global:NO id:self.deviceId];
            if ([button isEqualToString:self.lastButton] && now - self.lastButtonAt < 1.2) return;
            self.lastButton = button; self.lastButtonAt = now;
            PNode *sdk = [PNode Shared];
            if ([button isEqualToString:@"1"]) [sdk startBtnBackRecord];
            else if ([button isEqualToString:@"3"]) [sdk stopBtnBackRecord];
            else if ([button isEqualToString:@"5"]) [sdk pauseBtnBackRecord];
            else if ([button isEqualToString:@"7"]) [sdk continueBtnBackRecord];
            else return;
            [self emit:@"button" data:@{@"button": button} global:NO id:self.deviceId];
        } else {
            NSDictionary *types = @{@"6": @"battery", @"7": @"serial", @"13": @"capacity", @"17": @"firmware", @"18": @"firmware_code", @"10": @"duration"};
            NSDictionary *keys = @{@"6": @[@"cbc"], @"7": @[@"sn"], @"13": @[@"totalSpace", @"residueSpace"], @"17": @[@"version"], @"18": @[@"versionCode"], @"10": @[@"recordTime"]};
            NSMutableDictionary *safe = [NSMutableDictionary dictionary];
            for (NSString *key in keys[cmd]) safe[key] = [data[key] description] ?: NSNull.null;
            if (types[cmd]) [self emit:types[cmd] data:safe global:NO id:self.deviceId];
        }
    });
}
- (void)deviceRecordData:(NSData *)data {
    if (!data.length || self.closed || !self.audioHandler.sink) return;
    // SDK callback queues are not guaranteed. Bound queued audio before handing
    // it to the Flutter platform thread; never put audio on the status channel.
    @synchronized (self) {
        if (self.audioQueued >= 128 || data.length > 4096) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.audioHandler.sink) {
                    self.audioHandler.sink([FlutterError errorWithCode:@"audio_overrun" message:@"录音卡音频接收积压，请重新连接" details:nil]);
                    self.audioHandler.sink = nil;
                }
            });
            return;
        }
        self.audioQueued++;
    }
    NSInteger generation = self.epoch;
    NSUInteger audioGeneration = self.audioHandler.generation;
    NSData *copy = [data copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) { self.audioQueued--; }
        if (!self.closed && self.connected && generation == self.epoch && audioGeneration == self.audioHandler.generation && self.audioHandler.sink) {
            self.audioHandler.sink(@{@"epoch": @(generation), @"device_id": self.deviceId ?: @"",
                @"sequence": @(self.audioHandler.sequence++), @"bytes": [FlutterStandardTypedData typedDataWithBytes:copy]});
        }
    });
}
- (void)deviceFileData:(NSData *)data {
    if (data.length == 0) return;
    NSInteger generation = self.epoch;
    NSData *copy = [data copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.closed && self.connected && generation == self.epoch)
            [self emit:@"file_bytes" data:@{@"bytes": [FlutterStandardTypedData typedDataWithBytes:copy]} global:NO id:self.deviceId];
    });
}
- (void)logInfo:(NSString *)log {} // Never forward raw SDK logs, identity or authorization data.
- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events { self.sink = events; [self status]; return nil; }
- (FlutterError *)onCancelWithArguments:(id)arguments { self.sink = nil; return nil; }
- (void)close {
    if (self.initialized) { [[PNode Shared] stopSearch]; [[PNode Shared] closeConnect]; [PNode Shared].delegate = nil; }
    self.closed = YES; self.sink = nil; self.central.delegate = nil;
    self.audioHandler.sink = nil; [self.audioEvents setStreamHandler:nil];
    self.audioHandler.onSubscriptionChanged = nil;
    [self.methods setMethodCallHandler:nil]; [self.events setStreamHandler:nil];
}
@end

//
//  AppDelegate.m
//  Lookin
//
//  Created by Li Kai on 2018/8/4.
//  https://lookin.work
//

#import "AppDelegate.h"
#import "LKNavigationManager.h"
#import "LKConnectionManager.h"
#import "LKPreferenceManager.h"
#import "LKAppMenuManager.h"
#import "LKLaunchWindowController.h"
#import "LKAppsManager.h"
#import "LKInspectableApp.h"
#import "LookinDocument.h"
#import "NSString+Score.h"
#import "LookinDashboardBlueprint.h"
#import "LKPreferenceManager.h"
@import AppCenter;
@import AppCenterAnalytics;
@import AppCenterCrashes;

static NSString * const LKCLIUSBRootCommand = @"usb";
static NSString * const LKCLIOptionBundleID = @"--bundle-id";
static NSString * const LKCLIOptionDeviceName = @"--device-name";
static NSString * const LKCLIOptionLocalPath = @"--local-path";
static NSString * const LKCLIOptionRemotePath = @"--remote-path";
static NSString * const LKCLIOptionTimeout = @"--timeout";
static NSString * const LKCLIOptionNoOverwrite = @"--no-overwrite";
static NSString * const LKCLIOptionNoCreateDirectories = @"--no-mkdir";
static NSString * const LKCLIFileTransferContentKey = @"content";
static NSString * const LKCLIFileTransferRemotePathKey = @"remotePath";
static NSTimeInterval const LKCLIUSBDefaultTimeout = 15;
static NSTimeInterval const LKCLIUSBPollInterval = 1;

typedef NS_ENUM(NSUInteger, LKCLIUSBCommandType) {
    LKCLIUSBCommandTypeHelp,
    LKCLIUSBCommandTypeListApps,
    LKCLIUSBCommandTypePushFile,
    LKCLIUSBCommandTypePullFile
};

static NSString * LKCLIUSBUsageText(void) {
    return @"Usage:\n"
    "  LookinClient usb list-apps [--timeout <seconds>]\n"
    "  LookinClient usb push-file --bundle-id <bundle-id> --local-path <mac-path> --remote-path <sandbox-relative-path> [--device-name <device-name>] [--timeout <seconds>] [--no-overwrite] [--no-mkdir]\n"
    "  LookinClient usb pull-file --bundle-id <bundle-id> --remote-path <sandbox-relative-path> --local-path <mac-path> [--device-name <device-name>] [--timeout <seconds>]\n"
    "\n"
    "Examples:\n"
    "  LookinClient usb list-apps\n"
    "  LookinClient usb push-file --bundle-id com.example.demo --local-path ~/Desktop/config.json --remote-path Documents/config.json\n"
    "  LookinClient usb pull-file --bundle-id com.example.demo --remote-path Library/Caches/state.bin --local-path ~/Desktop/state.bin";
}

static void LKCLIWriteLine(NSString *text, BOOL standardError) {
    FILE *stream = standardError ? stderr : stdout;
    fprintf(stream, "%s\n", text.UTF8String);
    fflush(stream);
}

static NSError * LKCLIMakeError(NSString *description, NSString *recovery) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = description;
    if (recovery.length) {
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = recovery;
    }
    return [NSError errorWithDomain:@"LookinCLIErrorDomain" code:1 userInfo:userInfo];
}

@interface LKCLIUSBInvocation : NSObject

@property(nonatomic, assign) LKCLIUSBCommandType commandType;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, copy) NSString *deviceName;
@property(nonatomic, copy) NSString *localPath;
@property(nonatomic, copy) NSString *remotePath;
@property(nonatomic, assign) NSTimeInterval timeout;
@property(nonatomic, assign) BOOL overwrite;
@property(nonatomic, assign) BOOL createIntermediateDirectories;

+ (nullable instancetype)invocationWithArguments:(NSArray<NSString *> *)arguments
                               errorDescription:(NSString * __autoreleasing _Nullable * _Nullable)errorDescription;

@end

@implementation LKCLIUSBInvocation

+ (nullable instancetype)invocationWithArguments:(NSArray<NSString *> *)arguments
                               errorDescription:(NSString * __autoreleasing _Nullable * _Nullable)errorDescription {
    if (arguments.count <= 1) {
        return nil;
    }
    NSArray<NSString *> *tokens = [arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)];
    if (![tokens.firstObject isEqualToString:LKCLIUSBRootCommand]) {
        return nil;
    }
    if (tokens.count == 1) {
        if (errorDescription) {
            *errorDescription = LKCLIUSBUsageText();
        }
        return nil;
    }
    
    LKCLIUSBInvocation *invocation = [[self alloc] init];
    invocation.timeout = LKCLIUSBDefaultTimeout;
    invocation.overwrite = YES;
    invocation.createIntermediateDirectories = YES;
    
    NSString *subcommand = tokens[1];
    if ([subcommand isEqualToString:@"help"] || [subcommand isEqualToString:@"--help"]) {
        invocation.commandType = LKCLIUSBCommandTypeHelp;
        return invocation;
    }
    if ([subcommand isEqualToString:@"list-apps"]) {
        invocation.commandType = LKCLIUSBCommandTypeListApps;
    } else if ([subcommand isEqualToString:@"push-file"]) {
        invocation.commandType = LKCLIUSBCommandTypePushFile;
    } else if ([subcommand isEqualToString:@"pull-file"]) {
        invocation.commandType = LKCLIUSBCommandTypePullFile;
    } else {
        if (errorDescription) {
            *errorDescription = [NSString stringWithFormat:@"Unknown subcommand \"%@\".\n\n%@", subcommand, LKCLIUSBUsageText()];
        }
        return nil;
    }
    
    NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
    NSSet<NSString *> *optionsWithValue = [NSSet setWithArray:@[
        LKCLIOptionBundleID,
        LKCLIOptionDeviceName,
        LKCLIOptionLocalPath,
        LKCLIOptionRemotePath,
        LKCLIOptionTimeout
    ]];
    NSArray<NSString *> *rawOptions = [tokens subarrayWithRange:NSMakeRange(2, tokens.count - 2)];
    for (NSUInteger idx = 0; idx < rawOptions.count; idx++) {
        NSString *token = rawOptions[idx];
        if ([token isEqualToString:LKCLIOptionNoOverwrite]) {
            invocation.overwrite = NO;
            continue;
        }
        if ([token isEqualToString:LKCLIOptionNoCreateDirectories]) {
            invocation.createIntermediateDirectories = NO;
            continue;
        }
        if (![token hasPrefix:@"--"]) {
            if (errorDescription) {
                *errorDescription = [NSString stringWithFormat:@"Unexpected argument \"%@\".\n\n%@", token, LKCLIUSBUsageText()];
            }
            return nil;
        }
        if (![optionsWithValue containsObject:token]) {
            if (errorDescription) {
                *errorDescription = [NSString stringWithFormat:@"Unknown option \"%@\".\n\n%@", token, LKCLIUSBUsageText()];
            }
            return nil;
        }
        if (idx + 1 >= rawOptions.count) {
            if (errorDescription) {
                *errorDescription = [NSString stringWithFormat:@"Missing value for option \"%@\".\n\n%@", token, LKCLIUSBUsageText()];
            }
            return nil;
        }
        options[token] = rawOptions[idx + 1];
        idx++;
    }
    
    invocation.bundleIdentifier = options[LKCLIOptionBundleID];
    invocation.deviceName = options[LKCLIOptionDeviceName];
    invocation.localPath = [options[LKCLIOptionLocalPath] stringByExpandingTildeInPath];
    invocation.remotePath = options[LKCLIOptionRemotePath];
    
    NSString *timeoutString = options[LKCLIOptionTimeout];
    if (timeoutString.length > 0) {
        double timeout = timeoutString.doubleValue;
        if (timeout <= 0) {
            if (errorDescription) {
                *errorDescription = [NSString stringWithFormat:@"Invalid timeout \"%@\".\n\n%@", timeoutString, LKCLIUSBUsageText()];
            }
            return nil;
        }
        invocation.timeout = timeout;
    }
    
    switch (invocation.commandType) {
        case LKCLIUSBCommandTypeListApps:
        case LKCLIUSBCommandTypeHelp:
            return invocation;
        case LKCLIUSBCommandTypePushFile:
            if (!invocation.bundleIdentifier.length || !invocation.localPath.length || !invocation.remotePath.length) {
                if (errorDescription) {
                    *errorDescription = [NSString stringWithFormat:@"push-file requires %@, %@ and %@.\n\n%@",
                                         LKCLIOptionBundleID,
                                         LKCLIOptionLocalPath,
                                         LKCLIOptionRemotePath,
                                         LKCLIUSBUsageText()];
                }
                return nil;
            }
            return invocation;
        case LKCLIUSBCommandTypePullFile:
            if (!invocation.bundleIdentifier.length || !invocation.localPath.length || !invocation.remotePath.length) {
                if (errorDescription) {
                    *errorDescription = [NSString stringWithFormat:@"pull-file requires %@, %@ and %@.\n\n%@",
                                         LKCLIOptionBundleID,
                                         LKCLIOptionLocalPath,
                                         LKCLIOptionRemotePath,
                                         LKCLIUSBUsageText()];
                }
                return nil;
            }
            return invocation;
    }
    return nil;
}

@end

@interface LKCLIUSBRunner : NSObject

@property(nonatomic, strong) LKCLIUSBInvocation *invocation;
@property(nonatomic, copy) void (^completion)(int exitCode);

- (instancetype)initWithInvocation:(LKCLIUSBInvocation *)invocation completion:(void (^)(int exitCode))completion;
- (void)run;

@end

@implementation LKCLIUSBRunner

- (instancetype)initWithInvocation:(LKCLIUSBInvocation *)invocation completion:(void (^)(int exitCode))completion {
    if (self = [super init]) {
        _invocation = invocation;
        _completion = [completion copy];
    }
    return self;
}

- (void)run {
    if (self.invocation.commandType == LKCLIUSBCommandTypeHelp) {
        LKCLIWriteLine(LKCLIUSBUsageText(), NO);
        [self _finishWithExitCode:0];
        return;
    }
    
    [LKConnectionManager sharedInstance];
    switch (self.invocation.commandType) {
        case LKCLIUSBCommandTypeListApps:
            [self _runListApps];
            break;
        case LKCLIUSBCommandTypePushFile:
            [self _runPushFile];
            break;
        case LKCLIUSBCommandTypePullFile:
            [self _runPullFile];
            break;
        case LKCLIUSBCommandTypeHelp:
            break;
    }
}

- (void)_runListApps {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:self.invocation.timeout];
    [self _fetchUSBAppsUntilDeadline:deadline completion:^(NSArray<LKInspectableApp *> *apps, NSError *error) {
        if (error) {
            [self _printError:error];
            [self _finishWithExitCode:1];
            return;
        }
        if (apps.count == 0) {
            LKCLIWriteLine(@"No USB-inspectable iOS app was found.", NO);
            [self _finishWithExitCode:0];
            return;
        }
        for (LKInspectableApp *app in apps) {
            LookinAppInfo *info = app.appInfo;
            NSString *bundleID = info.appBundleIdentifier ?: @"<unknown-bundle-id>";
            NSString *appName = info.appName ?: @"<unknown-app>";
            NSString *deviceName = info.deviceDescription ?: @"<unknown-device>";
            NSString *serverVersion = info.serverReadableVersion.length > 0 ? info.serverReadableVersion : [NSString stringWithFormat:@"protocol:%d", info.serverVersion];
            LKCLIWriteLine([NSString stringWithFormat:@"%@ | %@ | %@ | LookinServer %@", bundleID, appName, deviceName, serverVersion], NO);
        }
        [self _finishWithExitCode:0];
    }];
}

- (void)_runPushFile {
    NSString *localPath = self.invocation.localPath.stringByStandardizingPath;
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:localPath isDirectory:&isDirectory] || isDirectory) {
        [self _printError:LKCLIMakeError(@"The local file does not exist or is not a regular file.", localPath)];
        [self _finishWithExitCode:1];
        return;
    }
    
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:localPath options:NSDataReadingMappedIfSafe error:&readError];
    if (!data) {
        [self _printError:readError];
        [self _finishWithExitCode:1];
        return;
    }
    
    [self _resolveTargetApp:^(LKInspectableApp *app, NSError *error) {
        if (!app) {
            [self _printError:error];
            [self _finishWithExitCode:1];
            return;
        }
        
        [[[app writeFileData:data
        toSandboxRelativePath:self.invocation.remotePath
                    overwrite:self.invocation.overwrite
createIntermediateDirectories:self.invocation.createIntermediateDirectories]
          deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            NSString *remotePath = self.invocation.remotePath;
            if ([value isKindOfClass:[NSDictionary class]]) {
                NSString *responsePath = [(NSDictionary *)value objectForKey:LKCLIFileTransferRemotePathKey];
                if ([responsePath isKindOfClass:[NSString class]] && responsePath.length > 0) {
                    remotePath = responsePath;
                }
            }
            LKCLIWriteLine([NSString stringWithFormat:@"Pushed %@ bytes to %@ (%@).",
                            @(data.length),
                            remotePath,
                            app.appInfo.deviceDescription ?: @"unknown-device"], NO);
            [self _finishWithExitCode:0];
        } error:^(NSError * _Nonnull error) {
            [self _printError:[self _errorByAddingUnsupportedHintIfNeeded:error]];
            [self _finishWithExitCode:1];
        }];
    }];
}

- (void)_runPullFile {
    NSString *localPath = self.invocation.localPath.stringByStandardizingPath;
    [self _resolveTargetApp:^(LKInspectableApp *app, NSError *error) {
        if (!app) {
            [self _printError:error];
            [self _finishWithExitCode:1];
            return;
        }
        
        [[[app readFileAtSandboxRelativePath:self.invocation.remotePath] deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            NSData *content = nil;
            NSString *remotePath = self.invocation.remotePath;
            if ([value isKindOfClass:[NSData class]]) {
                content = value;
            } else if ([value isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dict = (NSDictionary *)value;
                if ([dict[LKCLIFileTransferContentKey] isKindOfClass:[NSData class]]) {
                    content = dict[LKCLIFileTransferContentKey];
                }
                NSString *responsePath = dict[LKCLIFileTransferRemotePathKey];
                if ([responsePath isKindOfClass:[NSString class]] && responsePath.length > 0) {
                    remotePath = responsePath;
                }
            }
            if (!content) {
                [self _printError:LKCLIMakeError(@"The iOS app returned an invalid file payload.", @"Expected NSData or a dictionary containing a \"content\" key.")];
                [self _finishWithExitCode:1];
                return;
            }
            
            NSError *directoryError = nil;
            NSString *parentDirectory = localPath.stringByDeletingLastPathComponent;
            if (parentDirectory.length > 0 && ![[NSFileManager defaultManager] createDirectoryAtPath:parentDirectory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
                [self _printError:directoryError];
                [self _finishWithExitCode:1];
                return;
            }
            
            NSError *writeError = nil;
            if (![content writeToFile:localPath options:NSDataWritingAtomic error:&writeError]) {
                [self _printError:writeError];
                [self _finishWithExitCode:1];
                return;
            }
            
            LKCLIWriteLine([NSString stringWithFormat:@"Pulled %@ bytes from %@ to %@.",
                            @(content.length),
                            remotePath,
                            localPath], NO);
            [self _finishWithExitCode:0];
        } error:^(NSError * _Nonnull error) {
            [self _printError:[self _errorByAddingUnsupportedHintIfNeeded:error]];
            [self _finishWithExitCode:1];
        }];
    }];
}

- (void)_resolveTargetApp:(void (^)(LKInspectableApp *app, NSError *error))completion {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:self.invocation.timeout];
    [self _resolveTargetAppUntilDeadline:deadline completion:completion];
}

- (void)_resolveTargetAppUntilDeadline:(NSDate *)deadline completion:(void (^)(LKInspectableApp *app, NSError *error))completion {
    [self _fetchUSBAppsOnce:^(NSArray<LKInspectableApp *> *apps, NSError *error) {
        if (error) {
            if ([deadline timeIntervalSinceNow] > 0) {
                [self _retryAfterPollInterval:^{
                    [self _resolveTargetAppUntilDeadline:deadline completion:completion];
                }];
            } else {
                completion(nil, error);
            }
            return;
        }
        
        NSArray<LKInspectableApp *> *matchingApps = [self _matchingAppsFromUSBApps:apps];
        if (matchingApps.count == 1) {
            completion(matchingApps.firstObject, nil);
            return;
        }
        if (matchingApps.count > 1) {
            completion(nil, [self _multipleAppMatchErrorForApps:matchingApps]);
            return;
        }
        
        if ([deadline timeIntervalSinceNow] > 0) {
            [self _retryAfterPollInterval:^{
                [self _resolveTargetAppUntilDeadline:deadline completion:completion];
            }];
        } else {
            completion(nil, [self _appNotFoundErrorForApps:apps]);
        }
    }];
}

- (void)_fetchUSBAppsUntilDeadline:(NSDate *)deadline completion:(void (^)(NSArray<LKInspectableApp *> *apps, NSError *error))completion {
    [self _fetchUSBAppsOnce:^(NSArray<LKInspectableApp *> *apps, NSError *error) {
        if (error) {
            if ([deadline timeIntervalSinceNow] > 0) {
                [self _retryAfterPollInterval:^{
                    [self _fetchUSBAppsUntilDeadline:deadline completion:completion];
                }];
            } else {
                completion(nil, error);
            }
            return;
        }
        if (apps.count > 0 || [deadline timeIntervalSinceNow] <= 0) {
            completion(apps, nil);
            return;
        }
        [self _retryAfterPollInterval:^{
            [self _fetchUSBAppsUntilDeadline:deadline completion:completion];
        }];
    }];
}

- (void)_fetchUSBAppsOnce:(void (^)(NSArray<LKInspectableApp *> *apps, NSError *error))completion {
    [[[LKAppsManager sharedInstance] fetchAppInfosWithImage:NO localInfos:nil] subscribeNext:^(id  _Nullable value) {
        completion([self _usbInspectableAppsFromFetchValue:value], nil);
    } error:^(NSError * _Nonnull error) {
        completion(nil, error);
    }];
}

- (NSArray<LKInspectableApp *> *)_usbInspectableAppsFromFetchValue:(id)value {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<LKInspectableApp *> *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:[LKInspectableApp class]]) {
            continue;
        }
        LKInspectableApp *app = item;
        if (!app.appInfo || app.serverVersionError) {
            continue;
        }
        if (app.appInfo.deviceType == LookinAppInfoDeviceSimulator) {
            continue;
        }
        [result addObject:app];
    }
    return result;
}

- (NSArray<LKInspectableApp *> *)_matchingAppsFromUSBApps:(NSArray<LKInspectableApp *> *)apps {
    NSMutableArray<LKInspectableApp *> *result = [NSMutableArray array];
    for (LKInspectableApp *app in apps) {
        if (![app.appInfo.appBundleIdentifier isEqualToString:self.invocation.bundleIdentifier]) {
            continue;
        }
        if (self.invocation.deviceName.length > 0 && ![app.appInfo.deviceDescription isEqualToString:self.invocation.deviceName]) {
            continue;
        }
        [result addObject:app];
    }
    return result;
}

- (NSError *)_appNotFoundErrorForApps:(NSArray<LKInspectableApp *> *)apps {
    NSMutableString *recovery = [NSMutableString stringWithFormat:@"Bundle ID: %@", self.invocation.bundleIdentifier];
    if (self.invocation.deviceName.length > 0) {
        [recovery appendFormat:@", Device: %@", self.invocation.deviceName];
    }
    if (apps.count > 0) {
        [recovery appendString:@". Accessible USB apps right now:"];
        for (LKInspectableApp *app in apps) {
            [recovery appendFormat:@"\n- %@ on %@",
             app.appInfo.appBundleIdentifier ?: @"<unknown-bundle-id>",
             app.appInfo.deviceDescription ?: @"<unknown-device>"];
        }
    }
    return LKCLIMakeError(@"Failed to locate a matching USB-connected iOS app.", recovery);
}

- (NSError *)_multipleAppMatchErrorForApps:(NSArray<LKInspectableApp *> *)apps {
    NSMutableString *recovery = [NSMutableString stringWithString:@"Multiple USB devices matched the same bundle ID. Pass --device-name to disambiguate:"];
    for (LKInspectableApp *app in apps) {
        [recovery appendFormat:@"\n- %@", app.appInfo.deviceDescription ?: @"<unknown-device>"];
    }
    return LKCLIMakeError(@"More than one USB-connected iOS app matched the request.", recovery);
}

- (NSError *)_errorByAddingUnsupportedHintIfNeeded:(NSError *)error {
    if (error.code != LookinErrCode_Timeout) {
        return error;
    }
    NSString *recovery = error.localizedRecoverySuggestion ?: @"";
    NSString *hint = @"The target iOS app may not implement file-transfer request type 215 yet.";
    if (recovery.length > 0) {
        recovery = [NSString stringWithFormat:@"%@\n%@", recovery, hint];
    } else {
        recovery = hint;
    }
    return LKCLIMakeError(error.localizedDescription ?: @"Request timeout.", recovery);
}

- (void)_retryAfterPollInterval:(dispatch_block_t)block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LKCLIUSBPollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

- (void)_printError:(NSError *)error {
    NSString *message = error.localizedDescription ?: @"Unknown error.";
    if (error.localizedRecoverySuggestion.length > 0) {
        message = [message stringByAppendingFormat:@"\n%@", error.localizedRecoverySuggestion];
    }
    LKCLIWriteLine(message, YES);
}

- (void)_finishWithExitCode:(int)exitCode {
    if (self.completion) {
        self.completion(exitCode);
    }
}

@end

@interface AppDelegate ()

@property(nonatomic, assign) BOOL launchedToOpenFile;
@property(nonatomic, strong) LKCLIUSBInvocation *cliInvocation;
@property(nonatomic, copy) NSString *cliInvocationErrorDescription;
@property(nonatomic, strong) LKCLIUSBRunner *cliRunner;

@end

@implementation AppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    NSString *cliErrorDescription = nil;
    self.cliInvocation = [LKCLIUSBInvocation invocationWithArguments:NSProcessInfo.processInfo.arguments errorDescription:&cliErrorDescription];
    self.cliInvocationErrorDescription = cliErrorDescription;
    if (self.cliInvocation || self.cliInvocationErrorDescription.length > 0) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        return;
    }
    
    [[LKAppMenuManager sharedInstance] setup];
    
    [RACObserve([LKPreferenceManager mainManager], appearanceType) subscribeNext:^(NSNumber *number) {
        LookinPreferredAppeanranceType type = [number integerValue];
        switch (type) {
            case LookinPreferredAppeanranceTypeDark:
                NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
                break;
            case LookinPreferredAppeanranceTypeLight:
                NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
                break;
            default:
                NSApp.appearance = nil;
                break;
        }
    }];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    if (self.cliInvocationErrorDescription.length > 0) {
        LKCLIWriteLine(self.cliInvocationErrorDescription, YES);
        exit(2);
    }
    if (self.cliInvocation) {
        self.cliRunner = [[LKCLIUSBRunner alloc] initWithInvocation:self.cliInvocation completion:^(int exitCode) {
            exit(exitCode);
        }];
        [self.cliRunner run];
        return;
    }
    
    [LKConnectionManager sharedInstance];
    if (!self.launchedToOpenFile) {
        [[LKNavigationManager sharedInstance] showLaunch];
    }
    
    [self resolveAppCenterKey];
    
    NSString *key = [self resolveAppCenterKey];
    if (key) {
        [MSACAppCenter start:key withServices:@[
            [MSACAnalytics class],
            [MSACCrashes class]
        ]];
        MSACAppCenter.enabled = LKPreferenceManager.mainManager.enableReport;
    }
    else {
        MSACAppCenter.enabled = NO;
    }
    
#ifdef DEBUG
    [self _runTests];
#endif
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    self.launchedToOpenFile = YES;
    NSError *error;
    BOOL isSuccessful = [[LKNavigationManager sharedInstance] showReaderWithFilePath:filename error:&error];    
    return isSuccessful;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // 清理打开 UIImageView 的图片时创建的临时文件
    NSArray<NSString *> *tempImageFilesToDelete = [LKHelper sharedInstance].tempImageFiles;
    if (tempImageFilesToDelete.count == 0) {
        return NSTerminateNow;
    }
    [tempImageFilesToDelete enumerateObjectsUsingBlock:^(NSString * _Nonnull path, NSUInteger idx, BOOL * _Nonnull stop) {
        BOOL isSucc = [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (!isSucc) {
            NSAssert(NO, @"");
        }
    }];
    return NSTerminateNow;
}

#pragma mark - Test

- (NSString *)resolveAppCenterKey {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"hughkli.Lookin"]) {
        return @"fce2565c-518c-4851-be73-fa8317dd1590";
    }
    NSAssert(NO, @"");
    return nil;
}

/// 一些单元测试
- (void)_runTests {
    // 确保 LookinAttrGroupIdentifier 的 value 没有重复
    NSArray<LookinAttrGroupIdentifier> *allGroupIDs = [LookinDashboardBlueprint groupIDs];
    NSSet<LookinAttrGroupIdentifier> *allGroupIDs_unique = [NSSet setWithArray:allGroupIDs];
    if (allGroupIDs.count != allGroupIDs_unique.count) {
        NSAssert(NO, @"");
    }
    
    // 确保 LookinAttrSectionIdentifier 的 value 没有重复
    NSMutableArray<LookinAttrSectionIdentifier> *allSecIDs = [NSMutableArray array];
    [allGroupIDs enumerateObjectsUsingBlock:^(LookinAttrGroupIdentifier  _Nonnull groupID, NSUInteger idx, BOOL * _Nonnull stop) {
        NSArray<LookinAttrSectionIdentifier> *secIDs = [LookinDashboardBlueprint sectionIDsForGroupID:groupID];
        [allSecIDs addObjectsFromArray:secIDs];
    }];
    NSSet<LookinAttrSectionIdentifier> *allSecIDs_unique = [NSSet setWithArray:allSecIDs];
    if (allSecIDs.count != allSecIDs_unique.count) {
        NSAssert(NO, @"");
    }
    
    // 确保 LookinAttrIdentifier 的 value 没有重复
    NSMutableArray<LookinAttrIdentifier> *allAttrIDs = [NSMutableArray array];
    [allSecIDs enumerateObjectsUsingBlock:^(LookinAttrSectionIdentifier  _Nonnull secID, NSUInteger idx, BOOL * _Nonnull stop) {
        NSArray<LookinAttrIdentifier> *attrIDs = [LookinDashboardBlueprint attrIDsForSectionID:secID];
        [allAttrIDs addObjectsFromArray:attrIDs];
    }];
    NSSet<LookinAttrIdentifier> *allAttrIDs_unique = [NSSet setWithArray:allAttrIDs];
    if (allAttrIDs.count != allAttrIDs_unique.count) {
        NSAssert(NO, @"");
    }
}

@end

//
//  LKFileBrowserViewController.m
//  LookinClient
//
//  Created by OpenAI Codex.
//

#import "LKFileBrowserViewController.h"
#import "LKAppsManager.h"
#import "LKInspectableApp.h"
@import WebKit;

static NSString * const LKFileBrowserMessageHandlerName = @"lookinFileBrowser";
static NSString * const LKFileBrowserActionBootstrap = @"bootstrap";
static NSString * const LKFileBrowserActionListDirectory = @"listDirectory";
static NSString * const LKFileBrowserActionUploadFile = @"uploadFile";
static NSString * const LKFileBrowserActionImportURL = @"importURL";
static NSString * const LKFileBrowserActionDownloadFile = @"downloadFile";
static NSString * const LKFileBrowserActionCreateDirectory = @"createDirectory";
static NSString * const LKFileBrowserActionRemoveItem = @"removeItem";
static NSString * const LKFileBrowserItemsKey = @"items";
static NSString * const LKFileBrowserCurrentPathKey = @"currentPath";
static NSString * const LKFileBrowserSelectedAppIDKey = @"selectedAppID";
static NSString * const LKFileBrowserStatusMessageKey = @"statusMessage";

static NSString * LKFileBrowserJoinRemotePath(NSString *basePath, NSString *component) {
    NSString *cleanBasePath = [basePath isKindOfClass:[NSString class]] ? basePath : @"";
    NSString *cleanComponent = [component isKindOfClass:[NSString class]] ? component : @"";
    if (cleanBasePath.length == 0) {
        return cleanComponent;
    }
    if (cleanComponent.length == 0) {
        return cleanBasePath;
    }
    return [cleanBasePath stringByAppendingPathComponent:cleanComponent];
}

static BOOL LKFileBrowserURLPointsToLocalhost(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"localhost"] ||
    [host isEqualToString:@"127.0.0.1"] ||
    [host isEqualToString:@"::1"] ||
    [host isEqualToString:@"0.0.0.0"];
}

@interface LKWeakScriptMessageHandler : NSObject <WKScriptMessageHandler>

@property(nonatomic, weak) id<WKScriptMessageHandler> target;

@end

@implementation LKWeakScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:userContentController didReceiveScriptMessage:message];
}

@end

@interface LKFileBrowserViewController () <WKScriptMessageHandler, WKNavigationDelegate>

@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) LKWeakScriptMessageHandler *scriptMessageHandlerProxy;

@end

@implementation LKFileBrowserViewController

- (NSView *)makeContainerView {
    LKBaseView *containerView = [LKBaseView new];
    containerView.wantsLayer = YES;
    
    self.scriptMessageHandlerProxy = [[LKWeakScriptMessageHandler alloc] init];
    self.scriptMessageHandlerProxy.target = self;
    WKUserContentController *userContentController = [[WKUserContentController alloc] init];
    [userContentController addScriptMessageHandler:self.scriptMessageHandlerProxy name:LKFileBrowserMessageHandlerName];
    
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.userContentController = userContentController;
    
    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:containerView.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor]
    ]];
    [self _loadHTMLDocument];
    
    return containerView;
}

- (void)viewDidLayout {
    [super viewDidLayout];
}

- (void)dealloc {
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:LKFileBrowserMessageHandlerName];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary *body = (NSDictionary *)message.body;
    NSNumber *requestID = [body[@"id"] isKindOfClass:[NSNumber class]] ? body[@"id"] : nil;
    NSString *action = [body[@"action"] isKindOfClass:[NSString class]] ? body[@"action"] : nil;
    NSDictionary *payload = [body[@"payload"] isKindOfClass:[NSDictionary class]] ? body[@"payload"] : @{};
    if (!requestID || !action.length) {
        return;
    }
    
    if ([action isEqualToString:LKFileBrowserActionBootstrap]) {
        [self _handleBootstrapForRequestID:requestID payload:payload];
    } else if ([action isEqualToString:LKFileBrowserActionListDirectory]) {
        [self _handleListDirectoryForRequestID:requestID payload:payload];
    } else if ([action isEqualToString:LKFileBrowserActionUploadFile]) {
        [self _handleUploadFileForRequestID:requestID payload:payload];
    } else if ([action isEqualToString:LKFileBrowserActionImportURL]) {
        [self _handleImportURLForRequestID:requestID payload:payload];
    } else if ([action isEqualToString:LKFileBrowserActionDownloadFile]) {
        [self _handleDownloadFileForRequestID:requestID payload:payload];
    } else if ([action isEqualToString:LKFileBrowserActionCreateDirectory]) {
        [self _handleCreateDirectoryForRequestID:requestID payload:payload];
    } else if ([action isEqualToString:LKFileBrowserActionRemoveItem]) {
        [self _handleRemoveItemForRequestID:requestID payload:payload];
    } else {
        [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"Unknown file browser action." detail:action ?: @""]];
    }
}

#pragma mark - Actions

- (void)_handleBootstrapForRequestID:(NSNumber *)requestID payload:(NSDictionary *)payload {
    NSString *preferredAppID = [payload[@"appID"] isKindOfClass:[NSString class]] ? payload[@"appID"] : nil;
    NSString *preferredPath = [payload[@"remotePath"] isKindOfClass:[NSString class]] ? payload[@"remotePath"] : @"";
    [self _fetchUSBAppsWithCompletion:^(NSArray<LKInspectableApp *> *apps, NSError *error) {
        if (error) {
            [self _rejectRequestID:requestID error:error];
            return;
        }
        
        NSArray<NSDictionary *> *serializableApps = [apps lookin_map:^id(NSUInteger idx, LKInspectableApp *value) {
            return [self _serializableApp:value];
        }] ?: @[];
        if (apps.count == 0) {
            [self _resolveRequestID:requestID payload:@{
                @"apps": serializableApps,
                LKFileBrowserSelectedAppIDKey: [NSNull null],
                LKFileBrowserCurrentPathKey: @"",
                LKFileBrowserItemsKey: @[]
            }];
            return;
        }
        
        LKInspectableApp *selectedApp = [self _selectedAppFromApps:apps preferredAppID:preferredAppID];
        NSString *selectedAppID = [self _identifierForApp:selectedApp];
        if (selectedApp && !selectedApp.supportsFileTransfer) {
            [self _resolveRequestID:requestID payload:@{
                @"apps": serializableApps,
                LKFileBrowserSelectedAppIDKey: selectedAppID ?: [NSNull null],
                LKFileBrowserCurrentPathKey: preferredPath ?: @"",
                LKFileBrowserItemsKey: @[],
                LKFileBrowserStatusMessageKey: [self _fileTransferUnsupportedMessageForApp:selectedApp]
            }];
            return;
        }
        [[[selectedApp listDirectoryAtSandboxRelativePath:preferredPath] deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            NSMutableDictionary *payloadToSend = [[self _directoryPayloadFromResponse:value fallbackPath:preferredPath] mutableCopy];
            payloadToSend[@"apps"] = serializableApps;
            payloadToSend[LKFileBrowserSelectedAppIDKey] = selectedAppID ?: [NSNull null];
            [self _resolveRequestID:requestID payload:payloadToSend];
        } error:^(NSError * _Nonnull error) {
            [self _rejectRequestID:requestID error:error];
        }];
    }];
}

- (void)_handleListDirectoryForRequestID:(NSNumber *)requestID payload:(NSDictionary *)payload {
    NSString *appID = [payload[@"appID"] isKindOfClass:[NSString class]] ? payload[@"appID"] : @"";
    NSString *remotePath = [payload[@"remotePath"] isKindOfClass:[NSString class]] ? payload[@"remotePath"] : @"";
    [self _resolveAppWithIdentifier:appID completion:^(LKInspectableApp *app, NSError *error) {
        if (!app) {
            [self _rejectRequestID:requestID error:error];
            return;
        }
        [[[app listDirectoryAtSandboxRelativePath:remotePath] deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            [self _resolveRequestID:requestID payload:[self _directoryPayloadFromResponse:value fallbackPath:remotePath]];
        } error:^(NSError * _Nonnull error) {
            [self _rejectRequestID:requestID error:error];
        }];
    }];
}

- (void)_handleUploadFileForRequestID:(NSNumber *)requestID payload:(NSDictionary *)payload {
    NSString *appID = [payload[@"appID"] isKindOfClass:[NSString class]] ? payload[@"appID"] : @"";
    NSString *directoryPath = [payload[@"directoryPath"] isKindOfClass:[NSString class]] ? payload[@"directoryPath"] : @"";
    [self _resolveAppWithIdentifier:appID completion:^(LKInspectableApp *app, NSError *error) {
        if (!app) {
            [self _rejectRequestID:requestID error:error];
            return;
        }
        
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseDirectories = NO;
        panel.canChooseFiles = YES;
        panel.allowsMultipleSelection = NO;
        if ([panel runModal] != NSModalResponseOK || panel.URLs.count == 0) {
            [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"The upload was cancelled." detail:@""]];
            return;
        }
        
        NSURL *fileURL = panel.URLs.firstObject;
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:&readError];
        if (!data) {
            [self _rejectRequestID:requestID error:readError];
            return;
        }
        
        NSString *remotePath = LKFileBrowserJoinRemotePath(directoryPath, fileURL.lastPathComponent ?: @"");
        [[[app writeFileData:data toSandboxRelativePath:remotePath overwrite:YES createIntermediateDirectories:YES] deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            [self _resolveRequestID:requestID payload:@{
                @"remotePath": remotePath,
                @"bytes": @(data.length)
            }];
        } error:^(NSError * _Nonnull error) {
            [self _rejectRequestID:requestID error:error];
        }];
    }];
}

- (void)_handleImportURLForRequestID:(NSNumber *)requestID payload:(NSDictionary *)payload {
    NSString *appID = [payload[@"appID"] isKindOfClass:[NSString class]] ? payload[@"appID"] : @"";
    NSString *directoryPath = [payload[@"directoryPath"] isKindOfClass:[NSString class]] ? payload[@"directoryPath"] : @"";
    NSString *sourceURL = [payload[@"sourceURL"] isKindOfClass:[NSString class]] ? payload[@"sourceURL"] : @"";
    NSURL *url = [NSURL URLWithString:sourceURL];
    if (!url || sourceURL.length == 0) {
        [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"The source URL is invalid." detail:@""]];
        return;
    }
    NSString *fileName = url.lastPathComponent;
    if (fileName.length == 0) {
        [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"Cannot infer the destination file name from the URL." detail:sourceURL]];
        return;
    }
    NSString *remotePath = LKFileBrowserJoinRemotePath(directoryPath, fileName);
    
    [self _resolveAppWithIdentifier:appID completion:^(LKInspectableApp *app, NSError *error) {
        if (!app) {
            [self _rejectRequestID:requestID error:error];
            return;
        }
        RACSignal *signal = nil;
        if (LKFileBrowserURLPointsToLocalhost(url)) {
            signal = [app writeFileFromMacURLString:sourceURL
                              toSandboxRelativePath:remotePath
                                          overwrite:YES
                      createIntermediateDirectories:YES];
        } else {
            signal = [app downloadFileFromSourceURLString:sourceURL
                                   toSandboxRelativePath:remotePath
                                               overwrite:YES
                           createIntermediateDirectories:YES];
        }
        [[signal deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            [self _resolveRequestID:requestID payload:@{
                @"remotePath": remotePath,
                @"sourceURL": sourceURL,
                @"mode": LKFileBrowserURLPointsToLocalhost(url) ? @"macBridge" : @"iosDownload"
            }];
        } error:^(NSError * _Nonnull error) {
            [self _rejectRequestID:requestID error:error];
        }];
    }];
}

- (void)_handleDownloadFileForRequestID:(NSNumber *)requestID payload:(NSDictionary *)payload {
    NSString *appID = [payload[@"appID"] isKindOfClass:[NSString class]] ? payload[@"appID"] : @"";
    NSString *remotePath = [payload[@"remotePath"] isKindOfClass:[NSString class]] ? payload[@"remotePath"] : @"";
    if (remotePath.length == 0) {
        [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"The remote file path is empty." detail:@""]];
        return;
    }
    
    [self _resolveAppWithIdentifier:appID completion:^(LKInspectableApp *app, NSError *error) {
        if (!app) {
            [self _rejectRequestID:requestID error:error];
            return;
        }
        [[[app readFileAtSandboxRelativePath:remotePath] deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            NSData *content = nil;
            if ([value isKindOfClass:[NSData class]]) {
                content = value;
            } else if ([value isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dict = (NSDictionary *)value;
                if ([dict[@"content"] isKindOfClass:[NSData class]]) {
                    content = dict[@"content"];
                }
            }
            if (!content) {
                [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"The iOS app returned an invalid file payload." detail:@"Expected NSData or a dictionary containing a content key."]];
                return;
            }
            
            NSSavePanel *panel = [NSSavePanel savePanel];
            panel.nameFieldStringValue = remotePath.lastPathComponent ?: @"download.bin";
            if ([panel runModal] != NSModalResponseOK || !panel.URL) {
                [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"The download was cancelled." detail:@""]];
                return;
            }
            NSError *writeError = nil;
            if (![content writeToURL:panel.URL options:NSDataWritingAtomic error:&writeError]) {
                [self _rejectRequestID:requestID error:writeError];
                return;
            }
            [self _resolveRequestID:requestID payload:@{
                @"remotePath": remotePath,
                @"localPath": panel.URL.path ?: @"",
                @"bytes": @(content.length)
            }];
        } error:^(NSError * _Nonnull error) {
            [self _rejectRequestID:requestID error:error];
        }];
    }];
}

- (void)_handleCreateDirectoryForRequestID:(NSNumber *)requestID payload:(NSDictionary *)payload {
    NSString *appID = [payload[@"appID"] isKindOfClass:[NSString class]] ? payload[@"appID"] : @"";
    NSString *parentPath = [payload[@"parentPath"] isKindOfClass:[NSString class]] ? payload[@"parentPath"] : @"";
    NSString *name = [payload[@"name"] isKindOfClass:[NSString class]] ? payload[@"name"] : @"";
    if (name.length == 0) {
        [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"The folder name is empty." detail:@""]];
        return;
    }
    NSString *remotePath = LKFileBrowserJoinRemotePath(parentPath, name);
    [self _resolveAppWithIdentifier:appID completion:^(LKInspectableApp *app, NSError *error) {
        if (!app) {
            [self _rejectRequestID:requestID error:error];
            return;
        }
        [[[app createDirectoryAtSandboxRelativePath:remotePath createIntermediateDirectories:YES] deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            [self _resolveRequestID:requestID payload:@{
                @"remotePath": remotePath,
                @"name": name
            }];
        } error:^(NSError * _Nonnull error) {
            [self _rejectRequestID:requestID error:error];
        }];
    }];
}

- (void)_handleRemoveItemForRequestID:(NSNumber *)requestID payload:(NSDictionary *)payload {
    NSString *appID = [payload[@"appID"] isKindOfClass:[NSString class]] ? payload[@"appID"] : @"";
    NSString *remotePath = [payload[@"remotePath"] isKindOfClass:[NSString class]] ? payload[@"remotePath"] : @"";
    if (remotePath.length == 0) {
        [self _rejectRequestID:requestID error:[self _makeErrorWithMessage:@"The remote path is empty." detail:@""]];
        return;
    }
    [self _resolveAppWithIdentifier:appID completion:^(LKInspectableApp *app, NSError *error) {
        if (!app) {
            [self _rejectRequestID:requestID error:error];
            return;
        }
        [[[app removeItemAtSandboxRelativePath:remotePath] deliverOnMainThread] subscribeNext:^(id  _Nullable value) {
            [self _resolveRequestID:requestID payload:@{@"remotePath": remotePath}];
        } error:^(NSError * _Nonnull error) {
            [self _rejectRequestID:requestID error:error];
        }];
    }];
}

#pragma mark - Helpers

- (void)_fetchUSBAppsWithCompletion:(void (^)(NSArray<LKInspectableApp *> *apps, NSError *error))completion {
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

- (LKInspectableApp *)_selectedAppFromApps:(NSArray<LKInspectableApp *> *)apps preferredAppID:(NSString *)preferredAppID {
    LKInspectableApp *preferredApp = nil;
    if (preferredAppID.length > 0) {
        preferredApp = [apps lookin_firstFiltered:^BOOL(LKInspectableApp *obj) {
            return [[self _identifierForApp:obj] isEqualToString:preferredAppID];
        }];
        if (preferredApp && preferredApp.supportsFileTransfer) {
            return preferredApp;
        }
    }
    
    LKInspectableApp *inspectingApp = [LKAppsManager sharedInstance].inspectingApp;
    LKInspectableApp *matchedApp = nil;
    if (inspectingApp) {
        NSString *currentID = [self _identifierForApp:inspectingApp];
        matchedApp = [apps lookin_firstFiltered:^BOOL(LKInspectableApp *obj) {
            return [[self _identifierForApp:obj] isEqualToString:currentID];
        }];
        if (matchedApp && matchedApp.supportsFileTransfer) {
            return matchedApp;
        }
    }
    LKInspectableApp *firstSupportedApp = [apps lookin_firstFiltered:^BOOL(LKInspectableApp *obj) {
        return obj.supportsFileTransfer;
    }];
    if (firstSupportedApp) {
        return firstSupportedApp;
    }
    if (preferredApp) {
        return preferredApp;
    }
    if (matchedApp) {
        return matchedApp;
    }
    return apps.firstObject;
}

- (void)_resolveAppWithIdentifier:(NSString *)appID completion:(void (^)(LKInspectableApp *app, NSError *error))completion {
    if (appID.length == 0) {
        completion(nil, [self _makeErrorWithMessage:@"No target app is selected." detail:@""]);
        return;
    }
    [self _fetchUSBAppsWithCompletion:^(NSArray<LKInspectableApp *> *apps, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        LKInspectableApp *targetApp = [apps lookin_firstFiltered:^BOOL(LKInspectableApp *obj) {
            return [[self _identifierForApp:obj] isEqualToString:appID];
        }];
        if (!targetApp) {
            completion(nil, [self _makeErrorWithMessage:@"Failed to locate the target USB app." detail:appID]);
            return;
        }
        completion(targetApp, nil);
    }];
}

- (NSString *)_identifierForApp:(LKInspectableApp *)app {
    return [NSString stringWithFormat:@"%@", @(app.appInfo.appInfoIdentifier)];
}

- (NSDictionary *)_serializableApp:(LKInspectableApp *)app {
    LookinAppInfo *info = app.appInfo;
    return @{
        @"id": [self _identifierForApp:app] ?: @"",
        @"appName": info.appName ?: @"",
        @"bundleIdentifier": info.appBundleIdentifier ?: @"",
        @"deviceName": info.deviceDescription ?: @"",
        @"osVersion": info.osDescription ?: @"",
        @"serverVersion": info.serverReadableVersion ?: @"",
        @"supportsFileTransfer": @(app.supportsFileTransfer)
    };
}

- (NSString *)_fileTransferUnsupportedMessageForApp:(LKInspectableApp *)app {
    NSError *error = [app fileTransferUnsupportedError];
    if (error.localizedRecoverySuggestion.length > 0) {
        return [NSString stringWithFormat:@"%@ %@", error.localizedDescription ?: @"", error.localizedRecoverySuggestion];
    }
    return error.localizedDescription ?: @"";
}

- (NSDictionary *)_directoryPayloadFromResponse:(id)response fallbackPath:(NSString *)fallbackPath {
    NSString *currentPath = fallbackPath ?: @"";
    NSArray *items = nil;
    if ([response isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)response;
        if ([dict[@"remotePath"] isKindOfClass:[NSString class]]) {
            currentPath = dict[@"remotePath"];
        } else if ([dict[@"path"] isKindOfClass:[NSString class]]) {
            currentPath = dict[@"path"];
        }
        if ([dict[@"items"] isKindOfClass:[NSArray class]]) {
            items = dict[@"items"];
        } else if ([dict[@"entries"] isKindOfClass:[NSArray class]]) {
            items = dict[@"entries"];
        }
    } else if ([response isKindOfClass:[NSArray class]]) {
        items = response;
    }
    items = items ?: @[];
    
    NSArray<NSDictionary *> *normalizedItems = [items lookin_map:^id(NSUInteger idx, id value) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        NSDictionary *dict = (NSDictionary *)value;
        NSString *remotePath = @"";
        if ([dict[@"remotePath"] isKindOfClass:[NSString class]]) {
            remotePath = dict[@"remotePath"];
        } else if ([dict[@"path"] isKindOfClass:[NSString class]]) {
            remotePath = dict[@"path"];
        } else if ([dict[@"relativePath"] isKindOfClass:[NSString class]]) {
            remotePath = dict[@"relativePath"];
        } else if ([dict[@"name"] isKindOfClass:[NSString class]]) {
            remotePath = LKFileBrowserJoinRemotePath(currentPath, dict[@"name"]);
        }
        BOOL isDirectory = NO;
        if ([dict[@"isDirectory"] respondsToSelector:@selector(boolValue)]) {
            isDirectory = [dict[@"isDirectory"] boolValue];
        } else if ([dict[@"directory"] respondsToSelector:@selector(boolValue)]) {
            isDirectory = [dict[@"directory"] boolValue];
        } else if ([dict[@"type"] isKindOfClass:[NSString class]]) {
            isDirectory = [dict[@"type"] isEqualToString:@"directory"];
        }
        NSString *name = [dict[@"name"] isKindOfClass:[NSString class]] ? dict[@"name"] : remotePath.lastPathComponent;
        NSNumber *fileSize = [dict[@"fileSize"] isKindOfClass:[NSNumber class]] ? dict[@"fileSize"] : ([dict[@"size"] isKindOfClass:[NSNumber class]] ? dict[@"size"] : nil);
        NSString *sizeText = @"";
        if (fileSize && !isDirectory) {
            sizeText = [NSByteCountFormatter stringFromByteCount:fileSize.longLongValue countStyle:NSByteCountFormatterCountStyleFile];
        }
        NSString *kind = isDirectory ? @"Folder" : @"File";
        if ([dict[@"kind"] isKindOfClass:[NSString class]] && [dict[@"kind"] length] > 0) {
            kind = dict[@"kind"];
        }
        return @{
            @"name": name ?: @"",
            @"remotePath": remotePath ?: @"",
            @"isDirectory": @(isDirectory),
            @"kind": kind,
            @"sizeText": sizeText,
            @"fileSize": fileSize ?: [NSNull null]
        };
    }] ?: @[];
    
    return @{
        LKFileBrowserCurrentPathKey: currentPath ?: @"",
        LKFileBrowserItemsKey: normalizedItems
    };
}

- (NSError *)_makeErrorWithMessage:(NSString *)message detail:(NSString *)detail {
    return LookinErrorMake(message ?: @"Unknown error.", detail ?: @"");
}

- (void)_resolveRequestID:(NSNumber *)requestID payload:(id)payload {
    [self _sendToJavaScriptFunction:@"window.__lookinResolve" requestID:requestID payload:payload ?: @{}];
}

- (void)_rejectRequestID:(NSNumber *)requestID error:(NSError *)error {
    NSDictionary *payload = @{
        @"message": error.localizedDescription ?: @"Unknown error.",
        @"detail": error.localizedRecoverySuggestion ?: @"",
        @"code": @(error.code)
    };
    [self _sendToJavaScriptFunction:@"window.__lookinReject" requestID:requestID payload:payload];
}

- (void)_sendToJavaScriptFunction:(NSString *)functionName requestID:(NSNumber *)requestID payload:(id)payload {
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (!jsonData || jsonError) {
        return;
    }
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *script = [NSString stringWithFormat:@"%@(%@, %@);", functionName, requestID, jsonString];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSLog(@"LKFileBrowserViewController - didFinishNavigation");
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"LKFileBrowserViewController - didFailNavigation: %@", error);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"LKFileBrowserViewController - didFailProvisionalNavigation: %@", error);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    NSLog(@"LKFileBrowserViewController - web content process terminated");
}

- (void)_loadHTMLDocument {
    NSBundle *bundle = NSBundle.mainBundle;
    NSURL *htmlURL = [bundle URLForResource:@"index" withExtension:@"html"];
    if (!htmlURL) {
        NSLog(@"LKFileBrowserViewController - failed to locate index.html");
        return;
    }
    NSURL *readAccessURL = [htmlURL URLByDeletingLastPathComponent];
    [self.webView loadFileURL:htmlURL allowingReadAccessToURL:readAccessURL];
}

@end

//
//  LKDeviceItem.m
//  Lookin
//
//  Created by Li Kai on 2018/11/3.
//  https://lookin.work
//

#import "LKInspectableApp.h"
#import "LKConnectionManager.h"
#import "LookinConnectionResponseAttachment.h"
#import "LKNavigationManager.h"

static uint32_t const LKRequestTypeFileTransfer = 215;
static NSUInteger const LKInlineFileTransferMaxSize = 32 * 1024 * 1024;
static NSString * const LKFileTransferMinimumServerReadableVersion = @"1.2.8";

static NSString * const LKFileTransferActionKey = @"action";
static NSString * const LKFileTransferActionReadFile = @"readFile";
static NSString * const LKFileTransferActionWriteFile = @"writeFile";
static NSString * const LKFileTransferActionListDirectory = @"listDirectory";
static NSString * const LKFileTransferActionCreateDirectory = @"createDirectory";
static NSString * const LKFileTransferActionRemoveItem = @"removeItem";
static NSString * const LKFileTransferActionDownloadFromURL = @"downloadFromURL";
static NSString * const LKFileTransferRemotePathKey = @"remotePath";
static NSString * const LKFileTransferContentKey = @"content";
static NSString * const LKFileTransferOverwriteKey = @"overwrite";
static NSString * const LKFileTransferCreateDirectoriesKey = @"createIntermediateDirectories";
static NSString * const LKFileTransferSourceURLKey = @"sourceURL";

static BOOL LKFileTransferSupportsServerVersion(NSString *serverReadableVersion) {
    if (![serverReadableVersion isKindOfClass:[NSString class]] || serverReadableVersion.length == 0) {
        return NO;
    }
    return [serverReadableVersion compare:LKFileTransferMinimumServerReadableVersion options:NSNumericSearch] != NSOrderedAscending;
}

@implementation LKInspectableApp

- (BOOL)supportsFileTransfer {
    return LKFileTransferSupportsServerVersion(self.appInfo.serverReadableVersion);
}

- (NSError *)fileTransferUnsupportedError {
    NSString *currentVersion = self.appInfo.serverReadableVersion.length > 0 ? self.appInfo.serverReadableVersion : @"unknown";
    NSString *detail = [NSString stringWithFormat:NSLocalizedString(@"Please upgrade the LookinServer SDK version in your iOS project to 1.2.8 or higher to use the file browser and USB file transfer. Current LookinServer version: %@.", nil), currentVersion];
    return [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_ServerVersionTooLow userInfo:@{
        NSLocalizedDescriptionKey: NSLocalizedString(@"USB file transfer is not supported by the target iOS app.", nil),
        NSLocalizedRecoverySuggestionErrorKey: detail
    }];
}

- (RACSignal *)fetchHierarchyData {
    /// Lookin 1.0.4 开始加入这个参数
    NSDictionary *param = @{@"clientVersion": [LKHelper lookinReadableVersion]};
    return [self _requestWithType:LookinRequestTypeHierarchy data:param];
}

- (RACSignal *)submitInbuiltModification:(LookinAttributeModification *)modification {
    return [self _requestWithType:LookinRequestTypeInbuiltAttrModification data:modification];
}

- (RACSignal *)submitCustomModification:(LookinCustomAttrModification *)modification {
    return [self _requestWithType:LookinRequestTypeCustomAttrModification data:modification];
}

- (RACSignal *)fetchHierarchyDetailWithTaskPackages:(NSArray<LookinStaticAsyncUpdateTasksPackage *> *)packages {
    return [self _requestWithType:LookinRequestTypeHierarchyDetails data:packages];
}

- (void)cancelHierarchyDetailFetching {
    [self _cancelRequestWithType:LookinRequestTypeHierarchyDetails];
    [self _pushWithType:LookinPush_CanceHierarchyDetails data:nil];
}

- (RACSignal *)fetchModificationPatchWithTasks:(NSArray<LookinStaticAsyncUpdateTask *> *)tasks {
    return [self _requestWithType:LookinRequestTypeAttrModificationPatch data:tasks];
}

- (RACSignal *)fetchObjectWithOid:(unsigned long)oid {
    if (!oid) {
        return [RACSignal error:LookinErr_Inner];
    }
    return [self _requestWithType:LookinRequestTypeFetchObject data:@(oid)];
}

- (RACSignal *)fetchSelectorNamesWithClass:(NSString *)className hasArg:(BOOL)hasArg {
    return [self _requestWithType:LookinRequestTypeAllSelectorNames data:@{@"className":className, @"hasArg":@(hasArg)}];
}

- (RACSignal *)invokeMethodWithOid:(unsigned long)oid text:(NSString *)text {
    if (oid == 0 || !text.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    NSDictionary *param = @{@"oid":@(oid), @"text":text};
    return [[self _requestWithType:LookinRequestTypeInvokeMethod data:param] map:^id _Nullable(NSDictionary * _Nullable value) {
        if ([value[@"description"] isEqualToString:LookinStringFlag_VoidReturn]) {
            // 方法没有返回值时，替换成本地说明
            NSMutableDictionary *newValue = [value mutableCopy];
            newValue[@"description"] = NSLocalizedString(@"The method was invoked successfully and no value was returned.", nil);
            return newValue;
        } else {
            return value;
        }
    }];
}

- (RACSignal *)fetchAttrGroupListWithOid:(unsigned long)oid {
    if (!oid) {
        return [RACSignal error:LookinErr_Inner];
    }
    return [self _requestWithType:LookinRequestTypeAllAttrGroups data:@(oid)];
}

- (RACSignal *)fetchImageWithImageViewOid:(unsigned long)oid {
    if (!oid) {
        return [RACSignal error:LookinErr_Inner];
    }
    return [self _requestWithType:LookinRequestTypeFetchImageViewImage data:@(oid)];
}

- (RACSignal *)modifyGestureRecognizer:(unsigned long)oid toBeEnabled:(BOOL)shouldBeEnabled {
    if (!oid) {
        return [RACSignal error:LookinErr_Inner];
    }
    return [self _requestWithType:LookinRequestTypeModifyRecognizerEnable data:@{@"oid":@(oid), @"enable":@(shouldBeEnabled)}];
}

- (RACSignal *)writeFileData:(NSData *)data
         toSandboxRelativePath:(NSString *)remotePath
                     overwrite:(BOOL)overwrite
createIntermediateDirectories:(BOOL)createIntermediateDirectories {
    if (!data || !remotePath.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (![self supportsFileTransfer]) {
        return [RACSignal error:[self fileTransferUnsupportedError]];
    }
    if (data.length > LKInlineFileTransferMaxSize) {
        NSError *error = LookinErrorMake(@"The file is too large for inline USB transfer.",
                                         @"The current macOS client only supports single-request transfers up to 32 MB. Extend the protocol with chunked streaming if you need larger files.");
        return [RACSignal error:error];
    }
    NSDictionary *payload = @{
        LKFileTransferActionKey: LKFileTransferActionWriteFile,
        LKFileTransferRemotePathKey: remotePath,
        LKFileTransferContentKey: data,
        LKFileTransferOverwriteKey: @(overwrite),
        LKFileTransferCreateDirectoriesKey: @(createIntermediateDirectories)
    };
    return [self _requestWithType:LKRequestTypeFileTransfer data:payload];
}

- (RACSignal *)writeFileFromMacURLString:(NSString *)sourceURLString
                   toSandboxRelativePath:(NSString *)remotePath
                               overwrite:(BOOL)overwrite
           createIntermediateDirectories:(BOOL)createIntermediateDirectories {
    if (!sourceURLString.length || !remotePath.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (![self supportsFileTransfer]) {
        return [RACSignal error:[self fileTransferUnsupportedError]];
    }
    NSURL *sourceURL = [NSURL URLWithString:sourceURLString];
    if (!sourceURL) {
        NSError *error = LookinErrorMake(@"The URL is invalid.", @"Please provide a valid macOS-accessible URL.");
        return [RACSignal error:error];
    }
    
    @weakify(self);
    return [[self _fetchDataFromMacURL:sourceURL] flattenMap:^__kindof RACSignal * _Nullable(NSData * _Nullable data) {
        @strongify(self);
        if (!self) {
            return [RACSignal error:LookinErr_Inner];
        }
        return [self writeFileData:data
              toSandboxRelativePath:remotePath
                          overwrite:overwrite
      createIntermediateDirectories:createIntermediateDirectories];
    }];
}

- (RACSignal *)downloadFileFromSourceURLString:(NSString *)sourceURLString
                         toSandboxRelativePath:(NSString *)remotePath
                                     overwrite:(BOOL)overwrite
                 createIntermediateDirectories:(BOOL)createIntermediateDirectories {
    if (!sourceURLString.length || !remotePath.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (![self supportsFileTransfer]) {
        return [RACSignal error:[self fileTransferUnsupportedError]];
    }
    NSDictionary *payload = @{
        LKFileTransferActionKey: LKFileTransferActionDownloadFromURL,
        LKFileTransferSourceURLKey: sourceURLString,
        LKFileTransferRemotePathKey: remotePath,
        LKFileTransferOverwriteKey: @(overwrite),
        LKFileTransferCreateDirectoriesKey: @(createIntermediateDirectories)
    };
    return [self _requestWithType:LKRequestTypeFileTransfer data:payload];
}

- (RACSignal *)readFileAtSandboxRelativePath:(NSString *)remotePath {
    if (!remotePath.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (![self supportsFileTransfer]) {
        return [RACSignal error:[self fileTransferUnsupportedError]];
    }
    NSDictionary *payload = @{
        LKFileTransferActionKey: LKFileTransferActionReadFile,
        LKFileTransferRemotePathKey: remotePath
    };
    return [self _requestWithType:LKRequestTypeFileTransfer data:payload];
}

- (RACSignal *)listDirectoryAtSandboxRelativePath:(NSString *)remotePath {
    if (!remotePath) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (![self supportsFileTransfer]) {
        return [RACSignal error:[self fileTransferUnsupportedError]];
    }
    NSDictionary *payload = @{
        LKFileTransferActionKey: LKFileTransferActionListDirectory,
        LKFileTransferRemotePathKey: remotePath
    };
    return [self _requestWithType:LKRequestTypeFileTransfer data:payload];
}

- (RACSignal *)createDirectoryAtSandboxRelativePath:(NSString *)remotePath
                   createIntermediateDirectories:(BOOL)createIntermediateDirectories {
    if (!remotePath.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (![self supportsFileTransfer]) {
        return [RACSignal error:[self fileTransferUnsupportedError]];
    }
    NSDictionary *payload = @{
        LKFileTransferActionKey: LKFileTransferActionCreateDirectory,
        LKFileTransferRemotePathKey: remotePath,
        LKFileTransferCreateDirectoriesKey: @(createIntermediateDirectories)
    };
    return [self _requestWithType:LKRequestTypeFileTransfer data:payload];
}

- (RACSignal *)removeItemAtSandboxRelativePath:(NSString *)remotePath {
    if (!remotePath.length) {
        return [RACSignal error:LookinErr_Inner];
    }
    if (![self supportsFileTransfer]) {
        return [RACSignal error:[self fileTransferUnsupportedError]];
    }
    NSDictionary *payload = @{
        LKFileTransferActionKey: LKFileTransferActionRemoveItem,
        LKFileTransferRemotePathKey: remotePath
    };
    return [self _requestWithType:LKRequestTypeFileTransfer data:payload];
}

#pragma mark - Push From iOS


#pragma mark - Private

- (RACSignal *)_fetchDataFromMacURL:(NSURL *)url {
    return [RACSignal createSignal:^RACDisposable * _Nullable(id<RACSubscriber>  _Nonnull subscriber) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
            if (!data) {
                if (!error) {
                    error = LookinErrorMake(@"Failed to download the file from the macOS URL.", url.absoluteString ?: @"");
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [subscriber sendError:error];
                });
                return;
            }
            if (data.length > LKInlineFileTransferMaxSize) {
                NSError *sizeError = LookinErrorMake(@"The downloaded file is too large for inline USB transfer.",
                                                     @"The current macOS client only supports single-request transfers up to 32 MB. Extend the protocol with chunked streaming if you need larger files.");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [subscriber sendError:sizeError];
                });
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [subscriber sendNext:data];
                [subscriber sendCompleted];
            });
        });
        return nil;
    }];
}

- (void)_pushWithType:(uint32_t)pushType data:(id)data {
    if (!self.channel) {
        return;
    }
    [[LKConnectionManager sharedInstance] pushWithType:pushType data:data channel:self.channel];
}

- (RACSignal *)_requestWithType:(uint32_t)requestType data:(id)data {
    if (!self.channel) {
        return [RACSignal error:LookinErr_NoConnect];
    }
    return [[[LKConnectionManager sharedInstance] requestWithType:requestType data:data channel:self.channel] flattenMap:^__kindof RACSignal * _Nullable(RACTuple *tuple) {
        LookinConnectionResponseAttachment *attachment = tuple.first;
        if (attachment.error) {
            // 翻译成本地文字
            if (attachment.error.code == LookinErrCode_ObjectNotFound) {
                attachment.error = LookinErr_ObjNotFound;
            } else if (attachment.error.code == LookinErrCode_Inner) {
                attachment.error = LookinErr_Inner;
            }
            return [RACSignal error:attachment.error];
        } else {
            return [RACSignal return:attachment.data];
        }
    }];
}

- (void)_cancelRequestWithType:(uint32_t)requestType {
    if (!self.channel) {
        return;
    }
    [[LKConnectionManager sharedInstance] cancelRequestWithType:requestType channel:self.channel];
}

@end

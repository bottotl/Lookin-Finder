# USB File Transfer Protocol

This repository now includes a headless CLI mode in the macOS app binary:

```bash
LookinClient usb list-apps
LookinClient usb push-file --bundle-id com.example.demo --local-path ~/Desktop/config.json --remote-path Documents/config.json
LookinClient usb pull-file --bundle-id com.example.demo --remote-path Library/Caches/state.bin --local-path ~/Desktop/state.bin
```

## Scope

- Transport layer: existing Lookin USB channel (`Lookin_PTChannel` over `Lookin_PTUSBHub`)
- Business layer: one request type (`215`) for file and directory operations
- Path convention: `remotePath` is relative to the iOS app sandbox root (`NSHomeDirectory()`)
- Root directory convention: `remotePath == @""` means the sandbox root directory itself

Examples:

- `""` (sandbox root directory)
- `Documents/config.json`
- `Library/Caches/state.bin`
- `tmp/debug/output.log`

## Request Contract

Request type used by the macOS client:

- `215`: file transfer

Payload keys:

- `action`
- `remotePath`
- `content`
- `overwrite`
- `createIntermediateDirectories`

Supported actions:

- `readFile`
- `writeFile`
- `listDirectory`
- `createDirectory`
- `removeItem`
- `downloadFromURL`

## Root Path Rules

- `listDirectory` must accept `remotePath == @""` and interpret it as the sandbox root directory.
- `readFile`, `writeFile`, `createDirectory`, and `removeItem` require a non-empty relative path.
- `removeItem` should reject `remotePath == @""`; deleting the sandbox root is not a valid operation.

### Write File

Request payload:

```objc
@{
    @"action": @"writeFile",
    @"remotePath": @"Documents/config.json",
    @"content": <NSData *>,
    @"overwrite": @YES,
    @"createIntermediateDirectories": @YES
}
```

Suggested response payload:

```objc
@{
    @"remotePath": @"Documents/config.json",
    @"writtenBytes": @(data.length)
}
```

### Read File

Request payload:

```objc
@{
    @"action": @"readFile",
    @"remotePath": @"Library/Caches/state.bin"
}
```

Suggested response payload:

```objc
@{
    @"remotePath": @"Library/Caches/state.bin",
    @"content": <NSData *>,
    @"fileSize": @(data.length)
}
```

The macOS client also accepts a bare `NSData` response for `readFile`, but returning a dictionary is preferred.

### List Directory

Request payload:

```objc
@{
    @"action": @"listDirectory",
    @"remotePath": @""
}
```

Suggested response payload:

```objc
@{
    @"remotePath": @"",
    @"items": @[
        @{
            @"name": @"Documents",
            @"remotePath": @"Documents",
            @"isDirectory": @YES
        },
        @{
            @"name": @"config.json",
            @"remotePath": @"config.json",
            @"isDirectory": @NO,
            @"fileSize": @(1234)
        }
    ]
}
```

Minimum recommended item fields:

- `name`: last path component for display
- `remotePath`: sandbox-relative path for subsequent actions
- `isDirectory`: `@YES` for directories, `@NO` for regular files

Optional item fields:

- `fileSize`: recommended for files; omit for directories if not available

### Create Directory

Request payload:

```objc
@{
    @"action": @"createDirectory",
    @"remotePath": @"Documents/Exports",
    @"createIntermediateDirectories": @YES
}
```

Suggested response payload:

```objc
@{
    @"remotePath": @"Documents/Exports",
    @"created": @YES
}
```

### Remove Item

Request payload:

```objc
@{
    @"action": @"removeItem",
    @"remotePath": @"tmp/debug/output.log"
}
```

Suggested response payload:

```objc
@{
    @"remotePath": @"tmp/debug/output.log",
    @"removed": @YES
}
```

`removeItem` may target either a file or a directory. If the target is a directory, the iOS side should match `NSFileManager -removeItemAtPath:error:` behavior.

### Download From URL

Request payload:

```objc
@{
    @"action": @"downloadFromURL",
    @"sourceURL": @"https://example.com/template.xji",
    @"remotePath": @"Documents/template.xji",
    @"overwrite": @YES,
    @"createIntermediateDirectories": @YES
}
```

Suggested response payload:

```objc
@{
    @"sourceURL": @"https://example.com/template.xji",
    @"remotePath": @"Documents/template.xji",
    @"writtenBytes": @(data.length)
}
```

This action is intended for URLs that are directly reachable from the iOS device.

## Current Limitation

The current macOS implementation sends file bytes inline inside one request/response.

- Maximum supported inline payload size: `32 MB`
- This limit applies to request/response bodies that carry `content` bytes (`writeFile` request and `readFile` response).
- Directory actions (`listDirectory`, `createDirectory`, `removeItem`) do not carry inline file content, so they are not constrained by the `32 MB` file-byte limit.
- If you need larger file transfers, extend the protocol with chunked upload/download frames instead of increasing the inline limit.

## Mac-Hosted URL Download

If your source file is exposed by a service running on the Mac side, for example:

```objc
[NSString stringWithFormat:@"http://localhost:3335/templates/%@.xji", @"XJI-Chat"]
```

do not make the real iOS device resolve that URL directly.

On a real device:

- `localhost` means the iPhone/iPad itself
- it does not point to the paired Mac

For this case, the recommended flow is:

1. let the macOS client download the URL locally
2. then reuse `writeFile` over the existing USB channel

The macOS client now exposes a convenience wrapper for this flow:

```objc
- (RACSignal *)writeFileFromMacURLString:(NSString *)sourceURLString
                   toSandboxRelativePath:(NSString *)remotePath
                               overwrite:(BOOL)overwrite
           createIntermediateDirectories:(BOOL)createIntermediateDirectories;
```

This keeps `http://localhost:3335/...` valid because the URL is resolved on the Mac, not on the iOS device.

By contrast, the iOS-side `downloadFromURL` action should reject `localhost` / `127.0.0.1` / `::1` because those addresses point back to the device itself on real hardware.

## iOS-Side Requirements

This repo does not contain the full iOS `LookinServer` implementation, so the request handler must be added on the iOS side.

Recommended behavior on iOS:

1. Normalize `remotePath` against `NSHomeDirectory()`.
2. Treat `remotePath == @""` as the sandbox root directory for directory-listing scenarios.
3. Reject absolute paths that escape the sandbox root.
4. Reject `..` path traversal that escapes the sandbox root after normalization.
5. For `writeFile` and `createDirectory`, create intermediate directories only when `createIntermediateDirectories == YES`.
6. Respect `overwrite == NO`.
7. Reject `removeItem` on the sandbox root (`remotePath == @""`).
8. Return a normal `LookinConnectionResponseAttachment` with either response data or an `NSError`.

If you still want an iOS-side API shaped like "download from URL", the safest contract is:

1. use iOS-side `downloadFromURL` only for device-reachable hosts
2. use the mac-side bridge when the URL points to a Mac-local service such as `localhost:3335`

Suggested error cases:

- target path escapes sandbox root
- attempt to delete sandbox root
- target path already exists and overwrite is disabled
- file not found
- target path points to a directory when a regular file is expected
- target path points to a file when a directory is expected
- write/read failure from `NSFileManager` or `NSData`

## Compatibility

Older iOS builds that do not implement request type `215` will usually surface as a timeout on the macOS CLI.

The CLI already prints a hint for this case:

- `The target iOS app may not implement file-transfer request type 215 yet.`

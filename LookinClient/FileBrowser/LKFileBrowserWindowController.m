//
//  LKFileBrowserWindowController.m
//  LookinClient
//
//  Created by OpenAI Codex.
//

#import "LKFileBrowserWindowController.h"
#import "LKFileBrowserViewController.h"
#import "LKWindow.h"

@implementation LKFileBrowserWindowController

- (instancetype)init {
    LKWindow *window = [[LKWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1080, 720)
                                                   styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.title = NSLocalizedString(@"File Browser", nil);
    window.minSize = CGSizeMake(820, 520);
    [window center];
    
    if (self = [self initWithWindow:window]) {
        LKFileBrowserViewController *vc = [LKFileBrowserViewController new];
        self.contentViewController = vc;
        window.contentView = vc.view;
    }
    return self;
}

@end

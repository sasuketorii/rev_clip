//
//  main.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Cocoa/Cocoa.h>
#import "RCSingleInstanceLock.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // One process per data store, decided before any side effect (keychain, status
        // item, login item, alerts). A lock-file failure fails open.
        switch (RCSingleInstanceLockAcquireForProcess()) {
            case RCSingleInstanceLockResultHeld:
                NSLog(@"[Revclip] Another instance is already running; exiting.");
                return 0;
            case RCSingleInstanceLockResultError:
                NSLog(@"[Revclip] Could not take the single-instance lock; continuing without it.");
                break;
            case RCSingleInstanceLockResultAcquired:
                break;
        }
        return NSApplicationMain(argc, argv);
    }
}

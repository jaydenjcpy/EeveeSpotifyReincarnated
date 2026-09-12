#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <string.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/vm_prot.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>
#import "Tweak.h"

#if THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <libroot.h>
#endif

NSString *EeveeJBRootPath(NSString *path) {
#if THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return JBROOT_PATH_NSSTRING(path);
#endif
}

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument) {
    if (!target || !selector) return;
    typedef id (*SeekFn)(id, SEL, double);
    SeekFn fn = (SeekFn)objc_msgSend;
    (void)fn(target, selector, argument);
}

// NOP encoding on ARM64.
static const uint32_t kARM64NOP = 0xD503201F;

static void writeDebugLog(NSString *message);

BOOL EeveeSBPatchInstruction(uintptr_t runtimeAddress) {
    if (runtimeAddress == 0) return NO;

    // Verify the bytes we expect (any non-NOP code) are still there.
    uint32_t currentValue = 0;
    memcpy(&currentValue, (const void *)runtimeAddress, sizeof(uint32_t));
    if (currentValue == kARM64NOP) return YES; // already patched

    // Make the page containing the target instruction writable.
    // __TEXT is normally r-x; we flip to rw- for the duration of the write.
    vm_address_t page = runtimeAddress & ~0xFFFULL;

    kern_return_t kr = vm_protect(mach_task_self(), page, 0x1000, false,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        writeDebugLog([NSString stringWithFormat:@"[LyricsGatePatch] vm_protect RW failed: %d (PPL may be blocking)", kr]);
        return NO;
    }

    // Write the NOP.
    uint32_t nopBytes = kARM64NOP;
    memcpy((void *)runtimeAddress, &nopBytes, sizeof(uint32_t));

    // Flush instruction cache for the modified region.
    sys_icache_invalidate((void *)runtimeAddress, sizeof(uint32_t));

    // Restore original protection (r-x for __TEXT).
    vm_protect(mach_task_self(), page, 0x1000, false,
               VM_PROT_READ | VM_PROT_EXECUTE);

    // Verify post-patch state.
    uint32_t patched = 0;
    memcpy(&patched, (const void *)runtimeAddress, sizeof(uint32_t));
    return patched == kARM64NOP;
}

static void writeDebugLog(NSString *message) {
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void init() {
    @try {
        NSLog(@"[EeveeSpotify] Initializing tweak...");

        // Initialize Orion - do not remove this line.
        orion_init();

        NSLog(@"[EeveeSpotify] Tweak initialized successfully");
        // Custom initialization code goes here.
    }
    @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:@"ERROR: Failed to initialize tweak: %@, Reason: %@", exception, [exception reason]];
        NSLog(@"[EeveeSpotify] %@", errorMsg);
        writeDebugLog(errorMsg);
    }
}

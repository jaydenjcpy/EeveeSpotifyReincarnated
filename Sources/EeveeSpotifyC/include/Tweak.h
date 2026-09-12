#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);
NSString *EeveeJBRootPath(NSString *path);

// Inline memory patch helper: NOP a 4-byte ARM64 instruction at the given
// dyld-resolved runtime address (in-process). Temporarily flips the containing
// page to RW with vm_protect, writes the NOP, then restores RX and flushes the
// instruction cache via sys_icache_invalidate.
// Returns YES on success, NO on failure (bad address / protections denied).
BOOL EeveeSBPatchInstruction(uintptr_t runtimeAddress);

NS_ASSUME_NONNULL_END

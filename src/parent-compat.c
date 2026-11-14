#include <Carbon/Carbon.h>
#include <unistd.h>

/* Leave every result alone except an absent launcher for this process. */
static OSStatus fixed_GetProcessInformation(const ProcessSerialNumber *psn,
                                            ProcessInfoRec *info)
{
    OSStatus status = GetProcessInformation(psn, info);
    if (status != noErr || !psn || !info ||
        info->processLauncher.highLongOfPSN ||
        info->processLauncher.lowLongOfPSN)
        return status;

    ProcessSerialNumber self = {0, 0}, parent = {0, 0};
    if (GetCurrentProcess(&self) != noErr ||
        self.highLongOfPSN != psn->highLongOfPSN ||
        self.lowLongOfPSN != psn->lowLongOfPSN)
        return status;

    if (GetProcessForPID(getppid(), &parent) == noErr)
        info->processLauncher = parent;
    return status;
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} interpose __attribute__((section("__DATA,__interpose,interposing"))) = {
    (const void *)&fixed_GetProcessInformation,
    (const void *)&GetProcessInformation
};

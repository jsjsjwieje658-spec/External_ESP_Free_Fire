#import "MemoryUtils.h"
#include <errno.h>
#include <mach/error.h>
#include <stdlib.h>
#include <strings.h> // strcasestr
#include <string.h>

// Case-insensitive substring match across historical/bundle variants.
// Log evidence 2026-11-05: "freefireth" never matched (binary is "FreeFire", case-sensitive strstr).
static bool MatchProcName(const char *comm, const char *needle) {
    if (!comm || !needle || !*needle) return false;
    if (strcasestr(comm, needle)) return true;
    // Known variants for Free Fire TH (bundle com.dts.freefireth, binary FreeFire)
    return strcasestr(comm, "freefire") != NULL || strcasestr(comm, "FreeFire") != NULL;
}

pid_t GetGameProcesspid(char* GameProcessName) {
    size_t length = 0;
    static const int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    int err = sysctl((int *)name, (sizeof(name) / sizeof(*name)) - 1, NULL, &length, NULL, 0);
    
    if (err == -1) {
        err = errno;
        ESP_LOG_ERROR(@"[MEM] sysctl(len) failed errno=%d (%s)", err, strerror(err));
        return -1;
    }
    ESP_LOG_DEBUG(@"[MEM] GetGameProcesspid: proc table bytes=%zu", length);
    
    struct kinfo_proc *procBuffer = (struct kinfo_proc *)malloc(length);
    if (procBuffer == NULL) {
        ESP_LOG_ERROR(@"[MEM] malloc procBuffer failed (len=%zu)", length);
        return -1;
    }
    
    err = sysctl((int *)name, (sizeof(name) / sizeof(*name)) - 1, procBuffer, &length, NULL, 0);
    if (err == -1) {
        err = errno;
        ESP_LOG_ERROR(@"[MEM] sysctl(read) failed errno=%d (%s)", err, strerror(err));
        free(procBuffer);
        return -1;
    }
    
    int count = (int)length / sizeof(struct kinfo_proc);
    ESP_LOG_DEBUG(@"[MEM] scanning %d procs for '%s'", count, GameProcessName);
    int matches = 0;
    for (int i = 0; i < count; ++i) {
        const char *procname = procBuffer[i].kp_proc.p_comm;
        pid_t pid = procBuffer[i].kp_proc.p_pid;
        if (MatchProcName(procname, GameProcessName)) {
            matches++;
            ESP_LOG_INFO(@"[MEM] found '%s' pid=%d (comm='%s')", GameProcessName, pid, procname);
            free(procBuffer);
            return pid;
        }
        // Dump candidates that even vaguely look like the game (helps fix name drift)
        if (procname[0] && strcasestr(procname, "fire") != NULL) {
            ESP_LOG_DEBUG(@"[MEM]   candidate pid=%d comm='%s'", (int)pid, procname);
        }
    }
    
    // On total miss, dump a compact list of unique comms (DEBUG) so the right name can be identified remotely.
    if (matches == 0) {
        ESP_LOG_DEBUG(@"[MEM] dumping all procs (DEBUG) for name diagnosis:");
        for (int i = 0; i < count; ++i) {
            const char *procname = procBuffer[i].kp_proc.p_comm;
            if (procname[0]) {
                ESP_LOG_DEBUG(@"[MEM]   proc pid=%d comm='%s'", (int)procBuffer[i].kp_proc.p_pid, procname);
            }
        }
    }
    ESP_LOG_ERROR(@"[MEM] process '%s' not found among %d procs (case-insensitive) — is game running? see proc dump above.", GameProcessName, count);
    free(procBuffer);
    return -1;
}

vm_map_offset_t GetGameModule_Base(char* GameProcessName) {
    vm_map_offset_t vmoffset = 0;
    vm_map_size_t vmsize = 0;
    uint32_t nesting_depth = 0;
    struct vm_region_submap_info_64 vbr;
    mach_msg_type_number_t vbrcount = 16;
    
    pid_t pid = GetGameProcesspid(GameProcessName);
    Processpid = pid;
    if (pid == -1) {
        ESP_LOG_ERROR(@"[MEM] GetGameModule_Base: pid=-1, abort");
        return 0;
    }
    
    kern_return_t kret = task_for_pid(mach_task_self(), pid, &get_task);
    ESP_LOG_DEBUG(@"[MEM] task_for_pid(self, %d) -> kr=%d (%s) task=0x%x",
        pid, kret, mach_error_string(kret), get_task);
    if (kret != KERN_SUCCESS || get_task == MACH_PORT_NULL) {
        ESP_LOG_ERROR(@"[MEM] task_for_pid FAILED kr=%d (%s) — check entitlements (task_for_pid-allow)!",
            kret, mach_error_string(kret));
        return 0;
    }
    
    kern_return_t kr = mach_vm_region_recurse(get_task, &vmoffset, &vmsize, &nesting_depth, (vm_region_recurse_info_t)&vbr, &vbrcount);
    ESP_LOG_DEBUG(@"[MEM] mach_vm_region_recurse -> kr=%d (%s) base=0x%llx size=0x%llx name='%s'",
        kr, mach_error_string(kr), (unsigned long long)vmoffset,
        (unsigned long long)vmsize, ""); // iOS SDK: no object_name in submap_info
    if (kr == KERN_SUCCESS) {
        ESP_LOG_INFO(@"[MEM] module base=0x%llx (first region) pid=%d", (unsigned long long)vmoffset, pid);
        return vmoffset;
    }
    ESP_LOG_ERROR(@"[MEM] mach_vm_region_recurse FAILED kr=%d (%s)", kr, mach_error_string(kr));
    return 0;
}

bool _read(long addr, void *buffer, int len)
{
    if (!isVaildPtr(addr)) {
        ESP_LOG_DEBUG_THROTTLED(@"[READ] invalid ptr 0x%lx len=%d", addr, len);
        return false;
    }
    vm_size_t size = 0;
    kern_return_t error = vm_read_overwrite(get_task, (vm_address_t)addr, len, (vm_address_t)buffer, &size);
    if(error != KERN_SUCCESS || size != (vm_size_t)len)
    {
        ESP_LOG_DEBUG_THROTTLED(@"[READ] vm_read fail addr=0x%lx len=%d err=%d (%s) got=%zu",
            addr, len, error, mach_error_string(error), (size_t)size);
        return false;
    }
    return true;
}

extern "C" task_t ESPGetTargetTask(void) { return get_task; }
extern "C" pid_t ESPGetTargetPid(void) { return Processpid; }

#ifndef MemoryUtils_h
#define MemoryUtils_h

#include <mach/mach.h>
#include <sys/sysctl.h>
#include <string>
#include "DebugLogger.h"

#pragma mark - Get PID

static mach_port_t get_task;
static pid_t Processpid;

extern "C" kern_return_t mach_vm_region_recurse(vm_map_t                 map,
                                                mach_vm_address_t        *address,
                                                mach_vm_size_t           *size,
                                                uint32_t                 *depth,
                                                vm_region_recurse_info_t info,
                                                mach_msg_type_number_t   *infoCnt);

inline bool isVaildPtr(long addr){
    return addr > 0x100000000 && addr < 0x1600000000;
}

pid_t GetGameProcesspid(char* GameProcessName);
vm_map_offset_t GetGameModule_Base(char* GameProcessName);
bool _read(long addr, void *buffer, int len);

template<typename T> T ReadAddr(long address) {
    // Fix (log 2026-11-05): was `T data;` — UNINITIALIZED on read failure, so garbage
    // stack values repeatedly "validated" as pointers (e.g. StaticBlock=MatchGame=0x2c000000f).
    // Zero-init so failed reads deterministically yield 0 (invalid pointer).
    T data{};
    if (!_read(address, reinterpret_cast<void *>(&data), sizeof(T))) {
        // Keep silent at DEBUG here (hot path) — callers log stage-level failures.
        // ESP_LOG_DEBUG(@"[READ] fail addr=0x%lx size=%zu", address, sizeof(T));
    }
    return data;
}

// --- Task accessors (fix static-header linkage: header statics are per-TU copies) ---
// GetGameModule_Base stores the task in MemoryUtils.cpp's TU copy; other TUs
// must fetch it via these functions instead of reading `get_task` directly.
#ifdef __cplusplus
extern "C" {
#endif
task_t ESPGetTargetTask(void);
pid_t ESPGetTargetPid(void);
#ifdef __cplusplus
}
#endif

#endif

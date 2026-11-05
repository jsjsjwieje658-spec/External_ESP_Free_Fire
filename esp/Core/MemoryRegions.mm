#import "MemoryRegions.h"
#import "DebugLogger.h"
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <stdio.h>

extern "C" kern_return_t mach_vm_region_recurse(vm_map_t map,
                                                mach_vm_address_t *address,
                                                mach_vm_size_t *size,
                                                uint32_t *depth,
                                                vm_region_recurse_info_t info,
                                                mach_msg_type_number_t *infoCnt);

std::vector<VMRegionInfo> ESPEnumerateRegions(task_t task) {
    std::vector<VMRegionInfo> out;
    if (task == MACH_PORT_NULL || task == (task_t)MACH_PORT_NULL) {
        ESP_LOG_ERROR(@"[MEM] ESPEnumerateRegions: null task");
        return out;
    }
    mach_vm_address_t addr = 0;
    mach_vm_size_t size = 0;
    uint32_t depth = 0;
    while (true) {
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = mach_vm_region_recurse(task, &addr, &size, &depth,
                                                  (vm_region_recurse_info_t)&info, &infoCount);
        if (kr != KERN_SUCCESS) break; // end of map (KERN_INVALID_ADDRESS) or error
        VMRegionInfo r;
        r.address = addr; r.size = size;
        r.protection = info.protection;
        r.nesting = (int)depth;
        r.name = ""; // iOS SDK: vm_region_submap_info_64 has no object_name (debug-only; dropped)
        r.readable = (info.protection & VM_PROT_READ) != 0;
        out.push_back(std::move(r));
        addr += size;
        if (size == 0) break;
    }
    ESP_LOG_DEBUG(@"[MEM] enumerated %zu regions", out.size());
    return out;
}

void ESPDumpRegions(task_t task, const char *tag) {
    auto regions = ESPEnumerateRegions(task);
    for (auto &r : regions) {
        ESP_LOG_DEBUG(@"[MEMMAP] 0x%llx +0x%llx prot=0x%x nest=%d %s",
            (unsigned long long)r.address, (unsigned long long)r.size,
            r.protection, r.nesting, r.name.c_str());
    }
}

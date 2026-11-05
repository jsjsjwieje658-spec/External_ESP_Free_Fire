// MemoryRegions.h — enumerate target process VM regions via mach_vm_region_recurse
// Used by OffsetScanner to bound scans (only readable regions) and to print a
// human-readable map for debugging (like `vmmap`).
#ifndef MemoryRegions_h
#define MemoryRegions_h

#include <mach/mach.h>
#include <stdint.h>
#include <vector>
#include <string>

struct VMRegionInfo {
    uint64_t address;
    uint64_t size;
    uint32_t protection;
    int nesting;
    std::string name;
    bool readable;
};

// NOTE: NOT extern "C" — std::vector/std::string are C++ types.
std::vector<VMRegionInfo> ESPEnumerateRegions(task_t task);
void ESPDumpRegions(task_t task, const char *tag);

#endif

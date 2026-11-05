#import "AOBScanner.h"
#import "DebugLogger.h"
#import "MemoryRegions.h"
#import "MemoryUtils.h"
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <ctype.h>
#include <string.h>

static const size_t kChunk = 64 * 1024;

bool ESParsePattern(const char *pattern, std::vector<uint8_t> *bytes, std::vector<bool> *wild) {
    if (!pattern || !bytes || !wild) return false;
    bytes->clear(); wild->clear();
    const char *p = pattern;
    while (*p) {
        while (*p && isspace((unsigned char)*p)) p++;
        if (!*p) break;
        // token = 2 chars: "48", "??", "?f" (nibble wildcard also allowed)
        int hi = -1, lo = -1; // -1 = wildcard nibble
        bool isWild = false;
        if (p[0] == '?' && p[1] == '?') { isWild = true; p += 2; }
        else if (p[0] == '?' && isxdigit((unsigned char)p[1])) {
            hi = -1; lo = (p[1] <= '9') ? p[1]-'0' : (tolower(p[1])-'a'+10);
            isWild = true; p += 2; // nibble-wildcard treated as full wildcard in byte compare
        }
        else if (isxdigit((unsigned char)p[0]) && isxdigit((unsigned char)p[1])) {
            hi = (p[0] <= '9') ? p[0]-'0' : (tolower(p[0])-'a'+10);
            lo = (p[1] <= '9') ? p[1]-'0' : (tolower(p[1])-'a'+10);
            p += 2;
        } else {
            ESP_LOG_ERROR(@"[AOB] bad pattern near '%s'", p);
            return false;
        }
        uint8_t b = (hi < 0 ? 0 : (hi << 4)) | (lo < 0 ? 0 : lo);
        bytes->push_back(b);
        wild->push_back(isWild);
        if (*p == ',') p++; // allow comma separators
    }
    if (bytes->empty()) { ESP_LOG_ERROR(@"[AOB] empty pattern"); return false; }
    ESP_LOG_DEBUG(@"[AOB] parsed %zu bytes from '%s'", bytes->size(), pattern);
    return true;
}

std::vector<uint64_t> ESPScanRegion(task_t task, uint64_t start, uint64_t len,
                                    const std::vector<uint8_t> &pat, const std::vector<bool> &wild,
                                    size_t maxResults) {
    std::vector<uint64_t> hits;
    if (pat.empty() || len < pat.size()) return hits;
    std::vector<uint8_t> buf(kChunk);
    uint64_t off = 0;
    while (off < len && hits.size() < maxResults) {
        uint64_t toRead = len - off;
        if (toRead > kChunk) toRead = kChunk;
        // vm_read_overwrite via _read() would check isVaildPtr range — bypass by calling
        // vm_read_overwrite directly so we can scan any readable map address.
        vm_size_t sz = 0;
        kern_return_t kr = vm_read_overwrite(task, (vm_address_t)(start + off),
                                             (vm_size_t)toRead, (vm_address_t)buf.data(), &sz);
        if (kr != KERN_SUCCESS || sz == 0) { off += toRead; continue; }
        size_t n = (size_t)sz;
        if (n >= pat.size()) {
            for (size_t i = 0; i + pat.size() <= n && hits.size() < maxResults; i++) {
                bool ok = true;
                for (size_t j = 0; j < pat.size(); j++) {
                    if (!wild[j] && buf[i + j] != pat[j]) { ok = false; break; }
                }
                if (ok) hits.push_back(start + off + i);
            }
        }
        off += toRead;
        // Progress at DEBUG so huge scans are observable but not spammy.
        if ((off & 0xFFFFF) == 0)
            ESP_LOG_DEBUG_THROTTLED(@"[AOB] scan 0x%llx progress 0x%llx/0x%llx hits=%zu",
                (unsigned long long)start, (unsigned long long)off,
                (unsigned long long)len, hits.size());
    }
    return hits;
}

std::vector<uint64_t> ESPScanTask(task_t task, uint64_t rangeStart, uint64_t rangeEnd,
                                  const char *pattern, size_t maxResults) {
    std::vector<uint64_t> all;
    std::vector<uint8_t> pat; std::vector<bool> wild;
    if (!ESParsePattern(pattern, &pat, &wild)) return all;
    ESP_LOG_INFO(@"[AOB] scanning pattern '%s' range [0x%llx, 0x%llx)",
        pattern, (unsigned long long)rangeStart, (unsigned long long)rangeEnd);
    auto regions = ESPEnumerateRegions(task);
    ESP_LOG_INFO(@"[AOB] readable regions to scan: (see MEMMAP for list)");
    for (auto &r : regions) {
        if (!r.readable || r.size == 0) continue;
        uint64_t rs = r.address, re = r.address + r.size;
        if (rangeStart || rangeEnd) {
            if (re <= rangeStart || rs >= rangeEnd) continue;
            rs = rs < rangeStart ? rangeStart : rs;
            re = re > rangeEnd ? rangeEnd : re;
        }
        uint64_t len = re - rs;
        if (len < pat.size()) continue;
        ESP_LOG_DEBUG(@"[AOB] scanning region 0x%llx+0x%llx %s",
            (unsigned long long)rs, (unsigned long long)len, r.name.c_str());
        auto hits = ESPScanRegion(task, rs, len, pat, wild, maxResults - all.size());
        all.insert(all.end(), hits.begin(), hits.end());
        if (all.size() >= maxResults) break;
        // Avoid scanning gigantic anonymous regions with common patterns
        // (still scanned if user explicitly passed range 0/0).
    }
    ESP_LOG_INFO(@"[AOB] done: %zu hit(s) for '%s'", all.size(), pattern);
    for (auto h : all) ESP_LOG_INFO(@"[AOB] hit 0x%llx", (unsigned long long)h);
    return all;
}

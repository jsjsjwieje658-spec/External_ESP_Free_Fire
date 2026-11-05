// AOBScanner.h — AOB (Array Of Bytes) pattern scanner over another process via vm_read_overwrite.
// Pattern format: "48 8B ?? ?? 90 ??" (? = wildcard). Lengths in BYTES (not dwords).
// Used to re-find code/data when hardcoded RVA shifts (e.g. GameFacade TypeInfo).
// All scans are chunked (default 64KB) with progress logs.
#ifndef AOBScanner_h
#define AOBScanner_h

#include <stdint.h>
#include <stddef.h>
#include <vector>
#include <string>
#include <mach/mach.h> // task_t

// NOTE: NOT extern "C" — std::vector in signature.
bool ESParsePattern(const char *pattern, std::vector<uint8_t> *bytes, std::vector<bool> *wild);
std::vector<uint64_t> ESPScanRegion(task_t task, uint64_t start, uint64_t len,
                                    const std::vector<uint8_t> &pat, const std::vector<bool> &wild,
                                    size_t maxResults);
std::vector<uint64_t> ESPScanTask(task_t task, uint64_t rangeStart, uint64_t rangeEnd,
                                  const char *pattern, size_t maxResults);

#endif

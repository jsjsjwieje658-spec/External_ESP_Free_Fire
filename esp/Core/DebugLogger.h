// DebugLogger.h — unified debug logging for External ESP
// Adds: levels, timestamps, PID/base context, file log, timing guards, throttling.
// Usage (C++):
//   ESP_LOG_INFO(@"[ESP] base=%llx pid=%d", base, pid);
//   ESP_LOG_DEBUG(@"[ESP] chain matchGame=%llx", matchGame);
//   ESP_LOG_ERROR(@"[ESP] failed at stage=CameraMain err=invalid ptr camMgr=%llx", mgr);
// Usage (ObjC++ .mm): same macros (NSLog-backed, thread-safe).
#ifndef DebugLogger_h
#define DebugLogger_h

#include <Foundation/Foundation.h>
#include <stdint.h>
#include <stdarg.h>

// Compile-time gate: set to 0 to strip DEBUG logs in release (keep INFO/WARN/ERROR).
#ifndef ESP_DEBUG_ENABLED
#define ESP_DEBUG_ENABLED 1
#endif

// Throttle: per-file-frame logs (update_data runs at display rate) should not flood
// syslog/file. Set 1 to throttle DEBUG in update_data (log every Nth call).
#ifndef ESP_LOG_THROTTLE_DEBUG
#define ESP_LOG_THROTTLE_DEBUG 1
#endif

typedef NS_ENUM(NSUInteger, ESPLogLevel) {
    ESPLogLevelDebug = 0,
    ESPLogLevelInfo  = 1,
    ESPLogLevelWarn  = 2,
    ESPLogLevelError = 3,
    ESPLogLevelOff   = 4
};

#ifdef __cplusplus
extern "C" {
#endif

// Runtime level (default INFO). Set to DEBUG for verbose, OFF to silence.
void ESPSetLogLevel(ESPLogLevel level);
ESPLogLevel ESPGetLogLevel(void);

// Single entry point. Also mirrors to file if ESPLogToFile(true) was called
// (file: Documents/esp_debug.log — persist across HUD restarts, readable via
// Filza/TrollStore or `idevicesyslog`).
void ESPLog(ESPLogLevel level, const char *tag, NSString *fmt, ...);
void ESPLogToFile(BOOL enabled);

// Scoped timer: measures wall time of a block, logs at DEBUG/INFO.
typedef struct ESPScopedTimer {
    uint64_t startTicks; // CACurrentMediaTime() ticks
    const char *name;
    BOOL logAtEnd;
} ESPScopedTimer;

ESPScopedTimer ESPScopedTimerBegin(const char *name, BOOL logAtEnd);
void ESPScopedTimerEnd(ESPScopedTimer *timer);

#ifdef __cplusplus
}
#endif

// Macros — forward to ESPLog. `tag` defaults to __func__-ish short name.
#define _ESPONCE_TAG __func__

#define ESP_LOG_DEBUG(fmt, ...) \
    do { if (ESPGetLogLevel() <= ESPLogLevelDebug) \
        ESPLog(ESPLogLevelDebug, _ESPONCE_TAG, @fmt, ##__VA_ARGS__); } while(0)

#define ESP_LOG_INFO(fmt, ...) \
    do { if (ESPGetLogLevel() <= ESPLogLevelInfo) \
        ESPLog(ESPLogLevelInfo, _ESPONCE_TAG, @fmt, ##__VA_ARGS__); } while(0)

#define ESP_LOG_WARN(fmt, ...) \
    do { if (ESPGetLogLevel() <= ESPLogLevelWarn) \
        ESPLog(ESPLogLevelWarn, _ESPONCE_TAG, @fmt, ##__VA_ARGS__); } while(0)

#define ESP_LOG_ERROR(fmt, ...) \
    do { if (ESPGetLogLevel() <= ESPLogLevelError) \
        ESPLog(ESPLogLevelError, _ESPONCE_TAG, @fmt, ##__VA_ARGS__); } while(0)

// Throttled DEBUG for per-frame paths: logs every Nth invocation (N=30 ~2Hz).
#define ESP_LOG_DEBUG_THROTTLED(fmt, ...) \
    do { static NSUInteger _n = 0; if ((++_n % 30) == 0 && ESPGetLogLevel() <= ESPLogLevelDebug) \
        ESPLog(ESPLogLevelDebug, _ESPONCE_TAG, @fmt, ##__VA_ARGS__); } while(0)

// One-shot INFO (first N calls) for init paths.
#define ESP_LOG_INFO_ONCE(fmt, ...) \
    do { static NSUInteger _n = 0; if (_n++ < 5) \
        ESPLog(ESPLogLevelInfo, _ESPONCE_TAG, @fmt, ##__VA_ARGS__); } while(0)

#endif

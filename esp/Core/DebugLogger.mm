#import "DebugLogger.h"
#include <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static ESPLogLevel gLevel = ESPLogLevelInfo;
static BOOL gToFile = NO;
static NSString *gLogFile = nil;
static dispatch_queue_t gLogQueue = nil;

static dispatch_queue_t ESPLogQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQueue = dispatch_queue_create("dev.flork.external.esplog", DISPATCH_QUEUE_SERIAL);
        gLogFile = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/esp_debug.log"];
    });
    return gLogQueue;
}

extern "C" {
void ESPSetLogLevel(ESPLogLevel level) { gLevel = level; }
ESPLogLevel ESPGetLogLevel(void) { return gLevel; }
void ESPLogToFile(BOOL enabled) { gToFile = enabled; }

static NSString *ESPLevelString(ESPLogLevel lvl) {
    switch (lvl) {
        case ESPLogLevelDebug: return @"DEBUG";
        case ESPLogLevelInfo:  return @"INFO";
        case ESPLogLevelWarn:  return @"WARN";
        case ESPLogLevelError: return @"ERROR";
        default: return @"?";
    }
}

void ESPLog(ESPLogLevel level, const char *tag, NSString *fmt, ...) {
    if (level < gLevel || gLevel == ESPLogLevelOff) return;
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [%@] (%s) %@",
        [[NSDate date] description], ESPLevelString(level), tag ? tag : "?", body];
    // Console (NSLog) + optional file mirror. Serial queue keeps ordering.
    dispatch_async(ESPLogQueue(), ^{
        NSLog(@"%@", line);
        if (gToFile) {
            NSString *withNL = [line stringByAppendingString:@"\n"];
            @try {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogFile];
                if (!fh) {
                    [@"" writeToFile:gLogFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    fh = [NSFileHandle fileHandleForWritingAtPath:gLogFile];
                }
                [fh seekToEndOfFile];
                [fh writeData:[withNL dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) {}
        }
    });
}

ESPScopedTimer ESPScopedTimerBegin(const char *name, BOOL logAtEnd) {
    ESPScopedTimer t; t.startTicks = (uint64_t)(CACurrentMediaTime() * 1000000.0);
    t.name = name; t.logAtEnd = logAtEnd; return t;
}

void ESPScopedTimerEnd(ESPScopedTimer *timer) {
    if (!timer->logAtEnd) return;
    uint64_t now = (uint64_t)(CACurrentMediaTime() * 1000000.0);
    double ms = (double)(now - timer->startTicks) / 1000.0;
    ESP_LOG_DEBUG(@"[TIMER] %s took %.2f ms", timer->name ? timer->name : "?", ms);
}
} // extern "C"

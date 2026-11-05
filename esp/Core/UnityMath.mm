#import "UnityMath.h"
#include <math.h>

#pragma mark - Function Unity

Vector3 WorldToScreen(Vector3 obj, float *matrix, float screenX, float screenY) {
    Vector3 screen;
    if (!matrix) { ESP_LOG_ERROR(@"[W2S] null matrix"); screen.x=0; screen.y=0; return screen; }
    if (isnan(obj.x) || isnan(obj.y) || isnan(obj.z) || isinf(obj.x) || isinf(obj.y) || isinf(obj.z)) {
        ESP_LOG_WARN(@"[W2S] NaN obj=(%f,%f,%f)", obj.x, obj.y, obj.z);
    }
    float w = matrix[3] * obj.x + matrix[7] * obj.y + matrix[11] * obj.z + matrix[15];
    ESP_LOG_DEBUG_THROTTLED(@"[W2S] obj=(%.2f,%.2f,%.2f) w=%.4f", obj.x, obj.y, obj.z, w);
    if (w < 0.5) {
        // Behind camera or degenerate matrix — clamp so box sticks to edge instead of NaN.
        ESP_LOG_DEBUG_THROTTLED(@"[W2S] w<0.5 clamped");
        w = 0.5;
    }
    
    float x = (screenX / 2) + (matrix[0] * obj.x + matrix[4] * obj.y + matrix[8] * obj.z + matrix[12]) / w * (screenX / 2);
    float y = (screenY / 2) - (matrix[1] * obj.x + matrix[5] * obj.y + matrix[9] * obj.z + matrix[13]) / w * (screenY / 2);
    screen.x = x;
    screen.y = y;
    return screen;
}

Vector3 getPositionExt(uint64_t transObj2) {
    Vector3 kZero; kZero.x=0; kZero.y=0; kZero.z=0;
    if (!isVaildPtr((long)transObj2)) { ESP_LOG_WARN(@"[POS] invalid transObj2=0x%llx", (unsigned long long)transObj2); return kZero; }
    uint64_t transObj = ReadAddr<uint64_t>(transObj2 + 0x10);
    if (!isVaildPtr((long)transObj)) { ESP_LOG_WARN(@"[POS] invalid transObj from 0x%llx", (unsigned long long)transObj2); return kZero; }
    
    uint64_t matrix = ReadAddr<uint64_t>(transObj + 0x38);
    uint64_t index = ReadAddr<uint64_t>(transObj + 0x40);
    if (!isVaildPtr((long)matrix)) { ESP_LOG_WARN(@"[POS] invalid matrix transObj=0x%llx", (unsigned long long)transObj); return kZero; }
    ESP_LOG_DEBUG_THROTTLED(@"[POS] transObj2=0x%llx transObj=0x%llx matrix=0x%llx index=%llu",
        (unsigned long long)transObj2, (unsigned long long)transObj, (unsigned long long)matrix, (unsigned long long)index);
    
    uint64_t matrix_list = ReadAddr<uint64_t>(matrix + 0x18);
    uint64_t matrix_indices = ReadAddr<uint64_t>(matrix + 0x20);
    if (!isVaildPtr((long)matrix_list) || !isVaildPtr((long)matrix_indices)) {
        ESP_LOG_WARN(@"[POS] invalid matrix_list/indices list=0x%llx idx=0x%llx", (unsigned long long)matrix_list, (unsigned long long)matrix_indices);
        return kZero;
    }
    
    Vector3 result = ReadAddr<Vector3>(matrix_list + sizeof(TMatrix) * index);
    int transformIndex = ReadAddr<int>(matrix_indices + sizeof(int) * index);
    int guard = 0;
    while (transformIndex >= 0 && guard++ < 128) {
        TMatrix tMatrix = ReadAddr<TMatrix>(matrix_list + sizeof(TMatrix) * transformIndex);
        
        float rotX = tMatrix.rotation.x;
        float rotY = tMatrix.rotation.y;
        float rotZ = tMatrix.rotation.z;
        float rotW = tMatrix.rotation.w;
        
        float scaleX = result.x * tMatrix.scale.x;
        float scaleY = result.y * tMatrix.scale.y;
        float scaleZ = result.z * tMatrix.scale.z;
        
        result.x = tMatrix.position.x + scaleX +
                    (scaleX * ((rotY * rotY * -2.0) - (rotZ * rotZ * 2.0))) +
                    (scaleY * ((rotW * rotZ * -2.0) - (rotY * rotX * -2.0))) +
                    (scaleZ * ((rotZ * rotX * 2.0) - (rotW * rotY * -2.0)));
        result.y = tMatrix.position.y + scaleY +
                    (scaleX * ((rotX * rotY * 2.0) - (rotW * rotZ * -2.0))) +
                    (scaleY * ((rotZ * rotZ * -2.0) - (rotX * rotX * 2.0))) +
                    (scaleZ * ((rotW * rotX * -2.0) - (rotZ * rotY * -2.0)));
        result.z = tMatrix.position.z + scaleZ +
                    (scaleX * ((rotW * rotY * -2.0) - (rotX * rotZ * -2.0))) +
                    (scaleY * ((rotY * rotZ * 2.0) - (rotW * rotX * -2.0))) +
                    (scaleZ * ((rotX * rotX * -2.0) - (rotY * rotY * 2.0)));
        
        transformIndex = ReadAddr<int>(matrix_indices + sizeof(int) * transformIndex);
    }
    
    return result;
}

NSString *GetNickName(uint64_t PawnObject) {
    // CHANGED for 1.132.1: 0x358 (now Action) -> 0x498 (Player.OriginalNickName string)
    // Fallbacks tried in order if null/empty: 0x490, 0x460, 0x468.
    if (!isVaildPtr((long)PawnObject)) { ESP_LOG_WARN(@"[NAME] invalid PawnObject"); return @""; }
    uint64_t name = ReadAddr<uint64_t>(PawnObject + 0x498);
    ESP_LOG_DEBUG_THROTTLED(@"[NAME] player=0x%llx strObj=0x%llx", (unsigned long long)PawnObject, (unsigned long long)name);
    if (!isVaildPtr((long)name)) {
        static const int kFallbacks[] = { 0x490, 0x460, 0x468 };
        for (int off : kFallbacks) {
            name = ReadAddr<uint64_t>(PawnObject + off);
            ESP_LOG_WARN(@"[NAME] fallback off=0x%x -> 0x%llx", off, (unsigned long long)name);
            if (isVaildPtr((long)name)) break;
        }
    }
    if (!isVaildPtr((long)name)) { ESP_LOG_WARN(@"[NAME] all name offsets invalid"); return @""; }
    
    UTF8 PlayerName[32] = "";
    UTF16 buf16[16] = {0};
    
    _read(name + 0x14, buf16, 28);
    Utf16_To_Utf8(buf16, PlayerName, 28, strictConversion);
    
    return [NSString stringWithUTF8String:(const char *)PlayerName];
}
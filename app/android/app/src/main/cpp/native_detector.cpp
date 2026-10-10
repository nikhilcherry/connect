// Multi-model YOLOv8 detector on ncnn (Vulkan GPU or CPU). Each model has its own handle so
// several models can run concurrently on different threads / compute units.
#include <android/asset_manager_jni.h>
#include <android/bitmap.h>
#include <android/log.h>
#include <jni.h>
#include <omp.h>

#include <algorithm>
#include <chrono>
#include <mutex>
#include <string>
#include <vector>

#include "cpu.h"
#include "gpu.h"
#include "net.h"

#define TAG "RoadGuardNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

namespace {

struct Det {
    float x1, y1, x2, y2, score;
    int cls;
};

struct Model {
    ncnn::Net net;
    std::mutex mutex;
    int size = 640;
    int numClasses = 1;
    bool vulkan = false;
};

std::mutex g_errMutex;
std::string g_lastInfo;

void setInfo(const std::string& s) {
    std::lock_guard<std::mutex> l(g_errMutex);
    g_lastInfo = s;
}

float iou(const Det& a, const Det& b) {
    float ix = std::max(0.f, std::min(a.x2, b.x2) - std::max(a.x1, b.x1));
    float iy = std::max(0.f, std::min(a.y2, b.y2) - std::max(a.y1, b.y1));
    float inter = ix * iy;
    float uni = (a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - inter;
    return uni <= 0.f ? 0.f : inter / uni;
}

double ms(std::chrono::steady_clock::time_point a, std::chrono::steady_clock::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM*, void*) {
    ncnn::create_gpu_instance();
    return JNI_VERSION_1_6;
}

// Must be called once from the process main thread (see RoadGuardApp). libomp shuts its whole
// runtime down when the last thread that used it exits, and re-initialising it afterwards
// aborts. The main thread lives as long as the process, so the runtime stays up.
extern "C" JNIEXPORT void JNICALL
Java_com_iqoo_roadguard_NativeRuntime_init(JNIEnv*, jobject) {
    int n = 0;
#pragma omp parallel
    {
#pragma omp atomic
        n++;
    }
    LOGI("OpenMP initialised on main thread, %d threads", n);
}

extern "C" JNIEXPORT void JNICALL JNI_OnUnload(JavaVM*, void*) {
    ncnn::destroy_gpu_instance();
}

// Returns a model handle, or 0 on failure. nativeInfo() then describes the device or error.
extern "C" JNIEXPORT jlong JNICALL
Java_com_iqoo_roadguard_NativeDetector_nativeCreate(JNIEnv* env, jobject, jobject assetManager,
                                                    jstring param, jstring bin, jint inputSize,
                                                    jint numClasses, jboolean useVulkan,
                                                    jint threads, jboolean bigCoresOnly) {
    if (useVulkan && ncnn::get_gpu_count() == 0) {
        setInfo("no Vulkan device found");
        return 0;
    }
    auto* m = new Model();
    m->size = inputSize;
    m->numClasses = numClasses;
    m->vulkan = useVulkan;
    m->net.opt.use_vulkan_compute = useVulkan;
    m->net.opt.num_threads = threads;
    m->net.opt.lightmode = true;
    m->net.opt.use_fp16_packed = true;
    m->net.opt.use_fp16_storage = true;
    m->net.opt.use_fp16_arithmetic = useVulkan;

    AAssetManager* mgr = AAssetManager_fromJava(env, assetManager);
    const char* p = env->GetStringUTFChars(param, nullptr);
    const char* b = env->GetStringUTFChars(bin, nullptr);
    int r1 = m->net.load_param(mgr, p);
    int r2 = r1 == 0 ? m->net.load_model(mgr, b) : -1;
    env->ReleaseStringUTFChars(param, p);
    env->ReleaseStringUTFChars(bin, b);
    if (r1 != 0 || r2 != 0) {
        delete m;
        setInfo("failed to load ncnn model");
        return 0;
    }
    if (useVulkan) {
        setInfo(ncnn::get_gpu_info(0).device_name());
    } else {
        setInfo("CPU big cores=" + std::to_string(ncnn::get_big_cpu_count()) + " threads=" +
                std::to_string(threads));
    }
    return reinterpret_cast<jlong>(m);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_iqoo_roadguard_NativeDetector_nativeInfo(JNIEnv* env, jobject) {
    std::lock_guard<std::mutex> l(g_errMutex);
    return env->NewStringUTF(g_lastInfo.c_str());
}

// timings: [preMs, inferMs, postMs, maxScore]. Returns n*6 floats
// (x1,y1,x2,y2,score,class) in source-bitmap pixel coordinates, or null on failure.
// allowed: class ids to keep (null = all).
extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_iqoo_roadguard_NativeDetector_nativeDetect(JNIEnv* env, jobject, jlong handle,
                                                    jobject bitmap, jfloat confThreshold,
                                                    jintArray allowed, jfloatArray timings) {
    auto* m = reinterpret_cast<Model*>(handle);
    if (!m) return nullptr;
    std::lock_guard<std::mutex> lock(m->mutex);

    AndroidBitmapInfo info;
    if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
        info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) {
        return nullptr;
    }
    void* pixels = nullptr;
    if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS) {
        return nullptr;
    }

    std::vector<int> classes;
    if (allowed) {
        jsize n = env->GetArrayLength(allowed);
        classes.resize(n);
        env->GetIntArrayRegion(allowed, 0, n, classes.data());
    } else {
        for (int c = 0; c < m->numClasses; c++) classes.push_back(c);
    }

    const int w = info.width, h = info.height, S = m->size;
    const float scale = std::min((float)S / w, (float)S / h);
    const int nw = std::max(1, (int)(w * scale)), nh = std::max(1, (int)(h * scale));

    auto t0 = std::chrono::steady_clock::now();
    ncnn::Mat resized = ncnn::Mat::from_pixels_resize(
        (const unsigned char*)pixels, ncnn::Mat::PIXEL_RGBA2RGB, w, h, (int)info.stride, nw, nh);
    AndroidBitmap_unlockPixels(env, bitmap);

    const int wpad = S - nw, hpad = S - nh;
    ncnn::Mat in;
    ncnn::copy_make_border(resized, in, hpad / 2, hpad - hpad / 2, wpad / 2, wpad - wpad / 2,
                           ncnn::BORDER_CONSTANT, 114.f);
    const float norm[3] = {1 / 255.f, 1 / 255.f, 1 / 255.f};
    in.substract_mean_normalize(nullptr, norm);
    auto t1 = std::chrono::steady_clock::now();

    ncnn::Extractor ex = m->net.create_extractor();
    ex.input("in0", in);
    ncnn::Mat out;
    ex.extract("out0", out);
    auto t2 = std::chrono::steady_clock::now();

    // out: h = 4 + numClasses rows (cx, cy, w, h, class scores...), w = anchors.
    std::vector<Det> cands;
    float maxScore = 0.f;
    const int n = out.w;
    if (out.h >= 4 + m->numClasses) {
        const float* cx = out.row(0);
        const float* cy = out.row(1);
        const float* bw = out.row(2);
        const float* bh = out.row(3);
        const float padX = wpad / 2.f, padY = hpad / 2.f;
        for (int i = 0; i < n; i++) {
            float best = 0.f;
            int bestCls = -1;
            for (int c : classes) {
                float s = out.row(4 + c)[i];
                if (s > best) {
                    best = s;
                    bestCls = c;
                }
            }
            if (best > maxScore) maxScore = best;
            if (best < confThreshold || bestCls < 0) continue;
            Det d;
            d.x1 = std::clamp(((cx[i] - bw[i] / 2.f) - padX) / scale, 0.f, (float)w);
            d.y1 = std::clamp(((cy[i] - bh[i] / 2.f) - padY) / scale, 0.f, (float)h);
            d.x2 = std::clamp(((cx[i] + bw[i] / 2.f) - padX) / scale, 0.f, (float)w);
            d.y2 = std::clamp(((cy[i] + bh[i] / 2.f) - padY) / scale, 0.f, (float)h);
            d.score = best;
            d.cls = bestCls;
            cands.push_back(d);
        }
    }
    std::sort(cands.begin(), cands.end(), [](const Det& a, const Det& b) { return a.score > b.score; });
    std::vector<Det> kept;
    for (const Det& d : cands) {
        bool ok = true;
        for (const Det& k : kept) {
            if (k.cls == d.cls && iou(k, d) > 0.45f) {
                ok = false;
                break;
            }
        }
        if (ok) kept.push_back(d);
    }
    auto t3 = std::chrono::steady_clock::now();

    float t[4] = {(float)ms(t0, t1), (float)ms(t1, t2), (float)ms(t2, t3), maxScore};
    env->SetFloatArrayRegion(timings, 0, 4, t);

    std::vector<float> flat;
    flat.reserve(kept.size() * 6);
    for (const Det& d : kept) {
        flat.push_back(d.x1);
        flat.push_back(d.y1);
        flat.push_back(d.x2);
        flat.push_back(d.y2);
        flat.push_back(d.score);
        flat.push_back((float)d.cls);
    }
    jfloatArray result = env->NewFloatArray((jsize)flat.size());
    if (!flat.empty()) env->SetFloatArrayRegion(result, 0, (jsize)flat.size(), flat.data());
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_iqoo_roadguard_NativeDetector_nativeRelease(JNIEnv*, jobject, jlong handle) {
    auto* m = reinterpret_cast<Model*>(handle);
    if (!m) return;
    {
        std::lock_guard<std::mutex> lock(m->mutex);
    }
    delete m;
}

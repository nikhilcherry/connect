cmake_minimum_required(VERSION 3.22.1)
project(roadguard_native)

# Prebuilt ncnn (static, Vulkan enabled), passed in from Gradle.
set(ncnn_DIR ${NCNN_ROOT}/${ANDROID_ABI}/lib/cmake/ncnn)
find_package(ncnn REQUIRED)

add_library(roadguard_native SHARED native_detector.cpp)

target_compile_options(roadguard_native PRIVATE -O3 -fopenmp -ffast-math)
target_link_libraries(roadguard_native ncnn android jnigraphics log -fopenmp -static-openmp)

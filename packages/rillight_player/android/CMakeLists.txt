cmake_minimum_required(VERSION 3.22)
project(rillight_android_core LANGUAGES CXX)

if(NOT RILLIGHT_CORE_SDK_ROOT)
  message(FATAL_ERROR "Set RILLIGHT_CORE_SDK_ROOT to the verified Android FFmpeg SDK root")
endif()
set(RILLIGHT_CORE_PREFIX "${RILLIGHT_CORE_SDK_ROOT}/${ANDROID_ABI}")
if(NOT EXISTS "${RILLIGHT_CORE_PREFIX}/include/ass/ass.h" OR
   NOT EXISTS "${RILLIGHT_CORE_PREFIX}/lib/libass.so")
  message(FATAL_ERROR "Android core SDK requires pinned libass for text/ASS subtitles; run build_android_libass.py")
endif()
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native"
                 "${CMAKE_CURRENT_BINARY_DIR}/rillight_core")

add_library(rillight_android_core SHARED src/main/cpp/core_bridge.cpp)
target_compile_features(rillight_android_core PRIVATE cxx_std_17)
target_include_directories(rillight_android_core PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../native/core")
target_compile_options(rillight_android_core PRIVATE -Wall -Wextra -Werror)
target_link_libraries(rillight_android_core PRIVATE rillight_core android log)

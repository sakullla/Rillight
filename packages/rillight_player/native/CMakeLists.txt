cmake_minimum_required(VERSION 3.20)
project(rillight_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT RILLIGHT_CORE_PREFIX)
  message(FATAL_ERROR "Set RILLIGHT_CORE_PREFIX to a verified FFmpeg n9.0.2 SDK")
endif()
if(NOT EXISTS "${RILLIGHT_CORE_PREFIX}/rillight-core-dependencies.json")
  message(FATAL_ERROR "Run build_core_dependencies.py or provide a verified SDK")
endif()

find_package(Python3 COMPONENTS Interpreter REQUIRED)
if(ANDROID)
  set(core_target "android-${ANDROID_ABI}")
elseif(WIN32)
  set(core_target "windows-x64")
elseif(APPLE)
  set(core_target "macos-universal")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set(core_target "linux-x64")
else()
  message(FATAL_ERROR "Unsupported core target: ${CMAKE_SYSTEM_NAME}")
endif()
execute_process(
  COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/verify_core_dependencies.py"
    --prefix "${RILLIGHT_CORE_PREFIX}" --target "${core_target}"
  RESULT_VARIABLE verify_result
  OUTPUT_VARIABLE verify_output
  ERROR_VARIABLE verify_error
)
if(NOT verify_result EQUAL 0)
  message(FATAL_ERROR "FFmpeg SDK failed verification: ${verify_output}${verify_error}")
endif()

set(core_lib_dir "${RILLIGHT_CORE_PREFIX}/lib")

foreach(component avformat avcodec avutil avfilter swresample swscale)
  find_library(${component}_library NAMES ${component}
    PATHS "${core_lib_dir}" NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH REQUIRED)
endforeach()

add_library(rillight_core SHARED core/rillight_core.cpp core/decoder_probe.cpp
  core/portable_color_pipeline.cpp core/video_enhancer.cpp)
if(WIN32)
  target_sources(rillight_core PRIVATE core/windows_color_pipeline.cpp)
  target_link_libraries(rillight_core PRIVATE d3d11 d3dcompiler dxgi)
endif()
if(ANDROID)
  target_sources(rillight_core PRIVATE core/android_color_pipeline.cpp)
  target_link_libraries(rillight_core PRIVATE EGL GLESv3 log android)
endif()
target_include_directories(rillight_core PRIVATE "${RILLIGHT_CORE_PREFIX}/include")
set_target_properties(rillight_core PROPERTIES BUILD_RPATH "${core_lib_dir}")
# Android SDKs may gain libass after the first Gradle/CMake configure. Track
# the optional header/library so the cached native build is reconfigured.
file(TO_CMAKE_PATH "${RILLIGHT_CORE_PREFIX}" core_prefix_cmake)
file(GLOB subtitle_sdk_files CONFIGURE_DEPENDS
  "${core_prefix_cmake}/include/ass/ass.h"
  "${core_prefix_cmake}/lib/libass.*")
if(EXISTS "${RILLIGHT_CORE_PREFIX}/include/ass/ass.h")
  execute_process(
    COMMAND "${Python3_EXECUTABLE}"
      "${CMAKE_CURRENT_SOURCE_DIR}/verify_core_dependencies.py"
      --prefix "${RILLIGHT_CORE_PREFIX}" --target "${core_target}"
      --require-subtitles
    RESULT_VARIABLE ass_verify_result
    ERROR_VARIABLE ass_verify_error
  )
  if(NOT ass_verify_result EQUAL 0)
    message(FATAL_ERROR "libass SDK failed verification: ${ass_verify_error}")
  endif()
  find_library(ass_library NAMES ass PATHS "${core_lib_dir}"
    NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH REQUIRED)
  target_link_libraries(rillight_core PRIVATE ${ass_library})
  target_compile_definitions(rillight_core PRIVATE RILLIGHT_HAVE_LIBASS=1)
else()
  target_compile_definitions(rillight_core PRIVATE RILLIGHT_HAVE_LIBASS=0)
endif()
find_package(Threads REQUIRED)
target_link_libraries(rillight_core PRIVATE
  ${avformat_library} ${avcodec_library} ${avutil_library} ${avfilter_library}
  ${swresample_library} ${swscale_library} Threads::Threads)
if(ANDROID)
  target_link_libraries(rillight_core PRIVATE android log)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # The fixed SDK's shared FFmpeg libraries depend on one another. The linker
  # must resolve that closure while linking the core and its test executable.
  target_link_options(rillight_core PRIVATE "LINKER:-rpath-link,${core_lib_dir}")
endif()
if(APPLE)
  enable_language(OBJCXX)
  set(CMAKE_OBJCXX_STANDARD 17)
  set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
  target_sources(rillight_core PRIVATE core/macos_color_pipeline.mm)
  target_compile_definitions(rillight_core PRIVATE RILLIGHT_HAVE_MACOS_COLOR=1)
  set_source_files_properties(core/macos_color_pipeline.mm PROPERTIES
    COMPILE_OPTIONS "-fobjc-arc")
  target_link_libraries(rillight_core PRIVATE
    "-framework Metal" "-framework Foundation")
  set_target_properties(rillight_core PROPERTIES
    INSTALL_NAME_DIR "@rpath"
    MACOSX_RPATH ON)
endif()
if(MSVC)
  target_compile_options(rillight_core PRIVATE /W4 /WX)
else()
  target_compile_options(rillight_core PRIVATE -Wall -Wextra -Werror)
endif()

target_sources(rillight_core PRIVATE core/anime4k_glsl.cpp core/enhancement_models.cpp)
file(TO_CMAKE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/core/shaders/anime4k" rillight_anime4k_dir)
target_compile_definitions(rillight_core PRIVATE "RILLIGHT_ANIME4K_DIR=\"${rillight_anime4k_dir}\"")
# Weights are fetched from core_dependencies.json and copied beside the
# library. FindAsset uses that directory, not a configure-time absolute path.
execute_process(
  COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/build_core_dependencies.py"
    --stage-enhancement-only
  RESULT_VARIABLE enhancement_stage_result
  OUTPUT_VARIABLE enhancement_stage_output
  ERROR_VARIABLE enhancement_stage_error
)
if(NOT enhancement_stage_result EQUAL 0)
  message(FATAL_ERROR
    "Enhancement dependency staging failed: ${enhancement_stage_output}${enhancement_stage_error}")
endif()
set(rillight_enhancement_root "${CMAKE_CURRENT_SOURCE_DIR}/../../../build")
set(rillight_ncnn_dir "${rillight_enhancement_root}/enhancement-src/ncnn")
set(rillight_model_dir "${rillight_enhancement_root}/enhancement-models")
if(NOT EXISTS "${rillight_ncnn_dir}/CMakeLists.txt" OR
   NOT EXISTS "${rillight_model_dir}/rife-v4.6/flownet.param" OR
   NOT EXISTS "${rillight_model_dir}/rife-v4.6/flownet.bin" OR
   NOT EXISTS "${rillight_model_dir}/realesr-general-x4v3.param" OR
   NOT EXISTS "${rillight_model_dir}/realesr-general-x4v3.bin")
  message(FATAL_ERROR "Pinned ncnn, RIFE, or Real-ESRGAN files were not staged")
endif()
enable_language(C)
set(NCNN_VULKAN OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_BENCHMARK OFF CACHE BOOL "" FORCE)
set(NCNN_OPENMP OFF CACHE BOOL "" FORCE)
set(NCNN_PYTHON OFF CACHE BOOL "" FORCE)
set(NCNN_SHARED_LIB OFF CACHE BOOL "" FORCE)
set(NCNN_INSTALL_SDK OFF CACHE BOOL "" FORCE)
set(NCNN_PIXEL OFF CACHE BOOL "" FORCE)
set(NCNN_PIXEL_ROTATE OFF CACHE BOOL "" FORCE)
set(NCNN_PIXEL_AFFINE OFF CACHE BOOL "" FORCE)
set(NCNN_PIXEL_DRAWING OFF CACHE BOOL "" FORCE)
set(NCNN_INT8 OFF CACHE BOOL "" FORCE)
set(NCNN_BF16 OFF CACHE BOOL "" FORCE)
set(NCNN_C_API OFF CACHE BOOL "" FORCE)
add_subdirectory("${rillight_ncnn_dir}" "${CMAKE_CURRENT_BINARY_DIR}/ncnn" EXCLUDE_FROM_ALL)
target_compile_definitions(rillight_core PRIVATE RILLIGHT_HAVE_NCNN=1)
target_link_libraries(rillight_core PRIVATE ncnn)
add_custom_command(TARGET rillight_core POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    "${CMAKE_CURRENT_SOURCE_DIR}/core/shaders/anime4k"
    "$<TARGET_FILE_DIR:rillight_core>/shaders/anime4k"
  COMMAND ${CMAKE_COMMAND} -E make_directory
    "$<TARGET_FILE_DIR:rillight_core>/rife-v4.6"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${rillight_model_dir}/rife-v4.6/flownet.param"
    "$<TARGET_FILE_DIR:rillight_core>/rife-v4.6/flownet.param"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${rillight_model_dir}/rife-v4.6/flownet.bin"
    "$<TARGET_FILE_DIR:rillight_core>/rife-v4.6/flownet.bin"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${rillight_model_dir}/realesr-general-x4v3.param"
    "$<TARGET_FILE_DIR:rillight_core>/realesr-general-x4v3.param"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${rillight_model_dir}/realesr-general-x4v3.bin"
    "$<TARGET_FILE_DIR:rillight_core>/realesr-general-x4v3.bin"
  VERBATIM)

enable_testing()
add_subdirectory(core_tests)

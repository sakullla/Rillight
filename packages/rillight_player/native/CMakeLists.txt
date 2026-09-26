cmake_minimum_required(VERSION 3.20)
project(rillight_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT RILLIGHT_CORE_PREFIX)
  message(FATAL_ERROR "Set RILLIGHT_CORE_PREFIX to a verified FFmpeg n9.0.1 SDK")
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

add_library(rillight_core SHARED core/rillight_core.cpp)
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
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # The fixed SDK's shared FFmpeg libraries depend on one another. The linker
  # must resolve that closure while linking the core and its test executable.
  target_link_options(rillight_core PRIVATE "LINKER:-rpath-link,${core_lib_dir}")
endif()
if(MSVC)
  target_compile_options(rillight_core PRIVATE /W4 /WX)
else()
  target_compile_options(rillight_core PRIVATE -Wall -Wextra -Werror)
endif()

enable_testing()
add_subdirectory(core_tests)

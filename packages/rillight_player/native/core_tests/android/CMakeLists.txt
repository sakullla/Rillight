cmake_minimum_required(VERSION 3.20)
project(rillight_android_io_roles LANGUAGES CXX)
enable_testing()
add_executable(rillight_android_io_roles_test media_io_roles_test.cpp)
target_compile_features(rillight_android_io_roles_test PRIVATE cxx_std_17)
find_package(Threads REQUIRED)
target_link_libraries(rillight_android_io_roles_test PRIVATE Threads::Threads)
target_include_directories(rillight_android_io_roles_test PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../android/src/main/cpp")
add_test(NAME rillight_android_io_roles COMMAND rillight_android_io_roles_test)

# Run the encrypted HLS contract against the real core and the pinned host SDK.
# The lightweight role test above remains runnable without FFmpeg dependencies.
if(RILLIGHT_CORE_PREFIX)
  set(RILLIGHT_HLS_RUNTIME_LIBRARY_PATH "${RILLIGHT_CORE_PREFIX}/lib" CACHE STRING
      "Runtime library search path for the encrypted HLS regression")
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../.."
                   "${CMAKE_CURRENT_BINARY_DIR}/rillight_core_build")
  foreach(component avformat avcodec avutil)
    find_library(hls_${component} NAMES ${component}
      PATHS "${RILLIGHT_CORE_PREFIX}/lib" NO_DEFAULT_PATH
      NO_CMAKE_FIND_ROOT_PATH REQUIRED)
  endforeach()
  add_executable(rillight_android_encrypted_hls_test encrypted_hls_test.cpp)
  target_include_directories(rillight_android_encrypted_hls_test PRIVATE
    "${RILLIGHT_CORE_PREFIX}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../core")
  target_link_libraries(rillight_android_encrypted_hls_test PRIVATE
    rillight_core ${hls_avformat} ${hls_avcodec} ${hls_avutil}
    Threads::Threads)
  target_compile_options(rillight_android_encrypted_hls_test PRIVATE
    -Wall -Wextra -Werror -UNDEBUG)
  set_target_properties(rillight_android_encrypted_hls_test PROPERTIES
    BUILD_RPATH "${RILLIGHT_CORE_PREFIX}/lib")
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_options(rillight_android_encrypted_hls_test PRIVATE
      "LINKER:-rpath-link,${RILLIGHT_CORE_PREFIX}/lib")
  endif()
  add_test(NAME rillight_android_encrypted_hls
    COMMAND rillight_android_encrypted_hls_test)
  add_test(NAME rillight_android_encrypted_hls_bad_padding
    COMMAND rillight_android_encrypted_hls_test --bad-padding)
  add_test(NAME rillight_android_encrypted_hls_missing_key
    COMMAND rillight_android_encrypted_hls_test --missing-key)
  add_test(NAME rillight_android_encrypted_hls_eagain
    COMMAND rillight_android_encrypted_hls_test --eagain)
  set_tests_properties(rillight_android_encrypted_hls
    rillight_android_encrypted_hls_bad_padding
    rillight_android_encrypted_hls_missing_key
    rillight_android_encrypted_hls_eagain PROPERTIES TIMEOUT 20)
  option(RILLIGHT_TEST_HTTP_HLS "Exercise HTTP HLS over application-owned IO" ON)
  if(RILLIGHT_TEST_HTTP_HLS)
    add_test(NAME rillight_android_encrypted_hls_http
      COMMAND rillight_android_encrypted_hls_test --http)
    add_test(NAME rillight_android_encrypted_hls_http_bad_padding
      COMMAND rillight_android_encrypted_hls_test --http --bad-padding)
    add_test(NAME rillight_android_encrypted_hls_http_missing_key
      COMMAND rillight_android_encrypted_hls_test --http --missing-key)
    add_test(NAME rillight_android_encrypted_hls_http_eagain
      COMMAND rillight_android_encrypted_hls_test --http --eagain)
    set_tests_properties(rillight_android_encrypted_hls_http
      rillight_android_encrypted_hls_http_bad_padding
      rillight_android_encrypted_hls_http_missing_key
      rillight_android_encrypted_hls_http_eagain PROPERTIES TIMEOUT 20)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
      set_tests_properties(rillight_android_encrypted_hls_http
        rillight_android_encrypted_hls_http_bad_padding
        rillight_android_encrypted_hls_http_missing_key
        rillight_android_encrypted_hls_http_eagain PROPERTIES
        ENVIRONMENT "LD_LIBRARY_PATH=${RILLIGHT_HLS_RUNTIME_LIBRARY_PATH}")
    endif()
  endif()
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set_tests_properties(rillight_android_encrypted_hls
      rillight_android_encrypted_hls_bad_padding
      rillight_android_encrypted_hls_missing_key
      rillight_android_encrypted_hls_eagain PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${RILLIGHT_HLS_RUNTIME_LIBRARY_PATH}")
  endif()
endif()

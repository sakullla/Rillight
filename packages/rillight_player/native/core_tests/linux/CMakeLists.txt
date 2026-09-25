cmake_minimum_required(VERSION 3.16)
project(rillight_linux_frame_output LANGUAGES CXX)
enable_testing()
add_executable(rillight_linux_frame_output_test frame_output_test.cpp)
target_compile_features(rillight_linux_frame_output_test PRIVATE cxx_std_17)
if(MSVC)
  target_compile_options(rillight_linux_frame_output_test PRIVATE /UNDEBUG)
else()
  target_compile_options(rillight_linux_frame_output_test PRIVATE
    -Wall -Wextra -Werror -UNDEBUG)
endif()
add_test(NAME rillight_linux_frame_output COMMAND rillight_linux_frame_output_test)
add_executable(rillight_linux_audio_schedule_test audio_schedule_test.cpp)
target_compile_features(rillight_linux_audio_schedule_test PRIVATE cxx_std_17)
if(MSVC)
  target_compile_options(rillight_linux_audio_schedule_test PRIVATE /UNDEBUG)
else()
  target_compile_options(rillight_linux_audio_schedule_test PRIVATE
    -Wall -Wextra -Werror -UNDEBUG)
endif()
add_test(NAME rillight_linux_audio_schedule COMMAND rillight_linux_audio_schedule_test)

if(RILLIGHT_CORE_PREFIX)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../.."
                   "${CMAKE_CURRENT_BINARY_DIR}/core")
  foreach(component avformat avcodec avutil)
    find_library(t6_${component} NAMES ${component}
      PATHS "${RILLIGHT_CORE_PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)
  endforeach()
  add_executable(rillight_linux_short_audio_handoff
    short_audio_handoff_test.cpp)
  target_compile_features(rillight_linux_short_audio_handoff PRIVATE cxx_std_17)
  target_compile_options(rillight_linux_short_audio_handoff PRIVATE
    -Wall -Wextra -Werror -UNDEBUG)
  target_include_directories(rillight_linux_short_audio_handoff PRIVATE
    "${RILLIGHT_CORE_PREFIX}/include")
  target_link_libraries(rillight_linux_short_audio_handoff PRIVATE
    rillight_core ${t6_avformat} ${t6_avcodec} ${t6_avutil})
  target_link_options(rillight_linux_short_audio_handoff PRIVATE
    "LINKER:-rpath-link,${RILLIGHT_CORE_PREFIX}/lib")
  add_test(NAME rillight_linux_short_audio_handoff
    COMMAND rillight_linux_short_audio_handoff)
  set_tests_properties(rillight_linux_short_audio_handoff PROPERTIES
    TIMEOUT 15 ENVIRONMENT "LD_LIBRARY_PATH=${RILLIGHT_CORE_PREFIX}/lib")
endif()

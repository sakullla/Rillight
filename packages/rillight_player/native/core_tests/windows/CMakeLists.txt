cmake_minimum_required(VERSION 3.21)
project(rillight_windows_pixel_output LANGUAGES CXX)
enable_testing()
add_executable(rillight_windows_gpu_present_test gpu_present_test.cpp
  ../../../windows/gpu_present.cpp)
target_compile_features(rillight_windows_gpu_present_test PRIVATE cxx_std_17)
target_compile_definitions(rillight_windows_gpu_present_test PRIVATE NOMINMAX)
target_link_libraries(rillight_windows_gpu_present_test PRIVATE d3d11 d3dcompiler dxgi)
if(MSVC)
  target_compile_options(rillight_windows_gpu_present_test PRIVATE /W4 /WX /UNDEBUG)
else()
  target_compile_options(rillight_windows_gpu_present_test PRIVATE -Wall -Wextra -Werror -UNDEBUG)
endif()
add_test(NAME rillight_windows_gpu_present COMMAND rillight_windows_gpu_present_test)
add_executable(rillight_windows_pixel_output_test pixel_output_test.cpp
  ../../../windows/pixel_present.cpp)
target_compile_features(rillight_windows_pixel_output_test PRIVATE cxx_std_17)
if(MSVC)
  target_compile_options(rillight_windows_pixel_output_test PRIVATE /W4 /WX /UNDEBUG)
else()
  target_compile_options(rillight_windows_pixel_output_test PRIVATE
    -Wall -Wextra -Werror -UNDEBUG)
endif()
add_test(NAME rillight_windows_pixel_output
         COMMAND rillight_windows_pixel_output_test)
add_executable(rillight_windows_d3d_output_test d3d_output_test.cpp)
target_compile_features(rillight_windows_d3d_output_test PRIVATE cxx_std_17)
target_link_libraries(rillight_windows_d3d_output_test PRIVATE d3d11 dxgi)
add_test(NAME rillight_windows_d3d_output
         COMMAND rillight_windows_d3d_output_test)
add_executable(rillight_windows_wasapi_output_test wasapi_output_test.cpp)
target_compile_features(rillight_windows_wasapi_output_test PRIVATE cxx_std_17)
target_link_libraries(rillight_windows_wasapi_output_test PRIVATE ole32 uuid)
add_test(NAME rillight_windows_wasapi_output
         COMMAND rillight_windows_wasapi_output_test)
add_executable(rillight_windows_audio_schedule_test audio_schedule_test.cpp)
target_compile_features(rillight_windows_audio_schedule_test PRIVATE cxx_std_17)
if(MSVC)
  target_compile_options(rillight_windows_audio_schedule_test PRIVATE /W4 /WX /UNDEBUG)
else()
  target_compile_options(rillight_windows_audio_schedule_test PRIVATE
    -Wall -Wextra -Werror -UNDEBUG)
endif()
add_test(NAME rillight_windows_audio_schedule
         COMMAND rillight_windows_audio_schedule_test)
add_executable(rillight_windows_audio_route_test audio_route_test.cpp)
target_compile_features(rillight_windows_audio_route_test PRIVATE cxx_std_17)
if(MSVC)
  target_compile_options(rillight_windows_audio_route_test PRIVATE /W4 /WX /UNDEBUG)
else()
  target_compile_options(rillight_windows_audio_route_test PRIVATE
    -Wall -Wextra -Werror -UNDEBUG)
endif()
add_test(NAME rillight_windows_audio_route
         COMMAND rillight_windows_audio_route_test)

# Opt in with a verified SDK; CoreApi loads the DLL beside the executable.
set(RILLIGHT_CORE_PREFIX_WINDOWS_X64 "" CACHE PATH "Verified Windows core SDK")
if(RILLIGHT_CORE_PREFIX_WINDOWS_X64)
  add_executable(rillight_windows_audio_catchup_test audio_catchup_test.cpp
    ../../../windows/audio_output.cpp)
  target_compile_features(rillight_windows_audio_catchup_test PRIVATE cxx_std_17)
  target_compile_definitions(rillight_windows_audio_catchup_test PRIVATE NOMINMAX)
  target_link_libraries(rillight_windows_audio_catchup_test PRIVATE ole32 uuid)
  file(GLOB core_runtime "${RILLIGHT_CORE_PREFIX_WINDOWS_X64}/bin/*.dll")
  foreach(runtime IN LISTS core_runtime)
    add_custom_command(TARGET rillight_windows_audio_catchup_test POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${runtime}"
        "$<TARGET_FILE_DIR:rillight_windows_audio_catchup_test>")
  endforeach()
  add_test(NAME rillight_windows_audio_catchup
    COMMAND rillight_windows_audio_catchup_test)
endif()

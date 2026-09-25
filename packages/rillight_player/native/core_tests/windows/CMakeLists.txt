cmake_minimum_required(VERSION 3.21)
project(rillight_windows_pixel_output LANGUAGES CXX)
enable_testing()
add_executable(rillight_windows_pixel_output_test pixel_output_test.cpp)
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

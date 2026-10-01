cmake_minimum_required(VERSION 3.16)
project(rillight_macos_frame_output LANGUAGES CXX)
enable_testing()
add_executable(rillight_macos_frame_output_test frame_output_test.cpp)
target_include_directories(rillight_macos_frame_output_test PRIVATE ../../core)
target_compile_features(rillight_macos_frame_output_test PRIVATE cxx_std_17)
target_compile_options(rillight_macos_frame_output_test PRIVATE
  -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME rillight_macos_frame_output COMMAND rillight_macos_frame_output_test)
if(APPLE)
  enable_language(OBJCXX)
  foreach(component pixel_buffer pixel_conversion)
    add_executable(rillight_macos_${component}_test ${component}_test.mm)
    target_include_directories(rillight_macos_${component}_test PRIVATE ../../core)
    target_compile_features(rillight_macos_${component}_test PRIVATE cxx_std_17)
    target_compile_options(rillight_macos_${component}_test PRIVATE
      -Wall -Wextra -Werror -UNDEBUG -fobjc-arc)
    target_link_libraries(rillight_macos_${component}_test PRIVATE
      "-framework Accelerate" "-framework Foundation" "-framework CoreGraphics"
      "-framework CoreVideo" "-framework IOSurface")
    add_test(NAME rillight_macos_${component} COMMAND rillight_macos_${component}_test)
  endforeach()
endif()

add_executable(rillight_video_frame_cost_test video_frame_cost_test.cpp)
target_include_directories(rillight_video_frame_cost_test PRIVATE "${RILLIGHT_CORE_PREFIX}/include")
target_link_libraries(rillight_video_frame_cost_test PRIVATE ${avutil_library})
if(MSVC)
  target_compile_options(rillight_video_frame_cost_test PRIVATE /W4 /WX /UNDEBUG)
else()
  target_compile_options(rillight_video_frame_cost_test PRIVATE -Wall -Wextra -Werror -UNDEBUG)
endif()
add_test(NAME rillight_video_frame_cost COMMAND rillight_video_frame_cost_test)

add_executable(rillight_core_test core_test.cpp)
target_link_libraries(rillight_core_test PRIVATE rillight_core Threads::Threads)
set_target_properties(rillight_core_test PROPERTIES BUILD_RPATH "${core_lib_dir}")
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_options(rillight_core_test PRIVATE
    "LINKER:-rpath-link,${core_lib_dir}")
endif()
if(MSVC)
  target_compile_options(rillight_core_test PRIVATE /UNDEBUG)
else()
  target_compile_options(rillight_core_test PRIVATE -UNDEBUG)
endif()
add_test(NAME rillight_core_audio_session COMMAND rillight_core_test)
option(RILLIGHT_CORE_GPU_TESTS "Run color conversion on a real D3D11 or Metal device" OFF)
if(APPLE AND RILLIGHT_CORE_GPU_TESTS)
  add_executable(rillight_macos_color_pipeline_test
    macos/color_pipeline_test.cpp ../core/macos_color_pipeline.mm
    ../core/portable_color_pipeline.cpp)
  target_include_directories(rillight_macos_color_pipeline_test PRIVATE
    "${RILLIGHT_CORE_PREFIX}/include" "${CMAKE_CURRENT_SOURCE_DIR}/../core")
  target_link_libraries(rillight_macos_color_pipeline_test PRIVATE
    ${avutil_library} ${swscale_library} Threads::Threads
    "-framework Metal" "-framework Foundation")
  target_compile_options(rillight_macos_color_pipeline_test PRIVATE
    -Wall -Wextra -Werror -UNDEBUG)
  set_target_properties(rillight_macos_color_pipeline_test PROPERTIES
    BUILD_RPATH "${core_lib_dir}")
  add_test(NAME rillight_macos_color_pipeline COMMAND rillight_macos_color_pipeline_test)
  set_tests_properties(rillight_macos_color_pipeline PROPERTIES TIMEOUT 30
    ENVIRONMENT "DYLD_LIBRARY_PATH=${core_lib_dir}")
endif()
add_executable(rillight_portable_color_pipeline_test
  portable_color_pipeline_test.cpp ../core/portable_color_pipeline.cpp)
target_include_directories(rillight_portable_color_pipeline_test PRIVATE "${RILLIGHT_CORE_PREFIX}/include")
target_link_libraries(rillight_portable_color_pipeline_test PRIVATE
  ${avutil_library} ${swscale_library} Threads::Threads)
if(MSVC)
  target_compile_options(rillight_portable_color_pipeline_test PRIVATE /W4 /WX /UNDEBUG)
else()
  target_compile_options(rillight_portable_color_pipeline_test PRIVATE -Wall -Wextra -Werror -UNDEBUG)
endif()
set_target_properties(rillight_portable_color_pipeline_test PROPERTIES BUILD_RPATH "${core_lib_dir}")
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_options(rillight_portable_color_pipeline_test PRIVATE "LINKER:-rpath-link,${core_lib_dir}")
endif()
add_test(NAME rillight_portable_color_pipeline COMMAND rillight_portable_color_pipeline_test)
set_tests_properties(rillight_portable_color_pipeline PROPERTIES TIMEOUT 20)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set_tests_properties(rillight_portable_color_pipeline PROPERTIES ENVIRONMENT "LD_LIBRARY_PATH=${core_lib_dir}")
elseif(APPLE)
  set_tests_properties(rillight_portable_color_pipeline PROPERTIES ENVIRONMENT "DYLD_LIBRARY_PATH=${core_lib_dir}")
endif()
if(WIN32 AND RILLIGHT_CORE_GPU_TESTS)
  add_executable(rillight_windows_color_pipeline_test
    windows/color_pipeline_test.cpp ../core/windows_color_pipeline.cpp ../core/portable_color_pipeline.cpp)
  target_compile_features(rillight_windows_color_pipeline_test PRIVATE cxx_std_17)
  target_include_directories(rillight_windows_color_pipeline_test PRIVATE
    "${RILLIGHT_CORE_PREFIX}/include")
  target_link_libraries(rillight_windows_color_pipeline_test PRIVATE
    ${avutil_library} ${swscale_library} Threads::Threads d3d11 d3dcompiler dxgi)
  if(MSVC)
    target_compile_options(rillight_windows_color_pipeline_test PRIVATE /W4 /WX /UNDEBUG)
  else()
    target_compile_options(rillight_windows_color_pipeline_test PRIVATE -Wall -Wextra -Werror -UNDEBUG)
  endif()
  add_test(NAME rillight_windows_color_pipeline COMMAND rillight_windows_color_pipeline_test)
  set_tests_properties(rillight_windows_color_pipeline PROPERTIES TIMEOUT 20)
endif()
add_executable(rillight_core_startup_test startup_interleave_test.cpp)
target_include_directories(rillight_core_startup_test PRIVATE
  "${RILLIGHT_CORE_PREFIX}/include")
target_link_libraries(rillight_core_startup_test PRIVATE rillight_core
  ${avformat_library} ${avcodec_library} ${avutil_library})
set_target_properties(rillight_core_startup_test PROPERTIES
  BUILD_RPATH "${core_lib_dir}")
if(MSVC)
  target_compile_options(rillight_core_startup_test PRIVATE /UNDEBUG)
else()
  target_compile_options(rillight_core_startup_test PRIVATE -UNDEBUG)
endif()
add_test(NAME rillight_core_startup_interleave COMMAND rillight_core_startup_test)
set_tests_properties(rillight_core_startup_interleave PROPERTIES TIMEOUT 10)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_options(rillight_core_startup_test PRIVATE
    "LINKER:-rpath-link,${core_lib_dir}")
  set_tests_properties(rillight_core_startup_interleave PROPERTIES
    ENVIRONMENT "LD_LIBRARY_PATH=${core_lib_dir}")
endif()
if(APPLE)
  set_tests_properties(rillight_core_startup_interleave PROPERTIES
    ENVIRONMENT "DYLD_LIBRARY_PATH=${core_lib_dir}")
endif()
set_tests_properties(rillight_core_audio_session PROPERTIES TIMEOUT 20)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  # CTest runs against the fixed SDK in the build tree. FFmpeg's own shared
  # libraries have transitive dependencies that do not inherit our RUNPATH.
  set_tests_properties(rillight_core_audio_session PROPERTIES
    ENVIRONMENT "LD_LIBRARY_PATH=${core_lib_dir}")
endif()
if(APPLE)
  set_tests_properties(rillight_core_audio_session PROPERTIES
    ENVIRONMENT "DYLD_LIBRARY_PATH=${core_lib_dir}")
endif()

if(ass_library)
  add_executable(rillight_core_ass_test ass_test.cpp)
  target_include_directories(rillight_core_ass_test PRIVATE
    "${RILLIGHT_CORE_PREFIX}/include")
  target_link_libraries(rillight_core_ass_test PRIVATE rillight_core
    ${avformat_library} ${avcodec_library} ${avutil_library})
  set_target_properties(rillight_core_ass_test PROPERTIES
    BUILD_RPATH "${core_lib_dir}")
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_options(rillight_core_ass_test PRIVATE
      "LINKER:-rpath-link,${core_lib_dir}")
  endif()
  if(MSVC)
    target_compile_options(rillight_core_ass_test PRIVATE /W4 /WX /UNDEBUG)
  else()
    target_compile_options(rillight_core_ass_test PRIVATE
      -Wall -Wextra -Werror -UNDEBUG)
  endif()
  add_test(NAME rillight_core_ass_composition COMMAND rillight_core_ass_test)
  add_test(NAME rillight_core_mov_text COMMAND rillight_core_ass_test --mov-text-only)
  set_tests_properties(rillight_core_mov_text PROPERTIES TIMEOUT 15)
  if(APPLE)
    set_tests_properties(rillight_core_mov_text PROPERTIES
      ENVIRONMENT "DYLD_LIBRARY_PATH=${core_lib_dir}")
  elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set_tests_properties(rillight_core_mov_text PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${core_lib_dir}")
  endif()
  set_tests_properties(rillight_core_ass_composition PROPERTIES TIMEOUT 20)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set_tests_properties(rillight_core_ass_composition PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${core_lib_dir}")
  endif()
  if(APPLE)
    set_tests_properties(rillight_core_ass_composition PROPERTIES
      ENVIRONMENT "DYLD_LIBRARY_PATH=${core_lib_dir}")
  endif()
endif()

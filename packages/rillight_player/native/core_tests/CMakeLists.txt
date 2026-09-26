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

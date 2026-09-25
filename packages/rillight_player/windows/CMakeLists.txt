cmake_minimum_required(VERSION 3.21)
project(rillight_player LANGUAGES CXX)

set(PLUGIN_NAME rillight_player_plugin)
set(RILLIGHT_CORE_PREFIX_WINDOWS_X64 "$ENV{RILLIGHT_CORE_PREFIX_WINDOWS_X64}"
    CACHE PATH "Verified FFmpeg n9.0.1 Windows SDK with rillight_core.dll")
if(NOT EXISTS "${RILLIGHT_CORE_PREFIX_WINDOWS_X64}/rillight-core-dependencies.json")
  message(FATAL_ERROR "Set RILLIGHT_CORE_PREFIX_WINDOWS_X64 to the verified Windows core SDK")
endif()
find_package(Python3 COMPONENTS Interpreter REQUIRED)
execute_process(
  COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/../native/verify_core_dependencies.py"
    --prefix "${RILLIGHT_CORE_PREFIX_WINDOWS_X64}" --target windows-x64
  RESULT_VARIABLE verify_result
  OUTPUT_VARIABLE verify_output
  ERROR_VARIABLE verify_error)
if(NOT verify_result EQUAL 0)
  message(FATAL_ERROR "Windows core SDK verification failed: ${verify_output}${verify_error}")
endif()

file(GLOB CORE_RUNTIME CONFIGURE_DEPENDS
     "${RILLIGHT_CORE_PREFIX_WINDOWS_X64}/bin/*.dll")
set(CORE_DLL_FOUND FALSE)
foreach(runtime IN LISTS CORE_RUNTIME)
  get_filename_component(name "${runtime}" NAME)
  if(name STREQUAL "rillight_core.dll" OR name STREQUAL "librillight_core.dll")
    set(CORE_DLL_FOUND TRUE)
  endif()
endforeach()
if(NOT CORE_DLL_FOUND)
  message(FATAL_ERROR "The verified SDK has no rillight_core.dll")
endif()

add_library(${PLUGIN_NAME} SHARED
  rillight_player_plugin.cpp video_surface.cpp audio_output.cpp)
apply_standard_settings(${PLUGIN_NAME})
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL NOMINMAX _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter flutter_wrapper_plugin ole32 uuid)
set(rillight_player_bundled_libraries ${CORE_RUNTIME} PARENT_SCOPE)

set(RILLIGHT_RUNTIME_NOTICES "$<TARGET_FILE_DIR:${BINARY_NAME}>/data/rillight_player")
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../native/core_dependencies.json"
              "${RILLIGHT_CORE_PREFIX_WINDOWS_X64}/rillight-core-dependencies.json"
        DESTINATION "${RILLIGHT_RUNTIME_NOTICES}" COMPONENT Runtime)

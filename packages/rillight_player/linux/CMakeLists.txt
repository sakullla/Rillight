cmake_minimum_required(VERSION 3.16)
project(rillight_player LANGUAGES CXX)
set(PLUGIN_NAME rillight_player_plugin)
find_package(PkgConfig REQUIRED)
pkg_check_modules(EPOXY REQUIRED IMPORTED_TARGET epoxy)
pkg_check_modules(PULSE REQUIRED IMPORTED_TARGET libpulse)
if(NOT RILLIGHT_CORE_PREFIX)
  set(RILLIGHT_CORE_PREFIX "$ENV{RILLIGHT_CORE_PREFIX}" CACHE PATH
      "Verified FFmpeg n9.0.2 SDK prefix")
endif()
if(NOT EXISTS "${RILLIGHT_CORE_PREFIX}/rillight-core-dependencies.json")
  message(FATAL_ERROR "Set RILLIGHT_CORE_PREFIX to a verified FFmpeg n9.0.2 SDK")
endif()
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native"
                 "${CMAKE_CURRENT_BINARY_DIR}/rillight_core")
add_library(${PLUGIN_NAME} SHARED rillight_player_plugin.cc)
apply_standard_settings(${PLUGIN_NAME})
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_options(${PLUGIN_NAME} PRIVATE -fexceptions)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter rillight_core
  PkgConfig::PULSE PkgConfig::EPOXY)
set(rillight_player_bundled_libraries "$<TARGET_FILE:rillight_core>" PARENT_SCOPE)
# The app install copies only the shared library. Keep the pinned relative
# layout beside it; CMAKE_INSTALL_PREFIX is finalized after this file runs.
install(CODE "
  set(_enhancement_src \"$<TARGET_FILE_DIR:rillight_core>\")
  set(_enhancement_dst \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/lib\")
  if(EXISTS \"\${_enhancement_src}/rife-v4.6/flownet.bin\")
    file(COPY \"\${_enhancement_src}/rife-v4.6\" DESTINATION \"\${_enhancement_dst}\")
    file(COPY \"\${_enhancement_src}/realesr-general-x4v3.param\"
         DESTINATION \"\${_enhancement_dst}\")
    file(COPY \"\${_enhancement_src}/realesr-general-x4v3.bin\"
         DESTINATION \"\${_enhancement_dst}\")
  endif()
  if(EXISTS \"\${_enhancement_src}/shaders/anime4k\")
    file(COPY \"\${_enhancement_src}/shaders\" DESTINATION \"\${_enhancement_dst}\")
  endif()
" COMPONENT Runtime)

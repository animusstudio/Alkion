# The Flutter tooling requires CMake 3.10 or later.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "reps_capture_platform")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "reps_capture_platform_plugin")

add_library(${PLUGIN_NAME} SHARED
  "reps_capture_platform_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default; only FLUTTER_PLUGIN_EXPORT ones are visible.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

set(reps_capture_platform_bundled_libraries
  ""
  PARENT_SCOPE
)

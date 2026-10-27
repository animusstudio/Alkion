cmake_minimum_required(VERSION 3.22.1)
project(alkion_fileops LANGUAGES C)
add_library(alkion_fileops SHARED alkion_fileops.c)
set_target_properties(alkion_fileops PROPERTIES
  C_STANDARD 11 C_STANDARD_REQUIRED YES C_VISIBILITY_PRESET hidden)
target_compile_options(alkion_fileops PRIVATE -Wall -Wextra -Werror)

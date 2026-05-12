cmake_minimum_required(VERSION 3.10)
project(apex_allocator C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(apex_allocator SHARED allocator.c)
target_link_libraries(apex_allocator numa pthread)

target_include_directories(apex_allocator PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

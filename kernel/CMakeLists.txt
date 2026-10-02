cmake_minimum_required(VERSION 3.10)
project(lowlevel_kernel CXX)

# Standalone build of the low-level search kernel. It links the *unmodified* EECBS sources
# (everything in ../src except driver.cpp), so the kernel runs exactly the code the full
# eecbs binary runs. Boost is header-only for these sources (no program_options needed).

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "RelWithDebInfo")
endif()
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++14 -g -fno-omit-frame-pointer")

# gem5 SE mode needs a statically linked binary:  cmake -DKERNEL_STATIC=ON ..
option(KERNEL_STATIC "link statically (for gem5 SE mode)" OFF)
# m5_reset_stats/m5_dump_stats around the ROI: cmake -DKERNEL_M5OPS_DIR=~/gem5 ..
set(KERNEL_M5OPS_DIR "" CACHE PATH "gem5 checkout root; enables m5ops around the ROI")

set(EECBS_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/..)
include_directories(${EECBS_ROOT}/inc)
file(GLOB EECBS_SRC ${EECBS_ROOT}/src/*.cpp)
list(FILTER EECBS_SRC EXCLUDE REGEX ".*/driver\\.cpp$")

add_executable(lowlevel_kernel lowlevel_kernel.cpp ${EECBS_SRC})

find_package(Boost REQUIRED)
include_directories(${Boost_INCLUDE_DIRS})

if(KERNEL_STATIC)
    target_link_options(lowlevel_kernel PRIVATE -static)
endif()

if(KERNEL_M5OPS_DIR)
    target_compile_definitions(lowlevel_kernel PRIVATE USE_M5OPS)
    target_include_directories(lowlevel_kernel PRIVATE ${KERNEL_M5OPS_DIR}/include)
    # libm5.a is built with: scons -C ${KERNEL_M5OPS_DIR}/util/m5 build/x86/out/m5
    target_link_libraries(lowlevel_kernel
        ${KERNEL_M5OPS_DIR}/util/m5/build/x86/out/libm5.a)
endif()

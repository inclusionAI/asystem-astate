cmake_minimum_required(VERSION 3.25)

option(PREFER_CLANG "Prefer clang/clang++ when present" ON)
option(USE_LLD "Use lld when using Clang and lld exists" ON)
option(USE_MIMALLOC "Use mimalloc memory allocator" ON)
option(USE_ASTATE_RDMA_IMPL "Use RDMA implementation self backend" OFF)

if(NOT CMAKE_C_COMPILER AND NOT CMAKE_CXX_COMPILER AND PREFER_CLANG)
  find_program(CLANG_C   NAMES clang)
  find_program(CLANG_CXX NAMES clang++)
  if(CLANG_C AND CLANG_CXX)
    set(CMAKE_C_COMPILER   "${CLANG_C}"   CACHE FILEPATH "C compiler" FORCE)
    set(CMAKE_CXX_COMPILER "${CLANG_CXX}" CACHE FILEPATH "C++ compiler" FORCE)
    set(_picked "Clang")
  endif()
endif()

if(NOT CMAKE_C_COMPILER OR NOT CMAKE_CXX_COMPILER)
  find_program(GCC_C   NAMES gcc)
  find_program(GCC_CXX NAMES g++)
  if(GCC_C AND GCC_CXX)
    set(CMAKE_C_COMPILER   "${GCC_C}"   CACHE FILEPATH "C compiler" FORCE)
    set(CMAKE_CXX_COMPILER "${GCC_CXX}" CACHE FILEPATH "C++ compiler" FORCE)
    if(NOT DEFINED _picked)
      set(_picked "GCC")
    endif()
  endif()
endif()


# Project definition
project(Astate
    VERSION 0.0.1
    DESCRIPTION "Astate - High-performance tensor CACHE framework"
    LANGUAGES C CXX
)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

message(STATUS "Compiler picked: ${_picked} (C: ${CMAKE_C_COMPILER}  CXX: ${CMAKE_CXX_COMPILER})")
message(STATUS "USE_ASTATE_RDMA_IMPL = ${ASTATE_RDMA_IMPL}")


if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND USE_LLD)
  find_program(LLD_EXE NAMES lld ld.lld )
  if(LLD_EXE)
    add_link_options(-fuse-ld=lld)
    message(STATUS "Using LLD via -fuse-ld=lld")
  endif()
endif()

add_definitions(-DCPPHTTPLIB_KEEPALIVE_MAX_COUNT=1024 -DCPPHTTPLIB_THREAD_POOL_COUNT=128)
# Include configuration files
include(cmake/compiler_flags.cmake)
include(cmake/dependencies.cmake)

# Set default build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# Use glog for logging
add_definitions(-DC10_USE_GLOG)

# Global include directories
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include/
    ${CMAKE_CURRENT_SOURCE_DIR}/src/
    ${TORCH_INCLUDE_DIRS}
    ${PYTHON_INCLUDE_DIR}
    ${CUDA_INCLUDE_DIRS}
)

# Enable testing
if(ASTATE_ENABLE_TESTS)
    enable_testing()
    include(CTest)
endif()

# Source code
add_subdirectory(src)

# Python bindings
add_subdirectory(python)

# Third-party libraries
suppress_warnings_for_third_party_libraries()

# Installation configuration
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
    set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/install" CACHE PATH "Installation prefix" FORCE)
endif()

include(cmake/install_config.cmake)

# Print configuration summary
message(STATUS "")
message(STATUS "=== Astate Configuration Summary ===")
message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "C++ standard: ${CMAKE_CXX_STANDARD}")
message(STATUS "CUDA standard: ${CMAKE_CUDA_STANDARD}")
message(STATUS "CUDA architectures: ${CMAKE_CUDA_ARCHITECTURES}")
message(STATUS "Enable Python: ${ASTATE_ENABLE_PYTHON}")
message(STATUS "Enable tests: ${ASTATE_ENABLE_TESTS}")
message(STATUS "Enable tools: ${ASTATE_ENABLE_TOOLS}")
message(STATUS "Install prefix: ${CMAKE_INSTALL_PREFIX}")
message(STATUS "=====================================")
message(STATUS "")

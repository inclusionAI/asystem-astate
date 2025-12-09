# Dependencies management for Astate project
# This file manages all external dependencies for the Astate project

# ============================================
# Astate third-party prefix (installed by scripts/install_deps.sh)
# Default: ../install (relative to this CMake file's parent directory)
# ============================================
if(NOT DEFINED ASTATE_DEPS_PREFIX)
    # This cmake file is usually under <project_root> or <project_root>/cmake
    # Use its parent as project root, then append /install
    get_filename_component(Astate_PROJECT_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
    set(ASTATE_DEPS_PREFIX "${Astate_PROJECT_ROOT}/install" CACHE PATH "Prefix where Astate third-party deps are installed")
endif()

message(STATUS "Astate deps prefix: ${ASTATE_DEPS_PREFIX}")

# Let CMake and pkg-config see our own prefix first
set(CMAKE_PREFIX_PATH "${ASTATE_DEPS_PREFIX};${CMAKE_PREFIX_PATH}")
set(CMAKE_LIBRARY_PATH "${ASTATE_DEPS_PREFIX}/lib;${ASTATE_DEPS_PREFIX}/lib64;${CMAKE_LIBRARY_PATH}")
set(CMAKE_INCLUDE_PATH "${ASTATE_DEPS_PREFIX}/include;${CMAKE_INCLUDE_PATH}")

set(ENV{PKG_CONFIG_PATH}
    "${ASTATE_DEPS_PREFIX}/lib/pkgconfig:${ASTATE_DEPS_PREFIX}/lib64/pkgconfig:$ENV{PKG_CONFIG_PATH}")

# ========================
# Helper: find static libs / header-only libs in ASTATE_DEPS_PREFIX
# ========================

function(find_static_library LIB_NAME TARGET_NAME)
    if(NOT ARGN)
        message(FATAL_ERROR
            "find_static_library(${LIB_NAME} ${TARGET_NAME} <headers...>) needs at least one header name")
    endif()

    set(_ORIG_SUFFIXES "${CMAKE_FIND_LIBRARY_SUFFIXES}")
    set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")

    set(_LIB_CANDIDATES "${LIB_NAME}" "lib${LIB_NAME}.a")
    find_library(${LIB_NAME}_LIB
        NAMES ${_LIB_CANDIDATES}
        PATHS "${ASTATE_DEPS_PREFIX}/lib" "${ASTATE_DEPS_PREFIX}/lib64"
        NO_DEFAULT_PATH
    )

    set(CMAKE_FIND_LIBRARY_SUFFIXES "${_ORIG_SUFFIXES}")

    find_path(${LIB_NAME}_INCLUDE_DIR
        NAMES ${ARGN}
        PATHS "${ASTATE_DEPS_PREFIX}/include"
        NO_DEFAULT_PATH
    )

    set(_MISSING "")
    if(NOT ${LIB_NAME}_LIB)
        list(APPEND _MISSING
            "  - library: ${_LIB_CANDIDATES} in ${ASTATE_DEPS_PREFIX}/lib;${ASTATE_DEPS_PREFIX}/lib64")
    endif()
    if(NOT ${LIB_NAME}_INCLUDE_DIR)
        list(APPEND _MISSING
            "  - headers: ${ARGN} in ${ASTATE_DEPS_PREFIX}/include")
    endif()
    if(_MISSING)
        string(REPLACE ";" "\n" _MISSING "${_MISSING}")
        message(FATAL_ERROR
            "Could not find static library ${LIB_NAME} under Astate deps prefix (${ASTATE_DEPS_PREFIX}):\n${_MISSING}\n"
            "Hints: run scripts/install_deps.sh first, or set ${LIB_NAME}_LIB / ${LIB_NAME}_INCLUDE_DIR "
            "or ASTATE_DEPS_PREFIX / CMAKE_PREFIX_PATH.")
    endif()

    message(STATUS "Found static ${LIB_NAME}: ${${LIB_NAME}_LIB} (includes: ${${LIB_NAME}_INCLUDE_DIR})")
    add_library(${TARGET_NAME} STATIC IMPORTED GLOBAL)
    set_target_properties(${TARGET_NAME} PROPERTIES
        IMPORTED_LOCATION "${${LIB_NAME}_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${${LIB_NAME}_INCLUDE_DIR}"
    )
    set(${LIB_NAME}_FOUND TRUE PARENT_SCOPE)
endfunction()


function(find_header_only LIB_NAME TARGET_NAME)
    if(NOT ARGN)
        message(FATAL_ERROR
            "find_header_only(${LIB_NAME} ${TARGET_NAME} <headers...>) needs at least one header name")
    endif()

    find_path(${LIB_NAME}_INCLUDE_DIR
        NAMES ${ARGN}
        PATHS "${ASTATE_DEPS_PREFIX}/include"
        NO_DEFAULT_PATH
    )

    if(${LIB_NAME}_INCLUDE_DIR)
        message(STATUS "Found header-only ${LIB_NAME}: ${${LIB_NAME}_INCLUDE_DIR}")
        add_library(${TARGET_NAME} INTERFACE IMPORTED)
        set_target_properties(${TARGET_NAME} PROPERTIES
            INTERFACE_INCLUDE_DIRECTORIES "${${LIB_NAME}_INCLUDE_DIR}"
        )
        set(${LIB_NAME}_FOUND TRUE PARENT_SCOPE)
    else()
        message(FATAL_ERROR
            "Could not find header-only library ${LIB_NAME} under ${ASTATE_DEPS_PREFIX}/include\n"
            "Checked headers: ${ARGN}\n"
            "Hint: run scripts/install_deps.sh or install this dependency into ${ASTATE_DEPS_PREFIX}.")
    endif()
endfunction()

# ========================
# CUDA & Python
# ========================

find_package(CUDA REQUIRED)

# Python configuration
if(DEFINED ENV{CONDA_PREFIX} AND EXISTS "$ENV{CONDA_PREFIX}/bin/python")
    set(Python3_ROOT_DIR "$ENV{CONDA_PREFIX}")
    set(Python3_EXECUTABLE "$ENV{CONDA_PREFIX}/bin/python")
    message(STATUS "Using Conda Python: $ENV{CONDA_PREFIX}/bin/python")
elseif(EXISTS "/opt/conda/bin/python")
    set(Python3_ROOT_DIR "/opt/conda")
    set(Python3_EXECUTABLE "/opt/conda/bin/python")
    message(STATUS "Using system Conda Python: /opt/conda/bin/python")
else()
    message(STATUS "Using system Python search")
    unset(Python3_ROOT_DIR)
    unset(Python3_EXECUTABLE)
endif()

set(Python3_FIND_STRATEGY LOCATION)
find_package(Python3 REQUIRED COMPONENTS Interpreter Development)
set(PYTHON_INCLUDE_DIR ${Python3_INCLUDE_DIRS})

# Force PIC
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fPIC")

# ========================
# Third-party libraries (ASTATE_DEPS_PREFIX only)
# ========================

# gflags
find_static_library(gflags google::gflags gflags/gflags.h)

# glog
find_static_library(glog glog::glog glog/logging.h)

# fmt
find_static_library(fmt fmt::fmt fmt/format.h)

# spdlog (treat as header-only)
find_header_only(spdlog spdlog::spdlog spdlog/spdlog.h)

# JsonCpp
find_static_library(jsoncpp jsoncpp::jsoncpp json/json.h)

find_package(ZLIB REQUIRED)

# protobuf (static lib + protoc)
find_static_library(protobuf protobuf::libprotobuf google/protobuf/message.h)
set(_PROTOBUF_LIBPROTOBUF protobuf::libprotobuf)

# Prefer protoc in Astate deps prefix, then PATH
find_program(PROTOC_EXECUTABLE protoc
    PATHS "${ASTATE_DEPS_PREFIX}/bin"
    NO_DEFAULT_PATH
)
if(NOT PROTOC_EXECUTABLE)
    find_program(PROTOC_EXECUTABLE protoc)
endif()
if(NOT PROTOC_EXECUTABLE)
    message(FATAL_ERROR
        "protoc compiler not found.\n"
        "Expected in ${ASTATE_DEPS_PREFIX}/bin or in PATH.\n"
        "Hint: scripts/install_deps.sh should install protobuf (including protoc).")
else()
    message(STATUS "Found protoc: ${PROTOC_EXECUTABLE}")
endif()

if(TARGET protobuf::libprotobuf AND TARGET ZLIB::ZLIB)
    set_property(TARGET protobuf::libprotobuf APPEND PROPERTY
        INTERFACE_LINK_LIBRARIES ZLIB::ZLIB
    )
endif()

# brpc
find_static_library(brpc brpc::brpc brpc/server.h)

# httplib (header-only)
find_header_only(httplib httplib::httplib httplib.h)

# pybind11: prefer CMake config from ASTATE_DEPS_PREFIX
set(pybind11_DIR "${ASTATE_DEPS_PREFIX}/share/cmake/pybind11")
find_package(pybind11 CONFIG REQUIRED)
message(STATUS "Found pybind11 (CONFIG): ${pybind11_VERSION}")

# libevent
find_static_library(event event event2/event.h)

# folly
find_static_library(folly Folly::Folly folly/FBString.h)

# mimalloc (from Astate deps prefix, only if USE_MIMALLOC=ON)
if(USE_MIMALLOC)
    set(MIMALLOC_VERSIONS "3.1" "2.1" "2.0" "1.7" "")

    set(mimalloc_FOUND FALSE)
    foreach(version IN LISTS MIMALLOC_VERSIONS)
        set(_mi_lib_candidates "")
        set(_mi_inc_candidates "")

        if(version STREQUAL "")
            list(APPEND _mi_lib_candidates
                "${ASTATE_DEPS_PREFIX}/lib/libmimalloc.a"
                "${ASTATE_DEPS_PREFIX}/lib64/libmimalloc.a"
            )
            list(APPEND _mi_inc_candidates
                "${ASTATE_DEPS_PREFIX}/include"
            )
        else()
            list(APPEND _mi_lib_candidates
                "${ASTATE_DEPS_PREFIX}/lib/mimalloc-${version}/libmimalloc.a"
                "${ASTATE_DEPS_PREFIX}/lib64/mimalloc-${version}/libmimalloc.a"
            )
            list(APPEND _mi_inc_candidates
                "${ASTATE_DEPS_PREFIX}/include/mimalloc-${version}"
                "${ASTATE_DEPS_PREFIX}/include"
            )
        endif()

        unset(mimalloc_LIB CACHE)
        unset(mimalloc_INCLUDE_DIR CACHE)

        foreach(path IN LISTS _mi_lib_candidates)
            if(EXISTS "${path}")
                set(mimalloc_LIB "${path}")
                break()
            endif()
        endforeach()

        foreach(inc IN LISTS _mi_inc_candidates)
            if(EXISTS "${inc}/mimalloc.h")
                set(mimalloc_INCLUDE_DIR "${inc}")
                break()
            endif()
        endforeach()

        if(DEFINED mimalloc_LIB AND DEFINED mimalloc_INCLUDE_DIR)
            set(mimalloc_FOUND TRUE)
            break()
        endif()
    endforeach()

    if(mimalloc_FOUND)
        message(STATUS "Found mimalloc: ${mimalloc_LIB} (includes: ${mimalloc_INCLUDE_DIR})")

        add_library(mimalloc STATIC IMPORTED GLOBAL)
        set_target_properties(mimalloc PROPERTIES
            IMPORTED_LOCATION "${mimalloc_LIB}"
            INTERFACE_INCLUDE_DIRECTORIES "${mimalloc_INCLUDE_DIR}"
        )

        find_package(Threads QUIET)
        find_library(DL_LIBRARY dl)

        set(MIMALLOC_FOUND TRUE)
    else()
        message(FATAL_ERROR
            "USE_MIMALLOC is ON, but mimalloc static library was not found under ${ASTATE_DEPS_PREFIX}.\n"
            "Hint: run scripts/install_deps.sh so mimalloc is installed.")
    endif()
endif()

# ========================
# Boost (still from system)
# ========================

set(BOOST_COMPONENTS
    system filesystem thread regex program_options chrono date_time
    atomic serialization log context coroutine iostreams random timer
)
include_directories(SYSTEM /usr/include/boost1.78)
find_package(Boost QUIET COMPONENTS ${BOOST_COMPONENTS})
if(NOT Boost_FOUND)
    message(FATAL_ERROR "Boost 1.78.0 not found! Required components: ${BOOST_COMPONENTS}")
endif()

# ========================
# OpenSSL
# ========================

find_package(OpenSSL REQUIRED)

# ========================
# CUDA nvToolsExt
# ========================

if(NOT TARGET CUDA::nvToolsExt)
    find_library(NVTOOLSEXT_LIBRARY
        NAMES nvtx3interop nvToolsExt
        PATHS ${CMAKE_CUDA_TOOLKIT_ROOT_DIR}/targets/x86_64-linux/lib
              ${CMAKE_CUDA_TOOLKIT_ROOT_DIR}/lib64
              ${CMAKE_CUDA_TOOLKIT_ROOT_DIR}/lib
        NO_DEFAULT_PATH
    )
    if(NVTOOLSEXT_LIBRARY)
        add_library(CUDA::nvToolsExt SHARED IMPORTED)
        set_target_properties(CUDA::nvToolsExt PROPERTIES
            IMPORTED_LOCATION ${NVTOOLSEXT_LIBRARY}
        )
    else()
        add_library(CUDA::nvToolsExt INTERFACE IMPORTED)
    endif()
endif()

# ========================
# PyTorch
# ========================

execute_process(
    COMMAND ${Python3_EXECUTABLE} -c "import site; import os; print(site.getsitepackages()[0])"
    OUTPUT_VARIABLE SITE_PACKAGES_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
find_package(Torch REQUIRED PATHS ${SITE_PACKAGES_DIR}/torch/)

find_library(TORCH_PYTHON_LIBRARIES
    NAMES torch_python
    PATHS "${SITE_PACKAGES_DIR}/torch/lib"
    NO_DEFAULT_PATH
)
if(NOT TORCH_PYTHON_LIBRARIES)
    set(TORCH_PYTHON_LIBRARIES "")
endif()

# ========================
# UCX (Unified Communication X)
# ========================

find_static_library(ucp UCX::ucp ucp/api/ucp.h)
find_static_library(uct UCX::uct uct/api/uct.h)
find_static_library(ucs UCX::ucs ucs/type/status.h)
find_static_library(ucm UCX::ucm ucm/api/ucm.h)

add_library(UCX::ucx INTERFACE IMPORTED)

set_target_properties(UCX::ucx PROPERTIES
    INTERFACE_LINK_LIBRARIES
        "UCX::ucp;UCX::uct;UCX::ucm;UCX::ucs;bfd;pthread;dl;rt"
)

# ========================
# Tests (no auto-FetchContent for googletest)
# ========================

find_static_library(gtest      Astate_gtest      gtest/gtest.h)
find_static_library(gtest_main Astate_gtest_main gtest/gtest.h)
find_static_library(gmock      Astate_gmock      gmock/gmock.h)
find_static_library(gmock_main Astate_gmock_main gmock/gmock.h)

add_library(GTest::gtest       ALIAS Astate_gtest)
add_library(GTest::gtest_main  ALIAS Astate_gtest_main)
add_library(GTest::gmock       ALIAS Astate_gmock)
add_library(GTest::gmock_main  ALIAS Astate_gmock_main)

# Here we only define the dependency list. Actual gtest/gmock libraries
# must be provided by the user/toolchain if tests are enabled.
set(ASTATE_TEST_DEPS
    Astate_gtest
    Astate_gtest_main
    Astate_gmock
    Astate_gmock_main
    glog::glog
)

# ========================
# Aggregate dependency sets
# ========================

set(ASTATE_COMMON_DEPS
    pthread
    anl
    ${_PROTOBUF_LIBPROTOBUF}
)

if(TARGET google::gflags)
    list(APPEND ASTATE_COMMON_DEPS google::gflags)
elseif(TARGET gflags_nothreads_static)
    list(APPEND ASTATE_COMMON_DEPS gflags_nothreads_static)
endif()

if(TARGET glog::glog)
    list(APPEND ASTATE_COMMON_DEPS glog::glog)
elseif(TARGET glog)
    list(APPEND ASTATE_COMMON_DEPS glog)
endif()

if(TARGET spdlog::spdlog)
    list(APPEND ASTATE_COMMON_DEPS spdlog::spdlog)
endif()

if(TARGET jsoncpp::jsoncpp)
    list(APPEND ASTATE_COMMON_DEPS jsoncpp::jsoncpp)
elseif(TARGET jsoncpp_lib)
    list(APPEND ASTATE_COMMON_DEPS jsoncpp_lib)
endif()

if(TARGET brpc::brpc)
    list(APPEND ASTATE_COMMON_DEPS brpc::brpc)
elseif(TARGET brpc-static)
    list(APPEND ASTATE_COMMON_DEPS brpc-static)
endif()

if(TARGET httplib::httplib)
    list(APPEND ASTATE_COMMON_DEPS httplib::httplib)
elseif(TARGET httplib)
    list(APPEND ASTATE_COMMON_DEPS httplib)
endif()

if(TARGET event)
    list(APPEND ASTATE_COMMON_DEPS event)
endif()

if(TARGET Folly::Folly)
    list(APPEND ASTATE_COMMON_DEPS Folly::Folly)
endif()

if(TARGET Folly::Folly AND TARGET glog::glog)
    target_link_libraries(Folly::Folly INTERFACE glog::glog)
endif()

if(TARGET fmt::fmt)
    list(APPEND ASTATE_COMMON_DEPS fmt::fmt)
endif()

# Boost components
foreach(component ${BOOST_COMPONENTS})
    list(APPEND ASTATE_COMMON_DEPS Boost::${component})
endforeach()

list(APPEND ASTATE_COMMON_DEPS
    OpenSSL::SSL
    OpenSSL::Crypto
    dl
    leveldb
)

set(ASTATE_CUDA_DEPS
    CUDA::cudart
    CUDA::cublas
    CUDA::curand
    CUDA::nvToolsExt
)

set(ASTATE_PYTHON_DEPS
    Python3::Python
    ${TORCH_LIBRARIES}
    ${TORCH_PYTHON_LIBRARIES}
    pybind11::pybind11
)

if(USE_ASTATE_RDMA_IMPL)
    set(ASTATE_TRANSFER_DEPS
        numa
        ibverbs
        UCX::ucx
    )

    add_compile_definitions(
        ASTATE_RDMA_BACKEND_UCX=1
    )
else()
    set(ASTATE_TRANSFER_DEPS
        numa
        ibverbs
        utrans
    )

    add_compile_definitions(
        ASTATE_RDMA_BACKEND_UTRANS=1
    )
endif()


set(ASTATE_TRANSFER_DEPS
    numa
    ibverbs
    UCX::ucx
)

message(STATUS "=== Dependency Configuration ===")
message(STATUS "ASTATE_DEPS_PREFIX: ${ASTATE_DEPS_PREFIX}")
message(STATUS "ASTATE_COMMON_DEPS: ${ASTATE_COMMON_DEPS}")
message(STATUS "Python3: ${Python3_VERSION}")
message(STATUS "PyTorch: ${TORCH_LIBRARIES}")
message(STATUS "CUDA: ${CMAKE_CUDA_COMPILER_VERSION}")
message(STATUS "================================")

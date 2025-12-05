#!/bin/bash

# ========================
# Paths & global settings
# ========================

# Directory of this script (resolve relative path)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# Parent of scripts/ => project root
PARENT_DIR="$(dirname "${SCRIPT_DIR}")"

# Install prefix: parent_dir/install
INSTALL_PREFIX="${PARENT_DIR}/install"

# Working directory to keep third-party source trees
WORK_DIR="${PARENT_DIR}/thirdparties"

# Directory to track installed versions (stamp files)
STAMP_DIR="${INSTALL_PREFIX}/.dep_stamps"

mkdir -p "${INSTALL_PREFIX}" "${WORK_DIR}" "${STAMP_DIR}"

UTRANS_PKG_DIR="${PARENT_DIR}/utrans_pkg"
LIBUTRANS_DEB_PATH="${UTRANS_PKG_DIR}/libutrans_0.0.4-8_amd64.deb"
LIBUTRANS_RPM_PATH="${UTRANS_PKG_DIR}/libutrans-0.0.4-7.x86_64.rpm"

# Ensure our install prefix is visible to pkg-config (for brpc, folly, etc.)
export PKG_CONFIG_PATH="${INSTALL_PREFIX}/lib/pkgconfig:${INSTALL_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib:${INSTALL_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"

# ========================
# Helper: usage
# ========================

usage() {
    echo "Usage (single dependency):"
    echo "  $0 <repository-name> <git-tag> [cmake-options] [force_update] [clean_build] [clean_git]"
    echo ""
    echo "Usage (install all predefined dependencies):"
    echo "  $0"
    echo "  $0 all"
    echo ""
    echo "Examples (single dependency):"
    echo "  $0 brpc 1.12.1 \"-DCMAKE_BUILD_TYPE=Release\""
    echo "  $0 gflags v2.2.2 \"-DGFLAGS_BUILD_STATIC_LIBS=ON\" true"
    echo ""
    echo "Parameters (single dependency mode):"
    echo "  repository-name: Repository name (short name) or Git URL"
    echo "  git-tag:         Git tag, branch, or commit"
    echo "  cmake-options:   Optional CMake options (quoted as one argument)"
    echo "  force_update:    true/false (default false) – reinstall even if already installed"
    echo "  clean_build:     true/false (default true) – remove build directory after install"
    echo "  clean_git:       true/false (default true) – remove .git directory after install"
    echo ""
    echo "Default install prefix:"
    echo "  Dependencies are installed into ../install (parent directory of the current working directory)."
    echo "  You can override this by passing -DCMAKE_INSTALL_PREFIX=... in cmake-options, but by default this script"
    echo "  always injects -DCMAKE_INSTALL_PREFIX=../install into CMake configuration."
    echo ""
    echo "System packages:"
    echo "  On Ubuntu/Debian: this script installs apt-based build/runtime deps."
    echo "  On CentOS/RHEL-like: this script installs yum/dnf-based build/runtime deps."
    echo "  Option: --use-aliyun-mirror (Ubuntu/Debian only) to rewrite APT sources to Aliyun."
}


# ========================
# Helper: git URL handling
# ========================

is_valid_git_url() {
    local url="$1"
    if [[ "$url" =~ ^https?://.*\.git$ ]] || [[ "$url" =~ ^git@.*:.*\.git$ ]]; then
        return 0
    fi
    return 1
}

get_default_repo_url() {
    local name="$1"

    # Company-internal prefix mode
    if [[ -n "${INNER_DEPS_PREFIX:-}" ]]; then
        case "${name}" in
            # internal special-case: httplib name difference
            httplib)
                echo "${INNER_DEPS_PREFIX}/httplib.git"
                ;;
            ucx)
                echo "${INNER_DEPS_PREFIX}/ucx.git"
                ;;
            *)
                echo "${INNER_DEPS_PREFIX}/${name}.git"
                ;;
        esac
        return
    fi

    # Public / non-internal defaults
    case "$name" in
        libevent)
            echo "${LIBEVENT_REPO_URL:-https://github.com/libevent/libevent.git}"
            ;;
        gflags)
            echo "${GFLAGS_REPO_URL:-https://github.com/gflags/gflags.git}"
            ;;
        glog)
            echo "${GLOG_REPO_URL:-https://github.com/google/glog.git}"
            ;;
        fmt)
            echo "${FMT_REPO_URL:-https://github.com/fmtlib/fmt.git}"
            ;;
        jsoncpp)
            echo "${JSONCPP_REPO_URL:-https://github.com/open-source-parsers/jsoncpp.git}"
            ;;
        httplib)
            echo "${HTTPLIB_REPO_URL:-https://github.com/yhirose/cpp-httplib.git}"
            ;;
        protobuf)
            echo "${PROTOBUF_REPO_URL:-https://github.com/protocolbuffers/protobuf.git}"
            ;;
        brpc)
            echo "${BRPC_REPO_URL:-https://github.com/apache/brpc.git}"
            ;;
        folly)
            echo "${FOLLY_REPO_URL:-https://github.com/facebook/folly.git}"
            ;;
        mimalloc)
            echo "${MIMALLOC_REPO_URL:-https://github.com/microsoft/mimalloc.git}"
            ;;
        pybind11)
            echo "${PYBIND11_REPO_URL:-https://github.com/pybind/pybind11.git}"
            ;;
        spdlog)
            echo "${SPDLOG_REPO_URL:-https://github.com/gabime/spdlog.git}"
            ;;
        googletest)
            echo "${GTEST_REPO_URL:-https://github.com/google/googletest.git}"
            ;;
        ucx)
            echo "${UCX_REPO_URL:-https://github.com/openucx/ucx.git}"
            ;;
        *)
            echo "https://github.com/${name}/${name}.git"
            ;;
    esac
}

# ========================
# Helper: stamps (installed versions)
# ========================

is_installed() {
    local name="$1"
    local tag="$2"
    local stamp="${STAMP_DIR}/${name}-${tag}.stamp"
    [ -f "$stamp" ]
}

mark_installed() {
    local name="$1"
    local tag="$2"
    local stamp="${STAMP_DIR}/${name}-${tag}.stamp"
    mkdir -p "${STAMP_DIR}"
    touch "$stamp"
}

# ========================
# Helper: ensure source repository
# ========================

ensure_source_repo() {
    local name="$1"
    local url="$2"
    local tag="$3"

    local repo_path="${WORK_DIR}/${name}"

    echo "📂 Preparing source for ${name} (${tag}) in ${repo_path}"

    mkdir -p "${WORK_DIR}"

    if [ -d "${repo_path}/.git" ]; then
        echo "📁 Repository already exists, updating..."
        cd "${repo_path}" || exit 1
        git fetch --all --tags
        echo "🏷️  Checking out tag/branch/commit: ${tag}"
        git checkout "${tag}" || {
            echo "❌ Failed to checkout ${tag} in ${name}"
            exit 1
        }
    else
        if [ -d "${repo_path}" ]; then
            echo "⚠️  ${repo_path} exists but is not a git repo, removing..."
            rm -rf "${repo_path}"
        fi
        echo "📥 Cloning ${name} from ${url}..."
        git clone "${url}" "${repo_path}" || {
            echo "❌ Failed to clone repository: ${url}"
            exit 1
        }
        cd "${repo_path}" || exit 1
        echo "🏷️  Checking out tag/branch/commit: ${tag}"
        git checkout "${tag}" || {
            echo "❌ Failed to checkout ${tag} in ${name}"
            exit 1
        }
    fi

    if [ -f ".gitmodules" ]; then
        echo "📦 Updating submodules for ${name}..."
        git submodule update --init --recursive
    fi
}

# ========================
# CMake-based dependency installer
# ========================

install_cmake_dep() {
    local name="$1"
    local tag="$2"
    local repo_url="$3"
    local cmake_options="$4"
    local force_update="$5"
    local clean_build="$6"
    local clean_git="$7"

    echo "=============================="
    echo "🔧 Installing ${name} (${tag}) via CMake"
    echo "  Source repo:   ${repo_url}"
    echo "  Install prefix: ${INSTALL_PREFIX}"
    echo "  Force update:  ${force_update}"
    echo "  Clean build:   ${clean_build}"
    echo "  Clean .git:    ${clean_git}"
    echo "=============================="

    if [ "${force_update}" != "true" ] && is_installed "${name}" "${tag}"; then
        echo "✅ ${name}@${tag} already installed (stamp found in ${STAMP_DIR}), skipping."
        echo "   To reinstall, set force_update=true."
        return 0
    fi

    ensure_source_repo "${name}" "${repo_url}" "${tag}"

    local repo_path="${WORK_DIR}/${name}"
    local build_dir="${repo_path}/_build"

    if [ "${force_update}" = "true" ] && [ -d "${build_dir}" ]; then
        echo "🧹 Force update requested, removing existing build directory ${build_dir}..."
        rm -rf "${build_dir}"
    fi
    mkdir -p "${build_dir}"
    cd "${build_dir}" || exit 1

    echo "⚙️  Configuring CMake for ${name}..."
    echo "📁 Using default install prefix: ${INSTALL_PREFIX}"

    local BASE_CMAKE_OPTIONS="-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_CXX_FLAGS=\"-fPIC\" -DCMAKE_C_FLAGS=\"-fPIC\" -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} -DCMAKE_PREFIX_PATH=${INSTALL_PREFIX}"

    if [ -n "${cmake_options}" ]; then
        echo "Using custom CMake options: ${cmake_options}"
        echo "Adding base options: ${BASE_CMAKE_OPTIONS}"
        cmake .. ${BASE_CMAKE_OPTIONS} ${cmake_options} || {
            echo "❌ CMake configuration failed for ${name}"
            exit 1
        }
    else
        echo "Using default CMake options: ${BASE_CMAKE_OPTIONS}"
        cmake .. ${BASE_CMAKE_OPTIONS} || {
            echo "❌ CMake configuration failed for ${name}"
            exit 1
        }
    fi

    echo "🔨 Building ${name}..."
    make -j"$(nproc)" || {
        echo "❌ Build failed for ${name}"
        exit 1
    }

    echo "📦 Installing ${name}..."
    make install || {
        echo "❌ Install failed for ${name}"
        exit 1
    }

    mark_installed "${name}" "${tag}"
    echo "✅ ${name}@${tag} installation completed (prefix: ${INSTALL_PREFIX})"

    cd "${repo_path}" || exit 1

    if [ "${clean_build}" = "true" ] && [ -d "_build" ]; then
        echo "🧹 Cleaning build directory ${build_dir} to save disk space..."
        rm -rf "_build"
    else
        echo "💾 Keeping build directory: ${build_dir}"
    fi

    if [ "${clean_git}" = "true" ]; then
        if [ -d ".git" ]; then
            echo "🗂️  Cleaning .git directory for ${name} to save disk space..."
            rm -rf ".git"
            echo "💡 Note: git operations for ${name} are no longer possible in ${repo_path}."
        fi
    else
        echo "💾 Keeping git metadata for ${name} in ${repo_path}/.git"
    fi

    cd "${WORK_DIR}" || cd "${PARENT_DIR}" || true
}

# ========================
# Autotools-based installers: libevent, protobuf
# ========================

install_libevent() {
    local tag="$1"          # e.g. release-2.1.12-stable
    local force_update="$2" # true/false
    local name="libevent"
    local repo_url="$(get_default_repo_url libevent)"

    echo "=============================="
    echo "🔧 Installing ${name} (${tag}) via autotools"
    echo "  Source repo:   ${repo_url}"
    echo "  Install prefix: ${INSTALL_PREFIX}"
    echo "  Force update:  ${force_update}"
    echo "=============================="

    if [ "${force_update}" != "true" ] && is_installed "${name}" "${tag}"; then
        echo "✅ ${name}@${tag} already installed (stamp found in ${STAMP_DIR}), skipping."
        echo "   To reinstall, call with force_update=true."
        return 0
    fi

    ensure_source_repo "${name}" "${repo_url}" "${tag}"

    local repo_path="${WORK_DIR}/${name}"
    cd "${repo_path}" || exit 1

    echo "⚙️  Running autogen/configure for ${name}..."
    if [ -x "./autogen.sh" ]; then
        ./autogen.sh
    elif [ -x "./autogen" ]; then
        ./autogen
    fi

    CFLAGS="-fPIC" CPPFLAGS="-fPIC" ./configure \
        --prefix="${INSTALL_PREFIX}" \
        --disable-shared \
        --enable-static \
        --disable-debug-mode \
        --disable-samples \
        --disable-openssl || {
        echo "❌ configure failed for ${name}"
        exit 1
    }

    echo "🔨 Building ${name}..."
    make -j"$(nproc)" || {
        echo "❌ Build failed for ${name}"
        exit 1
    }

    echo "📦 Installing ${name}..."
    make install || {
        echo "❌ Install failed for ${name}"
        exit 1
    }

    mark_installed "${name}" "${tag}"
    echo "✅ ${name}@${tag} installation completed (prefix: ${INSTALL_PREFIX})"

    cd "${WORK_DIR}" || cd "${PARENT_DIR}" || true
}

install_protobuf() {
    local tag="$1"          # e.g. v3.13.0
    local force_update="$2" # true/false
    local name="protobuf"
    local repo_url="$(get_default_repo_url protobuf)"

    echo "=============================="
    echo "🔧 Installing ${name} (${tag}) via autotools"
    echo "  Source repo:   ${repo_url}"
    echo "  Install prefix: ${INSTALL_PREFIX}"
    echo "  Force update:  ${force_update}"
    echo "=============================="

    if [ "${force_update}" != "true" ] && is_installed "${name}" "${tag}"; then
        echo "✅ ${name}@${tag} already installed (stamp found in ${STAMP_DIR}), skipping."
        echo "   To reinstall, call with force_update=true."
        return 0
    fi

    ensure_source_repo "${name}" "${repo_url}" "${tag}"

    local repo_path="${WORK_DIR}/${name}"
    cd "${repo_path}" || exit 1

    echo "📦 Updating protobuf submodules..."
    git submodule update --init --recursive

    echo "⚙️  Running autogen/configure for protobuf..."
    if [ -x "./autogen.sh" ]; then
        ./autogen.sh
    elif [ -x "./autogen" ]; then
        ./autogen
    fi

    ./configure --disable-shared CXXFLAGS="-fPIC" --prefix="${INSTALL_PREFIX}" || {
        echo "❌ configure failed for protobuf"
        exit 1
    }

    echo "🔨 Building protobuf..."
    make -j"$(nproc)" || {
        echo "❌ Build failed for protobuf"
        exit 1
    }

    echo "📦 Installing protobuf..."
    make install || {
        echo "❌ Install failed for protobuf"
        exit 1
    }

    mark_installed "${name}" "${tag}"
    echo "✅ protobuf@${tag} installation completed (prefix: ${INSTALL_PREFIX})"

    cd "${WORK_DIR}" || cd "${PARENT_DIR}" || true
}

install_ucx() {
    local tag="$1"          # e.g. v1.19.1
    local force_update="$2" # true/false
    local name="ucx"
    local repo_url
    repo_url="$(get_default_repo_url ucx)"

    echo "=============================="
    echo "🔧 Installing ${name} (${tag}) via autotools"
    echo "  Source repo:   ${repo_url}"
    echo "  Install prefix: ${INSTALL_PREFIX}"
    echo "  Force update:  ${force_update}"
    echo "=============================="

    if [ "${force_update}" != "true" ] && is_installed "${name}" "${tag}"; then
        echo "✅ ${name}@${tag} already installed (stamp found in ${STAMP_DIR}), skipping."
        echo "   To reinstall, call with force_update=true."
        return 0
    fi

    ensure_source_repo "${name}" "${repo_url}" "${tag}"

    local repo_path="${WORK_DIR}/${name}"
    cd "${repo_path}" || exit 1

    echo "⚙️  Running autogen/configure for ${name}..."
    if [ -x "./autogen.sh" ]; then
        ./autogen.sh || {
            echo "❌ autogen.sh failed for ${name}"
            exit 1
        }
    fi

    CFLAGS="-fPIC" CXXFLAGS="-fPIC" ./contrib/configure-release \
        --prefix="${INSTALL_PREFIX}" \
        --enable-static \
        --disable-vfs \
        --disable-avx \
        --disable-doxygen-doc || {
        echo "❌ configure-release failed for ${name}"
        exit 1
    }

    echo "🔨 Building ${name}..."
    make -j"$(nproc)" || {
        echo "❌ Build failed for ${name}"
        exit 1
    }

    echo "📦 Installing ${name}..."
    make install || {
        echo "❌ Install failed for ${name}"
        exit 1
    }

    mark_installed "${name}" "${tag}"
    echo "✅ ${name}@${tag} installation completed (prefix: ${INSTALL_PREFIX})"

    cd "${WORK_DIR}" || cd "${PARENT_DIR}" || true
}

# ========================
# Install all dependencies
# ========================

install_all_deps() {
    echo "=========================================="
    echo "Installing all third-party dependencies"
    echo "  Install prefix: ${INSTALL_PREFIX}"
    echo "  Source root:    ${WORK_DIR}"
    echo "=========================================="

    # libevent (autotools)
    install_libevent "release-2.1.12-stable" "false"

    # gflags
    install_cmake_dep \
        "gflags" \
        "v2.2.2" \
        "$(get_default_repo_url gflags)" \
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DGFLAGS_BUILD_STATIC_LIBS=ON -DGFLAGS_NAMESPACE=google -DGFLAGS_BUILD_gflags_nothreads_LIB=ON -DGFLAGS_BUILD_SHARED_LIBS=OFF -DGFLAGS_BUILD_TESTING=OFF -DGFLAGS_IS_A_DLL=OFF" \
        "false" \
        "true" \
        "true"

    # glog
    install_cmake_dep \
        "glog" \
        "v0.6.0" \
        "$(get_default_repo_url glog)" \
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DWITH_UNWIND=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DWITH_GTEST=OFF -DWITH_GMOCK=OFF -DBUILD_TESTING=OFF -DWITH_GFLAGS=OFF" \
        "false" \
        "true" \
        "true"

    # fmt
    install_cmake_dep \
        "fmt" \
        "9.1.0" \
        "$(get_default_repo_url fmt)" \
        "-DCMAKE_POSITION_INDEPENDENT_CODE=TRUE -DFMT_TEST=OFF -DCMAKE_BUILD_TYPE=Release" \
        "false" \
        "true" \
        "true"

    # protobuf (autotools)
    install_protobuf "v3.13.0" "false"

    install_ucx "v1.19.1" "false"

    # jsoncpp
    install_cmake_dep \
        "jsoncpp" \
        "1.9.6" \
        "$(get_default_repo_url jsoncpp)" \
        "-DJSONCPP_WITH_TESTS=OFF -DJSONCPP_WITH_POST_BUILD_UNITTEST=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON" \
        "false" \
        "true" \
        "true"

    # httplib
    install_cmake_dep \
        "httplib" \
        "v0.14.1" \
        "$(get_default_repo_url httplib)" \
        "-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON" \
        "false" \
        "true" \
        "true"

    # brpc
    install_cmake_dep \
        "brpc" \
        "1.12.1" \
        "$(get_default_repo_url brpc)" \
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_BRPC_TOOLS=OFF -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWITH_GZIP=OFF -DWITH_ZLIB=OFF -DWITH_GFLAGS=ON -DWITH_GLOG=ON" \
        "false" \
        "true" \
        "true"

    # folly
    install_cmake_dep \
        "folly" \
        "v2023.12.04.00" \
        "$(get_default_repo_url folly)" \
        "-DBUILD_BENCHMARKS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_CXX_STANDARD_REQUIRED=ON -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF -DFOLLY_BUILD_BENCHMARKS=OFF -DFOLLY_BUILD_EXAMPLES=OFF -DFOLLY_BUILD_TESTS=OFF -DFOLLY_USE_SYMBOLIZER=OFF -DFOLLY_HAVE_LINUX_VDSO=OFF -DFOLLY_HAVE_WEAK_SYMBOLS=OFF -DFOLLY_USE_JEMALLOC=OFF" \
        "false" \
        "true" \
        "true"

    # mimalloc
    install_cmake_dep \
        "mimalloc" \
        "v3.1.5" \
        "$(get_default_repo_url mimalloc)" \
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DMI_OVERRIDE=OFF -DMI_OPT_ARCH=ON -DMI_OPT_SIMD=ON -DMI_LOCAL_DYNAMIC_TLS=ON -DMI_BUILD_SHARED=OFF -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF" \
        "false" \
        "true" \
        "true"

    # pybind11
    install_cmake_dep \
        "pybind11" \
        "v2.13.6" \
        "$(get_default_repo_url pybind11)" \
        "-DCMAKE_BUILD_TYPE=Release -DPYBIND11_PYTHON_VERSION=3 -DPYBIND11_FINDPYTHON=ON -DPYBIND11_TEST=OFF" \
        "false" \
        "true" \
        "true"

    # spdlog (version & options aligned with CMake FetchContent config)
    install_cmake_dep \
        "spdlog" \
        "v1.14.1" \
        "$(get_default_repo_url spdlog)" \
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DSPDLOG_NO_EXCEPTIONS=ON -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_TESTS=OFF -DSPDLOG_BUILD_SHARED=OFF" \
        "false" \
        "true" \
        "true"

    # googletest (for tests)
    install_cmake_dep \
        "googletest" \
        "v1.17.0" \
        "$(get_default_repo_url googletest)" \
        "-DCMAKE_BUILD_TYPE=Release -DBUILD_GTEST=ON -DBUILD_GMOCK=ON -DBUILD_SHARED_LIBS=OFF -DINSTALL_GTEST=ON" \
        "false" \
        "true" \
        "true"

    echo "✅ All third-party dependencies installed (prefix: ${INSTALL_PREFIX})"
}

verify_deps_in_install() {
  local PREFIX="${INSTALL_PREFIX}"
  local LIB_DIRS=()

  [[ -d "${PREFIX}/lib"   ]] && LIB_DIRS+=("${PREFIX}/lib")
  [[ -d "${PREFIX}/lib64" ]] && LIB_DIRS+=("${PREFIX}/lib64")

  if ((${#LIB_DIRS[@]}==0)); then
    echo "❌ No ${PREFIX}/lib or ${PREFIX}/lib64 found." >&2
    return 1
  fi

  # ---- Deps that MUST have static libs present (.a) and MUST NOT have shared libs ----
  # Right side lists required .a files (space-separated)
  declare -A STATIC_DEPS=(
    [libevent]="libevent.a"
    [protobuf]="libprotobuf.a libprotobuf-lite.a libprotoc.a"
    [gflags]="libgflags.a"
    [glog]="libglog.a"
    [fmt]="libfmt.a"
    [jsoncpp]="libjsoncpp.a"
    [brpc]="libbrpc.a"
    [folly]="libfolly.a"
    [mimalloc]="mimalloc-3.1/libmimalloc.a"
    [gtest]="libgtest.a"
  )

  # ---- Header-only deps (validate by header presence and absence of shared libs) ----
  declare -A HEADER_ONLY_DEPS=(
    [pybind11]="${PREFIX}/include/pybind11/pybind11.h"
    [httplib]="${PREFIX}/include/httplib.h ${PREFIX}/include/cpp-httplib/httplib.h"
    [spdlog]="${PREFIX}/include/spdlog/spdlog.h"
  )

  echo "🔎 Verifying prefix: ${PREFIX}"
  echo "📚 Library search paths: ${LIB_DIRS[*]}"
  echo

  # check all static deps
  for dep in "${!STATIC_DEPS[@]}"; do
    local archives="${STATIC_DEPS[$dep]}"
    local a base found_path shared_dir

    for a in $archives; do
      base="${a%.a}"   # e.g. libfmt.a -> libfmt

      # find static archive
      found_path=""
      for d in "${LIB_DIRS[@]}"; do
        if [[ -f "${d}/${a}" ]]; then
          found_path="${d}/${a}"
          break
        fi
      done

      if [[ -z "${found_path}" ]]; then
        echo "❌ ${dep}: Missing static archive ${a} (searched in: ${LIB_DIRS[*]})." >&2
        return 1
      fi

      # check there is NO shared lib for same base
      shared_dir=""
      for d in "${LIB_DIRS[@]}"; do
        if compgen -G "${d}/${base}.so"    >/dev/null || \
           compgen -G "${d}/${base}.so.*"  >/dev/null || \
           compgen -G "${d}/${base}.dylib" >/dev/null ; then
          shared_dir="${d}"
          break
        fi
      done

      if [[ -n "${shared_dir}" ]]; then
        echo "❌ ${dep}: Found shared library ${base}.so/.dylib in ${shared_dir}, but only static libraries are allowed." >&2
        return 1
      fi
    done

    echo "✅ ${dep}: Static archives present and no shared libraries found."
  done

  # check header-only deps
  for dep in "${!HEADER_ONLY_DEPS[@]}"; do
    local headers="${HEADER_ONLY_DEPS[$dep]}"
    local h found_header shared_dir guess_base

    found_header=""
    for h in $headers; do
      if [[ -f "$h" ]]; then
        found_header="$h"
        break
      fi
    done

    if [[ -z "${found_header}" ]]; then
      echo "❌ ${dep}: Header(s) not found (checked: $headers)." >&2
      return 1
    fi

    # ensure no shared lib like libpybind11.so/libhttplib.so/libspdlog.so
    guess_base="lib${dep}"
    shared_dir=""
    for d in "${LIB_DIRS[@]}"; do
      if compgen -G "${d}/${guess_base}.so"    >/dev/null || \
         compgen -G "${d}/${guess_base}.so.*"  >/dev/null || \
         compgen -G "${d}/${guess_base}.dylib" >/dev/null ; then
        shared_dir="${d}"
        break
      fi
    done

    if [[ -n "${shared_dir}" ]]; then
      echo "❌ ${dep}: Found shared library ${guess_base}.so/.dylib in ${shared_dir}, but header-only/static-only is required." >&2
      return 1
    fi

    echo "✅ ${dep}: Header(s) found and no shared libraries detected."
  done

  echo
  echo "🎉 All checks passed for prefix ${PREFIX}: required deps are present as static-only (or header-only with no shared libs)."
}

# ========================
# System-level dependencies
# ========================

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_LIKE="$ID_LIKE"
        OS_VERSION="$VERSION_ID"
    else
        echo "Cannot detect operating system type (missing /etc/os-release)" >&2
        exit 1
    fi

    case "$OS" in
        ubuntu|debian)
            OS_TYPE="ubuntu"
            ;;
        alinux|centos|rhel|fedora|anolis)
            OS_TYPE="centos"
            ;;
        *)
            case "$OS_LIKE" in
                *debian*)
                    OS_TYPE="ubuntu"
                    ;;
                *rhel*|*fedora*|*centos*)
                    OS_TYPE="centos"
                    ;;
                *)
                    OS_TYPE="unknown"
                    ;;
            esac
            ;;
    esac

    echo "Detected OS: ${OS} (type: ${OS_TYPE}, version: ${OS_VERSION})"
}

setup_ubuntu_mirror_aliyun() {
    if [ "$OS_TYPE" != "ubuntu" ]; then
        echo "setup_ubuntu_mirror_aliyun: OS_TYPE=${OS_TYPE}, only ubuntu/debian-like systems are supported." >&2
        return 1
    fi

    echo "Setting up Ubuntu Alibaba Cloud mirror (Aliyun)..."

    if [ ! -w /etc/apt/sources.list ]; then
        echo "⚠️  /etc/apt/sources.list is not writable; you probably need to run this script with sudo." >&2
        return 1
    fi

    local codename="${UBUNTU_CODENAME:-}"
    if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
        codename="$(lsb_release -sc)"
    fi
    codename="${codename:-noble}"

    cp /etc/apt/sources.list "/etc/apt/sources.list.backup.$(date +%Y%m%d%H%M%S)"

    cat > /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/ubuntu/ ${codename} main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${codename}-security main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${codename}-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${codename}-proposed main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ ${codename}-backports main restricted universe multiverse
EOF

    echo "Updated /etc/apt/sources.list to use Aliyun mirror (codename=${codename})"
    apt update
}

install_system_deps_ubuntu() {
    if [ "$OS_TYPE" != "ubuntu" ]; then
        echo "install_system_deps_ubuntu: OS_TYPE=${OS_TYPE}, only ubuntu/debian-like systems are supported." >&2
        exit 1
    fi

    echo "Installing system dependencies using apt on ${OS}..."

    apt update
    apt install -y \
        cmake make automake autoconf libtool \
        libssl-dev libleveldb-dev \
        google-perftools libgoogle-perftools-dev \
        iputils-ping telnet bc gdb pciutils \
        numactl screen libnuma-dev \
        libibverbs-dev librdmacm-dev ibverbs-providers \
        libboost-all-dev \
        libdouble-conversion-dev \
        zlib1g-dev libbz2-dev liblz4-dev libsnappy-dev \
        libdwarf-dev binutils-dev libaio-dev liburing-dev \
        libsodium-dev libunwind-dev \
        clang lld clang-tools gcc g++

    echo "✅ System dependencies installed successfully on ${OS}."
}

install_system_deps_centos() {
    if [ "$OS_TYPE" != "centos" ]; then
        echo "install_system_deps_centos: OS_TYPE=${OS_TYPE}, only RHEL/CentOS-like systems are supported." >&2
        exit 1
    fi

    local PKG_MGR
    if command -v dnf >/dev/null 2>&1; then
        PKG_MGR=dnf
    else
        PKG_MGR=yum
    fi

    echo "Installing system dependencies using ${PKG_MGR} on ${OS}..."

    ${PKG_MGR} -y install epel-release || true

    ${PKG_MGR} -y install \
        cmake make automake autoconf libtool \
        openssl-devel leveldb-devel \
        gperftools gperftools-devel \
        iputils telnet bc gdb pciutils \
        numactl numactl-devel \
        rdma-core rdma-core-devel libibverbs-devel librdmacm-devel \
        boost1.78-devel \
        double-conversion-devel \
        zlib-devel bzip2-devel lz4-devel snappy-devel \
        libdwarf-devel binutils-devel libaio-devel liburing-devel \
        libsodium-devel libunwind-devel \
        clang lld clang-tools-extra gcc gcc-c++

    echo "✅ System dependencies installed successfully on ${OS}."
}

install_libutrans() {
    echo "Installing libutrans package..."

    case "$OS_TYPE" in
        ubuntu)
            if [ ! -f "${LIBUTRANS_DEB_PATH}" ]; then
                echo "⚠️  libutrans DEB package not found at ${LIBUTRANS_DEB_PATH}, skip installing libutrans on Ubuntu."
                return 0
            fi

            echo "Installing libutrans from local DEB: ${LIBUTRANS_DEB_PATH}"
            dpkg -i "${LIBUTRANS_DEB_PATH}" || true

            apt --fix-broken install -y

            if [ -f /lib/x86_64-linux-gnu/libibverbs.so.1 ]; then
                echo "Creating symbolic link for libibverbs..."
                ln -sf /lib/x86_64-linux-gnu/libibverbs.so.1 /lib/x86_64-linux-gnu/libibverbs.so
                if [ -L /lib/x86_64-linux-gnu/libibverbs.so ]; then
                    echo "Symbolic link created successfully:"
                    ls -l /lib/x86_64-linux-gnu/libibverbs.so
                else
                    echo "Warning: Failed to create symbolic link"
                fi
            fi

            echo "libutrans installed successfully on Ubuntu."
            ;;

        centos)
            if [ ! -f "${LIBUTRANS_RPM_PATH}" ]; then
                echo "⚠️  libutrans RPM package not found at ${LIBUTRANS_RPM_PATH}, skip installing libutrans on CentOS."
                return 0
            fi

            local PKG_MGR
            if command -v dnf >/dev/null 2>&1; then
                PKG_MGR=dnf
            else
                PKG_MGR=yum
            fi

            echo "Installing libutrans from local RPM: ${LIBUTRANS_RPM_PATH} using ${PKG_MGR}..."
            ${PKG_MGR} install -y "${LIBUTRANS_RPM_PATH}"
            echo "libutrans installed successfully on CentOS."
            ;;

        *)
            echo "OS_TYPE=${OS_TYPE} not supported for libutrans installation, skipping."
            ;;
    esac
}

# ========================
# Main entry
# ========================

main() {
    local use_aliyun=0
    if [ "${1:-}" = "--use-aliyun-mirror" ]; then
        use_aliyun=1
        shift
    fi

    detect_os
    if [ "$OS_TYPE" = "ubuntu" ]; then
        if [ "$use_aliyun" -eq 1 ]; then
            setup_ubuntu_mirror_aliyun
        fi
        install_system_deps_ubuntu
        install_libutrans
    elif [ "$OS_TYPE" = "centos" ]; then
        install_system_deps_centos
        install_libutrans
    else
        echo "Note: system package installation is only supported on Ubuntu/Debian/CentOS-like systems; continuing with CMake deps only."
    fi

    if [ "$#" -eq 0 ] || [ "$1" = "all" ]; then
        install_all_deps
    else
        if [ "$#" -lt 2 ] || [ "$#" -gt 6 ]; then
            usage
            return 1
        fi

        local repo_name="$1"
        local git_tag="$2"
        local cmake_options="${3:-}"
        local force_update="${4:-false}"
        local clean_build="${5:-true}"
        local clean_git="${6:-true}"

        case "${repo_name}" in
            libevent)
                install_libevent "${git_tag}" "${force_update}"
                ;;
            protobuf)
                install_protobuf "${git_tag}" "${force_update}"
                ;;
            ucx)
                install_ucx "${git_tag}" "${force_update}"
                ;;
            *)
                local repo_basename
                local repo_url
                if is_valid_git_url "${repo_name}"; then
                    repo_url="${repo_name}"
                    repo_basename="$(basename "${repo_name}" .git)"
                    echo "🔧 Using provided Git URL: ${repo_name}"
                else
                    repo_basename="${repo_name}"
                    repo_url="$(get_default_repo_url "${repo_name}")"
                    echo "🔧 Using default repository URL: ${repo_url}"
                fi
                install_cmake_dep "${repo_basename}" "${git_tag}" "${repo_url}" "${cmake_options}" "${force_update}" "${clean_build}" "${clean_git}"
                ;;
        esac
    fi

    verify_deps_in_install
}


main "$@"

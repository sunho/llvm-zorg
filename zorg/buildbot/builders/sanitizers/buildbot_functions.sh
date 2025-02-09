#!/usr/bin/env bash

echo @@@BUILD_STEP Info@@@
(
  set +e
  env
  echo
  uptime
  echo
  ulimit -n 1000000
  ulimit -a
  echo
  df -h
  echo
  ccache -s
  exit 0
)
echo @@@BUILD_STEP Prepare@@@

BUILDBOT_CLOBBER="${BUILDBOT_CLOBBER:-}"
BUILDBOT_REVISION="${BUILDBOT_REVISION:-origin/main}"

export LIT_OPTS=--time-tests
CMAKE_COMMON_OPTIONS="-DLLVM_LIT_ARGS=-v"

function rm_dirs {
  while ! rm -rf $@ ; do sleep 1; done
}

function cleanup() {
  [[ -v BUILDBOT_BUILDERNAME ]] || return 0
  echo @@@BUILD_STEP cleanup@@@
  rm_dirs llvm_build2_* llvm_build_* libcxx_build_* compiler_rt_build* symbolizer_build* $@
  if ccache -s >/dev/null ; then
    rm_dirs llvm_build64 clang_build
  fi
  ls
}

function clobber {
  if [[ "$BUILDBOT_CLOBBER" != "" ]]; then
    echo @@@BUILD_STEP clobber@@@
    if [[ ! -v BUILDBOT_BUILDERNAME ]]; then
      echo "Clobbering is supported only on buildbot only!"
      exit 1
    fi
    rm_dirs *
  else
    BUILDBOT_BUILDERNAME=1 cleanup $@
  fi
}

BUILDBOT_MONO_REPO_PATH=${BUILDBOT_MONO_REPO_PATH:-}

function buildbot_update {
  echo @@@BUILD_STEP update $BUILDBOT_REVISION@@@
  if [[ -d "$BUILDBOT_MONO_REPO_PATH" ]]; then
    LLVM=$BUILDBOT_MONO_REPO_PATH/llvm
  else
    (
      local DEPTH=100
      [[ -d llvm-project ]] || (
        mkdir -p llvm-project
        cd llvm-project
        git init
        git remote add origin https://github.com/llvm/llvm-project.git
        git config --local advice.detachedHead false
      )
      cd llvm-project
      git fetch --depth $DEPTH origin main
      git clean -fd
      local REV=${BUILDBOT_REVISION}
      if [[  "$REV" != "origin/main" ]] ; then
        # "git fetch --depth 1 origin $REV" does not work with 2.11 on bots
        while true ; do
          git checkout -f $REV && break
          git rev-list --pretty --max-count=1 origin/main
          git rev-list --pretty --max-parents=0 origin/main
          echo "DEPTH=$DEPTH is too small"
          [[ "$DEPTH" -le "1000000" ]] || exit 1
          DEPTH=$(( $DEPTH * 10 ))
          git fetch --depth $DEPTH origin
        done
      fi
      git checkout -f $REV
      git status
      git rev-list --pretty --max-count=1 HEAD
    ) || { build_exception ; exit 1 ; }
    LLVM=$ROOT/llvm-project/llvm
  fi
}

function common_stage1_variables {
  STAGE1_DIR=llvm_build0
  stage1_clang_path=$ROOT/${STAGE1_DIR}/bin
  llvm_symbolizer_path=${stage1_clang_path}/llvm-symbolizer
  STAGE1_AS_COMPILER="-DCMAKE_C_COMPILER=${stage1_clang_path}/clang -DCMAKE_CXX_COMPILER=${stage1_clang_path}/clang++"
}

function build_stage1_clang_impl {
  mkdir -p ${STAGE1_DIR}
  local cmake_stage1_options="${CMAKE_COMMON_OPTIONS} -DLLVM_ENABLE_PROJECTS='clang;compiler-rt;lld'"
  if clang -v ; then
    cmake_stage1_options+=" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++"
  fi
  if ccache -s ; then
    cmake_stage1_options+=" -DLLVM_CCACHE_BUILD=ON"
  fi
  (cd ${STAGE1_DIR} && cmake ${cmake_stage1_options} $LLVM && ninja)
}

function build_stage1_clang {
  echo @@@BUILD_STEP stage1 build all@@@
  common_stage1_variables
  build_stage1_clang_impl
}

function download_clang_from_chromium {
  common_stage1_variables

  curl -s https://raw.githubusercontent.com/chromium/chromium/main/tools/clang/scripts/update.py \
    | python3 - --output-dir=${STAGE1_DIR}

  echo @@@BUILD_STEP using pre-built stage1 clang at $(cat ${STAGE1_DIR}/cr_build_revision)@@@
}

function build_clang_at_release_tag {
  local HOST_CLANG_REVISION=llvmorg-$(curl https://api.github.com/repos/llvm/llvm-project/releases/latest -s | jq .name -r | cut -f2 -d' ')
  common_stage1_variables

  if  [ -r ${STAGE1_DIR}/host_clang_revision ] && \
      [ "$(cat ${STAGE1_DIR}/host_clang_revision)" == $HOST_CLANG_REVISION ]
  then
    echo @@@BUILD_STEP using pre-built stage1 clang at r$HOST_CLANG_REVISION@@@
  else
    BUILDBOT_MONO_REPO_PATH= BUILDBOT_REVISION=$HOST_CLANG_REVISION buildbot_update

    rm -rf ${STAGE1_DIR}
    echo @@@BUILD_STEP build stage1 clang at $HOST_CLANG_REVISION@@@
    build_stage1_clang_impl && \
      ( echo $HOST_CLANG_REVISION > ${STAGE1_DIR}/host_clang_revision )
  fi
}

function build_stage1_clang_at_revison {
  build_clang_at_release_tag
}

function common_stage2_variables {
  cmake_stage2_common_options="\
    ${CMAKE_COMMON_OPTIONS} ${STAGE1_AS_COMPILER} -DLLVM_USE_LINKER=lld"
}

function build_stage2 {
  local sanitizer_name=$1
  echo @@@BUILD_STEP stage2/$sanitizer_name build libcxx@@@

  local libcxx_build_dir=libcxx_build_${sanitizer_name}
  local build_dir=llvm_build_${sanitizer_name}
  export STAGE2_DIR=${build_dir}
  local build_type="Release"
  local cmake_libcxx_cflags=

  common_stage2_variables

  if [ "$sanitizer_name" == "msan" ]; then
    export MSAN_SYMBOLIZER_PATH="${llvm_symbolizer_path}"
    llvm_use_sanitizer="Memory"
    fsanitize_flag="-fsanitize=memory -fsanitize-memory-use-after-dtor -fsanitize-memory-param-retval"
  elif [ "$sanitizer_name" == "msan_track_origins" ]; then
    export MSAN_SYMBOLIZER_PATH="${llvm_symbolizer_path}"
    llvm_use_sanitizer="MemoryWithOrigins"
    fsanitize_flag="-fsanitize=memory -fsanitize-memory-track-origins -fsanitize-memory-use-after-dtor -fsanitize-memory-param-retval"
  elif [ "$sanitizer_name" == "asan" ]; then
    export ASAN_SYMBOLIZER_PATH="${llvm_symbolizer_path}"
    export ASAN_OPTIONS="check_initialization_order=true:detect_stack_use_after_return=1:detect_leaks=1"
    llvm_use_sanitizer="Address"
    fsanitize_flag="-fsanitize=address"
    # FIXME: False ODR violations in libcxx tests.
    # https://github.com/google/sanitizers/issues/1017
    cmake_libcxx_cflags="-mllvm -asan-use-private-alias=1"
  elif [ "$sanitizer_name" == "hwasan" ]; then
    export HWASAN_SYMBOLIZER_PATH="${llvm_symbolizer_path}"
    llvm_use_sanitizer="HWAddress"
    fsanitize_flag="-fsanitize=hwaddress"
  elif [ "$sanitizer_name" == "ubsan" ]; then
    export UBSAN_OPTIONS="external_symbolizer_path=${llvm_symbolizer_path}:print_stacktrace=1"
    llvm_use_sanitizer="Undefined"
    fsanitize_flag="-fsanitize=undefined"
  else
    echo "Unknown sanitizer!"
    exit 1
  fi

  # Don't use libc++/libc++abi in UBSan builds (due to known bugs).
  mkdir -p ${libcxx_build_dir}
  (cd ${libcxx_build_dir} && \
    cmake \
      ${cmake_stage2_common_options} \
      -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
      -DCMAKE_BUILD_TYPE=${build_type} \
      -DLLVM_USE_SANITIZER=${llvm_use_sanitizer} \
      -DCMAKE_C_FLAGS="${fsanitize_flag} ${cmake_libcxx_cflags}" \
      -DCMAKE_CXX_FLAGS="${fsanitize_flag} ${cmake_libcxx_cflags}" \
      $LLVM && \
    ninja cxx cxxabi) || build_failure

  local libcxx_runtime_path=$(dirname $(find ${ROOT}/${libcxx_build_dir} -name libc++.so))
  local sanitizer_ldflags="-lc++abi -Wl,--rpath=${libcxx_runtime_path} -L${libcxx_runtime_path}"
  local sanitizer_cflags="-nostdinc++ -isystem ${ROOT}/${libcxx_build_dir}/include -isystem ${ROOT}/${libcxx_build_dir}/include/c++/v1 $fsanitize_flag"

  echo @@@BUILD_STEP stage2/$sanitizer_name build@@@

  # See http://llvm.org/bugs/show_bug.cgi?id=19071, http://www.cmake.org/Bug/view.php?id=15264
  sanitizer_cflags+=" $sanitizer_ldflags -w"

  mkdir -p ${build_dir}
  local cmake_stage2_clang_options="-DLLVM_ENABLE_PROJECTS='clang;lld;clang-tools-extra;mlir'"
  (cd ${build_dir} && \
   cmake \
     ${cmake_stage2_common_options} \
     ${cmake_stage2_clang_options} \
     -DCMAKE_BUILD_TYPE=${build_type} \
     -DLLVM_USE_SANITIZER=${llvm_use_sanitizer} \
     -DLLVM_ENABLE_LIBCXX=ON \
     -DCMAKE_C_FLAGS="${sanitizer_cflags}" \
     -DCMAKE_CXX_FLAGS="${sanitizer_cflags}" \
     -DCMAKE_EXE_LINKER_FLAGS="${sanitizer_ldflags}" \
     $LLVM && \
   ninja) || build_failure
}

function build_stage2_msan {
  build_stage2 msan
}

function build_stage2_msan_track_origins {
  build_stage2 msan_track_origins
}

function build_stage2_asan {
  build_stage2 asan
}

function build_stage2_hwasan {
  build_stage2 hwasan
}

function build_stage2_ubsan {
  build_stage2 ubsan
}

function check_stage1 {
  local sanitizer_name=$1

  echo @@@BUILD_STEP stage1/$sanitizer_name check-sanitizer@@@
  ninja -C ${STAGE1_DIR} check-sanitizer || build_failure

  echo @@@BUILD_STEP stage1/$sanitizer_name check-${sanitizer_name}@@@
  ninja -C ${STAGE1_DIR} check-${sanitizer_name} || build_failure
}

function check_stage1_msan {
  check_stage1 msan
}

function check_stage1_asan {
  check_stage1 asan
}

function check_stage1_hwasan {
  check_stage1 hwasan
}

function check_stage1_ubsan {
  check_stage1 ubsan
}

function check_stage2 {
  local sanitizer_name=$1

  echo @@@BUILD_STEP stage2/$sanitizer_name check-cxx@@@
  ninja -C libcxx_build_${sanitizer_name} check-cxx || build_failure

  echo @@@BUILD_STEP stage2/$sanitizer_name check-cxxabi@@@
  ninja -C libcxx_build_${sanitizer_name} check-cxxabi || build_failure

  echo @@@BUILD_STEP stage2/$sanitizer_name check@@@
  ninja -C ${STAGE2_DIR} check-all || build_failure
}

function check_stage2_msan {
  check_stage2 msan
}

function check_stage2_msan_track_origins {
  check_stage2 msan_track_origins
}

function check_stage2_asan {
  check_stage2 asan
}

function check_stage2_hwasan {
  check_stage2 hwasan
}

function check_stage2_ubsan {
  check_stage2 ubsan
}

function build_stage3 {
  local sanitizer_name=$1
  echo @@@BUILD_STEP build stage3/$sanitizer_name build@@@

  local build_dir=llvm_build2_${sanitizer_name}

  local clang_path=$ROOT/${STAGE2_DIR}/bin
  mkdir -p ${build_dir}
  (cd ${build_dir} && \
   cmake \
     ${CMAKE_COMMON_OPTIONS} \
     -DLLVM_ENABLE_PROJECTS='clang;lld;clang-tools-extra' \
     -DCMAKE_C_COMPILER=${clang_path}/clang \
     -DCMAKE_CXX_COMPILER=${clang_path}/clang++ \
     -DLLVM_USE_LINKER=lld \
     $LLVM && \
  ninja clang) || build_failure
}

function build_stage3_msan {
  build_stage3 msan
}

function build_stage3_msan_track_origins {
  build_stage3 msan_track_origins
}

function build_stage3_asan {
  build_stage3 asan
}

function build_stage3_hwasan {
  build_stage3 hwasan
}

function build_stage3_ubsan {
  build_stage3 ubsan
}

function check_stage3 {
  local sanitizer_name=$1
  echo @@@BUILD_STEP stage3/$sanitizer_name check@@@

  local build_dir=llvm_build2_${sanitizer_name}

  (cd ${build_dir} && env && ninja check-all) || build_failure
}

function check_stage3_msan {
  check_stage3 msan
}

function check_stage3_msan_track_origins {
  check_stage3 msan_track_origins
}

function check_stage3_asan {
  check_stage3 asan
}

function check_stage3_hwasan {
  check_stage3 hwasan
}

function check_stage3_ubsan {
  check_stage3 ubsan
}

function build_failure() {
  echo
  echo "How to reproduce locally: https://github.com/google/sanitizers/wiki/SanitizerBotReproduceBuild"
  echo

  sleep 5
  echo "@@@STEP_FAILURE@@@"
}

function build_exception() {
  echo
  echo "How to reproduce locally: https://github.com/google/sanitizers/wiki/SanitizerBotReproduceBuild"
  echo

  sleep 5
  echo "@@@STEP_EXCEPTION@@@"
}

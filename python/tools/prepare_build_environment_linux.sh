#! /bin/bash

set -e
set -x

pip install "cmake==3.22.*"

if [ "$CIBW_ARCHS" == "aarch64" ]; then

    OPENBLAS_VERSION=0.3.26
    curl -L -O https://github.com/xianyi/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.tar.gz
    tar xf *.tar.gz && rm *.tar.gz
    cd OpenBLAS-*
    # NUM_THREADS: maximum value for intra_threads
    # NUM_PARALLEL: maximum value for inter_threads
    make -j$(nproc) TARGET=ARMV8 NO_SHARED=1 BUILD_SINGLE=1 NO_LAPACK=1 ONLY_CBLAS=1 USE_OPENMP=1
    make -j$(nproc) install NO_SHARED=1
    cd ..
    rm -r OpenBLAS-*

else
    dnf install -y dnf-plugins-core
    # Install CUDA:
    dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
    # error mirrorlist.centos.org doesn't exists anymore.
    sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/*.repo
    sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/*.repo
    sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/*.repo
    dnf install --setopt=obsoletes=0 -y \
        cuda-nvcc-13-2 \
        cuda-cudart-devel-13-2 \
        libcurand-devel-13-2 \
        libcudnn9-devel-cuda-13 \
        libcublas-devel-13-2 \
        libnccl-2.30.4-1+cuda13.2 \
        libnccl-devel-2.30.4-1+cuda13.2

    export CUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-13.2
    ls -la ${CUDA_TOOLKIT_ROOT_DIR}
    ls -la ${CUDA_TOOLKIT_ROOT_DIR}/bin
    export CUDA_HOME=$CUDA_TOOLKIT_ROOT_DIR
    export CUDA_PATH=$CUDA_TOOLKIT_ROOT_DIR
    export PATH="${CUDA_TOOLKIT_ROOT_DIR}:${PATH}"
    export CUDACXX=${CUDA_TOOLKIT_ROOT_DIR}/bin/nvcc
    export LD_LIBRARY_PATH=${CUDA_TOOLKIT_ROOT_DIR}/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

    if ! find /usr/include "${CUDA_TOOLKIT_ROOT_DIR}" -name 'cuda_runtime.h' -print -quit 2>/dev/null | grep -q .; then
      echo "Did not find cuda_runtime.h !"
      exit 1
    fi

    ONEAPI_VERSION=2025.3.0
    dnf config-manager --add-repo https://yum.repos.intel.com/oneapi
    rpm --import https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
    dnf install -y intel-oneapi-mkl-devel-$ONEAPI_VERSION

    (
      ONEDNN_VERSION=3.1.1
      ONEDNN_OWNER="Phobos1641"
      ONEDNN_REPO="oneDNN"
      ONEDNN_TAG="v${ONEDNN_VERSION}-phobos"
      ONEDNN_PREFIX="/usr"

      ONEDNN_ASSET="onednn-${ONEDNN_TAG}-linux-x86_64-glibc2.34.tar.gz"
      ONEDNN_URL="https://github.com/${ONEDNN_OWNER}/${ONEDNN_REPO}/releases/download/${ONEDNN_TAG}"

      ONEDNN_TMP="$(mktemp -d)"
      curl -fsSL -o "${ONEDNN_TMP}/${ONEDNN_ASSET}"        "${ONEDNN_URL}/${ONEDNN_ASSET}"
      curl -fsSL -o "${ONEDNN_TMP}/${ONEDNN_ASSET}.sha256" "${ONEDNN_URL}/${ONEDNN_ASSET}.sha256"
      ( cd "$ONEDNN_TMP" && sha256sum -c "${ONEDNN_ASSET}.sha256" )

      mkdir -p "$ONEDNN_PREFIX"
      tar -xzf "${ONEDNN_TMP}/${ONEDNN_ASSET}" -C "$ONEDNN_PREFIX"
      rm -rf "$ONEDNN_TMP"
    )

    (
      OPENMPI_VERSION=4.1.8
      curl -L -O https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-${OPENMPI_VERSION}.tar.bz2
      tar xf *.tar.bz2 && rm *.tar.bz2
      cd openmpi-*
      ./configure
      make -j$(nproc) install
      cd ..
      rm -r openmpi-*
    )
    export LD_LIBRARY_PATH="/usr/local/lib/:$LD_LIBRARY_PATH"
fi

mkdir build-release && cd build-release

if [ "$CIBW_ARCHS" == "aarch64" ]; then
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_CLI=OFF -DWITH_MKL=OFF -DOPENMP_RUNTIME=COMP -DCMAKE_PREFIX_PATH="/opt/OpenBLAS" -DWITH_OPENBLAS=ON -DWITH_RUY=ON ..
else
    cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_FLAGS="-msse4.1" \
      -DBUILD_CLI=OFF \
      -DWITH_DNNL=ON \
      -DOPENMP_RUNTIME=COMP \
      -DCUDA_TOOLKIT_ROOT_DIR=${CUDA_TOOLKIT_ROOT_DIR} \
      -DWITH_CUDA=ON \
      -DWITH_CUDNN=ON \
      -DCUDA_DYNAMIC_LOADING=ON \
      -DCUDA_NVCC_FLAGS="-Xfatbin=-compress-all" \
      -DWITH_TENSOR_PARALLEL=ON \
      ..
fi

VERBOSE=1 make -j$(nproc) install
cd ..
rm -r build-release

cp README.md python/

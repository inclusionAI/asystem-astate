FROM nvidia/cuda:13.0.2-cudnn-devel-ubuntu24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        wget \
        ca-certificates \
        build-essential \
        cmake \
        pkg-config \
        make \
        ninja-build \
        libssl-dev \
        libffi-dev \
        && \
    rm -rf /var/lib/apt/lists/*

RUN wget https://mirror.nju.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh \
      -O /tmp/miniforge.sh && \
    bash /tmp/miniforge.sh -b -p /opt/conda && \
    rm -f /tmp/miniforge.sh

ENV PATH=/opt/conda/bin:$PATH \
    CONDA_AUTO_UPDATE_CONDA=false \
    PYTHONUNBUFFERED=1

RUN echo 'export PATH="/opt/conda/bin:$PATH"' >> /root/.bashrc && \
    echo 'export CONDA_AUTO_UPDATE_CONDA=false' >> /root/.bashrc && \
    echo 'export PYTHONUNBUFFERED=1' >> /root/.bashrc && \
    echo 'export PYTHONDONTWRITEBYTECODE=1' >> /root/.bashrc && source /root/.bashrc

RUN pip install torch torchvision --index-url https://download.pytorch.org/whl/cu130

WORKDIR /workspace

# ! must use docker build -f docker/xxDockerfile, can not build under same dir
COPY . /workspace

RUN cd /workspace
RUN make deps
RUN make install

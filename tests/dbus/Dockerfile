FROM ubuntu:22.04 AS build

RUN apt-get update && apt-get install -y \
    build-essential \
    meson \
    ninja-build \
    pkg-config \
    libunwind-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .

RUN meson setup build/ -Dverbose_mode=true

RUN cd build && meson compile

RUN useradd -u 1000 dbuz
USER dbuz
ENTRYPOINT ["./entrypoint.sh"]

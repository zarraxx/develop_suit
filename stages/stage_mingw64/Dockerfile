# syntax=docker/dockerfile:1.7

ARG STAGE_MINGW64_BASE_IMAGE=ghcr.io/zarraxx/develop_suit:llvm-18.1.8
ARG STAGE_MINGW64_ARCH

FROM ${STAGE_MINGW64_BASE_IMAGE}

ARG STAGE_MINGW64_ARCH

COPY stages/stage_mingw64/build/out/${STAGE_MINGW64_ARCH}/ /

ENV PATH=/opt/llvm-18.1.8/bin:/opt/x86_64-w64-windows-gnu/bin:/opt/cmake4/bin:/opt/cmake3/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /root

CMD ["/bin/bash"]

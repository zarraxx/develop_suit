# syntax=docker/dockerfile:1.7

ARG STAGE_TOOLS_BASE_IMAGE=ghcr.io/zarraxx/develop_suit:stage-llvm-2026-05-06
ARG STAGE_TOOLS_ARCH

FROM ${STAGE_TOOLS_BASE_IMAGE}

ARG STAGE_TOOLS_ARCH

COPY stages/stage_tools/build/out/${STAGE_TOOLS_ARCH}/ /

RUN ["/sbin/ldconfig"]

ENV PATH=/opt/cmake4/bin:/opt/cmake3/bin:/opt/llvm-18.1.8/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /root

CMD ["/bin/bash"]

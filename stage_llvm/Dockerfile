# syntax=docker/dockerfile:1.7

ARG STAGE_LLVM_ARCH

FROM scratch

ARG STAGE_LLVM_ARCH

COPY dist/stage_llvm/${STAGE_LLVM_ARCH}/ /

RUN ["/sbin/ldconfig"]

ENV PATH=/opt/llvm-18.1.8/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /root

CMD ["/bin/sh"]

# syntax=docker/dockerfile:1.7

ARG STAGE1_ARCH

FROM scratch

ARG STAGE1_ARCH

COPY dist/stage1/${STAGE1_ARCH}/ /

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /root

CMD ["/bin/sh"]

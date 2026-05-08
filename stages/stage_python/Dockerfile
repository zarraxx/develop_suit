# syntax=docker/dockerfile:1.7

ARG STAGE_PYTHON_ARCH

FROM scratch

ARG STAGE_PYTHON_ARCH

COPY dist/stage_python/${STAGE_PYTHON_ARCH}/ /

RUN ["/sbin/ldconfig"]

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /root

CMD ["/bin/sh"]

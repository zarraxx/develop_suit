# gdal package

`gdal` should build the geospatial SDK layer used by PostGIS and later GIS
packages. It should consume the image-codec prefix from `packages/image` and the
common base prefix from `packages/postgresql_dependencies`.

## Dependency Direction

Use both inputs for every target:

```text
postgresql_dependencies-18-<triple>.tar.xz
image-<triple>.tar.xz
```

`postgresql_dependencies` is the right common base for GDAL because it already
contains curl, sqlite, libxml2, libxslt, ICU, OpenSSL, zlib, zstd, and other
libraries GDAL commonly uses.

Important boundary: this package is intended to become the GDAL/geometry
dependency layer consumed by PostGIS. It should not add a `libpq` or
`pg_config` input just to enable GDAL's PostgreSQL driver. PostgreSQL client
linkage belongs to the PostgreSQL/PostGIS package step, where the PostgreSQL
package is already available.

## Boundary

This package should build:

- GEOS
- libyaml
- PROJ
- libgeotiff
- minizip from zlib, only as the FreeXL ZIP dependency
- FreeXL
- libspatialite
- GDAL

It should not rebuild image codecs from `packages/image`, nor rebuild common
libraries from `postgresql_dependencies`.

It may build minizip from the zlib source tree because FreeXL 2.0.0 requires
`minizip/unzip.h` and `libminizip`, while the base prefix only provides zlib
itself.

## Upstream Sources

GEOS:

```text
https://download.osgeo.org/geos/geos-3.14.1.tar.bz2
```

libyaml:

```text
https://pyyaml.org/download/libyaml/yaml-0.2.5.tar.gz
```

PROJ:

```text
https://github.com/OSGeo/PROJ/releases/download/9.8.1/proj-9.8.1.tar.gz
```

libgeotiff:

```text
https://github.com/OSGeo/libgeotiff/releases/download/1.7.4/libgeotiff-1.7.4.tar.gz
```

FreeXL:

```text
https://www.gaia-gis.it/gaia-sins/freexl-2.0.0.tar.gz
```

SpatiaLite:

```text
https://www.gaia-gis.it/gaia-sins/libspatialite-sources/libspatialite-5.1.0.tar.gz
```

GDAL:

```text
https://github.com/OSGeo/gdal/releases/download/v3.13.1/gdal-3.13.1.tar.gz
```

## Build Direction

Expected output:

```text
packages/gdal/build/out/gdal-<version>-<triple>
packages/gdal/build/dist/gdal-<version>-<triple>.tar.xz
```

Suggested build order:

1. Copy/extract `postgresql_dependencies` into the output prefix.
2. Overlay/copy the `image` prefix into the same output prefix.
3. Build GEOS shared libraries.
4. Build libyaml shared libraries.
5. Build PROJ against sqlite, curl, and tiff support from the prefix.
6. Build libgeotiff against PROJ and libtiff from the prefix.
7. Build minizip from zlib's `contrib/minizip` without rebuilding zlib.
8. Build FreeXL.
9. Build libspatialite against GEOS, PROJ, libxml2, sqlite, and FreeXL.
10. Build GDAL against the assembled prefix.
11. Disable GDAL PostgreSQL support in this package; PostGIS will combine GDAL
    with PostgreSQL separately.
12. Remove ordinary `.a` and `.la` files; preserve MinGW `*.dll.a` import
    libraries.
13. Rewrite Linux absolute in-prefix `DT_NEEDED` entries to library basenames.
14. Patch Linux ELF RUNPATH entries to be `$ORIGIN`-relative.

从  github release 下载基本的 postgresql18
添加

扩展
vector
https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.3.tar.gz

age
https://github.com/apache/age/releases/download/PG18%2Fv1.7.0-rc0/apache-age-1.7.0-src.tar.gz

pgroonga
https://packages.groonga.org/source/pgroonga/pgroonga-4.0.6.tar.gz

postgis
https://download.osgeo.org/postgis/source/postgis-3.6.4.tar.gz

pgrouting
https://github.com/pgRouting/pgrouting/releases/download/v4.0.1/pgrouting-4.0.1.tar.gz

pg_cron
https://github.com/citusdata/pg_cron/archive/refs/tags/v1.6.7.tar.gz

pg_partman
https://github.com/pgpartman/pg_partman/archive/refs/tags/v5.4.3.tar.gz

pg_net
https://github.com/supabase/pg_net/archive/refs/tags/v0.20.3.tar.gz

pgsql-http
https://github.com/pramsey/pgsql-http/archive/refs/tags/v1.7.1.tar.gz

pgmq
https://github.com/pgmq/pgmq/archive/refs/tags/v1.11.1.tar.gz

pgbouncer
https://www.pgbouncer.org/downloads/files/1.25.2/pgbouncer-1.25.2.tar.gz

plv8
https://github.com/plv8/plv8/archive/refs/tags/v3.2.4.tar.gz

timescaledb
https://github.com/timescale/timescaledb/archive/refs/tags/2.28.0.tar.gz

pgaudit
https://github.com/pgaudit/pgaudit/archive/refs/tags/18.0.tar.gz

pg_stat_monitor
https://github.com/percona/pg_stat_monitor/archive/refs/tags/2.3.2.tar.gz
MinGW64 skips pg_stat_monitor because upstream documents Linux distribution
support and the extension crashes under PostgreSQL EXEC_BACKEND on Windows.

<!-- tde
https://github.com/percona/pg_tde/archive/refs/tags/2.2.0.tar.gz -->

set_user
https://github.com/pgaudit/set_user/archive/refs/tags/REL4_2_0.tar.gz

<!-- pg_repack
https://github.com/reorg/pg_repack/archive/refs/tags/ver_1.5.3.tar.gz -->


fdw
https://github.com/pg-redis-fdw/redis_fdw/archive/refs/heads/REL_18_STABLE.zip
https://github.com/EnterpriseDB/mysql_fdw/archive/refs/tags/REL-2_9_3.tar.gz
https://github.com/tds-fdw/tds_fdw/archive/refs/tags/v2.0.5.tar.gz
https://github.com/pgspider/sqlite_fdw/archive/refs/tags/v2.5.0.tar.gz
https://github.com/EnterpriseDB/mongo_fdw/archive/refs/tags/REL-5_5_3.tar.gz

https://github.com/laurenz/oracle_fdw/archive/refs/tags/ORACLE_FDW_2_9_0.tar.gz
https://github.com/pg-fdw/db2_fdw/releases/download/18.1.2/db2_fdw-18.1.2.zip

Vendor FDW inputs

Oracle Instant Client and IBM DB2 CLI/ODBC are vendor binaries. They can be used
as local build inputs for oracle_fdw and db2_fdw, but they should not be bundled
as reusable dependency packages.

MinGW64:

```bash
./packages/postgresql18_dist/build.sh --target=mingw64 --runtime=docker --jobs=8 \
  --oracle-sdk-archive=cache/vendor/instantclient-sdk-windows.x64-23.26.2.0.0.zip \
  --oracle-basic-archive=cache/vendor/instantclient-basic-windows.x64-23.26.2.0.0.zip \
  --db2-cli-archive=cache/vendor/ntx64_odbc_cli.zip
```

x86_64 Linux:

```bash
./packages/postgresql18_dist/build.sh --target=x86_64 --jobs=8 \
  --oracle-sdk-archive=cache/vendor/instantclient-sdk-linux.x64-21.22.0.0.0dbru.zip \
  --oracle-basic-archive=cache/vendor/instantclient-basic-linux.x64-21.22.0.0.0dbru.zip \
  --db2-cli-archive=cache/vendor/linuxx64_odbc_cli.tar.gz
```

Service helpers

发行包根目录包含服务脚本：

```bash
./install_service.sh [data_dir] [service_name] [service_user]
./uninstall_service.sh [service_name]
```

默认 `data_dir=./var/lib/postgresql/18/main`，`service_name=postgresql18`，
Linux `service_user=postgres`。Linux 安装时如果用户不存在，会创建一个不能
登录的系统用户，并用该用户执行 `initdb`，所以默认数据库超级用户角色也是
`postgres`。

Windows 对应：

```cmd
install_service.cmd [data_dir] [service_name]
uninstall_service.cmd [service_name]
```


<!-- java

https://github.com/tada/pljava/archive/refs/tags/V1_6_10.tar.gz -->

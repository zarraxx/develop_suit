boost
https://archives.boost.io/release/1.84.0/source/boost_1_84_0.tar.bz2


./bootstrap.sh --prefix=${DEPENDENCY_LIBS_PATH}
./b2 install -j$(nproc) --prefix=${DEPENDENCY_LIBS_PATH} \
--with-system --with-thread --with-date_time --with-chrono --with-serialization --with-atomic
#!/usr/bin/env python3

import sqlite3


def main() -> None:
    connection = sqlite3.connect(":memory:")
    try:
        cursor = connection.cursor()
        cursor.execute("create table items (id integer primary key, name text)")
        cursor.executemany(
            "insert into items(name) values (?)",
            [("alpha",), ("beta",), ("gamma",)],
        )
        cursor.execute("select count(*), group_concat(name, ',') from items")
        row_count, names = cursor.fetchone()
        print(f"sqlite_version={sqlite3.sqlite_version}")
        print(f"row_count={row_count}")
        print(f"names={names}")
        if row_count != 3 or names != "alpha,beta,gamma":
            raise SystemExit("sqlite query result mismatch")
    finally:
        connection.close()


if __name__ == "__main__":
    main()

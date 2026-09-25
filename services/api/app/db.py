"""الوصول إلى قاعدة البيانات باسم المستخدم — آلية PostgREST نفسها.

كل طلب = معاملة واحدة على اتصال بدور `authenticator` (NOINHERIT: لا يملك بذاته شيئاً):
  role = authenticated  +  request.jwt.claims = الـpayload الذي تحقق منه security.py
ثم تقرر RLS ودوال `app.*` كل شيء. الإعدادان محليان للمعاملة (`set_config(..., true)`)، فلا يتسربان إلى
الطلب التالي على الاتصال نفسه من الـpool.
"""

import json
from contextlib import contextmanager
from typing import Any, Iterator

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


class Database:
    def __init__(self, conninfo: str):
        self._pool = ConnectionPool(conninfo, min_size=1, max_size=10, open=False, kwargs={"row_factory": dict_row})

    def open(self) -> None:
        self._pool.open(wait=True)

    def close(self) -> None:
        self._pool.close()

    @contextmanager
    def as_user(self, claims: dict[str, Any]) -> Iterator[psycopg.Connection]:
        with self._pool.connection() as conn, conn.transaction():
            conn.execute(
                "select set_config('role', 'authenticated', true),"
                "       set_config('request.jwt.claims', %s, true),"
                "       set_config('app.request_source', 'api', true)",
                [json.dumps(claims)],
            )
            yield conn

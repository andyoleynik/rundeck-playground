#!/bin/bash -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER web;
    CREATE DATABASE web;
    GRANT ALL PRIVILEGES ON DATABASE web TO web;
EOSQL

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "libpq-fe.h"

MODULE = PostgreSQL::Test::Pq		PACKAGE = PostgreSQL::Test::Pq

PROTOTYPES: ENABLE

TYPEMAP: <<EOTYPE

# would like to use T_PTROBJ here but it gets hung up on const-ness

PGresult *       T_PTR
const PGresult * T_PTR
PGconn *         T_PTR
const PGconn *   T_PTR
char *           T_PV
const char *     T_PV
ConnStatusType   T_ENUM
ExecStatusType   T_ENUM
Oid              T_UV

EOTYPE

PGresult *
PQchangePassword(PGconn *conn, const char *user, const char *passwd);

void
PQclear(PGresult *res);

PGconn *
PQconnectdb(const char *conninfo);

int
PQconsumeInput(PGconn *conn);

char *
PQerrorMessage(const PGconn *conn);

PGresult *
PQexec(PGconn *conn, const char *query);

void
PQfinish(PGconn *conn);

char *
PQfname(const PGresult *res, int field_num);

Oid
PQftype(const PGresult *res, int field_num);

int
PQgetisnull(const PGresult *res, int tup_num, int field_num);

PGresult *
PQgetResult(PGconn *conn);

char *
PQgetvalue(const PGresult *res, int tup_num, int field_num);

int
PQisBusy(PGconn *conn);

int
PQnfields(const PGresult *res);

int
PQntuples(const PGresult *res);

ExecStatusType
PQresultStatus(const PGresult *res);

int
PQsendQuery(PGconn *conn, const char *query);

ConnStatusType
PQstatus(const PGconn *conn);

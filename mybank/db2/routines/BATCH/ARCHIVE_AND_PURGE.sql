-- Nightly (every EOD): keeps the database bounded. Business-dated data older than
-- REF.BANK_CONTROL.RETENTION_BUSINESS_DAYS business days is archived or purged:
--   TXN.POSTED_TXN   -> moved to TXN.POSTED_TXN_ARCHIVE in chunks of 5000 (archive kept 2x retention)
--   GL.GL_ENTRY      -> folded, one business date per commit, into a single 'Brought forward' entry
--                       per GL code dated on the retention boundary, so every GL sum is unchanged
--   everything else  -> chunked deletes (see C_TARGETS). Wall-clock tables use the compressed-time
--                       equivalent: retention x MINUTES_PER_BUSINESS_DAY minutes. Statements: 3 months.
CREATE OR REPLACE PROCEDURE BATCH.ARCHIVE_AND_PURGE (OUT P_ROWS_PROCESSED INTEGER)
    LANGUAGE SQL
    SPECIFIC BATCH_ARCHIVE_AND_PURGE
    MODIFIES SQL DATA
BEGIN
    DECLARE SQLSTATE CHAR(5) DEFAULT '00000';
    DECLARE SQLCODE  INTEGER DEFAULT 0;
    DECLARE V_SQLSTATE CHAR(5);
    DECLARE V_SQLCODE  INTEGER;
    DECLARE V_MSG      VARCHAR(1000);
    DECLARE V_RUN_ID   BIGINT;
    DECLARE V_ROWS     INTEGER DEFAULT 0;
    DECLARE V_COUNT    INTEGER;
    DECLARE V_TODAY    DATE;
    DECLARE V_RETENTION SMALLINT;
    DECLARE V_MINUTES   SMALLINT;
    DECLARE V_KEEP_FROM DATE;
    DECLARE V_ARCHIVE_KEEP_FROM DATE;
    DECLARE V_STMT_KEEP_FROM DATE;
    DECLARE V_KEEP_TS   TIMESTAMP;
    DECLARE V_D         DATE;
    DECLARE V_N         INTEGER DEFAULT 0;
    DECLARE V_HOLIDAY   INTEGER;
    DECLARE V_CHUNK     INTEGER DEFAULT 5000;
    DECLARE V_MAX_TXN   BIGINT;
    DECLARE V_ARCHIVED  INTEGER DEFAULT 0;
    DECLARE V_ARCH_PURGED INTEGER DEFAULT 0;
    DECLARE V_GL_DATE   DATE;
    DECLARE V_GL_DATES  INTEGER DEFAULT 0;
    DECLARE V_GL_ROWS   INTEGER DEFAULT 0;
    DECLARE V_CORR      BIGINT;
    DECLARE V_TABLE_ROWS INTEGER;
    DECLARE V_SQL       VARCHAR(1000);
    DECLARE V_DETAIL    VARCHAR(800) DEFAULT '';

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS EXCEPTION 1 V_MSG = MESSAGE_TEXT;
        VALUES (SQLSTATE, SQLCODE) INTO V_SQLSTATE, V_SQLCODE;
        CALL UTIL.END_JOB_RUN(V_RUN_ID, 'F', V_ROWS, V_MSG);
        CALL UTIL.LOG_ERROR('BATCH.ARCHIVE_AND_PURGE', V_SQLSTATE, V_SQLCODE, V_MSG,
                            'KEEP_FROM=' || COALESCE(CHAR(V_KEEP_FROM, ISO), '-'));
        RESIGNAL;
    END;

    CALL UTIL.START_JOB_RUN('ARCHIVE_AND_PURGE', V_RUN_ID);

    SELECT BUSINESS_DATE, RETENTION_BUSINESS_DAYS, MINUTES_PER_BUSINESS_DAY
      INTO V_TODAY, V_RETENTION, V_MINUTES
      FROM REF.BANK_CONTROL
     WHERE CONTROL_ID = 1;

    -- Walk back RETENTION business days for the live horizon, and as many again for the archive
    SET V_D = V_TODAY;
    WHILE V_N < V_RETENTION * 2 DO
        SET V_D = V_D - 1 DAY;
        SELECT COUNT(*) INTO V_HOLIDAY FROM REF.HOLIDAY WHERE HOLIDAY_DATE = V_D;
        IF DAYOFWEEK_ISO(V_D) < 6 AND V_HOLIDAY = 0 THEN
            SET V_N = V_N + 1;
            IF V_N = V_RETENTION THEN
                SET V_KEEP_FROM = V_D;
            END IF;
        END IF;
    END WHILE;
    SET V_ARCHIVE_KEEP_FROM = V_D;
    SET V_STMT_KEEP_FROM = ADD_MONTHS(V_TODAY, -3);
    SET V_KEEP_TS = CURRENT TIMESTAMP - (V_RETENTION * V_MINUTES) MINUTES;

    ------------------------------------------------------------------
    -- 1. Posted transactions -> archive, 5000 at a time
    ------------------------------------------------------------------
    ARCHIVE_LOOP:
    LOOP
        SET V_MAX_TXN = NULL;
        SELECT MAX(X.TXN_ID)
          INTO V_MAX_TXN
          FROM (SELECT TXN_ID
                  FROM TXN.POSTED_TXN
                 WHERE BUSINESS_DATE < V_KEEP_FROM
                 ORDER BY TXN_ID
                 FETCH FIRST 5000 ROWS ONLY) X;
        IF V_MAX_TXN IS NULL THEN
            LEAVE ARCHIVE_LOOP;
        END IF;

        INSERT INTO TXN.POSTED_TXN_ARCHIVE
        SELECT *
          FROM TXN.POSTED_TXN
         WHERE BUSINESS_DATE < V_KEEP_FROM
           AND TXN_ID <= V_MAX_TXN;
        GET DIAGNOSTICS V_COUNT = ROW_COUNT;

        -- Deletes are allowed; only updates are blocked by TRG_POSTED_TXN_IMMUTABLE
        DELETE FROM TXN.POSTED_TXN
         WHERE BUSINESS_DATE < V_KEEP_FROM
           AND TXN_ID <= V_MAX_TXN;

        COMMIT;
        SET V_ARCHIVED = V_ARCHIVED + V_COUNT;
    END LOOP ARCHIVE_LOOP;

    ARCHIVE_PURGE_LOOP:
    LOOP
        DELETE FROM (SELECT 1
                       FROM TXN.POSTED_TXN_ARCHIVE
                      WHERE BUSINESS_DATE < V_ARCHIVE_KEEP_FROM
                      FETCH FIRST 5000 ROWS ONLY);
        GET DIAGNOSTICS V_COUNT = ROW_COUNT;
        COMMIT;
        SET V_ARCH_PURGED = V_ARCH_PURGED + V_COUNT;
        IF V_COUNT < V_CHUNK THEN
            LEAVE ARCHIVE_PURGE_LOOP;
        END IF;
    END LOOP ARCHIVE_PURGE_LOOP;

    ------------------------------------------------------------------
    -- 2. GL entries -> 'Brought forward' per GL code on the boundary date. One old business
    --    date per unit of work: fold its per-GL totals into the b/f row, delete it, commit.
    --    Last night's b/f row is itself older than the boundary tonight, so it rolls forward.
    ------------------------------------------------------------------
    SET V_CORR = NEXT VALUE FOR TXN.SEQ_CORRELATION;
    GL_LOOP:
    LOOP
        SET V_GL_DATE = NULL;
        SELECT MIN(BUSINESS_DATE)
          INTO V_GL_DATE
          FROM GL.GL_ENTRY
         WHERE BUSINESS_DATE < V_KEEP_FROM;
        IF V_GL_DATE IS NULL THEN
            LEAVE GL_LOOP;
        END IF;

        MERGE INTO GL.GL_ENTRY B
        USING (SELECT GL_CODE, SUM(AMOUNT) AS AMOUNT
                 FROM GL.GL_ENTRY
                WHERE BUSINESS_DATE = V_GL_DATE
                GROUP BY GL_CODE) S
           ON B.GL_CODE = S.GL_CODE
          AND B.BUSINESS_DATE = V_KEEP_FROM
          AND B.TXN_ID IS NULL
          AND B.DESCRIPTION = 'Brought forward'
         WHEN MATCHED THEN
              UPDATE SET B.AMOUNT = B.AMOUNT + S.AMOUNT
         WHEN NOT MATCHED AND S.AMOUNT <> 0 THEN
              INSERT (BUSINESS_DATE, GL_CODE, AMOUNT, CORRELATION_ID, TXN_ID, DESCRIPTION)
              VALUES (V_KEEP_FROM, S.GL_CODE, S.AMOUNT, V_CORR, NULL, 'Brought forward');

        DELETE FROM GL.GL_ENTRY
         WHERE BUSINESS_DATE = V_GL_DATE;
        GET DIAGNOSTICS V_COUNT = ROW_COUNT;

        COMMIT;
        SET V_GL_DATES = V_GL_DATES + 1;
        SET V_GL_ROWS = V_GL_ROWS + V_COUNT;
    END LOOP GL_LOOP;

    ------------------------------------------------------------------
    -- 3. Plain purges, chunked
    ------------------------------------------------------------------
    FOR T AS C_TARGETS CURSOR WITH HOLD FOR
        SELECT TARGET, PREDICATE, CHUNK
          FROM (VALUES (1,  'ACCT.DAILY_BALANCE',       'BUSINESS_DATE < :KEEP_DATE',                          5000),
                       (2,  'ACCT.INTEREST_ACCRUAL',    'BUSINESS_DATE < :KEEP_DATE',                          5000),
                       (3,  'CARD.AUTHORISATION',       'STATUS IN (''S'', ''X'', ''R'', ''D'') AND BUSINESS_DATE < :KEEP_DATE', 5000),
                       (4,  'TXN.PENDING_TXN',          'STATUS IN (''D'', ''F'') AND VALUE_DATE < :KEEP_DATE', 5000),
                       (5,  'PAY.PAYMENT',              'STATUS IN (''C'', ''R'') AND BUSINESS_DATE < :KEEP_DATE', 5000),
                       (6,  'PAY.DD_COLLECTION',        'PROCESSED_DATE < :KEEP_DATE',                         5000),
                       (7,  'ACCT.ACCOUNT_HOLD',        'STATUS <> ''A'' AND RELEASED_TS < :KEEP_TS',          5000),
                       (8,  'OPS.NOTIFICATION_OUTBOX',  'STATUS IN (''S'', ''F'') AND CREATED_TS < :KEEP_TS',  5000),
                       (9,  'OPS.BATCH_JOB_RUN',        'STATUS <> ''R'' AND BUSINESS_DATE < :KEEP_DATE',      5000),
                       (10, 'OPS.STATEMENT',            'PERIOD_END < :STMT_DATE',                             200)
               ) AS X (SEQ, TARGET, PREDICATE, CHUNK)
         ORDER BY SEQ
    DO
        SET V_SQL = 'DELETE FROM (SELECT 1 FROM ' || T.TARGET || ' WHERE '
                    || REPLACE(REPLACE(REPLACE(T.PREDICATE,
                           ':KEEP_DATE', '''' || CHAR(V_KEEP_FROM, ISO) || ''''),
                           ':KEEP_TS',   '''' || CHAR(V_KEEP_TS) || ''''),
                           ':STMT_DATE', '''' || CHAR(V_STMT_KEEP_FROM, ISO) || '''')
                    || ' FETCH FIRST ' || RTRIM(CHAR(T.CHUNK)) || ' ROWS ONLY)';
        SET V_TABLE_ROWS = 0;

        CHUNK_LOOP:
        LOOP
            EXECUTE IMMEDIATE V_SQL;
            GET DIAGNOSTICS V_COUNT = ROW_COUNT;
            COMMIT;
            SET V_TABLE_ROWS = V_TABLE_ROWS + V_COUNT;
            IF V_COUNT < T.CHUNK THEN
                LEAVE CHUNK_LOOP;
            END IF;
        END LOOP CHUNK_LOOP;

        SET V_ROWS = V_ROWS + V_TABLE_ROWS;
        IF V_TABLE_ROWS > 0 THEN
            SET V_DETAIL = V_DETAIL || ', ' || T.TARGET || ' ' || RTRIM(CHAR(V_TABLE_ROWS));
        END IF;
    END FOR;

    SET V_ROWS = V_ROWS + V_ARCHIVED + V_ARCH_PURGED + V_GL_ROWS;
    SET P_ROWS_PROCESSED = V_ROWS;
    CALL UTIL.END_JOB_RUN(V_RUN_ID, 'S', V_ROWS,
         'Kept from ' || CHAR(V_KEEP_FROM, ISO) || ': ' || RTRIM(CHAR(V_ARCHIVED)) || ' txns archived, '
         || RTRIM(CHAR(V_ARCH_PURGED)) || ' archive rows purged, ' || RTRIM(CHAR(V_GL_ROWS))
         || ' GL entries from ' || RTRIM(CHAR(V_GL_DATES)) || ' dates brought forward' || V_DETAIL);
END@

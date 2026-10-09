-- MyBank plc: reference data
-- Statement terminator: @

INSERT INTO REF.BANK_CONTROL (CONTROL_ID, BUSINESS_DATE, PREV_BUSINESS_DATE, DAY_STATUS)
VALUES (1, '2026-10-01', '2026-09-30', 'O')@

-- UK (England & Wales) bank holidays
INSERT INTO REF.HOLIDAY (HOLIDAY_DATE, DESCRIPTION) VALUES
    ('2026-01-01', 'New Year''s Day'),
    ('2026-04-03', 'Good Friday'),
    ('2026-04-06', 'Easter Monday'),
    ('2026-05-04', 'Early May bank holiday'),
    ('2026-05-25', 'Spring bank holiday'),
    ('2026-08-31', 'Summer bank holiday'),
    ('2026-12-25', 'Christmas Day'),
    ('2026-12-28', 'Boxing Day (substitute day)'),
    ('2027-01-01', 'New Year''s Day'),
    ('2027-03-26', 'Good Friday'),
    ('2027-03-29', 'Easter Monday'),
    ('2027-05-03', 'Early May bank holiday'),
    ('2027-05-31', 'Spring bank holiday'),
    ('2027-08-30', 'Summer bank holiday'),
    ('2027-12-27', 'Christmas Day (substitute day)'),
    ('2027-12-28', 'Boxing Day (substitute day)'),
    ('2028-01-03', 'New Year''s Day (substitute day)'),
    ('2028-04-14', 'Good Friday'),
    ('2028-04-17', 'Easter Monday'),
    ('2028-05-01', 'Early May bank holiday'),
    ('2028-05-29', 'Spring bank holiday'),
    ('2028-08-28', 'Summer bank holiday'),
    ('2028-12-25', 'Christmas Day'),
    ('2028-12-26', 'Boxing Day'),
    ('2029-01-01', 'New Year''s Day'),
    ('2029-03-30', 'Good Friday'),
    ('2029-04-02', 'Easter Monday'),
    ('2029-05-07', 'Early May bank holiday'),
    ('2029-05-28', 'Spring bank holiday'),
    ('2029-08-27', 'Summer bank holiday'),
    ('2029-12-25', 'Christmas Day'),
    ('2029-12-26', 'Boxing Day')@

INSERT INTO REF.BRANCH (BRANCH_ID, SORT_CODE, NAME, TOWN, REGION, OPENED_DATE, CLOSED_DATE) VALUES
    (1,  '080101', 'Head Office',          'London',      'London',     '1998-04-01', NULL),
    (2,  '080102', 'Cheapside',            'London',      'London',     '1998-04-01', NULL),
    (3,  '080201', 'Manchester King St',   'Manchester',  'North West', '1999-06-14', NULL),
    (4,  '080202', 'Liverpool Castle St',  'Liverpool',   'North West', '2001-02-05', NULL),
    (5,  '080301', 'Leeds Park Row',       'Leeds',       'Yorkshire',  '1999-09-20', NULL),
    (6,  '080302', 'Sheffield Fargate',    'Sheffield',   'Yorkshire',  '2003-03-10', '2019-11-29'),
    (7,  '080401', 'Birmingham Colmore',   'Birmingham',  'Midlands',   '1998-10-12', NULL),
    (8,  '080402', 'Nottingham Market Sq', 'Nottingham',  'Midlands',   '2004-05-17', NULL),
    (9,  '080501', 'Bristol Corn St',      'Bristol',     'South West', '2000-01-24', NULL),
    (10, '080601', 'Cardiff Queen St',     'Cardiff',     'Wales',      '2002-08-05', NULL),
    (11, '080701', 'Newcastle Grey St',    'Newcastle',   'North East', '2005-11-07', NULL),
    (12, '089999', 'Digital',              'London',      'Digital',    '2015-01-05', NULL)@

-- Chart of accounts. Debits positive, credits negative.
INSERT INTO REF.GL_ACCOUNT (GL_CODE, NAME, GL_TYPE, PARENT_GL_CODE, POSTABLE) VALUES
    ('1000', 'Assets',                            'A', NULL,   'N'),
    ('2000', 'Liabilities',                       'L', NULL,   'N'),
    ('3000', 'Equity',                            'Q', NULL,   'N'),
    ('4000', 'Income',                            'I', NULL,   'N'),
    ('5000', 'Expenses',                          'E', NULL,   'N')@

INSERT INTO REF.GL_ACCOUNT (GL_CODE, NAME, GL_TYPE, PARENT_GL_CODE, POSTABLE) VALUES
    ('1100', 'Cash - branches and ATMs',          'A', '1000', 'Y'),
    ('1200', 'Interest receivable',               'A', '1000', 'N'),
    ('1300', 'Customer lending',                  'A', '1000', 'N'),
    ('1500', 'Scheme settlement',                 'A', '1000', 'N'),
    ('1900', 'Internal transfer suspense',        'A', '1000', 'Y'),
    ('2100', 'Customer deposits',                 'L', '2000', 'N'),
    ('2200', 'Interest payable',                  'L', '2000', 'N'),
    ('3100', 'Retained earnings',                 'Q', '3000', 'Y'),
    ('4100', 'Fee and commission income',         'I', '4000', 'Y'),
    ('4200', 'Interest income',                   'I', '4000', 'N'),
    ('5100', 'Interest expense',                  'E', '5000', 'Y'),
    ('5200', 'Fraud and operational losses',      'E', '5000', 'Y')@

INSERT INTO REF.GL_ACCOUNT (GL_CODE, NAME, GL_TYPE, PARENT_GL_CODE, POSTABLE) VALUES
    ('1210', 'Accrued overdraft interest receivable', 'A', '1200', 'Y'),
    ('1220', 'Accrued loan interest receivable',      'A', '1200', 'Y'),
    ('1310', 'Personal loans',                        'A', '1300', 'Y'),
    ('1510', 'Faster Payments settlement',            'A', '1500', 'Y'),
    ('1520', 'Card scheme settlement',                'A', '1500', 'Y'),
    ('1530', 'BACS settlement',                       'A', '1500', 'Y'),
    ('1540', 'CHAPS settlement',                      'A', '1500', 'Y'),
    ('2110', 'Current account deposits',              'L', '2100', 'Y'),
    ('2120', 'Savings deposits',                      'L', '2100', 'Y'),
    ('2210', 'Accrued credit interest payable',       'L', '2200', 'Y'),
    ('4210', 'Overdraft interest income',             'I', '4200', 'Y'),
    ('4220', 'Loan interest income',                  'I', '4200', 'Y')@

INSERT INTO REF.PRODUCT (PRODUCT_CODE, NAME, PRODUCT_TYPE, CONTROL_GL_CODE, MONTHLY_FEE,
                         OVERDRAFT_ALLOWED, DEFAULT_OD_LIMIT, OD_RATE, MIN_AGE, ACTIVE,
                         LAUNCHED_DATE, WITHDRAWN_DATE) VALUES
    ('CUR001', 'MyBank Current Account',   'CUR', '2110',  0.00, 'Y',  250.00, 39.9000, 18, 'Y', '2008-01-01', NULL),
    ('CUR002', 'MyBank Premier Current',   'CUR', '2110', 12.50, 'Y', 1500.00, 19.9000, 18, 'Y', '2012-03-01', NULL),
    ('CUR003', 'MyBank Student Account',   'CUR', '2110',  0.00, 'Y', 1000.00,  0.0000, 17, 'Y', '2010-08-01', NULL),
    ('CUR004', 'MyBank Basic Account',     'CUR', '2110',  0.00, 'N',    0.00,  0.0000, 16, 'Y', '2016-01-01', NULL),
    ('SAV001', 'Easy Saver',               'SAV', '2120',  0.00, 'N',    0.00,  0.0000, 16, 'Y', '2009-01-01', NULL),
    ('SAV002', 'Bonus Saver',              'SAV', '2120',  0.00, 'N',    0.00,  0.0000, 18, 'Y', '2019-05-01', NULL),
    ('SAV003', 'Instant Access Classic',   'SAV', '2120',  0.00, 'N',    0.00,  0.0000, 16, 'N', '2001-01-01', '2014-12-31'),
    ('LON001', 'Personal Loan',            'LON', '1310',  0.00, 'N',    0.00,  0.0000, 18, 'Y', '2008-01-01', NULL)@

INSERT INTO REF.INTEREST_RATE_TIER (PRODUCT_CODE, EFFECTIVE_FROM, TIER_FROM, TIER_TO, ANNUAL_RATE) VALUES
    ('CUR001', '2008-01-01',     0.00,      NULL, 0.0000),
    ('CUR002', '2012-03-01',     0.00,   5000.00, 1.0000),
    ('CUR002', '2012-03-01',  5000.00,      NULL, 0.0000),
    ('CUR003', '2010-08-01',     0.00,      NULL, 0.0000),
    ('CUR004', '2016-01-01',     0.00,      NULL, 0.0000),
    ('SAV001', '2025-01-01',     0.00,  10000.00, 3.0000),
    ('SAV001', '2025-01-01', 10000.00,      NULL, 3.2500),
    ('SAV001', '2026-08-01',     0.00,  10000.00, 2.5000),
    ('SAV001', '2026-08-01', 10000.00,      NULL, 2.7500),
    ('SAV002', '2019-05-01',     0.00,      NULL, 3.7500),
    ('SAV003', '2001-01-01',     0.00,      NULL, 0.5000)@

INSERT INTO REF.FEE_SCHEDULE (FEE_CODE, DESCRIPTION, PRODUCT_CODE, FLAT_AMOUNT, PCT_RATE,
                              MIN_AMOUNT, MAX_AMOUNT, GL_CODE) VALUES
    ('MFEEPREM', 'Premier monthly account fee',       'CUR002', 12.50, 0.0000,  0.00,  NULL, '4100'),
    ('UNPAIDDD', 'Unpaid direct debit',               NULL,     10.00, 0.0000,  0.00,  NULL, '4100'),
    ('UNPAIDSO', 'Unpaid standing order',             NULL,     10.00, 0.0000,  0.00,  NULL, '4100'),
    ('FXCARD',   'Non-sterling card transaction',     NULL,      0.00, 2.7500,  0.00,  NULL, '4100'),
    ('CASHABRD', 'Cash withdrawal abroad',            NULL,      0.00, 1.5000,  2.00,  5.00, '4100'),
    ('CHAPSOUT', 'Outbound CHAPS payment',            NULL,     25.00, 0.0000,  0.00,  NULL, '4100'),
    ('REPLCARD', 'Replacement card',                  NULL,      5.00, 0.0000,  0.00,  NULL, '4100'),
    ('ODOVERLM', 'Over-limit handling',               NULL,      6.00, 0.0000,  0.00,  NULL, '4100')@

INSERT INTO REF.MERCHANT_CATEGORY (MCC, DESCRIPTION, RISK_WEIGHT) VALUES
    ('5411', 'Grocery stores, supermarkets',       1),
    ('5812', 'Restaurants',                        1),
    ('5814', 'Fast food',                          1),
    ('5541', 'Service stations',                   1),
    ('4111', 'Local commuter transport',           1),
    ('4121', 'Taxis and rideshare',                1),
    ('5732', 'Electronics stores',                 2),
    ('5311', 'Department stores',                  1),
    ('5912', 'Pharmacies',                         1),
    ('5691', 'Clothing stores',                    1),
    ('7832', 'Cinemas',                            1),
    ('5999', 'Miscellaneous retail',               2),
    ('4829', 'Money transfer',                     4),
    ('6051', 'Quasi-cash, crypto',                 5),
    ('7995', 'Betting and gambling',               5)@

-- Fraud rules. RULE_SQL is a SELECT returning (ACCOUNT_ID, CARD_ID, SCORE, DETAIL)
-- with the token :BDATE standing for the business date. BATCH.RUN_FRAUD_RULES substitutes
-- a date literal and runs each one as dynamic SQL. This is Db2 SQL living in data rows.
INSERT INTO RISK.FRAUD_RULE (RULE_ID, NAME, DESCRIPTION, SEVERITY, RULE_SQL) VALUES
(1, 'CARD_VELOCITY', 'More than 15 card authorisations on one card within a business day', 3,
 'SELECT A.ACCOUNT_ID, A.CARD_ID, SMALLINT(MIN(100, COUNT(*) * 4)),
         ''Auths: '' || RTRIM(CHAR(COUNT(*))) || '' in '' ||
         RTRIM(CHAR(TIMESTAMPDIFF(4, CHAR(MAX(A.AUTH_TS) - MIN(A.AUTH_TS))))) || '' minutes''
    FROM CARD.AUTHORISATION A
   WHERE A.BUSINESS_DATE = :BDATE
   GROUP BY A.ACCOUNT_ID, A.CARD_ID
  HAVING COUNT(*) > 15
    WITH UR'),
(2, 'GAMBLING_SPEND', 'Gambling and quasi-cash spend over 500 in a business day', 2,
 'SELECT A.ACCOUNT_ID, MAX(A.CARD_ID), SMALLINT(60),
         ''High-risk MCC spend '' || VARCHAR(DECIMAL(SUM(A.AMOUNT), 15, 2))
    FROM CARD.AUTHORISATION A
    JOIN CARD.MERCHANT M ON M.MERCHANT_ID = A.MERCHANT_ID
    JOIN REF.MERCHANT_CATEGORY C ON C.MCC = M.MCC
   WHERE A.BUSINESS_DATE = :BDATE
     AND A.RESPONSE_CODE = ''00''
     AND C.RISK_WEIGHT >= 5
   GROUP BY A.ACCOUNT_ID
  HAVING SUM(A.AMOUNT) > 500
    WITH UR'),
(3, 'DECLINE_BURST', 'Five or more declined authorisations on a card in a business day', 2,
 'SELECT A.ACCOUNT_ID, A.CARD_ID, SMALLINT(50),
         ''Declines: '' || DIGITS(SMALLINT(COUNT(*))) || '' last code '' || VALUE(MAX(A.RESPONSE_CODE), ''??'')
    FROM CARD.AUTHORISATION A
   WHERE A.BUSINESS_DATE = :BDATE
     AND A.RESPONSE_CODE <> ''00''
   GROUP BY A.ACCOUNT_ID, A.CARD_ID
  HAVING COUNT(*) >= 5
    WITH UR'),
(4, 'NEW_PAYEE_LARGE', 'Faster Payment over 2,000 to a payee created in the last 3 days', 3,
 'SELECT P.ACCOUNT_ID, CAST(NULL AS BIGINT), SMALLINT(70),
         ''New payee '' || P.COUNTERPARTY_SORT || ''/'' || P.COUNTERPARTY_ACCT || '' amount '' ||
         VARCHAR(P.AMOUNT)
    FROM PAY.PAYMENT P
    JOIN ACCT.ACCOUNT A ON A.ACCOUNT_ID = P.ACCOUNT_ID
    JOIN PAY.PAYEE Y ON Y.CUSTOMER_ID = A.PRIMARY_CUSTOMER_ID
                    AND Y.SORT_CODE = P.COUNTERPARTY_SORT
                    AND Y.ACCOUNT_NO = P.COUNTERPARTY_ACCT
   WHERE P.BUSINESS_DATE = :BDATE
     AND P.DIRECTION = ''O''
     AND P.AMOUNT > 2000
     AND DAYS(P.BUSINESS_DATE) - DAYS(Y.CREATED_DATE) <= 3
    WITH UR'),
(5, 'DORMANT_REAWAKENED', 'Debit on an account with no activity for 180+ days before today', 2,
 'SELECT T.ACCOUNT_ID, CAST(NULL AS BIGINT), SMALLINT(40),
         ''Dormant '' || RTRIM(CHAR(DAYS(T.BUSINESS_DATE) - DAYS(D.PREV_ACTIVITY))) || '' days''
    FROM TXN.POSTED_TXN T
    JOIN (SELECT ACCOUNT_ID, MAX(BUSINESS_DATE) AS PREV_ACTIVITY
            FROM TXN.POSTED_TXN
           WHERE BUSINESS_DATE < :BDATE
           GROUP BY ACCOUNT_ID) D ON D.ACCOUNT_ID = T.ACCOUNT_ID
   WHERE T.BUSINESS_DATE = :BDATE
     AND T.AMOUNT < 0
     AND DAYS(T.BUSINESS_DATE) - DAYS(D.PREV_ACTIVITY) >= 180
    WITH UR'),
(6, 'ROUND_CASH', 'Three or more round-hundred cash withdrawals in a business day', 1,
 'SELECT T.ACCOUNT_ID, CAST(NULL AS BIGINT), SMALLINT(30),
         RTRIM(CHAR(COUNT(*))) || '' round cash withdrawals totalling '' ||
         VARCHAR_FORMAT(ABS(SUM(T.AMOUNT)), ''999,990.00'')
    FROM TXN.POSTED_TXN T
   WHERE T.BUSINESS_DATE = :BDATE
     AND T.TXN_TYPE = ''CASH''
     AND T.AMOUNT < 0
     AND MOD(INT(ABS(T.AMOUNT)), 100) = 0
   GROUP BY T.ACCOUNT_ID
  HAVING COUNT(*) >= 3
    WITH UR')@

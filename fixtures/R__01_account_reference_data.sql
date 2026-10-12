INSERT INTO crm.account_category (code, active, sort_order)
VALUES ('EMPLOYEE', TRUE, 10),
       ('SUPPLIER', TRUE, 20),
       ('CLIENT', TRUE, 30),
       ('COURIER', TRUE, 40)
ON CONFLICT (code) DO UPDATE
    SET active = EXCLUDED.active,
        sort_order = EXCLUDED.sort_order,
        updated_at = NOW();

INSERT INTO crm.access_role (scope_type, code, active, sort_order)
VALUES ('GLOBAL', 'OWNER', TRUE, 10),
       ('GLOBAL', 'CRM_ADMIN', TRUE, 20),
       ('GLOBAL', 'OPERATIONS_MANAGER', TRUE, 30),
       ('GLOBAL', 'CUSTOMER_MANAGER', TRUE, 40),
       ('GLOBAL', 'WEBSITE_MANAGER', TRUE, 45),
       ('GLOBAL', 'BUYER', TRUE, 50),
       ('GLOBAL', 'LOGISTICS_SPECIALIST', TRUE, 60),
       ('GLOBAL', 'WAREHOUSE_OPERATOR', TRUE, 70),
       ('GLOBAL', 'CASHIER', TRUE, 80),
       ('GLOBAL', 'COURIER', TRUE, 90),
       ('GLOBAL', 'ACCOUNTANT', TRUE, 100),
       ('GLOBAL', 'FINANCIAL_CONTROLLER', TRUE, 110),
       ('GLOBAL', 'SUPPLIER', TRUE, 120),
       ('GLOBAL', 'CUSTOMER', TRUE, 130),
       ('PROJECT', 'OPERATIONS_MANAGER', TRUE, 30),
       ('PROJECT', 'CUSTOMER_MANAGER', TRUE, 40),
       ('PROJECT', 'WEBSITE_MANAGER', TRUE, 45),
       ('PROJECT', 'BUYER', TRUE, 50),
       ('PROJECT', 'LOGISTICS_SPECIALIST', TRUE, 60),
       ('PROJECT', 'WAREHOUSE_OPERATOR', TRUE, 70),
       ('PROJECT', 'CASHIER', TRUE, 80),
       ('PROJECT', 'ACCOUNTANT', TRUE, 100),
       ('PROJECT', 'FINANCIAL_CONTROLLER', TRUE, 110),
       ('PROJECT', 'SUPPLIER', TRUE, 120),
       ('PROJECT', 'CUSTOMER', TRUE, 130)
ON CONFLICT (scope_type, code) DO UPDATE
    SET active = EXCLUDED.active,
        sort_order = EXCLUDED.sort_order,
        updated_at = NOW();

DELETE FROM crm.access_role
WHERE NOT (
    (scope_type = 'GLOBAL' AND code IN (
        'OWNER',
        'CRM_ADMIN',
        'OPERATIONS_MANAGER',
        'CUSTOMER_MANAGER',
        'WEBSITE_MANAGER',
        'BUYER',
        'LOGISTICS_SPECIALIST',
        'WAREHOUSE_OPERATOR',
        'CASHIER',
        'COURIER',
        'ACCOUNTANT',
        'FINANCIAL_CONTROLLER',
        'SUPPLIER',
        'CUSTOMER'
    ))
    OR
    (scope_type = 'PROJECT' AND code IN (
        'OPERATIONS_MANAGER',
        'CUSTOMER_MANAGER',
        'WEBSITE_MANAGER',
        'BUYER',
        'LOGISTICS_SPECIALIST',
        'WAREHOUSE_OPERATOR',
        'CASHIER',
        'ACCOUNTANT',
        'FINANCIAL_CONTROLLER',
        'SUPPLIER',
        'CUSTOMER'
    ))
);

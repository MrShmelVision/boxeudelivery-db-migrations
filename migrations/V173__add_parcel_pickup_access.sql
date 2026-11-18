ALTER TABLE crm.inbound_delivery
    ADD COLUMN pickup_access_code varchar(150),
    ADD COLUMN pickup_access_qr_content varchar(2048),
    ADD COLUMN pickup_access_instructions varchar(1000),
    ADD COLUMN pickup_access_updated_at timestamptz,
    ADD COLUMN pickup_access_replacement_required boolean NOT NULL DEFAULT false;

ALTER TABLE crm.inbound_delivery
    ADD CONSTRAINT ck_inbound_delivery_pickup_access_route CHECK (
        transport_mode = 'COURIER_VIA_PICKUP_POINT'
        OR (pickup_access_code IS NULL AND pickup_access_qr_content IS NULL
            AND pickup_access_instructions IS NULL AND NOT pickup_access_replacement_required)
    ),
    ADD CONSTRAINT ck_inbound_delivery_pickup_qr_bytes CHECK (
        pickup_access_qr_content IS NULL OR octet_length(pickup_access_qr_content) BETWEEN 1 AND 2048
    );

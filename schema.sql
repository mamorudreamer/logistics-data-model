-- Модель данных B2B-логистического кабинета
-- Диалект: PostgreSQL

CREATE TABLE client (
    id          bigserial PRIMARY KEY,
    name        text        NOT NULL,
    inn         text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app_user (
    id         bigserial PRIMARY KEY,
    client_id  bigint REFERENCES client (id),
    full_name  text NOT NULL,
    email      text NOT NULL UNIQUE,
    role       text NOT NULL
        CHECK (role IN ('CLIENT', 'MANAGER', 'LOGIST', 'WAREHOUSE', 'ADMIN')),
    is_active  boolean NOT NULL DEFAULT true
);

-- Сотрудники клиента привязаны к организации, сотрудники компании - нет
ALTER TABLE app_user ADD CONSTRAINT app_user_client_scope
    CHECK ((role = 'CLIENT') = (client_id IS NOT NULL));

CREATE TABLE warehouse (
    id      bigserial PRIMARY KEY,
    code    text NOT NULL UNIQUE,
    city    text NOT NULL,
    address text
);

CREATE TABLE request (
    id             bigserial PRIMARY KEY,
    client_id      bigint      NOT NULL REFERENCES client (id),
    created_by     bigint      NOT NULL REFERENCES app_user (id),
    current_status text        NOT NULL DEFAULT 'NEW'
        CHECK (current_status IN ('NEW', 'IN_REVIEW', 'APPROVED', 'IN_PROGRESS',
                                  'IN_TRANSIT', 'DELIVERED', 'CLOSED',
                                  'CANCELLED', 'DISCREPANCY')),
    origin_city    text        NOT NULL,
    dest_city      text        NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    closed_at      timestamptz
);

-- current_status - намеренная денормализация: кэш последнего перехода
-- из status_history. Источник истины - история, поле нужно для списков
-- и фильтров без подзапроса на каждую строку.

CREATE INDEX request_status_idx  ON request (current_status);
CREATE INDEX request_client_idx  ON request (client_id, created_at DESC);

CREATE TABLE cargo_item (
    id         bigserial PRIMARY KEY,
    request_id bigint  NOT NULL REFERENCES request (id) ON DELETE CASCADE,
    name       text    NOT NULL,
    quantity   numeric(12, 3) NOT NULL CHECK (quantity > 0),
    weight_kg  numeric(12, 3) NOT NULL CHECK (weight_kg > 0),
    volume_m3  numeric(12, 3) CHECK (volume_m3 > 0)
);

CREATE INDEX cargo_item_request_idx ON cargo_item (request_id);

CREATE TABLE status_history (
    id          bigserial PRIMARY KEY,
    request_id  bigint      NOT NULL REFERENCES request (id) ON DELETE CASCADE,
    from_status text,
    to_status   text        NOT NULL,
    changed_by  bigint      NOT NULL REFERENCES app_user (id),
    changed_at  timestamptz NOT NULL DEFAULT now(),
    comment     text
);

CREATE INDEX status_history_request_idx ON status_history (request_id, changed_at);

-- Согласование многостороннее: строка на каждого согласующего.
-- Заявка переходит в APPROVED только когда нет ни одной строки
-- с decision IS NULL и ни одной с decision = 'REJECTED'.
CREATE TABLE approval (
    id           bigserial PRIMARY KEY,
    request_id   bigint      NOT NULL REFERENCES request (id) ON DELETE CASCADE,
    approver_id  bigint      NOT NULL REFERENCES app_user (id),
    decision     text        CHECK (decision IN ('APPROVED', 'REJECTED')),
    requested_at timestamptz NOT NULL DEFAULT now(),
    decided_at   timestamptz,
    comment      text,
    UNIQUE (request_id, approver_id)
);

ALTER TABLE approval ADD CONSTRAINT approval_decision_time
    CHECK ((decision IS NULL) = (decided_at IS NULL));

CREATE INDEX approval_pending_idx ON approval (approver_id) WHERE decision IS NULL;

CREATE TABLE shipment (
    id           bigserial PRIMARY KEY,
    request_id   bigint NOT NULL UNIQUE REFERENCES request (id) ON DELETE CASCADE,
    warehouse_id bigint NOT NULL REFERENCES warehouse (id),
    logist_id    bigint REFERENCES app_user (id),
    planned_at   timestamptz,
    shipped_at   timestamptz,
    delivered_at timestamptz
);

-- Расхождение фиксирует склад; решение о возврате заявки принимает менеджер.
-- Поэтому reported_by и роль инициатора возврата - разные вещи.
CREATE TABLE discrepancy (
    id            bigserial PRIMARY KEY,
    shipment_id   bigint      NOT NULL REFERENCES shipment (id) ON DELETE CASCADE,
    cargo_item_id bigint      REFERENCES cargo_item (id),
    kind          text        NOT NULL
        CHECK (kind IN ('QUANTITY', 'WEIGHT', 'VOLUME', 'MISSING', 'OTHER')),
    expected      numeric(12, 3),
    actual        numeric(12, 3),
    reported_by   bigint      NOT NULL REFERENCES app_user (id),
    reported_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX discrepancy_shipment_idx ON discrepancy (shipment_id);

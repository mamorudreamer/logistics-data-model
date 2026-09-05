-- Аналитические запросы к модели B2B-логистических заявок
-- Диалект: PostgreSQL

-- =====================================================================
-- 1. Где заявки простаивают дольше всего
--
-- Вопрос бизнеса: на каком шаге процесса теряется время.
-- Приём: LEAD() по истории переходов даёт момент выхода из статуса.
-- Медиана важнее среднего - несколько зависших заявок вытягивают AVG.
-- =====================================================================

WITH periods AS (
    SELECT
        h.request_id,
        h.to_status AS status,
        h.changed_at AS entered_at,
        LEAD(h.changed_at) OVER (
            PARTITION BY h.request_id ORDER BY h.changed_at
        ) AS left_at
    FROM status_history h
)
SELECT
    status,
    COUNT(*) AS transitions,
    ROUND(AVG(EXTRACT(EPOCH FROM (left_at - entered_at)) / 3600)::numeric, 1)
        AS avg_hours,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (left_at - entered_at)) / 3600
    )::numeric, 1) AS median_hours,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (left_at - entered_at)) / 3600
    )::numeric, 1) AS p90_hours
FROM periods
WHERE left_at IS NOT NULL
GROUP BY status
ORDER BY median_hours DESC;

-- Ограничение: заявки, которые прямо сейчас находятся в статусе, дают
-- left_at IS NULL и в расчёт не попадают. Это смещает оценку вниз -
-- именно зависшие заявки ещё не вышли из статуса. Для оперативного
-- мониторинга нужен отдельный запрос по открытым заявкам:
-- COALESCE(left_at, now()) вместо фильтра по NULL.


-- =====================================================================
-- 2. Доля заявок, вернувшихся на доработку, по месяцам
--
-- Вопрос бизнеса: улучшается ли качество заполнения заявок.
-- Возврат = переход IN_REVIEW -> NEW. Заявка могла вернуться несколько
-- раз, поэтому считаем уникальные заявки, а не переходы.
-- =====================================================================

WITH reworked AS (
    SELECT DISTINCT request_id
    FROM status_history
    WHERE from_status = 'IN_REVIEW'
      AND to_status   = 'NEW'
)
SELECT
    DATE_TRUNC('month', r.created_at)::date AS month,
    COUNT(*)                                AS requests,
    COUNT(w.request_id)                     AS with_rework,
    ROUND(100.0 * COUNT(w.request_id) / NULLIF(COUNT(*), 0), 1) AS rework_pct
FROM request r
LEFT JOIN reworked w ON w.request_id = r.id
GROUP BY 1
ORDER BY 1;


-- =====================================================================
-- 3. Кто тормозит согласование
--
-- Вопрос бизнеса: согласование многостороннее, и общий срок определяет
-- самый медленный участник. Нужно найти именно его, а не среднее по всем.
-- Приём: FILTER вместо CASE-агрегатов - читается чище.
-- =====================================================================

SELECT
    u.full_name,
    COUNT(*)                                        AS assigned,
    COUNT(*) FILTER (WHERE a.decision IS NULL)      AS pending,
    COUNT(*) FILTER (WHERE a.decision = 'REJECTED') AS rejected,
    ROUND(AVG(EXTRACT(EPOCH FROM (a.decided_at - a.requested_at)) / 3600)
          FILTER (WHERE a.decided_at IS NOT NULL)::numeric, 1) AS avg_hours_to_decide,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.decision = 'REJECTED')
          / NULLIF(COUNT(*) FILTER (WHERE a.decision IS NOT NULL), 0), 1)
        AS reject_pct
FROM approval a
JOIN app_user u ON u.id = a.approver_id
WHERE a.requested_at >= now() - interval '90 days'
GROUP BY u.full_name
HAVING COUNT(*) >= 5
ORDER BY pending DESC, avg_hours_to_decide DESC NULLS LAST;


-- =====================================================================
-- 4. Расхождения груза по классам
--
-- Вопрос бизнеса: гипотеза, что тяжёлый и объёмный груз чаще расходится
-- с заявкой. Если подтверждается - для этих классов нужна дополнительная
-- проверка при создании заявки, а не разбор на складе.
-- =====================================================================

WITH request_cargo AS (
    SELECT
        c.request_id,
        SUM(c.weight_kg) AS total_weight,
        SUM(c.volume_m3) AS total_volume
    FROM cargo_item c
    GROUP BY c.request_id
),
classified AS (
    SELECT
        s.id AS shipment_id,
        CASE
            WHEN rc.total_weight >= 1000 THEN 'тяжёлый'
            WHEN rc.total_volume >= 10   THEN 'объёмный'
            ELSE                              'стандартный'
        END AS cargo_class
    FROM shipment s
    JOIN request_cargo rc ON rc.request_id = s.request_id
    WHERE s.shipped_at IS NOT NULL
)
SELECT
    cl.cargo_class,
    COUNT(*)                                  AS shipments,
    COUNT(DISTINCT d.shipment_id)             AS with_discrepancy,
    ROUND(100.0 * COUNT(DISTINCT d.shipment_id) / NULLIF(COUNT(*), 0), 1)
        AS discrepancy_pct
FROM classified cl
LEFT JOIN discrepancy d ON d.shipment_id = cl.shipment_id
GROUP BY cl.cargo_class
ORDER BY discrepancy_pct DESC;


-- =====================================================================
-- 5. Воронка заявок по когортам создания
--
-- Вопрос бизнеса: какая доля созданных заявок доходит до закрытия
-- и где основной отвал. Считаем по факту достижения статуса в истории,
-- а не по current_status - иначе отменённые заявки исчезнут из воронки.
-- =====================================================================

WITH reached AS (
    SELECT
        r.id,
        DATE_TRUNC('month', r.created_at)::date AS cohort,
        BOOL_OR(h.to_status = 'APPROVED')    AS got_approved,
        BOOL_OR(h.to_status = 'IN_TRANSIT')  AS got_shipped,
        BOOL_OR(h.to_status = 'DELIVERED')   AS got_delivered,
        BOOL_OR(h.to_status = 'CLOSED')      AS got_closed,
        BOOL_OR(h.to_status = 'CANCELLED')   AS got_cancelled
    FROM request r
    LEFT JOIN status_history h ON h.request_id = r.id
    GROUP BY r.id, 2
)
SELECT
    cohort,
    COUNT(*)                                          AS created,
    COUNT(*) FILTER (WHERE got_approved)              AS approved,
    COUNT(*) FILTER (WHERE got_shipped)               AS shipped,
    COUNT(*) FILTER (WHERE got_delivered)             AS delivered,
    COUNT(*) FILTER (WHERE got_closed)                AS closed,
    COUNT(*) FILTER (WHERE got_cancelled)             AS cancelled,
    ROUND(100.0 * COUNT(*) FILTER (WHERE got_closed) / NULLIF(COUNT(*), 0), 1)
        AS close_rate_pct
FROM reached
GROUP BY cohort
ORDER BY cohort;

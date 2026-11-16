-- SPDX-License-Identifier: MIT

-- The direction of energy a physical meter profile reports, as an ESPI
-- flowDirection code: 1 (delivered from the grid, the default) or 19
-- (received from the customer: electricity exported to the grid, such as
-- solar). A net-metered site may register its export as a separate
-- profile so each profile is one stream. Existing profiles are delivered.
ALTER TABLE physical_meter
    ADD COLUMN flow_direction INT UNSIGNED NOT NULL DEFAULT 1
        AFTER commodity,
    ADD CONSTRAINT chk_physical_meter_flow CHECK (
        flow_direction = 1 OR (flow_direction = 19 AND commodity = 1)
    );

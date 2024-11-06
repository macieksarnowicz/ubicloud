WITH 
"total_ipv4" AS 
(
    SELECT 
        "routed_to_host_id", 
        CAST(round(sum(power(2, (32 - masklen("cidr"))))) AS integer) AS "total_ipv4" 
    FROM "address" 
    WHERE (family("cidr") = 4) 
    GROUP BY "routed_to_host_id"
), 
"used_ipv4" AS 
(
    SELECT 
        "routed_to_host_id", 
        (count("assigned_vm_address"."id") + 1) AS "used_ipv4" 
    FROM "address" 
    LEFT JOIN "assigned_vm_address" ON ("assigned_vm_address"."address_id" = "address"."id") 
    GROUP BY "routed_to_host_id"
), 
"storage_devices" AS 
(
    SELECT 
        "vm_host_id", 
        count(*) AS "num_storage_devices", 
        sum("available_storage_gib") AS "available_storage_gib", 
        sum("total_storage_gib") AS "total_storage_gib", 
        json_agg(
            json_build_object(
                'id', 
                "storage_device"."id", 
                'total_storage_gib', 
                "total_storage_gib", 
                'available_storage_gib', "available_storage_gib"
                ) 
    ORDER BY "available_storage_gib") AS "storage_devices" 
    FROM "storage_device" 
    WHERE ("enabled" IS TRUE) 
    GROUP BY "vm_host_id" 
    HAVING ((sum("available_storage_gib") >= 40) AND (count(*) >= 1))
), 
"vm_provisioning" AS 
(
    SELECT 
        "vm_host_id", 
        count(*) AS "vm_provisioning_count" 
    FROM "vm" 
    WHERE ("display_state" = 'creating') 
    GROUP BY "vm_host_id"
) 
SELECT 
    "vm_host"."id" AS "vm_host_id", 
    "total_cores", 
    "used_cores", 
    "total_hugepages_1g", 
    "used_hugepages_1g", 
    "location", 
    "num_storage_devices", 
    "available_storage_gib", 
    "total_storage_gib", 
    "storage_devices", 
    "total_ipv4", 
    "used_ipv4", 
    coalesce("vm_provisioning_count", 0) AS "vm_provisioning_count" 
FROM "vm_host" 
INNER JOIN "storage_devices" ON ("storage_devices"."vm_host_id" = "vm_host"."id") 
INNER JOIN "total_ipv4" ON ("total_ipv4"."routed_to_host_id" = "vm_host"."id") 
INNER JOIN "used_ipv4" ON ("used_ipv4"."routed_to_host_id" = "vm_host"."id") 
LEFT JOIN "vm_provisioning" ON ("vm_provisioning"."vm_host_id" = "vm_host"."id") 
INNER JOIN "boot_image" ON ("vm_host"."id" = "boot_image"."vm_host_id") 
WHERE (("arch" = 'x64') -- AND 
    -- (("total_hugepages_1g" - "used_hugepages_1g") >= 8) AND 
    -- (("total_cores" - "used_cores") >= 1) AND 
    -- ("boot_image"."name" = 'ubuntu-jammy') AND 
    -- ("boot_image"."activated_at" IS NOT NULL) AND 
    -- ("used_ipv4" < "total_ipv4") AND 
    -- ("location" = 'hetzner-fsn1') AND
    -- ("allocation_state" = 'accepting')
    )

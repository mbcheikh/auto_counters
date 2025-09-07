-- auto_counters--1.0.sql
-- Automatic counter definitions table
CREATE TABLE sys_auto_counter_def (
    counter_id VARCHAR(100) NOT NULL,
    table_name VARCHAR(100) NOT NULL,
    fields TEXT[] NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    trigger_created BOOLEAN DEFAULT FALSE,
    trigger_name VARCHAR(100) DEFAULT 'trg_auto_counter',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_fields_length CHECK (array_length(fields, 1) >= 2),
    PRIMARY KEY (counter_id, table_name)
);
COMMENT ON TABLE sys_auto_counter_def IS 'Definition of automatic numbering schemes';
COMMENT ON COLUMN sys_auto_counter_def.fields IS 'The last field is the counter, the others define the key';

-- Counter values table
CREATE TABLE sys_auto_counter (
    counter_id VARCHAR(100) NOT NULL,
    counter_key VARCHAR(500) NOT NULL,
    counter_value INTEGER NOT NULL DEFAULT 1,
    last_used TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (counter_id, counter_key)
);
COMMENT ON TABLE sys_auto_counter IS 'Current counter values';

-- Performance indexes
CREATE INDEX idx_sys_counter_key ON sys_auto_counter(counter_id, counter_key);
CREATE INDEX idx_sys_autocounter_def_table ON sys_auto_counter_def(table_name, is_active);
CREATE INDEX idx_sys_counter_def_active ON sys_auto_counter_def(is_active);

CREATE OR REPLACE FUNCTION set_field(
        record_data ANYELEMENT,
        field_name TEXT,
        field_value ANYELEMENT
    ) RETURNS ANYELEMENT AS $$ BEGIN EXECUTE format(
        'SELECT set_public_field($1, %L, %L)',
        field_name,
        field_value::text
    ) INTO record_data;
RETURN record_data;
END;
$$ LANGUAGE plpgsql;

-- Main function to generate counter values
CREATE OR REPLACE FUNCTION get_next_counter_value(
        p_counter_id VARCHAR,
        p_key_values TEXT []
    ) RETURNS INTEGER AS $$
DECLARE v_next_val INTEGER;
v_counter_key TEXT;
v_fields_count INTEGER;
BEGIN -- Check that the counter exists and is active
IF NOT EXISTS (
    SELECT 1
    FROM sys_auto_counter_def
    WHERE counter_id = p_counter_id
        AND is_active = TRUE
) THEN RAISE EXCEPTION 'Counter % does not exist or is not active',
p_counter_id;
END IF;
-- Check the number of parameters
SELECT array_length(fields, 1) INTO v_fields_count
FROM sys_auto_counter_def
WHERE counter_id = p_counter_id;
IF array_length(p_key_values, 1) != v_fields_count - 1 THEN RAISE EXCEPTION 'Invalid number of key values. Expected %, got %',
v_fields_count - 1,
array_length(p_key_values, 1);
END IF;
-- Generate a unique key for this combination
v_counter_key := array_to_string(p_key_values, '|');
-- Atomically increment the counter
INSERT INTO sys_auto_counter (counter_id, counter_key, counter_value)
VALUES (p_counter_id, v_counter_key, 1) ON CONFLICT (counter_id, counter_key) DO
UPDATE
SET counter_value = sys_auto_counter.counter_value + 1,
    last_used = CURRENT_TIMESTAMP
RETURNING counter_value INTO v_next_val;
RETURN v_next_val;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Generic trigger function
CREATE OR REPLACE FUNCTION generic_counter_trigger()
RETURNS TRIGGER AS $$
DECLARE
    counter_rec RECORD;
    key_values TEXT[];
    field_value TEXT;
    counter_field_name TEXT;
    counter_value INTEGER;
    field_index INTEGER;
    new_jsonb JSONB;
BEGIN
    -- Convert NEW to JSONB using row_to_json first
    new_jsonb := row_to_json(NEW)::jsonb;
    
    -- Find all counters defined for this table
    FOR counter_rec IN 
        SELECT * FROM sys_auto_counter_def 
        WHERE table_name = TG_TABLE_NAME AND is_active = TRUE
    LOOP
        -- Check if the counter field is NULL (needs to be generated)
        counter_field_name := counter_rec.fields[array_length(counter_rec.fields, 1)];
        
        -- Use the converted JSONB instead of direct cast
        field_value := (new_jsonb->>counter_field_name);
        
        IF field_value IS NULL THEN
            -- Build key values
            key_values := ARRAY[]::TEXT[];
            
            FOR field_index IN 1..(array_length(counter_rec.fields, 1) - 1) LOOP
                field_value := (new_jsonb->>counter_rec.fields[field_index]);
                
                IF field_value IS NULL THEN
                    RAISE EXCEPTION 'Field % for counter % cannot be NULL', 
                        counter_rec.fields[field_index], counter_rec.counter_id;
                END IF;
                key_values := array_append(key_values, field_value);
            END LOOP;

            -- Generate the counter value
            counter_value := get_next_counter_value(counter_rec.counter_id, key_values);
            
            -- Direct modification with hstore
            NEW := NEW #= format('%s=>%s', counter_field_name, counter_value)::hstore;
            
            -- Optional debug logging
            RAISE NOTICE 'Generated value % for field % in counter %', 
                counter_value, counter_field_name, counter_rec.counter_id;
        END IF;
    END LOOP;

    RETURN NEW;
    
EXCEPTION
    WHEN others THEN
        RAISE EXCEPTION 'Error in generic_counter_trigger for table %: %', 
            TG_TABLE_NAME, SQLERRM;
END;
$$ LANGUAGE plpgsql;
-- Function to automatically create triggers
CREATE OR REPLACE FUNCTION create_counter_trigger_on_def_insert() RETURNS TRIGGER AS $$
DECLARE table_exists BOOLEAN;
BEGIN -- Check if target table exists
SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
            AND table_name = NEW.table_name
    ) INTO table_exists;
IF NOT table_exists THEN RAISE WARNING 'Table % does not exist. Trigger will not be created now.',
NEW.table_name;
RETURN NEW;
END IF;
-- Attempt to create trigger
BEGIN EXECUTE format(
    '
            CREATE TRIGGER %I
                BEFORE INSERT ON %I
                FOR EACH ROW
                EXECUTE FUNCTION generic_counter_trigger()',
    NEW.trigger_name,
    NEW.table_name
);
-- Mark trigger as created
NEW.trigger_created := TRUE;
NEW.updated_at := CURRENT_TIMESTAMP;
EXCEPTION
WHEN others THEN RAISE WARNING 'Error creating trigger on %: %',
NEW.table_name,
SQLERRM;
NEW.trigger_created := FALSE;
END;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers on sys_auto_counter_def table
CREATE TRIGGER trg_auto_create_counter_trigger BEFORE
INSERT ON sys_auto_counter_def FOR EACH ROW
    WHEN (NEW.is_active = TRUE) EXECUTE FUNCTION create_counter_trigger_on_def_insert();

CREATE OR REPLACE FUNCTION update_counter_trigger_on_def_change() RETURNS TRIGGER AS $$ BEGIN -- If table changes or activating a previously disabled counter
    IF OLD.table_name != NEW.table_name
    OR (
        NOT OLD.is_active
        AND NEW.is_active
    ) THEN -- Remove old trigger if it existed
    IF OLD.trigger_created THEN BEGIN EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %I',
        OLD.trigger_name,
        OLD.table_name
    );
EXCEPTION
WHEN others THEN RAISE WARNING 'Error removing old trigger: %',
SQLERRM;
END;
END IF;
-- Recreate trigger for new setup
PERFORM create_counter_trigger_on_def_insert(NEW);
END IF;
NEW.updated_at := CURRENT_TIMESTAMP;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_auto_update_counter_trigger BEFORE
UPDATE ON sys_auto_counter_def FOR EACH ROW EXECUTE FUNCTION update_counter_trigger_on_def_change();

-- Management functions
CREATE OR REPLACE FUNCTION sync_all_counter_triggers() RETURNS void AS $$
DECLARE def_record RECORD;
BEGIN FOR def_record IN
SELECT *
FROM sys_auto_counter_def
WHERE is_active = TRUE LOOP -- Check if trigger actually exists
    PERFORM 1
FROM pg_trigger tg
    JOIN pg_class cls ON tg.tgrelid = cls.oid
WHERE cls.relname = def_record.table_name
    AND tg.tgname = def_record.trigger_name;
IF NOT FOUND
AND def_record.trigger_created THEN -- Trigger is marked as created but doesn't exist
UPDATE sys_auto_counter_def
SET trigger_created = FALSE
WHERE counter_id = def_record.counter_id;
END IF;
END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_counter_status(p_counter_id VARCHAR DEFAULT NULL) RETURNS TABLE (
        counter_id VARCHAR,
        table_name VARCHAR,
        fields TEXT [],
        is_active BOOLEAN,
        trigger_created BOOLEAN,
        total_keys BIGINT,
        last_used TIMESTAMP,
        created_at TIMESTAMP
    ) AS $$ BEGIN RETURN QUERY
SELECT d.counter_id,
    d.table_name,
    d.fields,
    d.is_active,
    d.trigger_created,
    COUNT(c.counter_key) as total_keys,
    MAX(c.last_used) as last_used,
    d.created_at
FROM sys_auto_counter_def d
    LEFT JOIN sys_auto_counter c ON d.counter_id = c.counter_id
WHERE (
        p_counter_id IS NULL
        OR d.counter_id = p_counter_id
    )
GROUP BY d.counter_id,
    d.table_name,
    d.fields,
    d.is_active,
    d.trigger_created,
    d.created_at
ORDER BY d.counter_id;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION create_counter_def(
        p_counter_id VARCHAR,
        p_table_name VARCHAR,
        p_fields TEXT [],
        p_description TEXT DEFAULT NULL,
        p_is_active BOOLEAN DEFAULT TRUE
    ) RETURNS VOID AS $$
DECLARE v_table_exists BOOLEAN;
v_field_exists BOOLEAN;
v_last_field_type REGTYPE;
v_field_count INTEGER;
v_last_field TEXT;
v_schema_name TEXT := 'public';
v_qualified_table_name TEXT;
BEGIN -- 1. Counter ID validation
IF p_counter_id IS NULL
OR trim(p_counter_id) = '' THEN RAISE EXCEPTION 'Counter ID cannot be empty';
END IF;
IF EXISTS (
    SELECT 1
    FROM sys_auto_counter_def
    WHERE counter_id = p_counter_id
) THEN RAISE EXCEPTION 'Counter ID % already exists',
p_counter_id;
END IF;
-- 2. Fields array validation
v_field_count := array_length(p_fields, 1);
IF v_field_count IS NULL
OR v_field_count < 2 THEN RAISE EXCEPTION 'Fields array must contain at least 2 elements';
END IF;
v_last_field := p_fields [v_field_count];
-- 3. Table existence validation
v_qualified_table_name := format('%I.%I', v_schema_name, p_table_name);
SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = v_schema_name
            AND table_name = p_table_name
    ) INTO v_table_exists;
IF NOT v_table_exists THEN RAISE EXCEPTION 'Table % does not exist in schema %',
p_table_name,
v_schema_name;
END IF;
-- 4. Field existence validation
FOR i IN 1..v_field_count LOOP
SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = v_schema_name
            AND table_name = p_table_name
            AND column_name = p_fields [i]
    ) INTO v_field_exists;
IF NOT v_field_exists THEN RAISE EXCEPTION 'Field % does not exist in table %',
p_fields [i],
p_table_name;
END IF;
END LOOP;
-- 5. Last field type validation (must be numeric)
SELECT data_type INTO v_last_field_type
FROM information_schema.columns
WHERE table_schema = v_schema_name
    AND table_name = p_table_name
    AND column_name = v_last_field;
IF v_last_field_type NOT IN ('integer', 'bigint', 'smallint', 'numeric') THEN RAISE EXCEPTION 'Last field % must be numeric type (current: %)',
v_last_field,
v_last_field_type;
END IF;
-- 6. Insert with additional validation
INSERT INTO sys_auto_counter_def (
        counter_id,
        table_name,
        fields,
        description,
        is_active
    )
VALUES (
        p_counter_id,
        p_table_name,
        p_fields,
        p_description,
        p_is_active
    );
RAISE NOTICE 'Counter % successfully created for table %',
p_counter_id,
p_table_name;
EXCEPTION
WHEN unique_violation THEN RAISE EXCEPTION 'Counter ID % already exists',
p_counter_id;
WHEN others THEN RAISE EXCEPTION 'Error creating counter: %',
SQLERRM;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION update_counter_def(
        p_counter_id VARCHAR,
        p_table_name VARCHAR DEFAULT NULL,
        p_fields TEXT [] DEFAULT NULL,
        p_description TEXT DEFAULT NULL,
        p_is_active BOOLEAN DEFAULT NULL
    ) RETURNS VOID AS $$
DECLARE v_old_rec sys_auto_counter_def %ROWTYPE;
v_table_exists BOOLEAN;
v_field_exists BOOLEAN;
v_last_field_type REGTYPE;
v_field_count INTEGER;
v_last_field TEXT;
v_schema_name TEXT := 'public';
update_query TEXT;
update_fields TEXT [] := ARRAY []::TEXT [];
BEGIN -- 1. Check if counter exists
SELECT * INTO v_old_rec
FROM sys_auto_counter_def
WHERE counter_id = p_counter_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Counter % not found',
p_counter_id;
END IF;
-- 2. Validate new table if provided
IF p_table_name IS NOT NULL THEN
SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = v_schema_name
            AND table_name = p_table_name
    ) INTO v_table_exists;
IF NOT v_table_exists THEN RAISE EXCEPTION 'Table % does not exist',
p_table_name;
END IF;
END IF;
-- 3. Validate new fields if provided
IF p_fields IS NOT NULL THEN v_field_count := array_length(p_fields, 1);
IF v_field_count < 2 THEN RAISE EXCEPTION 'Fields array must contain at least 2 elements';
END IF;
v_last_field := p_fields [v_field_count];
-- Validate field existence
FOR i IN 1..v_field_count LOOP
SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = v_schema_name
            AND table_name = COALESCE(p_table_name, v_old_rec.table_name)
            AND column_name = p_fields [i]
    ) INTO v_field_exists;
IF NOT v_field_exists THEN RAISE EXCEPTION 'Field % does not exist in table %',
p_fields [i],
COALESCE(p_table_name, v_old_rec.table_name);
END IF;
END LOOP;
-- Validate last field type
SELECT data_type INTO v_last_field_type
FROM information_schema.columns
WHERE table_schema = v_schema_name
    AND table_name = COALESCE(p_table_name, v_old_rec.table_name)
    AND column_name = v_last_field;
IF v_last_field_type NOT IN ('integer', 'bigint', 'smallint', 'numeric') THEN RAISE EXCEPTION 'Last field % must be numeric type',
v_last_field;
END IF;
END IF;
-- 4. Build update query
IF p_table_name IS NOT NULL THEN update_fields := array_append(
    update_fields,
    format('table_name = %L', p_table_name)
);
END IF;
IF p_fields IS NOT NULL THEN update_fields := array_append(update_fields, format('fields = %L', p_fields));
END IF;
IF p_description IS NOT NULL THEN update_fields := array_append(
    update_fields,
    format('description = %L', p_description)
);
END IF;
IF p_is_active IS NOT NULL THEN update_fields := array_append(
    update_fields,
    format('is_active = %L', p_is_active)
);
END IF;
IF array_length(update_fields, 1) = 0 THEN RAISE NOTICE 'No fields to update for counter %',
p_counter_id;
RETURN;
END IF;
update_fields := array_append(update_fields, 'updated_at = CURRENT_TIMESTAMP');
update_query := 'UPDATE sys_auto_counter_def SET ' || array_to_string(update_fields, ', ') || format(' WHERE counter_id = %L', p_counter_id);
EXECUTE update_query;
RAISE NOTICE 'Counter % successfully updated',
p_counter_id;
EXCEPTION
WHEN others THEN RAISE EXCEPTION 'Error updating counter %: %',
p_counter_id,
SQLERRM;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION delete_counter_def(
        p_counter_id VARCHAR,
        p_cascade BOOLEAN DEFAULT FALSE
    ) RETURNS VOID AS $$
DECLARE v_counter_exists BOOLEAN;
BEGIN -- 1. Check if counter exists
SELECT EXISTS (
        SELECT 1
        FROM sys_auto_counter_def
        WHERE counter_id = p_counter_id
    ) INTO v_counter_exists;
IF NOT v_counter_exists THEN RAISE EXCEPTION 'Counter % not found',
p_counter_id;
END IF;
-- 2. Cascade deletion if requested
IF p_cascade THEN
DELETE FROM sys_auto_counter
WHERE counter_id = p_counter_id;
RAISE NOTICE 'Counter values for % deleted (cascade)',
p_counter_id;
ELSE -- Check if associated values exist
IF EXISTS (
    SELECT 1
    FROM sys_auto_counter
    WHERE counter_id = p_counter_id
) THEN RAISE EXCEPTION 'Counter % has associated values. Use p_cascade := true to also delete values.',
p_counter_id;
END IF;
END IF;
-- 3. Delete definition
DELETE FROM sys_auto_counter_def
WHERE counter_id = p_counter_id;
RAISE NOTICE 'Counter % successfully deleted',
p_counter_id;
EXCEPTION
WHEN others THEN RAISE EXCEPTION 'Error deleting counter %: %',
p_counter_id,
SQLERRM;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_counter_def(p_counter_id VARCHAR DEFAULT NULL) RETURNS TABLE (
        counter_id VARCHAR,
        table_name VARCHAR,
        fields TEXT [],
        description TEXT,
        is_active BOOLEAN,
        trigger_created BOOLEAN,
        created_at TIMESTAMP,
        updated_at TIMESTAMP,
        table_exists BOOLEAN,
        fields_valid BOOLEAN,
        last_field_numeric BOOLEAN
    ) AS $$ BEGIN IF p_counter_id IS NULL THEN RETURN QUERY
SELECT scd.counter_id,
    scd.table_name,
    scd.fields,
    scd.description,
    scd.is_active,
    scd.trigger_created,
    scd.created_at,
    scd.updated_at,
    EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
            AND table_name = scd.table_name
    ) as table_exists,
    TRUE as fields_valid,
    TRUE as last_field_numeric
FROM sys_auto_counter_def scd
ORDER BY scd.counter_id;
ELSE RETURN QUERY
SELECT scd.counter_id,
    scd.table_name,
    scd.fields,
    scd.description,
    scd.is_active,
    scd.trigger_created,
    scd.created_at,
    scd.updated_at,
    EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
            AND table_name = scd.table_name
    ) as table_exists,
    TRUE as fields_valid,
    TRUE as last_field_numeric
FROM sys_auto_counter_def scd
WHERE scd.counter_id = p_counter_id;
END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION toggle_counter_def(
        p_counter_id VARCHAR,
        p_is_active BOOLEAN
    ) RETURNS VOID AS $$ BEGIN
UPDATE sys_auto_counter_def
SET is_active = p_is_active,
    updated_at = CURRENT_TIMESTAMP
WHERE counter_id = p_counter_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Counter % not found',
p_counter_id;
END IF;
RAISE NOTICE 'Counter % %',
p_counter_id,
CASE
    WHEN p_is_active THEN 'activated'
    ELSE 'deactivated'
END;
EXCEPTION
WHEN others THEN RAISE EXCEPTION 'Error toggling counter %: %',
p_counter_id,
SQLERRM;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Utility views
CREATE VIEW vw_counter_status AS
SELECT *
FROM get_counter_status();

CREATE VIEW vw_counter_values AS
SELECT c.counter_id,
    d.table_name,
    c.counter_key,
    c.counter_value,
    c.last_used
FROM sys_auto_counter c
    JOIN sys_auto_counter_def d ON c.counter_id = d.counter_id
ORDER BY d.table_name,
    c.counter_key;

-- Installation function
CREATE OR REPLACE FUNCTION auto_counters_install() RETURNS void AS $$ BEGIN RAISE NOTICE 'auto_counters extension successfully installed';
RAISE NOTICE 'Use SELECT sync_all_counter_triggers() to synchronize existing triggers';
END;
$$ LANGUAGE plpgsql;

-- Permission grants
GRANT USAGE ON SCHEMA public TO public;
GRANT SELECT,
    INSERT,
    UPDATE ON sys_auto_counter_def TO public;
GRANT SELECT,
    INSERT,
    UPDATE ON sys_auto_counter TO public;
GRANT SELECT ON vw_counter_status TO public;
GRANT SELECT ON vw_counter_values TO public;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO public;

-- Function comments
COMMENT ON FUNCTION get_next_counter_value(VARCHAR, TEXT []) IS 'Generates the next value of a counter';
COMMENT ON FUNCTION generic_counter_trigger() IS 'Generic trigger for automatic numbering';
COMMENT ON FUNCTION sync_all_counter_triggers() IS 'Synchronizes all counter triggers';
COMMENT ON FUNCTION get_counter_status(VARCHAR) IS 'Returns counter status';

-- Initial installation
SELECT auto_counters_install();
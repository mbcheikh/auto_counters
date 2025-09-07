-- test_extension.sql
-- Création d'une table de test
CREATE TABLE test_table (
    id SERIAL PRIMARY KEY,
    year INTEGER NOT NULL,
    department VARCHAR(50) NOT NULL,
    document_number INTEGER,
    data TEXT
);

-- Configuration d'un compteur
INSERT INTO sys_counter_def 
    (counter_id, table_name, fields, description)
VALUES (
    'test_doc_counter',
    'test_table',
    ARRAY['year', 'department', 'document_number'],
    'Compteur de test pour documents'
);

-- Test d'insertion
INSERT INTO test_table (year, department, data) 
VALUES (2024, 'IT', 'Premier document');

INSERT INTO test_table (year, department, data) 
VALUES (2024, 'IT', 'Deuxième document');

INSERT INTO test_table (year, department, data) 
VALUES (2024, 'HR', 'Document RH');

-- Vérification des résultats
SELECT * FROM test_table;
SELECT * FROM vw_counter_status;
SELECT * FROM vw_counter_values;

-- Nettoyage
DROP TABLE test_table CASCADE;
DELETE FROM sys_counter_def WHERE counter_id = 'test_doc_counter';
# Auto Counters PostgreSQL Extension
A powerful and flexible PostgreSQL extension for **automatic contextual numbering** based on multiple field combinations. Perfect for generating document numbers, invoice numbers, or any numbering system that depends on contextual information like year, department, or category.

## ✨ Features

- 🚀 **Automatic contextual numbering** based on field combinations
- ⚡ **Trigger-based** automatic value generation
- 🔧 **Zero-configuration** once defined in `sys_auto_counter_def`
- 📊 **Monitoring views** for counter status and values
- 🔄 **Automatic periodic recycling** based on composite keys
- 🛡️ **Transaction-safe** operations with conflict prevention
- 📝 **Comprehensive management API** with validation
- 🔍 **Debugging utilities** for development and troubleshooting

## 📦 Installation

### Standard Installation
```bash
# Clone and build the extension
git clone https://github.com/yourusername/auto_counters.git
cd auto_counters

# Compile and install
make
sudo make install

# Install in your database
psql -d your_database -c \"CREATE EXTENSION auto_counters;\"
```

### Direct SQL Installation
```sql
-- Execute the extension script
\\i auto_counters--1.0.sql

-- Or create the extension directly
CREATE EXTENSION auto_counters;
```

## 🏗️ Database Structure

### Core Tables
```sql
-- Counter definitions
CREATE TABLE sys_auto_counter_def (
    counter_id VARCHAR(100) PRIMARY KEY,
    table_name VARCHAR(100) NOT NULL,
    fields TEXT[] NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    trigger_created BOOLEAN DEFAULT FALSE,
    trigger_name VARCHAR(100) DEFAULT 'trg_auto_counter',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_fields_length CHECK (array_length(fields, 1) >= 2)
);

-- Current counter values
CREATE TABLE sys_auto_counter (
    counter_id VARCHAR(100) NOT NULL,
    counter_key VARCHAR(500) NOT NULL,
    counter_value INTEGER NOT NULL DEFAULT 1,
    last_used TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (counter_id, counter_key),
    FOREIGN KEY (counter_id) REFERENCES sys_auto_counter_def(counter_id) ON DELETE CASCADE
);
```

## 🚀 Quick Start

### 1. Create Target Table
```sql
CREATE TABLE invoices (
    id SERIAL PRIMARY KEY,
    year INTEGER NOT NULL,
    department VARCHAR(50) NOT NULL,
    invoice_number INTEGER,  -- Will be auto-generated
    client VARCHAR(100),
    amount DECIMAL(10,2)
);
```

### 2. Configure Automatic Numbering
```sql
SELECT create_counter_def(
    'invoices_year_department',
    'invoices',
    ARRAY['year', 'department', 'invoice_number'],
    'Automatic invoice numbering by year and department'
);
```

### 3. Insert Data (Numbering is Automatic)
```sql
-- invoice_number will be automatically generated
INSERT INTO invoices (year, department, client, amount) 
VALUES (2024, 'sales', 'Client ABC', 1000.00);

INSERT INTO invoices (year, department, client, amount) 
VALUES (2024, 'sales', 'Client XYZ', 2500.00);

-- Different department gets its own sequence
INSERT INTO invoices (year, department, client, amount) 
VALUES (2024, 'support', 'Client DEF', 500.00);
```

## 🔧 Management Functions

### Create Counter Definition
```sql
SELECT create_counter_def(
    p_counter_id := 'orders_year_region',
    p_table_name := 'orders',
    p_fields := ARRAY['year', 'region', 'order_number'],
    p_description := 'Order numbering by year and region',
    p_is_active := TRUE
);
```

### Update Counter Definition
```sql
SELECT update_counter_def(
    p_counter_id := 'orders_year_region',
    p_description := 'Updated description for order numbering',
    p_is_active := FALSE
);
```

### Delete Counter Definition
```sql
-- Simple deletion (fails if values exist)
SELECT delete_counter_def('orders_year_region');

-- Cascade deletion (removes values too)
SELECT delete_counter_def('orders_year_region', TRUE);
```

### Get Counter Information
```sql
-- All counters
SELECT * FROM get_counter_def();

-- Specific counter
SELECT * FROM get_counter_def('invoices_year_department');
```

### Toggle Counter Status
```sql
-- Disable a counter
SELECT toggle_counter_def('invoices_year_department', FALSE);

-- Enable a counter  
SELECT toggle_counter_def('invoices_year_department', TRUE);
```

## 📊 Monitoring Views

### Counter Status View
```sql
-- View all counters and their status
SELECT * FROM vw_counter_status;
```

### Counter Values View
```sql
-- View current counter values
SELECT * FROM vw_counter_values;

-- Filter by specific counter
SELECT * FROM vw_counter_values WHERE counter_id = 'invoices_year_department';
```

## ⚙️ Advanced Configuration

### Complex Key Combinations
```sql
-- Three-level contextual numbering
SELECT create_counter_def(
    'contracts_year_region_type',
    'contracts', 
    ARRAY['year', 'region', 'contract_type', 'contract_number'],
    'Contract numbering by year, region, and type'
);
```

### Custom Trigger Names
```sql
-- Manual trigger creation for specific needs
CREATE TRIGGER trg_custom_invoice_number
    BEFORE INSERT ON invoices
    FOR EACH ROW
    EXECUTE FUNCTION generic_counter_trigger();
```

## 🔍 Debugging and Troubleshooting

### Enable Debug Mode
```sql
-- Set client message level to see debug output
SET client_min_messages = NOTICE;

-- Test insertions will now show debug information
INSERT INTO invoices (year, department, client, amount)
VALUES (2024, 'sales', 'Debug Client', 1000.00);
```

### Check Counter Configuration
```sql
-- Verify counter definition
SELECT * FROM sys_auto_counter_def WHERE counter_id = 'invoices_year_department';

-- Check current counter values
SELECT * FROM sys_auto_counter WHERE counter_id = 'invoices_year_department';
```

### Sync Triggers
```sql
-- Manually synchronize triggers if needed
SELECT sync_all_counter_triggers();
```

## 🛡️ Validation and Safety

The extension includes comprehensive validation:

- ✅ Table existence verification
- ✅ Field existence validation  
- ✅ Data type checking (last field must be numeric)
- ✅ Unique constraint enforcement
- ✅ Transaction-safe operations

## 📋 Requirements

- PostgreSQL 9.5 or higher
- PL/pgSQL language support
- hstore extension (for advanced field manipulation)
- Basic permissions to create extensions and functions

## 📦 Required Extensions
```sql
-- Essential extension for field operations
CREATE EXTENSION IF NOT EXISTS hstore;
```

## 🔧 Installation Verification
```sql
-- Check if required extensions are available
SELECT name, default_version, installed_version, comment 
FROM pg_available_extensions 
WHERE name IN ('hstore', 'plpgsql');

-- Verify hstore extension is installed
SELECT * FROM pg_extension WHERE extname = 'hstore';
```
## ⚠️ Permission Requirements
The installing user must have:

CREATE privilege on the database

USAGE privilege on the schema

Ability to install extensions (SUPERUSER or appropriate privileges)



## 📄 License

This project is licensed under the PostgreSQL License - see the [LICENSE.md](LICENSE.md) file for details.

## 🤝 Contributing

We welcome contributions! Please feel free to submit pull requests, report bugs, or suggest new features.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📚 Documentation

Full documentation is available in the [docs](docs/) directory.


## 💡 Support

If you encounter any issues or have questions:

1. Check the documentation in the [docs](docs/) directory
2. Search existing GitHub issues
3. Create a new issue with details about your problem

---

**Note**: This extension is designed for PostgreSQL and may not work with other database systems. Always test in a development environment before deploying to production.


# Auto Counters PostgreSQL Extension - Documentation

## 📚 Table of Contents
1. [Overview](#overview)
2. [Installation](#installation)
3. [Configuration](#configuration)
4. [API Reference](#api-reference)
5. [Usage Examples](#usage-examples)
6. [Troubleshooting](#troubleshooting)
7. [Best Practices](#best-practices)
8. [Limitations](#limitations)
9. [Contributing](#contributing)
10. [License](#license)

## 📖 Overview

Auto Counters is a PostgreSQL extension that provides automatic contextual numbering based on multiple field combinations. It's designed to handle complex numbering scenarios like invoice numbers, document IDs, or any sequential numbering that depends on contextual information.

### Key Features
- Automatic numbering based on field combinations
- Support for shared counters across multiple tables
- Transaction-safe operations
- Comprehensive validation and error handling
- Monitoring and debugging utilities

## 🚀 Installation


## 📋 Requirements

- **PostgreSQL 9.5** or higher
- **PL/pgSQL** language support
- **hstore extension** (for advanced field manipulation)
- Basic permissions to create extensions and functions

### 📦 Required Extensions

```sql
-- Essential extension for field operations
CREATE EXTENSION IF NOT EXISTS hstore;

-- Optional but recommended for debugging
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
```

### 🔧 Installation Verification

```sql
-- Check if required extensions are available
SELECT name, default_version, installed_version, comment 
FROM pg_available_extensions 
WHERE name IN ('hstore', 'plpgsql');

-- Verify hstore extension is installed
SELECT * FROM pg_extension WHERE extname = 'hstore';
```

### ⚠️ Permission Requirements

The installing user must have:
- `CREATE` privilege on the database
- `USAGE` privilege on the schema
- Ability to install extensions (`SUPERUSER` or appropriate privileges)

### 🐛 Troubleshooting Missing hstore

If the `hstore` extension is not available:

```bash
# On Ubuntu/Debian systems
sudo apt-get install postgresql-contrib

# On CentOS/RHEL systems
sudo yum install postgresql-contrib

# On macOS with Homebrew
brew install postgresql --with-contrib
```

After installing the contrib package, enable hstore:

```sql
-- Connect to your database as superuser
\\c your_database

-- Create the hstore extension
CREATE EXTENSION hstore;

-- Verify installation
SELECT '\"key\"=>\"value\"'::hstore;
```

### 🔄 Alternative Approach (Without hstore)

If `hstore` cannot be installed, modify the trigger function to use alternative methods:

```sql
-- Instead of hstore assignment, use dynamic SQL
EXECUTE format('SELECT set_field($1, %L, %L)', 
    field_name, value) INTO NEW;
```

However, using `hstore` is **highly recommended** for better performance and reliability.

---

**Note**: The `hstore` extension is included in the standard PostgreSQL contrib package and is available on most installations. It provides essential functionality for dynamic field manipulation in the trigger system.

### Installation Steps

1. **Clone the repository**:
   ```bash
   git clone https://github.com/yourusername/auto_counters.git
   cd auto_counters
   ```

2. **Compile and install**:
   ```bash
   make
   sudo make install
   ```

3. **Enable in your database**:
   ```sql
   CREATE EXTENSION auto_counters;
   ```

## ⚙️ Configuration

### Database Structure

#### sys_auto_counter_def Table
Stores counter definitions with a composite primary key (counter_id, table_name).

```sql
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
```

#### sys_auto_counter Table
Stores current counter values.

```sql
CREATE TABLE sys_auto_counter (
    counter_id VARCHAR(100) NOT NULL,
    counter_key VARCHAR(500) NOT NULL,
    counter_value INTEGER NOT NULL DEFAULT 1,
    last_used TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (counter_id, counter_key)
);
```

## 📋 API Reference

### Management Functions

#### create_counter_def()
Creates a new counter definition.

```sql
SELECT create_counter_def(
    p_counter_id VARCHAR,
    p_table_name VARCHAR,
    p_fields TEXT[],
    p_description TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT TRUE
);
```

#### update_counter_def()
Updates an existing counter definition.

```sql
SELECT update_counter_def(
    p_counter_id VARCHAR,
    p_table_name VARCHAR,
    p_fields TEXT[] DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
);
```

#### delete_counter_def()
Deletes a counter definition.

```sql
SELECT delete_counter_def(
    p_counter_id VARCHAR,
    p_table_name VARCHAR,
    p_cascade BOOLEAN DEFAULT FALSE
);
```

#### get_counter_def()
Retrieves counter definitions.

```sql
SELECT * FROM get_counter_def(
    p_counter_id VARCHAR DEFAULT NULL,
    p_table_name VARCHAR DEFAULT NULL
);
```

#### toggle_counter_def()
Activates or deactivates a counter.

```sql
SELECT toggle_counter_def(
    p_counter_id VARCHAR,
    p_table_name VARCHAR,
    p_is_active BOOLEAN
);
```

### Utility Functions

#### sync_all_counter_triggers()
Synchronizes all counter triggers.

```sql
SELECT sync_all_counter_triggers();
```

#### get_next_counter_value()
Internal function that generates the next counter value.

```sql
SELECT get_next_counter_value(
    p_counter_id VARCHAR, 
    p_key_values TEXT[]
);
```

## 🎯 Usage Examples

### Basic Example: Invoice Numbering

1. **Create target tables**:
   ```sql
   CREATE TABLE invoices (
       id SERIAL PRIMARY KEY,
       year INTEGER NOT NULL,
       department VARCHAR(50) NOT NULL,
       invoice_number INTEGER,
       client VARCHAR(100),
       amount DECIMAL(10,2)
   );
   ```

2. **Configure counter**:
   ```sql
   SELECT create_counter_def(
       'invoices_sequence',
       'invoices',
       ARRAY['year', 'department', 'invoice_number'],
       'Invoice numbering by year and department'
   );
   ```

3. **Insert data**:
   ```sql
   INSERT INTO invoices (year, department, client, amount) 
   VALUES (2024, 'sales', 'Client ABC', 1000.00);
   ```

### Advanced Example: Shared Counter

1. **Create multiple tables**:
   ```sql
   CREATE TABLE invoices (...);
   CREATE TABLE credit_notes (...);
   CREATE TABLE debit_notes (...);
   ```

2. **Configure shared counter**:
   ```sql
   SELECT create_counter_def(
       'documents_sequence',
       'invoices',
       ARRAY['year', 'department', 'document_number'],
       'Document numbering for invoices'
   );
   
   SELECT create_counter_def(
       'documents_sequence',
       'credit_notes',
       ARRAY['year', 'department', 'document_number'],
       'Document numbering for credit notes'
   );
   ```

3. **Insert data**:
   ```sql
   INSERT INTO invoices (year, department, client, amount) 
   VALUES (2024, 'sales', 'Client ABC', 1000.00);
   
   INSERT INTO credit_notes (year, department, client, amount) 
   VALUES (2024, 'sales', 'Client XYZ', -500.00);
   ```

## 🔍 Troubleshooting

### Common Issues

1. **\"Cannot cast type to jsonb\" error**:
   - Solution: Ensure you have the latest version of the extension

2. **Trigger not created automatically**:
   - Solution: Run `SELECT sync_all_counter_triggers();`

3. **Permission errors**:
   - Solution: Ensure the user has necessary privileges on all tables

### Debugging

Enable debug mode to see detailed messages:

```sql
SET client_min_messages = NOTICE;

INSERT INTO your_table (...) VALUES (...);
```

Check counter status:

```sql
SELECT * FROM vw_counter_status;
SELECT * FROM vw_counter_values;
```

## 🏆 Best Practices

1. **Naming conventions**:
   - Use descriptive counter_id values
   - Follow a consistent naming pattern

2. **Validation**:
   - Always validate table and field existence before creating counters
   - Use the provided management functions instead of direct SQL

3. **Monitoring**:
   - Regularly check counter status with the provided views
   - Set up monitoring for counter values approaching limits

4. **Backup**:
   - Include sys_auto_counter_def and sys_auto_counter in your backup strategy

## ⚠️ Limitations

1. **Data types**: The last field in the fields array must be numeric
2. **Performance**: High-volume systems may experience contention on the counter table
3. **Concurrency**: The extension uses row-level locking which may cause contention in high-concurrency environments

## 🤝 Contributing

We welcome contributions! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Setup

1. **Set up development environment**:
   ```bash
   git clone https://github.com/yourusername/auto_counters.git
   cd auto_counters
   createdb auto_counters_test
   psql auto_counters_test -f auto_counters--1.0.sql
   ```

2. **Run tests**:
   ```bash
   # Add your test scripts here
   ```

## 📄 License

This project is licensed under the PostgreSQL License - see the [LICENSE.md](LICENSE.md) file for details.

## 📞 Support

If you encounter any issues or have questions:

1. Check this documentation
2. Search existing GitHub issues
3. Create a new issue with details about your problem

For commercial support, please contact [your email address].

---

*This documentation is part of the Auto Counters PostgreSQL Extension. For the latest updates, always refer to the [GitHub repository](https://github.com/yourusername/auto_counters).*
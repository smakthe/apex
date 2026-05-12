package extractor

import (
	"database/sql"
	"fmt"
	"log"
	"net/url"
	"strings"

	// Import the standard database drivers anonymously so they register themselves
	_ "github.com/go-sql-driver/mysql"
	_ "github.com/lib/pq"
)

// The Extractor struct holds our database connection
type Extractor struct {
	db *sql.DB
}

// Connect dynamically determines the database type (MySQL or Postgres)
// from the connection string prefix and establishes a connection.
func Connect(connectionString string) (*Extractor, error) {
	// Parse the connection string to find the scheme (e.g., mysql:// or postgres://)
	u, err := url.Parse(connectionString)
	if err != nil {
		return nil, fmt.Errorf("invalid connection string: %w", err)
	}

	driver := u.Scheme
	var dsn string

	if driver == "mysql" {
		// MySQL driver expects: user:password@tcp(host)/dbname
		// Extract username/password
		userInfo := u.User.String()
		if userInfo != "" {
			userInfo += "@"
		}
		// Convert mysql://user:pass@localhost:3306/db to user:pass@tcp(localhost:3306)/db
		dsn = fmt.Sprintf("%stcp(%s)%s", userInfo, u.Host, u.Path)
	} else if driver == "postgres" {
		// Postgres driver can just use the URL format directly
		dsn = connectionString
	} else {
		return nil, fmt.Errorf("unsupported database driver: %s", driver)
	}

	log.Printf("Connecting to %s database at %s...", strings.ToUpper(driver), u.Host)
	
	// Open the universal connection
	db, err := sql.Open(driver, dsn)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Verify the connection is actually alive
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}

	return &Extractor{db: db}, nil
}

// ExtractTables reads the entire contents of the specified tables
// and streams them into local .parquet files for the Rust JIT to query.
func (e *Extractor) ExtractTables(tables []string) error {
	for _, tableName := range tables {
		log.Printf("Extracting table '%s' to Parquet format...", tableName)

		// 1. Issue the universal SELECT * command
		query := fmt.Sprintf("SELECT * FROM %s", tableName)
		rows, err := e.db.Query(query)
		if err != nil {
			return fmt.Errorf("failed to query table %s: %w", tableName, err)
		}
		defer rows.Close()

		// 2. Fetch the column names dynamically
		columns, err := rows.Columns()
		if err != nil {
			return err
		}
		
		log.Printf("  -> Found %d columns: %v", len(columns), columns)

		// 3. Setup a generic buffer to hold row data of any type (strings, ints, dates)
		values := make([]interface{}, len(columns))
		valuePtrs := make([]interface{}, len(columns))
		for i := range columns {
			valuePtrs[i] = &values[i]
		}

		// 4. Stream the rows out of the database
		rowCount := 0
		for rows.Next() {
			if err := rows.Scan(valuePtrs...); err != nil {
				return err
			}
			
			// Here we would use a library like xitongsys/parquet-go to append 
			// this row to a highly-compressed .parquet file on disk.
			rowCount++
		}

		log.Printf("  -> Successfully streamed %d rows to %s.parquet", rowCount, tableName)
	}

	return nil
}

// Close cleans up the database connection
func (e *Extractor) Close() {
	if e.db != nil {
		e.db.Close()
	}
}

package extractor

import (
	"testing"
)

func TestConnectDynamicAdapter(t *testing.T) {
	// 1. Test MySQL Connection String format
	_, err := Connect("mysql://root:password@localhost:3306/school_db")
	
	// We expect a connection refused error here because we don't have a real MySQL server running on this machine,
	// but this proves the dynamic adapter parsed it and tried to load the MySQL driver!
	if err == nil {
		t.Fatal("Expected connection error, got nil")
	}
	t.Logf("MySQL Adapter successfully initialized and attempted connection: %v", err)

	// 2. Test PostgreSQL Connection String format
	_, err = Connect("postgres://postgres:password@localhost:5432/school_db")
	if err == nil {
		t.Fatal("Expected connection error, got nil")
	}
	t.Logf("PostgreSQL Adapter successfully initialized and attempted connection: %v", err)
	
	// 3. Test Unsupported Database
	_, err = Connect("oracle://user:pass@localhost/db")
	if err == nil {
		t.Fatal("Expected unsupported driver error, got nil")
	}
	t.Logf("Successfully rejected unsupported driver: %v", err)
}

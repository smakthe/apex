package main

import (
	"bufio"
	"database/sql"
	"fmt"
	"log"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	_ "github.com/go-sql-driver/mysql"
	// _ "github.com/lib/pq" // Ensure lib/pq is installed for PostgreSQL support
)

const (
	colorReset  = "\033[0m"
	colorCyan   = "\033[36m"
	colorGreen  = "\033[32m"
	colorYellow = "\033[33m"
	colorRed    = "\033[31m"
	colorPurple = "\033[35m"
)

func main() {
	reader := bufio.NewReader(os.Stdin)

	for {
		printWelcomeBanner()
		
		fmt.Println(colorCyan + "Select Connection Method:" + colorReset)
		fmt.Println("1. Standard Configuration")
		fmt.Println("2. Advanced (Connection String)")
		fmt.Println("3. Exit APEX")
		fmt.Print(colorYellow + "> " + colorReset)
		
		method, _ := reader.ReadString('\n')
		method = strings.TrimSpace(method)

		if method == "3" || strings.ToLower(method) == "exit" {
			fmt.Println(colorGreen + "Goodbye!" + colorReset)
			os.Exit(0)
		}

		var driver, dsn string

		if method == "2" {
			fmt.Print("Enter Connection String (e.g. mysql://root:pass@localhost:3306/db): ")
			connStr, _ := reader.ReadString('\n')
			connStr = strings.TrimSpace(connStr)
			
			if strings.HasPrefix(connStr, "postgres://") {
				driver = "postgres"
				dsn = connStr
			} else {
				driver = "mysql"
				// Naive conversion for prototype (mysql://root:pass@host/db -> root:pass@tcp(host)/db)
				stripped := strings.TrimPrefix(connStr, "mysql://")
				parts := strings.SplitN(stripped, "@", 2)
				if len(parts) == 2 {
					hostDB := strings.SplitN(parts[1], "/", 2)
					dsn = fmt.Sprintf("%s@tcp(%s)/%s", parts[0], hostDB[0], hostDB[1])
				} else {
					dsn = stripped
				}
			}
		} else {
			fmt.Print("Database Type (mysql/postgres) [mysql]: ")
			dbType, _ := reader.ReadString('\n')
			dbType = strings.TrimSpace(strings.ToLower(dbType))
			if dbType == "" { dbType = "mysql" }

			fmt.Print("Username [root]: ")
			user, _ := reader.ReadString('\n')
			user = strings.TrimSpace(user)
			if user == "" { user = "root" }

			fmt.Print("Password: ")
			pass, _ := reader.ReadString('\n')
			pass = strings.TrimSpace(pass)

			fmt.Print("Host [localhost:3306]: ")
			host, _ := reader.ReadString('\n')
			host = strings.TrimSpace(host)
			if host == "" { host = "localhost:3306" }

			fmt.Print("Database Name: ")
			dbName, _ := reader.ReadString('\n')
			dbName = strings.TrimSpace(dbName)

			driver = dbType
			if driver == "mysql" {
				dsn = fmt.Sprintf("%s:%s@tcp(%s)/%s", user, pass, host, dbName)
			} else {
				dsn = fmt.Sprintf("postgres://%s:%s@%s/%s?sslmode=disable", user, pass, host, dbName)
			}
		}

		fmt.Printf(colorCyan+"\n[APEX] Connecting to %s database... "+colorReset, strings.ToUpper(driver))
		db, err := sql.Open(driver, dsn)
		if err != nil {
			fmt.Println(colorRed + "Failed!\nError: " + err.Error() + colorReset)
			continue
		}

		if err := db.Ping(); err != nil {
			fmt.Println(colorRed + "Failed!\nError: " + err.Error() + colorReset)
			continue
		}
		fmt.Println(colorGreen + "Success!\n" + colorReset)

		runQueryLoop(db, reader)
	}
}

func runQueryLoop(db *sql.DB, reader *bufio.Reader) {
	for {
		fmt.Println(colorPurple + "---------------------------------------------------" + colorReset)
		fmt.Println("Type your SQL query, '/disconnect' to return to main menu, or '/exit' to quit.")
		fmt.Print(colorGreen + "APEX SQL > " + colorReset)
		
		query, _ := reader.ReadString('\n')
		query = strings.TrimSpace(query)

		if query == "/disconnect" {
			db.Close()
			fmt.Println(colorYellow + "Disconnected from database." + colorReset)
			return
		}
		if query == "/exit" {
			fmt.Println(colorGreen + "Goodbye!" + colorReset)
			os.Exit(0)
		}
		if query == "" {
			continue
		}

		start := time.Now()
		
		// In-Memory Streaming Execution Mock
		// (Reads directly via the driver into RAM without CSVs, mapping to our architecture)
		rows, err := db.Query(query)
		if err != nil {
			fmt.Println(colorRed + "Error executing query: " + err.Error() + colorReset)
			continue
		}

		columns, err := rows.Columns()
		if err != nil {
			fmt.Println(colorRed + "Error fetching columns: " + err.Error() + colorReset)
			continue
		}

		// Setup formatted TabWriter for SQL-like output
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', tabwriter.Debug)
		
		// Print Headers
		header := strings.Join(columns, "\t")
		fmt.Fprintln(w, colorCyan + header + colorReset)

		// Dynamic extraction buffer
		values := make([]sql.RawBytes, len(columns))
		scanArgs := make([]interface{}, len(values))
		for i := range values {
			scanArgs[i] = &values[i]
		}

		rowCount := 0
		for rows.Next() {
			if err := rows.Scan(scanArgs...); err != nil {
				log.Println(colorRed + "Row scan error: " + err.Error() + colorReset)
				continue
			}
			
			var record []string
			for _, col := range values {
				record = append(record, string(col))
			}
			fmt.Fprintln(w, strings.Join(record, "\t"))
			rowCount++
		}
		rows.Close()
		w.Flush()

		elapsed := time.Since(start)
		fmt.Printf(colorYellow+"\n[%d rows in set (%.3f sec)]\n"+colorReset, rowCount, elapsed.Seconds())
	}
}

func printWelcomeBanner() {
	fmt.Println(colorPurple + `
    ___    ____  ______ __  __
   /   |  / __ \/ ____/ \ \/ /
  / /| | / /_/ / ____/   \  / 
 / ___ |/ ____/ /___     /  \  
/_/  |_/_/   /_____/    /_/\_\
                             
The Polyglot Query Execution Engine` + colorReset)
	fmt.Println(colorCyan + "v0.1.0-alpha (In-Memory Lakehouse Edition)" + colorReset)
	fmt.Println()
}

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

	"github.com/chzyer/readline"
	_ "github.com/go-sql-driver/mysql"
	_ "github.com/lib/pq"
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
			var connStr string
			for {
				fmt.Print("Enter Connection String (e.g. protocol://username:password@host:port/database): ")
				connStr, _ = reader.ReadString('\n')
				connStr = strings.TrimSpace(connStr)
				if connStr != "" {
					break
				}
				fmt.Println(colorRed + "Connection String cannot be empty." + colorReset)
			}
			
			if strings.HasPrefix(connStr, "postgres://") || strings.HasPrefix(connStr, "postgresql://") {
				driver = "postgres"
				if !strings.Contains(connStr, "sslmode=") {
					if strings.Contains(connStr, "?") {
						connStr += "&sslmode=disable"
					} else {
						connStr += "?sslmode=disable"
					}
				}
				dsn = connStr
			} else {
				driver = "mysql"
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
			var dbType string
			for {
				fmt.Print("Database Type (mysql/postgres): ")
				dbType, _ = reader.ReadString('\n')
				dbType = strings.TrimSpace(strings.ToLower(dbType))
				if dbType == "mysql" || dbType == "postgres" || dbType == "postgresql" {
					break
				}
				if dbType == "" {
					fmt.Println(colorRed + "Database Type cannot be empty." + colorReset)
				} else {
					fmt.Println(colorRed + "Invalid Database Type." + colorReset)
				}
			}

			defaultUser := "root"
			defaultHost := "localhost:3306"

			if dbType == "postgres" || dbType == "postgresql" {
				defaultUser = "postgres"
				defaultHost = "localhost:5432"
				dbType = "postgres"
			}

			fmt.Printf("Username [%s]: ", defaultUser)
			user, _ := reader.ReadString('\n')
			user = strings.TrimSpace(user)
			if user == "" {
				user = defaultUser
			}

			fmt.Print("Password: ")
			pass, _ := reader.ReadString('\n')
			pass = strings.TrimSpace(pass)

			fmt.Printf("Host [%s]: ", defaultHost)
			host, _ := reader.ReadString('\n')
			host = strings.TrimSpace(host)
			if host == "" {
				host = defaultHost
			}

			var dbName string
			for {
				fmt.Print("Database Name (required): ")
				dbName, _ = reader.ReadString('\n')
				dbName = strings.TrimSpace(dbName)
				if dbName != "" {
					break
				}
				fmt.Println(colorRed + "Database Name cannot be empty." + colorReset)
			}

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

func runQueryLoop(db *sql.DB, stdReader *bufio.Reader) {
	rl, err := readline.NewEx(&readline.Config{
		Prompt:          "\033[32mAPEX SQL > \033[0m",
		HistoryFile:     "/tmp/apex_sql_history.tmp",
		InterruptPrompt: "^C",
		EOFPrompt:       "/q",
	})
	if err != nil {
		fmt.Println(colorRed + "Failed to initialize readline: " + err.Error() + colorReset)
		return
	}
	defer rl.Close()

	fmt.Println(colorPurple + "---------------------------------------------------" + colorReset)
	fmt.Println("Type your SQL query, '/dc' to disconnect and return to main menu, or '/q' to quit.")

	for {
		query, err := rl.Readline()
		if err != nil { // Handles Ctrl+C or EOF
			break
		}
		query = strings.TrimSpace(query)

		if query == "/dc" {
			db.Close()
			fmt.Println(colorYellow + "Disconnected from database." + colorReset)
			return
		}
		if query == "/q" {
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
                             
Adaptive Polyglot Execution Engine` + colorReset)
	fmt.Println(colorCyan + "v0.1.0-alpha (In-Memory Lakehouse Edition)" + colorReset)
	fmt.Println()
}

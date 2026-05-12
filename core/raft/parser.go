package raft

import (
	"errors"
	"fmt"

	"github.com/xwb1989/sqlparser"
)

// ParsedQuery represents a simplified version of the AST
// that we will eventually serialize and send to the Haskell Optimizer.
type ParsedQuery struct {
	Type       string
	TableNames []string
	// Note: In future phases we will add WhereConditions, GroupBy, etc.
}

// ParseSQL takes a raw SQL string from the user and parses it into a structural Go AST.
func ParseSQL(sqlString string) (*ParsedQuery, error) {
	// 1. Use the battle-tested library to generate the massive AST
	stmt, err := sqlparser.Parse(sqlString)
	if err != nil {
		return nil, fmt.Errorf("syntax error in SQL: %w", err)
	}

	result := &ParsedQuery{}

	// 2. Walk the AST to extract the components we need
	switch stmt := stmt.(type) {
	case *sqlparser.Select:
		result.Type = "SELECT"
		
		// Loop through the FROM clause to find all the tables being queried
		for _, tableExpr := range stmt.From {
			switch t := tableExpr.(type) {
			case *sqlparser.AliasedTableExpr:
				if tableName, ok := t.Expr.(sqlparser.TableName); ok {
					result.TableNames = append(result.TableNames, tableName.Name.String())
				}
			case *sqlparser.JoinTableExpr:
				// If it's a massive join (like the 8-table school query), we extract both sides
				if left, ok := t.LeftExpr.(*sqlparser.AliasedTableExpr); ok {
					if tableName, ok := left.Expr.(sqlparser.TableName); ok {
						result.TableNames = append(result.TableNames, tableName.Name.String())
					}
				}
				if right, ok := t.RightExpr.(*sqlparser.AliasedTableExpr); ok {
					if tableName, ok := right.Expr.(sqlparser.TableName); ok {
						result.TableNames = append(result.TableNames, tableName.Name.String())
					}
				}
			}
		}
	case *sqlparser.Insert:
		result.Type = "INSERT"
	case *sqlparser.Update:
		result.Type = "UPDATE"
	case *sqlparser.Delete:
		result.Type = "DELETE"
	default:
		return nil, errors.New("unsupported SQL statement type")
	}

	return result, nil
}

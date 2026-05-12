package raft

import (
	"testing"
)

func TestParseSQL(t *testing.T) {
	// The complex query from your school database
	sql := `SELECT schools.board, AVG(marks.score) as avg_math_score
FROM marks
JOIN enrollments ON marks.enrollment_id = enrollments.id
WHERE subjects.name = 'Mathematics' AND classrooms.grade = '8'
GROUP BY schools.board`

	ast, err := ParseSQL(sql)
	if err != nil {
		t.Fatalf("Failed to parse: %v", err)
	}

	t.Logf("Successfully parsed SQL into Go struct!")
	t.Logf("Query Type: %s", ast.Type)
	t.Logf("Tables Found: %v", ast.TableNames)
}

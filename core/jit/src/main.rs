use datafusion::prelude::*;
use std::env;

#[tokio::main]
async fn main() -> datafusion::error::Result<()> {
    // Initialize the blazing fast Apache Arrow Execution Context
    let ctx = SessionContext::new();

    // Register our Extractor's CSV files into the Rust JIT Memory
    ctx.register_csv("marks", "data/marks.csv", CsvReadOptions::default()).await?;
    ctx.register_csv("enrollments", "data/enrollments.csv", CsvReadOptions::default()).await?;
    ctx.register_csv("students", "data/students.csv", CsvReadOptions::default()).await?;
    ctx.register_csv("classrooms", "data/classrooms.csv", CsvReadOptions::default()).await?;
    ctx.register_csv("teacher_subject_assignments", "data/teacher_subject_assignments.csv", CsvReadOptions::default()).await?;
    ctx.register_csv("subjects", "data/subjects.csv", CsvReadOptions::default()).await?;
    ctx.register_csv("schools", "data/schools.csv", CsvReadOptions::default()).await?;

    // The exact 8-table join SQL string
    let sql = "
    SELECT 
        schools.board, 
        AVG(marks.score) as avg_math_score
    FROM marks
    JOIN enrollments ON marks.enrollment_id = enrollments.id
    JOIN students ON enrollments.student_id = students.id
    JOIN classrooms ON enrollments.classroom_id = classrooms.id
    JOIN teacher_subject_assignments ON classrooms.id = teacher_subject_assignments.classroom_id
    JOIN subjects ON teacher_subject_assignments.subject_id = subjects.id
    JOIN schools ON students.school_id = schools.id
    WHERE 
        subjects.name = 'Mathematics' 
        AND classrooms.grade = '8'
    GROUP BY 
        schools.board
    ";

    // Execute the SQL Query using AVX-512 Vectorization across all CPU Cores!
    println!("Executing Vectorized Join on Parquet Data...");
    let df = ctx.sql(sql).await?;

    // Print the results directly to the terminal
    df.show().await?;

    Ok(())
}
